defmodule AshEnterprise.Canonical.PersonSealingTest do
  @moduledoc """
  A correspondent's address is sealed under the person's own erasure scope and
  found through a blind index (ADR 0024, `AshEnterprise.Canonical.PersonSeal`).

  Phrased first as what must not happen: a write that cannot reach a live
  scope stored unsealed, an address in the clear in the table or the audit
  log, one person shared across tenants, a blind index keyed by something a
  routine rotation changes. The concurrent upsert is in the durability tier
  (`test/ash_enterprise/durability/person_seal_concurrency_test.exs`): the
  sandbox has one connection, and a lock taken twice on it never waits.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Canonical.{Person, PersonSeal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{BlindIndex, Crypto, Scope, Shredded}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.ActorContext

  setup do
    tenant = tenant!()
    %{tenant: tenant, address: "Sealed.Fixture-#{tenant.unique}@person-seal.synthetic.test"}
  end

  describe "refused" do
    test "a Person write with no resolvable scope is refused, never stored unsealed", ctx do
      person = upsert!(ctx.tenant, ctx.address, "Sealed Fixture")
      shred!(ctx.tenant, scope!(person))

      # The projectors' upsert finds the person by the index and must seal
      # under their scope, which is gone.
      assert {:error, %Ash.Error.Invalid{}} = upsert(ctx.tenant, ctx.address, "Again")

      # A new address for them: refused the same way.
      replacement = "replacement-#{ctx.tenant.unique}@person-seal.synthetic.test"

      assert {:error, %Ash.Error.Invalid{}} =
               person
               |> Ash.Changeset.for_update(:mdm_survivor_update, %{email: replacement},
                 tenant: ctx.tenant.id,
                 authorize?: false
               )
               |> Ash.update()

      # A golden recreated under its pinned id finds the shredded scope.
      Repo.query!("DELETE FROM canonical_people WHERE id = $1::uuid", [Ecto.UUID.dump!(person.id)])

      assert {:error, %Ash.Error.Invalid{}} =
               Person
               |> Ash.Changeset.for_create(
                 :mdm_replay_golden,
                 Map.merge(owner(ctx.tenant), %{golden_id: person.id, email: replacement}),
                 tenant: ctx.tenant.id,
                 authorize?: false
               )
               |> Ash.create()

      refute_table_spells([ctx.address, replacement])
    end

    test "an address that is blank names nobody: no index, no scope, no ciphertext", ctx do
      person = upsert!(ctx.tenant, nil, "Name Only #{ctx.tenant.unique}")

      assert is_nil(person.email)
      assert %{email_bidx: nil, encrypted_email: nil, erasure_scope_id: nil} = stored(person)
      assert BlindIndex.of(ctx.tenant.id, "   ") == nil

      assert {:error, %Ash.Error.Invalid{}} =
               Person.by_address("  ", tenant: ctx.tenant.id, authorize?: false)
    end

    test "a blind index needs the tenant it is unique in" do
      assert_raise ArgumentError, ~r/tenant/, fn -> BlindIndex.of(nil, "a@b.test") end
    end
  end

  describe "at rest" do
    test "canonical_people holds no fixture address in plaintext after projection (SQL sweep)",
         ctx do
      loser_address = "loser-#{ctx.tenant.unique}@person-seal.synthetic.test"
      survivor = upsert!(ctx.tenant, nil, "Survivor #{ctx.tenant.unique}")
      loser = upsert!(ctx.tenant, loser_address, nil)
      other = upsert!(ctx.tenant, ctx.address, "Sealed Fixture")

      merge!(ctx.tenant, loser, survivor)

      # The survivor inherited the address, sealed under its own scope; the
      # loser's provenance holds the prior address sealed under the loser's.
      survivor = Ash.reload!(survivor, tenant: ctx.tenant.id, authorize?: false)
      assert to_string(survivor.email) == loser_address
      assert stored(survivor).erasure_scope_id == scope!(survivor).id

      loser = Ash.reload!(loser, tenant: ctx.tenant.id, authorize?: false)
      assert is_nil(loser.email)
      assert %{"prior_email_sealed" => _} = loser.merge_provenance
      refute Map.has_key?(loser.merge_provenance, "prior_email")
      refute Map.has_key?(loser.merge_provenance, "merged_attrs")
      assert PersonSeal.prior_email(loser.merge_provenance) == loser_address

      assert to_string(other.email) == ctx.address
      assert scope!(other).kind == :data_subject
      refute scope!(other).ref =~ "@"

      %{rows: [[people]]} = Repo.query!("SELECT count(*) FROM canonical_people")
      assert people >= 3
      refute_table_spells([ctx.address, String.downcase(ctx.address), loser_address])
    end

    test "a shred makes the address unreadable on the row and in the merge provenance", ctx do
      survivor = upsert!(ctx.tenant, nil, "Survivor #{ctx.tenant.unique}")
      loser = upsert!(ctx.tenant, ctx.address, nil)
      merge!(ctx.tenant, loser, survivor)

      survivor = Ash.reload!(survivor, tenant: ctx.tenant.id, authorize?: false)
      loser = Ash.reload!(loser, tenant: ctx.tenant.id, authorize?: false)
      shred!(ctx.tenant, scope!(survivor))
      shred!(ctx.tenant, scope!(loser))

      assert %Shredded{} = Ash.reload!(survivor, tenant: ctx.tenant.id, authorize?: false).email

      assert PersonSeal.prior_email(
               Ash.reload!(loser, tenant: ctx.tenant.id, authorize?: false).merge_provenance
             ) == nil
    end
  end

  describe "tenancy" do
    test "the same address in another tenant is a different row under a different scope", ctx do
      other_tenant = tenant!()

      mine = upsert!(ctx.tenant, ctx.address, "Mine")
      theirs = upsert!(other_tenant, ctx.address, "Theirs")

      assert mine.id != theirs.id
      assert scope!(mine).id != scope!(theirs).id
      assert stored(mine).email_bidx != stored(theirs).email_bidx

      assert Person.by_address!(ctx.address, tenant: ctx.tenant.id, authorize?: false).id ==
               mine.id

      assert Person.by_address!(ctx.address, tenant: other_tenant.id, authorize?: false).id ==
               theirs.id
    end
  end

  describe "lookup" do
    test "a part of an address finds nobody; an unknown address finds nobody", ctx do
      upsert!(ctx.tenant, ctx.address, "Sealed Fixture")

      assert Person.by_address!("Sealed.Fixture", tenant: ctx.tenant.id, authorize?: false) ==
               nil

      assert Person.by_address!(
               "nobody-#{ctx.tenant.unique}@person-seal.synthetic.test",
               tenant: ctx.tenant.id,
               authorize?: false
             ) == nil
    end

    test "lookup by exact address finds the person through the blind index", ctx do
      person = upsert!(ctx.tenant, ctx.address, "Sealed Fixture")

      # Case and surrounding space aside, as the ci_string column was.
      found =
        Person.by_address!("  " <> String.upcase(ctx.address) <> " ",
          tenant: ctx.tenant.id,
          authorize?: false
        )

      assert found.id == person.id
      assert to_string(found.email) == ctx.address

      # And a second projection of it converges on the same row and scope.
      again = upsert!(ctx.tenant, String.downcase(ctx.address), "Sealed Fixture")
      assert again.id == person.id
      assert stored(again).erasure_scope_id == stored(person).erasure_scope_id
    end
  end

  describe "the key" do
    test "the blind-index key is not derived from secret_key_base and is not the bare digest of the address",
         ctx do
      index = BlindIndex.of(ctx.tenant.id, ctx.address)
      normalized = BlindIndex.normalize(ctx.address)

      assert byte_size(index) == 32
      refute index == :crypto.hash(:sha256, normalized)
      refute index == :crypto.hash(:sha256, ["v1", 0, ctx.tenant.id, 0, normalized])

      endpoint = Application.get_env(:ash_enterprise, AshEnterpriseWeb.Endpoint)
      secret_key_base = Keyword.fetch!(endpoint, :secret_key_base)

      refute index == :crypto.mac(:hmac, :sha256, secret_key_base, normalized)

      # Rotating the endpoint's secret changes nothing...
      on_exit(fn -> Application.put_env(:ash_enterprise, AshEnterpriseWeb.Endpoint, endpoint) end)

      Application.put_env(
        :ash_enterprise,
        AshEnterpriseWeb.Endpoint,
        Keyword.put(endpoint, :secret_key_base, String.duplicate("r", 64))
      )

      assert BlindIndex.of(ctx.tenant.id, ctx.address) == index

      # ...while the erasure master key is what it is derived from.
      erasure = Application.get_env(:ash_enterprise, Erasure)
      on_exit(fn -> Application.put_env(:ash_enterprise, Erasure, erasure) end)

      Application.put_env(
        :ash_enterprise,
        Erasure,
        Keyword.put(erasure, :master_key, Base.encode64(Crypto.generate_key()))
      )

      refute BlindIndex.of(ctx.tenant.id, ctx.address) == index
    end
  end

  describe "the audit log" do
    test "no audit event spells the fixture address or name, including merge provenance", ctx do
      name = "Audited Fixture #{ctx.tenant.unique}"
      loser_address = "audited-loser-#{ctx.tenant.unique}@person-seal.synthetic.test"

      survivor = upsert!(ctx.tenant, ctx.address, name)
      loser = upsert!(ctx.tenant, loser_address, "Loser #{name}")

      loser = merge!(ctx.tenant, loser, survivor)

      unmerged =
        loser
        |> Ash.Changeset.for_update(:mdm_unmerge, %{}, tenant: ctx.tenant.id, authorize?: false)
        |> Ash.update!()

      # The unmerge restored the loser's address from its sealed provenance.
      assert to_string(Ash.reload!(unmerged, tenant: ctx.tenant.id, authorize?: false).email) ==
               loser_address

      assert_no_audit_event_spells([
        ctx.address,
        String.downcase(ctx.address),
        loser_address,
        name
      ])
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp tenant! do
    unique = System.unique_integer([:positive])

    %{organization: org, user: user} =
      Seeder.seed_tenant(
        name: "Person Seal #{unique}",
        unique_name: "person-seal-#{unique}",
        email: "operator-#{unique}@person-seal.synthetic.test"
      )

    Seeder.grant_platform_operator(user)
    actor = ActorContext.attach(user, ActorContext.build(user, tenant: org.id))

    %{id: org.id, user: user, actor: actor, unique: unique}
  end

  defp owner(tenant),
    do: %{owner_id: tenant.user.id, owning_business_unit_id: tenant.user.owning_business_unit_id}

  defp upsert(tenant, email, name) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(tenant), %{email: email, name: name}),
      tenant: tenant.id,
      authorize?: false
    )
    |> Ash.create(upsert?: true, upsert_identity: :unique_email_bidx, upsert_fields: [])
  end

  defp upsert!(tenant, email, name) do
    {:ok, person} = upsert(tenant, email, name)
    person
  end

  defp merge!(tenant, loser, survivor) do
    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id},
      tenant: tenant.id,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp scope!(person) do
    {:ok, scope} =
      Erasure.scope_by_ref(:data_subject, PersonSeal.scope_ref(person.id), authorize?: false)

    assert %Scope{} = scope
    scope
  end

  defp shred!(tenant, scope) do
    Erasure.shred_scope!(scope, scope.ref, "person seal test", actor: tenant.actor)
  end

  defp stored(person) do
    %{rows: [[bidx, sealed, scope_id]]} =
      Repo.query!(
        "SELECT email_bidx, encrypted_email, erasure_scope_id FROM canonical_people WHERE id = $1::uuid",
        [Ecto.UUID.dump!(person.id)]
      )

    %{
      email_bidx: bidx,
      encrypted_email: sealed,
      erasure_scope_id: scope_id && Ecto.UUID.load!(scope_id)
    }
  end

  defp refute_table_spells(strings) do
    %{rows: rows} = Repo.query!("SELECT row_to_json(p)::text FROM canonical_people p")
    text = rows |> List.flatten() |> Enum.join("\n")

    for string <- strings do
      refute String.contains?(String.downcase(text), String.downcase(string)),
             "canonical_people spells #{inspect(string)}"
    end
  end

  defp assert_no_audit_event_spells(strings) do
    %{rows: rows} = Repo.query!("SELECT row_to_json(e)::text FROM audit_events e")
    assert rows != []
    text = rows |> List.flatten() |> Enum.join("\n")

    for string <- strings do
      refute String.contains?(text, string), "audit_events spells #{inspect(string)}"
    end
  end
end
