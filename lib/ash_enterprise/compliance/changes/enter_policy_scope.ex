defmodule AshEnterprise.Compliance.Changes.EnterPolicyScope do
  @moduledoc """
  On a user's `:assign_to_business_unit` and `:activate`: an active person in one of an
  organization's business units is in scope for its policy acknowledgements, so their
  standing is recorded for CC1.1, CC2.2 and CC5.3
  (`AshEnterprise.Compliance.PolicyAcknowledgement.record_entered/4`, reason `"joined"` or
  `"activated"`).

  Without it, findings change only when someone signs or a version is published, and both
  reach only the people in scope at that moment: a person who joined after the last
  publish would have no finding at all, and a person reactivated after a new version would
  keep the finding they had on the old one.

  In `after_action`, inside the user's transaction, so the user and their standing commit
  together. Nothing is written when the organization has no current policy, or the user is
  not active or has no business unit. The unit is read without authorization: which
  organization a person belongs to is the bookkeeping of a write that was itself
  authorized.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Compliance.PolicyAcknowledgement

  @impl true
  def change(changeset, _opts, _context) do
    reason = reason(changeset.action.name)

    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case enter(user, reason) do
        :ok -> {:ok, user}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp reason(:activate), do: "activated"
  defp reason(_assign), do: "joined"

  defp enter(%{lifecycle_status: :active, owning_business_unit_id: unit_id} = user, reason)
       when is_binary(unit_id) do
    case organization_of(unit_id) do
      nil -> :ok
      organization_id -> PolicyAcknowledgement.record_entered(organization_id, user.id, reason)
    end
  end

  defp enter(_user, _reason), do: :ok

  defp organization_of(unit_id) do
    BusinessUnit
    |> Ash.Query.filter(id == ^unit_id)
    |> Ash.Query.select([:organization_id])
    |> Ash.read_one!(authorize?: false)
    |> case do
      %{organization_id: organization_id} -> organization_id
      nil -> nil
    end
  end
end
