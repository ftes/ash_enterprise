defmodule AshEnterprise.Canonical.Preparations.ByAddress do
  @moduledoc """
  `Person.by_address`: the person an exact address belongs to, found through
  its blind index (`AshEnterprise.Erasure.BlindIndex`). The address is sealed,
  so the database can only match it whole: case and surrounding space aside,
  a part of an address finds nobody.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Erasure.BlindIndex

  @impl true
  def prepare(query, _opts, _context) do
    case BlindIndex.of(query.tenant, Ash.Query.get_argument(query, :email)) do
      nil -> Ash.Query.filter(query, false)
      bidx -> Ash.Query.filter(query, email_bidx == ^bidx)
    end
  end
end
