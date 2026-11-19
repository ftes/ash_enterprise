defmodule AshEnterprise.Signatures.Changes.ScopeFromSigner do
  @moduledoc """
  Names the erasure scope a signer event's personal fields are sealed under: its signer's
  (`erasure_scope_id`, the person's own scope), before
  `AshEnterprise.Erasure.Changes.SealUnderScope` seals them.

  An event with no signer (a signed copy that arrived as a document version, which is the
  request's rather than one person's) has no person's scope. It is recorded when it carries
  none of the personal fields, and refused when it carries one: personal data is never
  stored unsealed or under a guessed scope. This host offers only the in-platform provider,
  so every event it records names its signer.

  The signer is read without authorization, in the event's tenant: which key seals the row
  is the write's bookkeeping, and the write is the package's own consequence of an act the
  host already authorized.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Signatures.Signer

  @payload AshSignatures.payload_fields(:signer_event)

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :signer_id) do
      nil -> without_signer(changeset)
      signer_id -> from_signer(changeset, signer_id)
    end
  end

  defp from_signer(changeset, signer_id) do
    Signer
    |> Ash.Query.filter(id == ^signer_id)
    |> Ash.Query.select([:erasure_scope_id])
    |> Ash.read_one(tenant: changeset.tenant, authorize?: false)
    |> case do
      {:ok, %{erasure_scope_id: scope_id}} when is_binary(scope_id) ->
        Ash.Changeset.force_change_attribute(changeset, :erasure_scope_id, scope_id)

      {:ok, _none} ->
        Ash.Changeset.add_error(changeset, field: :signer_id, message: "no such signer here")

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp without_signer(changeset) do
    if Enum.all?(@payload, &(Ash.Changeset.get_argument(changeset, &1) in [nil, ""])) do
      Enum.reduce(@payload, changeset, &Ash.Changeset.delete_argument(&2, &1))
    else
      Ash.Changeset.add_error(changeset,
        field: :signer_id,
        message:
          "an event that carries personal fields must name its signer, whose scope seals them"
      )
    end
  end
end
