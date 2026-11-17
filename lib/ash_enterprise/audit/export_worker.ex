defmodule AshEnterprise.Audit.ExportWorker do
  @moduledoc """
  Ships committed audit events to the deployment's OTLP log endpoint, every minute
  (`config/config.exs` crontab), so the security rules in SigNoz read the audit chain itself
  rather than spans (`devenv/observability/security/`, ADR 0025 as amended).

  ## How

  For each chain (every organization's, and the chain with no tenant) it reads the events
  after that chain's `AshEnterprise.Audit.ExportCursor` through
  the `stream` callback of `AshEnterprise.Audit.EventSource`, in sequence order, a batch at a time. Each
  batch becomes one OTLP/HTTP JSON request (`AshEnterprise.Audit.OtlpExport`, posted by
  `AshEnterprise.Audit.OtlpExport.Client`). The cursor moves past a batch only when the
  endpoint answers 2xx.

  Only committed events are ever read: a rolled-back write leaves no row, so it exports
  nothing. Nothing here runs on the write path, so an endpoint that is down cannot fail, slow
  or roll back a write.

  ## Delivery: at least once, with a dedupe key

  A crash between the endpoint's 2xx and the cursor's update sends that batch again on the
  next run. `(audit.tenant_id, audit.sequence, audit.hash)` names one event exactly, so a
  consumer can drop the repeat. Nothing is lost by a crash; a duplicate is possible.

  ## Ordering, per chain

  Within a tenant's chain, `sequence` order is commit order (`AshEnterprise.Audit.EventLog`,
  "Something depends on that lock"), so a cursor on it skips nothing. The chain with no
  tenant has no such guarantee: an event that commits after a later-numbered one could be
  passed over. That chain is therefore read only up to events older than a settle window
  (`:settle_seconds`, default 60): a write whose transaction stays open longer than that
  can still be missed. Its events are exported best effort, and the
  refused-sign-in rule that counts them says so.

  ## Failure is recorded, and one chain does not stop the others

  A non-2xx answer or a transport error leaves the cursor where it was, sets the cursor's
  `failing_since` and `last_error`, emits `[:ash_enterprise, :audit, :export, :failed]`
  (measurement `count`, metadata `chain` and `reason`) and moves on to the next chain. A
  chain that raises is handled the same way. The next run after recovery exports the
  backlog, once.

  ## Bounded, and lag is visible

  One run sends at most `:max_batches` batches of `:batch_size` events per chain and stops
  starting new ones after `:deadline_ms`; the rest waits for the next run. Each run emits
  `[:ash_enterprise, :audit, :export]` with measurements `exported` (events acknowledged),
  `failed` (chains whose export failed) and `lag_seconds` (the age of the oldest event not
  yet exported, across chains). The `ash_enterprise.audit.export.*` metrics carry them
  (`AshEnterpriseWeb.Telemetry.audit_export_metrics/0`) and the `audit-export-stalled` rule
  alarms on them. Retention archives hot rows after ninety days and this reads the hot
  table only, so an export lagging that far would skip what was archived: the lag rule
  fires long before.

  ## Configuration

      config :ash_enterprise, AshEnterprise.Audit.ExportWorker,
        endpoint: "http://collector:4318",   # OTEL_EXPORTER_OTLP_ENDPOINT, in config/runtime.exs
        headers: "authorization=...",         # OTEL_EXPORTER_OTLP_HEADERS
        service_name: "ash_enterprise"        # OTEL_SERVICE_NAME

  With no endpoint the worker reads nothing, writes nothing, posts nothing and returns
  `{:ok, :not_configured}`: an unconfigured deployment exports nothing and says so in each
  job's result.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.{EventSource, OtlpExport}
  alias AshEnterprise.Audit.OtlpExport.Client
  alias AshEnterprise.Platform.SystemActor

  @event [:ash_enterprise, :audit, :export]
  @failed_event [:ash_enterprise, :audit, :export, :failed]

  @defaults [batch_size: 500, max_batches: 20, deadline_ms: 45_000, settle_seconds: 60]

  @doc "The telemetry event each run emits."
  def event, do: @event

  @doc "The telemetry event each failed chain export emits."
  def failed_event, do: @failed_event

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc """
  Exports every chain once. Options override the application config: `:endpoint`,
  `:headers`, `:service_name`, `:req_options`, `:batch_size`, `:max_batches`,
  `:deadline_ms`, `:settle_seconds`, `:now`.

  Returns `{:ok, :not_configured}` with no endpoint, otherwise
  `{:ok, %{exported: n, failed: [chain], lag_seconds: s}}`.
  """
  @spec run(keyword()) :: {:ok, :not_configured | map()}
  def run(opts \\ []) do
    config = Keyword.merge(@defaults, Application.get_env(:ash_enterprise, __MODULE__, []))
    config = Keyword.merge(config, opts)

    case config[:endpoint] do
      endpoint when is_binary(endpoint) and endpoint != "" -> {:ok, export(config)}
      _none -> {:ok, :not_configured}
    end
  end

  defp export(config) do
    config =
      config
      |> Keyword.put_new_lazy(:now, &DateTime.utc_now/0)
      |> Keyword.put(:started, System.monotonic_time(:millisecond))

    results = for chain <- chains(), do: {chain, export_chain(chain, config)}

    summary = %{
      exported: results |> Enum.map(fn {_, result} -> result.exported end) |> Enum.sum(),
      failed: for({chain, %{error: error}} <- results, error != nil, do: chain),
      lag_seconds:
        results |> Enum.map(fn {_, result} -> result.lag_seconds end) |> Enum.max(fn -> 0 end)
    }

    :telemetry.execute(
      @event,
      %{
        exported: summary.exported,
        failed: length(summary.failed),
        lag_seconds: summary.lag_seconds
      },
      %{}
    )

    summary
  end

  # Every organization's chain, the chain with no tenant, and any chain that already has a
  # cursor (an organization archived since keeps its cursor, and its events still go).
  defp chains do
    organizations =
      AshEnterprise.Accounts.list_organizations!(authorize?: false) |> Enum.map(& &1.id)

    cursors =
      Audit.list_export_cursors!(actor: SystemActor.oban())
      |> Enum.map(& &1.chain_organization_id)

    Enum.uniq([nil | organizations] ++ cursors)
  end

  defp export_chain(chain, config) do
    cursor = cursor!(chain)
    {cursor, exported, error} = batches(chain, cursor, config, 0, 0)

    if error, do: fail(chain, cursor, error)

    %{exported: exported, error: error, lag_seconds: lag(chain, cursor, config)}
  rescue
    exception ->
      reason = "raised: " <> (exception.__struct__ |> inspect() |> String.slice(0, 80))

      Logger.error(
        "The audit export of chain #{inspect(chain)} raised: #{Exception.message(exception)}"
      )

      emit_failed(chain, reason)
      %{exported: 0, error: reason, lag_seconds: 0}
  end

  defp batches(chain, cursor, config, batch, exported) do
    if batch >= config[:max_batches] or out_of_time?(config) do
      {cursor, exported, nil}
    else
      chain
      |> pending(cursor.last_sequence, config[:batch_size], config)
      |> send_batch(chain, cursor, config, batch, exported)
    end
  end

  defp send_batch([], _chain, cursor, _config, _batch, exported), do: {cursor, exported, nil}

  defp send_batch(events, chain, cursor, config, batch, exported) do
    case post(events, config) do
      :ok ->
        last = List.last(events).sequence

        cursor =
          Audit.advance_export_cursor!(cursor, last, length(events), actor: SystemActor.oban())

        batches(chain, cursor, config, batch + 1, exported + length(events))

      {:error, reason} ->
        {cursor, exported, reason}
    end
  end

  # The events after `after_sequence`. On the chain with no tenant, only those older than
  # the settle window, stopping at the first that is not, so the cursor never passes an
  # event that might still be preceded by one committing late.
  defp pending(chain, after_sequence, limit, config) do
    {:ok, {events, _last}} = EventSource.stream(chain, after_sequence, limit)

    case chain do
      nil ->
        settled = DateTime.add(config[:now], -config[:settle_seconds], :second)
        Enum.take_while(events, &(DateTime.compare(&1.occurred_at, settled) != :gt))

      _tenant ->
        events
    end
  end

  defp post(events, config) do
    body =
      OtlpExport.request_body(events,
        now: config[:now],
        service_name: config[:service_name] || "ash_enterprise"
      )

    Client.post_logs(config[:endpoint], body,
      headers: config[:headers],
      req_options: config[:req_options] || []
    )
  end

  defp fail(chain, cursor, reason) do
    Logger.warning("The audit export of chain #{inspect(chain)} failed: #{reason}")
    Audit.fail_export_cursor!(cursor, reason, actor: SystemActor.oban())
    emit_failed(chain, reason)
  end

  defp emit_failed(chain, reason),
    do: :telemetry.execute(@failed_event, %{count: 1}, %{chain: chain, reason: reason})

  # The age of the oldest event this chain has not exported yet; zero when there is none.
  defp lag(chain, cursor, config) do
    case EventSource.stream(chain, cursor.last_sequence, 1) do
      {:ok, {[event], _}} -> max(DateTime.diff(config[:now], event.occurred_at, :second), 0)
      _none -> 0
    end
  end

  defp cursor!(chain) do
    case Audit.export_cursor!(chain, actor: SystemActor.oban()) do
      nil -> Audit.start_export_cursor!(chain, actor: SystemActor.oban())
      cursor -> cursor
    end
  end

  defp out_of_time?(config),
    do: System.monotonic_time(:millisecond) - config[:started] > config[:deadline_ms]
end
