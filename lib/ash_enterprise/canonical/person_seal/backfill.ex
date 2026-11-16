defmodule AshEnterprise.Canonical.PersonSeal.Backfill do
  @moduledoc """
  Seals every `AshEnterprise.Canonical.Person` written before addresses were
  sealed (`mix ash_enterprise.erasure.seal_people`).

  A row needs sealing while its plaintext column (`legacy_email`) still holds
  an address, or its `merge_provenance` still holds a prior address or merged
  values in the clear. Each such row is updated through `Person.seal_legacy`,
  one transaction per row, so a failure leaves the rows before it sealed and
  a rerun picks up the rest.

  A dry run reads only: it writes nothing and opens no scope. Counts only,
  never values.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Canonical.Person

  @empty %{people: 0, sealed: 0, provenance: 0}

  @doc """
  Runs over every tenant, or the one `:tenant` names. `apply?: true` writes;
  otherwise the counts are what a run would do. Returns `%{people:, sealed:,
  provenance:}`: rows needing a seal, addresses sealed (or to seal), and
  merge provenances rewritten (or to rewrite).
  """
  @spec run(keyword()) :: %{
          people: non_neg_integer(),
          sealed: non_neg_integer(),
          provenance: non_neg_integer()
        }
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    opts
    |> tenants()
    |> Enum.reduce(@empty, fn tenant, counts ->
      tenant |> pending() |> Enum.reduce(counts, &visit(&1, &2, tenant, apply?))
    end)
  end

  defp visit(person, counts, tenant, apply?) do
    if apply?, do: seal!(person, tenant)

    %{
      counts
      | people: counts.people + 1,
        sealed: counts.sealed + if(person.legacy_email, do: 1, else: 0),
        provenance: counts.provenance + if(plaintext_provenance?(person), do: 1, else: 0)
    }
  end

  @doc "The people in `tenant` that still need sealing."
  @spec pending(term()) :: [Person.t()]
  def pending(tenant) do
    Person
    |> Ash.Query.filter(not is_nil(legacy_email) or not is_nil(merge_provenance))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.filter(&(&1.legacy_email || plaintext_provenance?(&1)))
  end

  defp plaintext_provenance?(%{merge_provenance: %{} = provenance}),
    do: Map.has_key?(provenance, "prior_email") or Map.has_key?(provenance, "merged_attrs")

  defp plaintext_provenance?(_person), do: false

  defp seal!(person, tenant) do
    person
    |> Ash.Changeset.for_update(:seal_legacy, %{}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  defp tenants(opts) do
    case Keyword.get(opts, :tenant) do
      nil -> Organization |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
      tenant -> [tenant]
    end
  end
end
