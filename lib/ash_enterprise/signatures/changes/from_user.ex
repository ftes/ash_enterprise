defmodule AshEnterprise.Signatures.Changes.FromUser do
  @moduledoc """
  Fills a new signer from the user it names (`user_id`): the person must be an active user
  of the request's organization, their email is copied as the signer's `email`, and the
  signer is sealed under the person's own erasure scope (`data_subject`,
  `AshEnterprise.Execution.Changes.SealingScope.scope_ref/1`, the one scope per person that
  erasing them reaches). `AshEnterprise.Erasure.Changes.SealUnderScope` then seals the
  email under it.

  The email is never taken as input: it is the account's, as it stood when the person was
  asked. A user has no display name here, so `name` stays empty.

  Runs in `change/3`, before the seal, which needs the scope and the value on the
  changeset. The user and their business unit are read without authorization: which person
  a signer is and which key seals the row are the action's bookkeeping, and the action
  itself is authorized as its caller. A shredded scope is refused: nothing new lands under
  it.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Platform.SystemActor

  @label "Signature requests"

  @impl true
  def change(changeset, _opts, _context) do
    with true <- changeset.valid?,
         user_id when is_binary(user_id) <- Ash.Changeset.get_attribute(changeset, :user_id) do
      case fill(changeset, user_id) do
        {:ok, changeset} ->
          changeset

        {:error, field, message} ->
          Ash.Changeset.add_error(changeset, field: field, message: message)
      end
    else
      _ -> changeset
    end
  end

  defp fill(changeset, user_id) do
    with {:ok, user} <- member(user_id, changeset.tenant),
         {:ok, scope_id} <- scope(user.id) do
      {:ok,
       changeset
       |> Ash.Changeset.force_change_attribute(:erasure_scope_id, scope_id)
       |> Ash.Changeset.set_argument(:email, to_string(user.email))}
    end
  end

  defp member(user_id, tenant) do
    with {:ok, %User{lifecycle_status: :active} = user} <- read_one(User, user_id),
         {:ok, %{organization_id: organization_id}} <-
           read_one(BusinessUnit, user.owning_business_unit_id),
         true <- to_string(organization_id) == to_string(tenant) do
      {:ok, user}
    else
      _ -> {:error, :user_id, "is not an active user of this organization"}
    end
  end

  defp read_one(_resource, nil), do: {:ok, nil}

  defp read_one(resource, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(authorize?: false)
  end

  defp scope(user_id) do
    case Erasure.ensure_scope(:data_subject, SealingScope.scope_ref(user_id), %{label: @label},
           actor: SystemActor.system()
         ) do
      {:ok, %{status: :active, id: scope_id}} -> {:ok, scope_id}
      {:ok, _shredded} -> {:error, :erasure_scope_id, "the person's erasure scope is shredded"}
      {:error, error} -> {:error, :erasure_scope_id, Exception.message(error)}
    end
  end
end
