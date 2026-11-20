defmodule AshEnterprise.Accounts.Preparations.AskedToAcknowledge do
  @moduledoc """
  The people a policy review asks to acknowledge the organization's policies
  (`User.asked_to_acknowledge`): every active user whose home business unit is in the
  organization.

  The same rule a signer row holds a person to (`AshEnterprise.Signatures.Changes.FromUser`),
  so everyone this read returns can be asked. It is one read so that narrowing who is asked,
  by a role or a team, is a change here and nowhere else.

  The organization's business units are read once, by id, without authorization: which units
  are the organization's is bookkeeping, and the read itself is authorized as its caller.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit

  @impl true
  def prepare(query, _opts, _context) do
    organization_id = Ash.Query.get_argument(query, :organization_id)

    unit_ids =
      BusinessUnit
      |> Ash.Query.filter(organization_id == ^organization_id)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false, tenant: organization_id)
      |> Enum.map(& &1.id)

    Ash.Query.filter(
      query,
      lifecycle_status == :active and owning_business_unit_id in ^unit_ids
    )
  end
end
