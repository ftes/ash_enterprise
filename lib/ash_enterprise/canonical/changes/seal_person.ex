defmodule AshEnterprise.Canonical.Changes.SealPerson do
  @moduledoc """
  On every `AshEnterprise.Canonical.Person` create and update: an `email`
  argument becomes the person's blind index and their address sealed under
  their own erasure scope (`AshEnterprise.Canonical.PersonSeal.put_email/3`),
  never a plaintext column. An upsert (`:upsert_from_source`) first finds the
  person the address already belongs to, under that address's lock.

  It also loads `email` on the result, so a caller reads back the address it
  wrote the way it reads one from a query.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.PersonSeal

  @impl true
  def change(changeset, _opts, _context) do
    changeset = Ash.Changeset.load(changeset, :email)

    case Ash.Changeset.fetch_argument(changeset, :email) do
      {:ok, email} -> PersonSeal.put_email(changeset, email, upsert?: upsert?(changeset))
      :error -> changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    case Ash.Changeset.fetch_argument(changeset, :email) do
      :error -> {:ok, change(changeset, opts, context)}
      {:ok, _email} -> {:not_atomic, "sealing an address needs the person's erasure scope key"}
    end
  end

  defp upsert?(%{action_type: :create, action: %{upsert?: true}}), do: true
  defp upsert?(_changeset), do: false
end
