defmodule AshEnterprise.Signatures.ReminderWorker do
  @moduledoc """
  Reminds the people a signature or acknowledgement request is waiting on, on the host's
  schedule: once a day (the crontab in `config/config.exs`), every signer whose turn it is
  (`notified` or `viewed`, on a request still open) and who has heard nothing for the
  interval is reminded once.

  "Heard nothing" is the later of when they were notified and when they were last reminded
  (their last `reminded` event). The interval is a host setting, seven days unless set:

      config :ash_enterprise, AshEnterprise.Signatures.ReminderWorker, interval_days: 7

  A reminder is the signer's `remind` act, which only the job runner takes
  (`SystemActor.oban/0`; the action is machinery-only and declared as an effect). It records
  a `reminded` event in the person's own chain of events; with the in-app provider that
  event is the reminder, shown where the person acknowledges. A signer who has signed,
  declined or been withdrawn, or whose request has ended, is never reminded.

  Signers are read across organizations as the job runner, by status and time only, and
  each is reminded in its own organization. A failure is logged and the rest go on.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  require Ash.Query
  require Logger

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.{Signer, SignerEvent}

  @default_interval_days 7
  @waiting [:notified, :viewed]
  @open [:sent, :partially_signed]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, remind_due(DateTime.utc_now())}
  end

  @doc "Days a signer waits without word before a reminder: the host setting, 7 by default."
  @spec interval_days() :: pos_integer()
  def interval_days do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval_days, @default_interval_days)
  end

  @doc """
  Reminds every signer due a reminder at `now`: `%{reminded: n, failed: n}`. `now` is the
  clock, passed in so a test can move it; `interval_days:` overrides the setting.
  """
  @spec remind_due(DateTime.t(), keyword()) :: %{
          reminded: non_neg_integer(),
          failed: non_neg_integer()
        }
  def remind_due(%DateTime{} = now, opts \\ []) do
    interval = Keyword.get(opts, :interval_days, interval_days())
    cutoff = DateTime.add(now, -interval * 86_400, :second)

    cutoff
    |> due()
    |> Enum.reduce(%{reminded: 0, failed: 0}, fn signer, tally ->
      case remind(signer) do
        :ok -> Map.update!(tally, :reminded, &(&1 + 1))
        :error -> Map.update!(tally, :failed, &(&1 + 1))
      end
    end)
  end

  @doc "The signers due a reminder: waiting on them, and nothing heard since `cutoff`."
  @spec due(DateTime.t()) :: [struct()]
  def due(cutoff) do
    waiting = waiting(cutoff)
    last = last_reminded(Enum.map(waiting, & &1.id))

    Enum.filter(waiting, fn signer ->
      heard = Enum.max([signer.notified_at, Map.get(last, signer.id)], &later?/2)
      DateTime.compare(heard, cutoff) != :gt
    end)
  end

  defp later?(nil, _other), do: false
  defp later?(_one, nil), do: true
  defp later?(one, other), do: DateTime.compare(one, other) != :lt

  defp waiting(cutoff) do
    Signer
    |> Ash.Query.filter(
      status in ^@waiting and not is_nil(notified_at) and notified_at <= ^cutoff and
        request.status in ^@open
    )
    |> Ash.read!(actor: SystemActor.oban(), tenant: nil)
  end

  defp last_reminded([]), do: %{}

  defp last_reminded(signer_ids) do
    SignerEvent
    |> Ash.Query.filter(signer_id in ^signer_ids and type == :reminded)
    |> Ash.Query.select([:signer_id, :occurred_at])
    |> Ash.read!(actor: SystemActor.oban(), tenant: nil)
    |> Enum.group_by(& &1.signer_id, & &1.occurred_at)
    |> Map.new(fn {signer_id, times} -> {signer_id, Enum.max(times, DateTime)} end)
  end

  defp remind(signer) do
    case Signatures.remind_signer(signer,
           actor: SystemActor.oban(),
           tenant: signer.organization_id
         ) do
      {:ok, _reminded} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "signature reminder failed for signer #{signer.id}: #{Exception.message(error)}"
        )

        :error
    end
  end
end
