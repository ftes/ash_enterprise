defmodule AshEnterprise.Compliance.Changes.ReviewPolicyAcknowledgements do
  @moduledoc """
  On a policy's `mint`: every person in scope is evaluated again against the new set of
  current policies (`AshEnterprise.Compliance.PolicyAcknowledgement.record_published/2`), so
  publishing version 2 puts out everyone who held only version 1.

  In `after_action`, inside the publish transaction, after the previous version was
  superseded: the events see the set as it will be committed, and a publish that rolls
  back takes its events with it.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Compliance.PolicyAcknowledgement

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, policy ->
      case PolicyAcknowledgement.record_published(policy) do
        :ok -> {:ok, policy}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
