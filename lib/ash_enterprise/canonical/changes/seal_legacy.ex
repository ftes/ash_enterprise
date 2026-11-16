defmodule AshEnterprise.Canonical.Changes.SealLegacy do
  @moduledoc """
  `Person.seal_legacy`: seals a row written before addresses were sealed.

  The expand migration keeps the old plaintext `email` column (read here as
  `legacy_email`) until the contract migration drops it. This moves its value
  under the person's own scope, computes the blind index, and blanks the
  plaintext. A merge recorded before the seal kept the loser's prior address
  and the merged values in `merge_provenance` in the clear: the prior address
  is sealed the same way and the merged values, which nothing reads back,
  are dropped.

  Run for every row by `mix ash_enterprise.erasure.seal_people`, and for one
  row by the projectors' upsert when it meets an address that only the old
  column holds.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.PersonSeal

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> seal_address(changeset.data.legacy_email)
    |> Ash.Changeset.before_action(&seal_provenance/1)
  end

  defp seal_address(changeset, nil), do: changeset
  defp seal_address(changeset, email), do: PersonSeal.put_email(changeset, email)

  defp seal_provenance(changeset) do
    with_scope(changeset, changeset.data.merge_provenance)
  end

  # A merged loser whose address was released has no address to seal, only
  # the prior one in its provenance: its scope is opened for that.
  defp with_scope(changeset, %{"prior_email" => email} = provenance)
       when is_binary(email) and email != "" do
    if Ash.Changeset.get_attribute(changeset, :erasure_scope_id) do
      store(changeset, provenance)
    else
      case PersonSeal.ensure_scope(changeset.data.id) do
        {:ok, scope_id} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:erasure_scope_id, scope_id)
          |> store(provenance)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, field: :erasure_scope_id, message: inspect(error))
      end
    end
  end

  defp with_scope(changeset, provenance), do: store(changeset, provenance)

  defp store(changeset, provenance) do
    case PersonSeal.seal_provenance(changeset, provenance) do
      {:ok, provenance} when provenance == changeset.data.merge_provenance ->
        changeset

      {:ok, provenance} ->
        Ash.Changeset.force_change_attribute(changeset, :merge_provenance, provenance)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, field: :merge_provenance, message: error)
    end
  end
end
