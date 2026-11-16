defmodule AshEnterprise.Durability.PersonSealConcurrencyTest do
  @moduledoc """
  The projectors' upsert of a sealed address against other connections
  (`AshEnterprise.Canonical.PersonSeal`): two projections of one new address
  must end with one row under one scope. A plain `ON CONFLICT` upsert cannot
  promise that, because each writer would open a scope and seal under it
  before knowing who wins, leaving the row's ciphertext under a scope its
  `erasure_scope_id` does not name.

  The interleaving is forced by holding the tenant's audit lock (the first
  lock the upsert takes) and waiting until Postgres reports both writers
  blocked, so the test does not depend on timing. The sandbox cannot show
  this: it has one connection, and a lock taken twice on it never waits.
  """

  use AshEnterprise.DurabilityCase, async: false

  require Ash.Query

  alias AshEnterprise.Canonical.{Person, PersonSeal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.Seeder

  setup do
    unique = System.unique_integer([:positive])

    %{organization: organization, user: user} =
      Seeder.seed_tenant(name: "Person seal #{unique}", unique_name: "person-seal-#{unique}")

    %{tenant: organization.id, user: user, unique: unique}
  end

  test "two concurrent projections of one address converge on one row and one scope", ctx do
    address = "converge-#{ctx.unique}@person-seal.synthetic.test"
    started_at = DateTime.utc_now()
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          upsert(ctx, "holder-#{ctx.unique}@person-seal.synthetic.test")
          send(test_pid, :holding_audit_lock)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :holding_audit_lock, 10_000

    writers =
      for name <- ["First", "Second"] do
        Task.async(fn -> upsert(ctx, address, name) end)
      end

    await_advisory_waiters(2)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 20_000)

    assert [{:ok, first}, {:ok, second}] = Task.await_many(writers, 20_000)
    assert first.id == second.id

    assert [person] =
             Person
             |> Ash.Query.for_read(:by_address, %{email: address},
               tenant: ctx.tenant,
               authorize?: false
             )
             |> Ash.read!()

    assert to_string(person.email) == address

    # One scope for the address, and it is the one the row names: the losing
    # writer opened none of its own.
    {:ok, scope} =
      Erasure.scope_by_ref(:data_subject, PersonSeal.scope_ref(person.id), authorize?: false)

    assert scope.id == person.erasure_scope_id

    %{rows: [[scopes]]} =
      Repo.query!(
        "SELECT count(*) FROM erasure_scopes s WHERE s.kind = 'data_subject' " <>
          "AND s.ref LIKE 'canonical_person:%' AND s.inserted_at >= $1 AND NOT EXISTS (" <>
          "SELECT 1 FROM canonical_people p WHERE 'canonical_person:' || p.id::text = s.ref)",
        [started_at]
      )

    assert scopes == 0
  end

  defp upsert(ctx, email, name \\ nil) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        name: name,
        email: email,
        owner_id: ctx.user.id,
        owning_business_unit_id: ctx.user.owning_business_unit_id
      },
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create(upsert?: true, upsert_identity: :unique_email_bidx, upsert_fields: [])
  end

  # Polled because Postgres has no notification for a backend starting to wait.
  defp await_advisory_waiters(count, attempts \\ 500) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted " <>
          "AND database = (SELECT oid FROM pg_database WHERE datname = current_database())"
      )

    cond do
      waiting >= count ->
        :ok

      attempts == 0 ->
        flunk("#{waiting} of #{count} connections were waiting on an advisory lock")

      true ->
        Process.sleep(20)
        await_advisory_waiters(count, attempts - 1)
    end
  end
end
