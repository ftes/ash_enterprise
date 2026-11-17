defmodule AshEnterprise.Erasure.PersonErasure.Subject do
  @moduledoc """
  What one address reaches in one tenant: the rows `AshEnterprise.Erasure.PersonErasure`'s
  `erase` shreds, blanks or deletes, found without writing anything. The dry run of
  `mix ash_enterprise.erasure.erase_person` prints its counts; the erase finds it again
  inside its own transaction, under the address's lock, and acts on that.

  ## The people

  A `AshEnterprise.Canonical.Person` is the address's when

    * its blind index is the address's (`AshEnterprise.Erasure.BlindIndex`), or, for a
      row written before addresses were sealed, its plaintext column holds the address;
    * an attribute statement says its address was this one (`AshEnterprise.Mdm.AttributeAssertion`,
      `attribute: "email"`). The projectors write a statement on the person the address
      resolved to, so a statement is the address's own record of who it was. This is
      what finds a merged-away record: a merge clears the loser's address and keeps its
      statements;
    * it was merged into one of those (`master_id`), because a merge is the decision that
      the two are one person.

  A golden that absorbed one of these and is not itself the address's (it has an
  address of its own) is a survivor: it is refolded without the erased statements, never
  erased.

  ## The rows around them

  Every attribute statement about those people, and any statement elsewhere spelling the
  address; the MDM staged rows whose mapped address is this one; their attendances and
  conversation participations (derived joins that hold ids, as
  `AshEnterprise.Canonical.Derive.forget_scope/1` deletes on a shred). Messages and events
  stay, with their foreign keys to the blanked person.

  ## The account

  A sign-in account (`AshEnterprise.Accounts.User`) with the address, whose business unit
  is in the tenant: the scopes their own content is sealed under, their requests'
  (`invocation_requester:<id>`) and each assistant thread's. The account row itself is not
  reached; offboarding is its own act.

  Reads only, with authorization off: the operator act that uses it is authorized as a
  whole (`AshEnterprise.Erasure.PersonErasure`), and a console dry run has no actor until
  one is resolved.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Assistant.Thread
  alias AshEnterprise.Canonical.{ConversationParticipant, EventAttendee, Person}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{BlindIndex, Scope}
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Mdm.{AttributeAssertion, StagedRecord}

  @golden_resource "AshEnterprise.Canonical.Person"

  @enforce_keys [:tenant]
  defstruct tenant: nil,
            people: [],
            survivor_ids: [],
            assertion_ids: [],
            staged_records: [],
            attendance_count: 0,
            participation_count: 0,
            scopes: [],
            account?: false,
            account_scopes: []

  @type t :: %__MODULE__{
          tenant: Ash.UUID.t(),
          people: [Person.t()],
          survivor_ids: [Ash.UUID.t()],
          assertion_ids: [Ash.UUID.t()],
          staged_records: [struct()],
          attendance_count: non_neg_integer(),
          participation_count: non_neg_integer(),
          scopes: [Scope.t()],
          account?: boolean(),
          account_scopes: [Scope.t()]
        }

  @doc "Everything `email` reaches in `tenant`. Reads only."
  @spec find(Ash.UUID.t(), String.t() | Ash.CiString.t()) :: t()
  def find(tenant, email) when is_binary(tenant) do
    normalized = BlindIndex.normalize(email)
    people = people(tenant, email, normalized)
    ids = Enum.map(people, & &1.id)
    account = account(tenant, normalized)

    %__MODULE__{
      tenant: tenant,
      people: people,
      survivor_ids: survivors(people),
      assertion_ids: assertion_ids(tenant, ids, normalized),
      staged_records: staged_records(tenant, normalized),
      attendance_count: count(EventAttendee, tenant, ids),
      participation_count: count(ConversationParticipant, tenant, ids),
      scopes: scopes(Enum.map(people, & &1.erasure_scope_id)),
      account?: not is_nil(account),
      account_scopes: account_scopes(tenant, account)
    }
  end

  @doc """
  The counts a receipt and a dry run report: never an address, a name, an index or
  an id that names a person. `scopes` and `account_scopes` are the ones still holding
  a key, which an erase shreds.
  """
  @spec counts(t()) :: %{String.t() => non_neg_integer()}
  def counts(%__MODULE__{} = subject) do
    %{
      "people" => length(subject.people),
      "merged_records" => Enum.count(subject.people, & &1.merged),
      "survivors_refolded" => length(subject.survivor_ids),
      "scopes" => subject.scopes |> active() |> length(),
      "scopes_already_shredded" => length(subject.scopes) - length(active(subject.scopes)),
      "account_scopes" => subject.account_scopes |> active() |> length(),
      "attribute_assertions" => length(subject.assertion_ids),
      "staged_records" => length(subject.staged_records),
      "attendances" => subject.attendance_count,
      "participations" => subject.participation_count
    }
  end

  @doc "The scopes still holding a key, which an erase shreds."
  @spec active([Scope.t()]) :: [Scope.t()]
  def active(scopes), do: Enum.filter(scopes, &(&1.status == :active))

  @doc "Whether the address reaches nothing at all in the tenant."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = subject) do
    subject.people == [] and subject.assertion_ids == [] and subject.staged_records == [] and
      subject.account_scopes == []
  end

  # --- people ------------------------------------------------------------------

  defp people(tenant, email, normalized) do
    bidx = BlindIndex.of(tenant, email)
    legacy = Ash.CiString.new(normalized)

    direct =
      Person
      |> Ash.Query.filter(email_bidx == ^bidx or (is_nil(email_bidx) and legacy_email == ^legacy))
      |> read!(tenant)

    stated = stated_golden_ids(tenant, normalized)
    found = MapSet.new(Enum.map(direct, & &1.id) ++ stated)

    found
    |> MapSet.to_list()
    |> with_absorbed(tenant, found)
    |> by_id(tenant)
  end

  # The records merged into any found person, until no new one turns up. A merge
  # repoints every absorbed record at the newest golden, so one pass is the normal
  # case; the loop is bounded by the rows there are.
  defp with_absorbed([], _tenant, found), do: MapSet.to_list(found)

  defp with_absorbed(frontier, tenant, found) do
    absorbed =
      Person
      |> Ash.Query.filter(master_id in ^frontier)
      |> Ash.Query.select([:id])
      |> read!(tenant)
      |> Enum.map(& &1.id)
      |> Enum.reject(&MapSet.member?(found, &1))

    with_absorbed(absorbed, tenant, MapSet.union(found, MapSet.new(absorbed)))
  end

  defp by_id([], _tenant), do: []

  defp by_id(ids, tenant) do
    Person
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> read!(tenant)
  end

  defp stated_golden_ids(tenant, normalized) do
    AttributeAssertion
    |> Ash.Query.filter(
      golden_resource == @golden_resource and attribute == "email" and
        string_downcase(string_trim(type(value[:v], :string))) == ^normalized
    )
    |> Ash.Query.select([:golden_id])
    |> read!(tenant)
    |> Enum.map(& &1.golden_id)
  end

  # Goldens outside the erased set that absorbed one inside it.
  defp survivors(people) do
    ids = MapSet.new(people, & &1.id)

    people
    |> Enum.filter(&(&1.merged and is_binary(&1.master_id)))
    |> Enum.map(& &1.master_id)
    |> Enum.reject(&MapSet.member?(ids, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- rows around them ----------------------------------------------------------

  defp assertion_ids(tenant, person_ids, normalized) do
    AttributeAssertion
    |> Ash.Query.filter(
      golden_resource == @golden_resource and
        (golden_id in ^person_ids or
           (attribute == "email" and
              string_downcase(string_trim(type(value[:v], :string))) == ^normalized))
    )
    |> Ash.Query.select([:id])
    |> read!(tenant)
    |> Enum.map(& &1.id)
  end

  defp staged_records(tenant, normalized) do
    StagedRecord
    |> Ash.Query.filter(
      string_downcase(string_trim(type(mapped[:email], :string))) == ^normalized
    )
    |> Ash.Query.sort(id: :asc)
    |> read!(tenant)
  end

  defp count(_resource, _tenant, []), do: 0

  defp count(resource, tenant, person_ids) do
    resource
    |> Ash.Query.filter(person_id in ^person_ids)
    |> Ash.count!(tenant: tenant, authorize?: false)
  end

  defp scopes(scope_ids) do
    case scope_ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> []
      ids -> ids |> Erasure.scopes_by_id!(authorize?: false) |> Enum.sort_by(& &1.id)
    end
  end

  # --- the account ---------------------------------------------------------------

  defp account(tenant, normalized) do
    with {:ok, %User{} = user} <- User |> Ash.Query.filter(email == ^normalized) |> read_one(),
         {:ok, %{organization_id: ^tenant}} <-
           BusinessUnit
           |> Ash.Query.filter(id == ^user.owning_business_unit_id)
           |> Ash.Query.select([:organization_id])
           |> read_one() do
      user
    else
      _ -> nil
    end
  end

  defp account_scopes(_tenant, nil), do: []

  defp account_scopes(tenant, user) do
    requester =
      case Erasure.scope_by_ref(:data_subject, SealingScope.scope_ref(user.id), authorize?: false) do
        {:ok, %Scope{} = scope} -> [scope.id]
        {:ok, nil} -> []
      end

    threads =
      Thread
      |> Ash.Query.filter(owner_id == ^user.id)
      |> Ash.Query.select([:erasure_scope_id])
      |> read!(tenant)
      |> Enum.map(& &1.erasure_scope_id)

    scopes(requester ++ threads)
  end

  defp read!(query, tenant), do: Ash.read!(query, tenant: tenant, authorize?: false)

  defp read_one(query), do: Ash.read_one(query, authorize?: false)
end
