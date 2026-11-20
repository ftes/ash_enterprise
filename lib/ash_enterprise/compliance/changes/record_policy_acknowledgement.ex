defmodule AshEnterprise.Compliance.Changes.RecordPolicyAcknowledgement do
  @moduledoc """
  On a signer's `sign`: when the request is an acknowledgement that shows a policy version,
  appends the person's `policy_acknowledged` events
  (`AshEnterprise.Compliance.PolicyAcknowledgement.record_signed/2`).

  In `after_action`, inside the signing transaction: an acknowledgement is recorded with its
  compliance events or not at all, so a criterion never misses an acknowledgement that
  happened. Every other signer action passes through untouched.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Compliance.PolicyAcknowledgement

  @impl true
  def change(%{action: %{name: :sign}} = changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, signer ->
      case PolicyAcknowledgement.record_signed(signer) do
        result when result in [:ok, :skip] -> {:ok, signer}
        {:error, error} -> {:error, error}
      end
    end)
  end

  def change(changeset, _opts, _context), do: changeset
end
