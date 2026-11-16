defmodule AshEnterprise.AI.ModelCall.Preparations.ForTenant do
  @moduledoc """
  Narrows a `AshEnterprise.AI.ModelCall` read to the calls made for the tenant
  the read runs in. `ModelCall` is not a multitenant resource (a call can be
  made for no tenant), so the read's tenant does not narrow it by itself.

  A read with no tenant, or a tenant that is not an organisation id, matches
  nothing: no caller reads another tenant's calls, or the tenantless ones,
  through this action by leaving the tenant out.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case organization_id(query.tenant) do
      nil -> Ash.Query.filter(query, false)
      id -> Ash.Query.filter(query, organization_id == ^id)
    end
  end

  defp organization_id(%{id: id}), do: organization_id(id)

  defp organization_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp organization_id(_none), do: nil
end
