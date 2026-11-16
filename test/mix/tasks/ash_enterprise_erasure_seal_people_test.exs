defmodule Mix.Tasks.AshEnterprise.Erasure.SealPeopleTest do
  @moduledoc """
  `mix ash_enterprise.erasure.seal_people` seals the people written before
  addresses were sealed (ADR 0024). A row from before the seal is made the way
  the expand migration leaves one: the address in the old plaintext column, no
  blind index, no scope; a merged loser's provenance holding the prior address
  and the merged values in the clear. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.{Person, PersonSeal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Repo
  alias Mix.Tasks.AshEnterprise.Erasure.SealPeople

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    unique = System.unique_integer([:positive])

    %{organization: org, user: user} =
      Seeder.seed_tenant(name: "Seal people #{unique}", unique_name: "seal-people-#{unique}")

    address = "legacy-#{unique}@seal-people.synthetic.test"
    prior = "prior-#{unique}@seal-people.synthetic.test"

    legacy = legacy!(org.id, user, "Legacy #{unique}", address, nil)

    loser =
      legacy!(org.id, user, nil, nil, %{
        "prior_email" => prior,
        "merged_attrs" => %{"email" => prior, "name" => "Legacy #{unique}"},
        "survivor_id" => legacy.id
      })

    %{tenant: org.id, legacy: legacy, loser: loser, address: address, prior: prior}
  end

  test "dry run writes nothing and opens no scope; --apply seals every row; a second run finds nothing",
       ctx do
    before = rows(ctx)

    SealPeople.run(["--tenant", ctx.tenant])
    assert counts() == %{"people" => "2", "sealed" => "1", "provenance" => "1"}
    assert rows(ctx) == before
    assert scope(ctx.legacy) == nil
    assert scope(ctx.loser) == nil

    SealPeople.run(["--apply", "--tenant", ctx.tenant])
    assert counts() == %{"people" => "2", "sealed" => "1", "provenance" => "1"}

    legacy = Ash.reload!(ctx.legacy, tenant: ctx.tenant, authorize?: false)
    assert to_string(legacy.email) == ctx.address
    assert legacy.legacy_email == nil
    assert legacy.erasure_scope_id == scope(ctx.legacy).id
    assert Person.by_address!(ctx.address, tenant: ctx.tenant, authorize?: false).id == legacy.id

    loser = Ash.reload!(ctx.loser, tenant: ctx.tenant, authorize?: false)
    assert loser.erasure_scope_id == scope(ctx.loser).id
    assert PersonSeal.prior_email(loser.merge_provenance) == ctx.prior
    refute Map.has_key?(loser.merge_provenance, "prior_email")
    refute Map.has_key?(loser.merge_provenance, "merged_attrs")
    assert loser.merge_provenance["survivor_id"] == ctx.legacy.id

    %{rows: rows} =
      Repo.query!(
        "SELECT row_to_json(p)::text FROM canonical_people p WHERE p.organization_id = $1::uuid",
        [Ecto.UUID.dump!(ctx.tenant)]
      )

    text = rows |> List.flatten() |> Enum.join("\n")
    refute text =~ ctx.address
    refute text =~ ctx.prior

    SealPeople.run(["--apply", "--tenant", ctx.tenant])
    assert counts() == %{"people" => "0", "sealed" => "0", "provenance" => "0"}
  end

  test "the task prints counts, never an address", ctx do
    SealPeople.run(["--tenant", ctx.tenant])
    assert_received {:mix_shell, :info, [output]}
    refute output =~ "@"
  end

  # A person as the expand migration finds one written before the seal.
  defp legacy!(tenant, user, name, email, provenance) do
    person =
      Person
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        %{name: name, owner_id: user.id, owning_business_unit_id: user.owning_business_unit_id},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!(upsert?: true, upsert_identity: :unique_email_bidx, upsert_fields: [])

    Repo.query!(
      "UPDATE canonical_people SET email = $2, merge_provenance = $3 WHERE id = $1::uuid",
      [Ecto.UUID.dump!(person.id), email, provenance]
    )

    person
  end

  defp rows(ctx) do
    %{rows: rows} =
      Repo.query!(
        "SELECT row_to_json(p)::text FROM canonical_people p WHERE p.id = ANY($1::uuid[])",
        [Enum.map([ctx.legacy.id, ctx.loser.id], &Ecto.UUID.dump!/1)]
      )

    Enum.sort(rows)
  end

  defp scope(person) do
    {:ok, scope} =
      Erasure.scope_by_ref(:data_subject, PersonSeal.scope_ref(person.id), authorize?: false)

    scope
  end

  defp counts do
    assert_received {:mix_shell, :info, [output]}

    ~r/^\s+(\w+): (\d+)$/m
    |> Regex.scan(output)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end
end
