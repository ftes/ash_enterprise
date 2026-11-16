defmodule AshEnterprise.Audit.Verify do
  @moduledoc """
  Walks the audit log's hash chains and reports where, if anywhere, one stops adding up.

  The body of `mix ash_enterprise.audit.verify` and `AshEnterprise.Release.audit_verify/2`:
  a release has no Mix, so the check lives here and both are thin callers. It reads through
  `AshEvents.Chain` and writes nothing. See `AshEvents.Chain` for what each kind of finding
  means and why rows predating the chain are skipped rather than reported.

  One chain that cannot be read (its verification raises) does not stop the others: it is
  reported with the error, every other chain is still verified, and the status is
  `:broken`, so the task and the release command exit non-zero.
  """

  alias AshEnterprise.Audit.EventLog

  @type report :: %{
          status: :ok | :broken,
          chains: [map()],
          checked: non_neg_integer(),
          findings: non_neg_integer(),
          unreadable: non_neg_integer()
        }

  @doc """
  Verifies every chain, or only `tenant`'s (an organization id). `:verifier` replaces the
  function that verifies one chain (`AshEvents.Chain.verify/2`).
  """
  @spec report(String.t() | nil, keyword()) :: report()
  def report(tenant \\ nil, opts \\ []) do
    verifier = Keyword.get(opts, :verifier, &AshEvents.Chain.verify/2)

    chains =
      case tenant do
        nil ->
          AshEvents.Chain.verify_all(EventLog, on_error: :return, verifier: verifier)

        tenant ->
          case AshEvents.Chain.verify_isolated(EventLog, tenant, verifier) do
            {:ok, chain} -> [chain]
            {:error, message} -> [unreadable(tenant, message)]
          end
      end

    findings = chains |> Enum.flat_map(& &1.findings) |> length()
    unreadable = Enum.count(chains, &Map.has_key?(&1, :error))

    %{
      status: if(AshEvents.Chain.clean?(chains), do: :ok, else: :broken),
      chains: chains,
      checked: chains |> Enum.map(& &1.checked) |> Enum.sum(),
      findings: findings,
      unreadable: unreadable
    }
  end

  # The shape `AshEvents.Chain.verify_all/2` gives a chain whose verification raised.
  defp unreadable(partition, message) do
    %{
      partition: partition,
      anchored_after: nil,
      checked: 0,
      skipped_unchained_prefix: 0,
      findings: [],
      error: message
    }
  end

  @doc "The report as lines of text, one block per chain and a closing verdict."
  @spec lines(report()) :: [String.t()]
  def lines(%{chains: chains} = report) do
    Enum.flat_map(chains, &chain_lines/1) ++ [verdict(report)]
  end

  defp chain_lines(%{partition: org, checked: checked} = chain) do
    skipped =
      if chain.skipped_unchained_prefix > 0,
        do: ["  #{chain.skipped_unchained_prefix} event(s) predate the chain and were skipped."],
        else: []

    unread =
      case chain do
        %{error: message} -> ["  could not be verified: #{message}"]
        _read -> []
      end

    ["", "Chain #{org || "(no tenant)"} -- #{checked} event(s) checked"] ++
      unread ++
      skipped ++
      Enum.map(chain.findings, fn f ->
        "  seq #{f.sequence}  #{f.problem}  #{f.id}  #{f.occurred_at}"
      end)
  end

  defp verdict(%{status: :ok} = report),
    do: "\n#{report.checked} events across #{length(report.chains)} chain(s) verified. No breaks."

  defp verdict(%{unreadable: 0} = report),
    do: "\n#{report.findings} finding(s). The audit log has been modified."

  defp verdict(report),
    do:
      "\n#{report.findings} finding(s); #{report.unreadable} chain(s) could not be verified. " <>
        "The audit log is not known to be intact."
end
