defmodule AshEnterprise.Canonical.PersonSeal do
  @moduledoc """
  How a `AshEnterprise.Canonical.Person` keeps its address sealed (ADR 0024).

  Each person has an erasure scope of their own: `kind: :data_subject`, ref
  `canonical_person:<id>`, an opaque id that never names them. The address is
  stored only as ciphertext sealed under that scope's key
  (`encrypted_email`, read back through
  `AshEnterprise.Erasure.Calculations.Unseal` as `email`), and found by its
  blind index (`email_bidx`, `AshEnterprise.Erasure.BlindIndex`). Shredding
  the scope makes the address unreadable everywhere it was sealed, the row
  and its audit copy alike.

  The scope is opened the first time something is sealed for the person, by
  the system actor, as the other scope openers do
  (`AshEnterprise.Credentialing.Changes.OpenClinicianScope`): a tenant role
  cannot write `AshEnterprise.Erasure.Scope`, and opening one says nothing
  about content. A shredded scope is never reopened, and nothing new is
  sealed under it.

  `put_email/2` is the one way any write sets a person's address: the
  projectors' upsert and the MDM writes go through
  `AshEnterprise.Canonical.Changes.SealPerson`, and the merge and the
  unmerge call it directly.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{BlindIndex, Keyring, Scope}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo.AdvisoryLock

  @label "Person"
  @address_lock "canonical.person.address"

  @doc "The erasure scope ref of the person with `id`."
  @spec scope_ref(Ash.UUID.t()) :: String.t()
  def scope_ref(id), do: "canonical_person:#{id}"

  @doc """
  Sets the address a person write stores: its blind index now, the sealed
  value inside the write's transaction, under the person's own scope. `nil`
  or blank clears both.

  On an upsert (`upsert?: true`) the write first takes the address's lock
  and looks for the person the address already belongs to, so the address
  is sealed under that person's scope and two concurrent projections of one
  new address end with one row and one scope.
  """
  @spec put_email(Ash.Changeset.t(), String.t() | Ash.CiString.t() | nil, keyword()) ::
          Ash.Changeset.t()
  def put_email(changeset, email, opts \\ []) do
    if blank?(email) do
      changeset
      |> Ash.Changeset.force_change_attribute(:email_bidx, nil)
      |> Ash.Changeset.force_change_attribute(:encrypted_email, nil)
      |> Ash.Changeset.force_change_attribute(:legacy_email, nil)
    else
      # The index is computed in the hook: the tenant it is unique in may be
      # given to the action call rather than to the changeset.
      Ash.Changeset.before_action(
        changeset,
        &seal_email(&1, email, Keyword.put(opts, :email, email))
      )
    end
  end

  defp blank?(nil), do: true
  defp blank?(email), do: BlindIndex.normalize(email) == ""

  defp seal_email(changeset, email, opts) do
    bidx = BlindIndex.of(changeset.tenant, email)
    changeset = Ash.Changeset.force_change_attribute(changeset, :email_bidx, bidx)

    with {:ok, changeset, scope_id} <- resolve_scope(changeset, bidx, opts),
         :ok <- live!(scope_id),
         {:ok, sealed} <- seal_term(scope_id, Ash.CiString.new(to_string(email))) do
      changeset
      |> Ash.Changeset.force_change_attribute(:erasure_scope_id, scope_id)
      |> Ash.Changeset.force_change_attribute(:encrypted_email, sealed)
      |> Ash.Changeset.force_change_attribute(:legacy_email, nil)
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, field: :erasure_scope_id, message: message)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # An upsert: the address's lock, then the person it already belongs to.
  # The audit-log lock first, as every MDM path takes it
  # (`AshEnterprise.Mdm.Refold.lock!/2`), so the two are always ordered the
  # same way.
  defp resolve_scope(%{action_type: :create} = changeset, bidx, opts) do
    if Keyword.get(opts, :upsert?, false) do
      tenant = to_string(changeset.tenant)
      AdvisoryLock.xact_lock_audit_log!(Person, changeset.tenant)
      AdvisoryLock.xact_lock!(@address_lock, tenant <> ":" <> Base.encode16(bidx))

      case existing(changeset, bidx, Keyword.fetch!(opts, :email)) do
        {:ok, %Person{} = person} -> person_scope(changeset, person)
        {:ok, nil} -> new_person_scope(changeset)
        {:error, error} -> {:error, error}
      end
    else
      new_person_scope(changeset)
    end
  end

  defp resolve_scope(changeset, _bidx, _opts), do: person_scope(changeset, changeset.data)

  defp person_scope(changeset, %{erasure_scope_id: scope_id}) when is_binary(scope_id),
    do: {:ok, changeset, scope_id}

  defp person_scope(changeset, %{id: id}) do
    with {:ok, scope_id} <- ensure_scope(id), do: {:ok, changeset, scope_id}
  end

  # A pinned id (the MDM replay) finds the scope it had; a fresh one opens one.
  defp new_person_scope(changeset) do
    id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()

    with {:ok, scope_id} <- ensure_scope(id) do
      {:ok, Ash.Changeset.force_change_attribute(changeset, :id, id), scope_id}
    end
  end

  # The person the address belongs to: by its blind index, else (a row from
  # before the seal) by the plaintext column the expand migration keeps,
  # which is sealed in place first so the upsert then meets it on the index.
  defp existing(changeset, bidx, email) do
    case read_one(Ash.Query.filter(Person, email_bidx == ^bidx), changeset.tenant) do
      {:ok, nil} -> legacy(changeset, email)
      other -> other
    end
  end

  defp legacy(changeset, email) do
    address = email |> to_string() |> String.trim()

    Person
    |> Ash.Query.filter(is_nil(email_bidx) and legacy_email == ^Ash.CiString.new(address))
    |> read_one(changeset.tenant)
    |> case do
      {:ok, %Person{} = person} -> seal_legacy(person, changeset.tenant)
      other -> other
    end
  end

  defp read_one(query, tenant) do
    query
    |> Ash.Query.limit(1)
    |> Ash.read_one(tenant: tenant, authorize?: false)
  end

  defp seal_legacy(person, tenant) do
    person
    |> Ash.Changeset.for_update(:seal_legacy, %{}, tenant: tenant, authorize?: false)
    |> Ash.update(tenant: tenant, authorize?: false)
  end

  @doc """
  `merge_provenance` as it is stored: the loser's prior address sealed under
  the loser's own scope (`"prior_email_sealed"`), never in the clear, and no
  copy of the merged values. Provenance already in that form comes back
  unchanged. `person` is the record the provenance belongs to (a changeset
  or a person), whose scope is opened if it has none.
  """
  @spec seal_provenance(Ash.Changeset.t() | struct(), map() | nil) ::
          {:ok, map() | nil} | {:error, String.t()}
  def seal_provenance(_person, nil), do: {:ok, nil}

  def seal_provenance(person, provenance) when is_map(provenance) do
    cleaned = Map.drop(provenance, ["merged_attrs", "prior_email"])

    case provenance["prior_email"] do
      email when is_binary(email) and email != "" ->
        with {:ok, scope_id} <- scope_of(person),
             {:ok, sealed} <- seal_term(scope_id, email) do
          {:ok, Map.put(cleaned, "prior_email_sealed", sealed)}
        else
          {:error, error} when is_binary(error) -> {:error, error}
          {:error, error} -> {:error, Exception.message(error)}
        end

      _none ->
        {:ok, cleaned}
    end
  end

  @doc """
  The loser's prior address from `merge_provenance`: unsealed, or the
  plaintext a merge recorded before the seal. nil when there is none or its
  scope has been shredded.
  """
  @spec prior_email(map() | nil) :: String.t() | nil
  def prior_email(%{"prior_email_sealed" => sealed}) when is_binary(sealed) do
    case open_term(sealed) do
      {:ok, email} -> email
      :shredded -> nil
    end
  end

  def prior_email(%{"prior_email" => email}) when is_binary(email) and email != "", do: email
  def prior_email(_provenance), do: nil

  defp scope_of(%Ash.Changeset{} = changeset) do
    case Ash.Changeset.get_attribute(changeset, :erasure_scope_id) do
      nil -> ensure_scope(changeset.data.id)
      scope_id -> {:ok, scope_id}
    end
  end

  defp scope_of(%{erasure_scope_id: scope_id}) when is_binary(scope_id), do: {:ok, scope_id}
  defp scope_of(%{id: id}), do: ensure_scope(id)

  @doc """
  The live scope of the person with `id`, opened the first time. A shredded
  scope is an error: nothing new lands under it.
  """
  @spec ensure_scope(Ash.UUID.t()) :: {:ok, Ash.UUID.t()} | {:error, term()}
  def ensure_scope(id) do
    case Erasure.ensure_scope(:data_subject, scope_ref(id), %{label: @label},
           actor: SystemActor.system()
         ) do
      {:ok, %Scope{status: :active, id: scope_id}} ->
        {:ok, scope_id}

      {:ok, %Scope{}} ->
        {:error, "the person's erasure scope is shredded; nothing may land under it"}

      {:error, error} ->
        {:error, error}
    end
  end

  # Inside the write's transaction, under a FOR SHARE lock on the scope row,
  # as `AshEnterprise.Erasure.Changes.SealUnderScope` does: a shred racing
  # this write either reaches the row or refuses it.
  defp live!(scope_id) do
    Scope
    |> Ash.Query.filter(id == ^scope_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Scope{status: :active}} ->
        :ok

      {:ok, %Scope{status: :shredded}} ->
        {:error, "erasure scope #{scope_id} has been shredded; nothing may land under it"}

      {:ok, nil} ->
        {:error, "erasure scope #{scope_id} does not exist"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Seals `value` under `scope_id` in the stored form every sealed column here
  uses (base64 of the sealed binary of the value serialized as `ash_cloak`
  serializes it), so `AshEnterprise.Erasure.Calculations.Unseal` and the
  vault read it back.
  """
  @spec seal_term(Ash.UUID.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def seal_term(scope_id, %Ash.CiString{} = value) do
    {:ok, dumped} = Ash.Type.dump_to_embedded(:ci_string, value, [])
    seal_binary(scope_id, :erlang.term_to_binary({:__ash_cloak__, dumped}))
  end

  def seal_term(scope_id, value) when is_binary(value),
    do: seal_binary(scope_id, :erlang.term_to_binary(value))

  defp seal_binary(scope_id, plaintext) do
    case Keyring.seal(scope_id, plaintext) do
      {:ok, sealed} ->
        {:ok, Base.encode64(sealed)}

      {:error, :shredded} ->
        {:error, "erasure scope #{scope_id} has been shredded; nothing may land under it"}

      {:error, :unknown_scope} ->
        {:error, "erasure scope #{scope_id} does not exist"}
    end
  end

  @doc """
  Opens a string sealed by `seal_term/2`: `{:ok, value}`, or `:shredded`.
  """
  @spec open_term(String.t()) :: {:ok, term()} | :shredded
  def open_term(stored) do
    case stored |> Base.decode64!() |> Keyring.open!() do
      {:ok, plaintext} ->
        case Ash.Helpers.non_executable_binary_to_term(plaintext, [:safe]) do
          {:__ash_cloak__, dumped} -> {:ok, dumped}
          value -> {:ok, value}
        end

      {:shredded, _marker} ->
        :shredded
    end
  end
end
