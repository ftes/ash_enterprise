defmodule AshEnterprise.Compliance.Changes.ReviewPolicyAcknowledgements do
  @moduledoc """
  On a policy's `mint`: every person in scope is evaluated again against the new set of
  current policies (`AshEnterprise.Compliance.PolicyAcknowledgement.record_published/2`), so
  publishing version 2 puts out everyone who held only version 1.

  In `after_action`, inside the publish transaction, after the previous version was
  superseded: the events see the set as it will be committed, and a publish that rolls
  back takes its events with it.

  It also enqueues `AshEnterprise.Signatures.ReaskWorker` in the same transaction, which
  asks everyone again over the new set in the organization's current policy review: a
  person who is out because of the new version is asked to acknowledge it, not left with
  only the old request until next year.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Compliance.PolicyAcknowledgement
  alias AshEnterprise.Signatures.ReaskWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, policy ->
      with :ok <- PolicyAcknowledgement.record_published(policy),
           {:ok, _job} <- Oban.insert(ReaskWorker.job(policy.organization_id)) do
        {:ok, policy}
      end
    end)
  end
end
