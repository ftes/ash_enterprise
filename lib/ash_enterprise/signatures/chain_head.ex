defmodule AshEnterprise.Signatures.ChainHead do
  @moduledoc """
  The head of a tenant's audit chain (`AshEnterprise.Audit.EventLog`): the hash of its last
  event, which each signature completion records beside its own hash, so the completion
  points at the chain it was written next to.

  Read through Ash as the process actor, as `AshEnterprise.Audit.EventSource` reads the
  log. A `nil` tenant reads the chain of events with no tenant, never every tenant's. An
  empty chain has no head (`nil`).
  """

  @behaviour AshSignatures.ChainHead

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def head(tenant) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> null_chain(is_nil(tenant))
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      [%{hash: hash}] -> hash
      [] -> nil
    end
  end

  defp null_chain(query, true), do: Ash.Query.filter(query, is_nil(organization_id))
  defp null_chain(query, false), do: query
end
