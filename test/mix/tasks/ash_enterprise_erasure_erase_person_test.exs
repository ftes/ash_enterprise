defmodule Mix.Tasks.AshEnterprise.Erasure.ErasePersonTest do
  @moduledoc """
  `mix ash_enterprise.erasure.erase_person` erases a person by their address
  (`AshEnterprise.Erasure.PersonErasure`). A dry run by default, counts only; `--apply`
  erases as the person `--as` names, under their own grants. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, tenant!: 1]

  alias AshEnterprise.Canonical.{Person, PersonSeal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.PersonErasure
  alias AshEnterprise.Repo
  alias Mix.Tasks.AshEnterprise.Erasure.ErasePerson

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    operator = tenant!(operator?: true)
    unique = System.unique_integer([:positive])
    address = "task-#{unique}@erase-person.synthetic.test"

    person =
      Person
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        %{
          email: address,
          name: "Task Fixture #{unique}",
          owner_id: operator.user.id,
          owning_business_unit_id: operator.user.owning_business_unit_id
        },
        tenant: operator.tenant,
        authorize?: false
      )
      |> Ash.create!(upsert?: true, upsert_identity: :unique_email_bidx, upsert_fields: [])

    %{operator: operator, address: address, person: person}
  end

  test "refused without an operator's grant, and nothing is changed", ctx do
    other = tenant!()
    before = row(ctx.person)

    assert_raise Mix.Error, ~r/may not erase/, fn ->
      ErasePerson.run(args(ctx, other.email) ++ ["--apply"])
    end

    assert_raise Mix.Error, ~r/--reason is required/, fn ->
      ErasePerson.run([
        "--tenant",
        ctx.operator.tenant,
        "--email",
        ctx.address,
        "--as",
        other.email
      ])
    end

    assert_raise Mix.Error, ~r/no user/, fn ->
      ErasePerson.run(args(ctx, "nobody-#{System.unique_integer()}@example.test"))
    end

    assert row(ctx.person) == before
    assert receipts(ctx) == []
  end

  test "mix ash_enterprise.erasure.erase_person dry run changes nothing; --apply runs as the named person under their grants",
       ctx do
    before = row(ctx.person)

    ErasePerson.run(args(ctx, ctx.operator.email))
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Dry run: nothing written."
    assert output =~ "people: 1"
    assert output =~ "scopes: 1"
    assert output =~ "may erase"
    refute output =~ ctx.address
    refute output =~ "Task Fixture"

    assert row(ctx.person) == before
    assert scope(ctx.person).status == :active
    assert receipts(ctx) == []

    ErasePerson.run(args(ctx, ctx.operator.email) ++ ["--apply"])
    assert_received {:mix_shell, :info, [applied]}
    applied = IO.iodata_to_binary(applied |> List.wrap() |> Enum.reject(&is_atom/1))
    assert applied =~ "Erased."
    refute applied =~ ctx.address

    assert scope(ctx.person).status == :shredded
    assert [receipt] = receipts(ctx)
    assert receipt.created_by_id == ctx.operator.user.id
    assert receipt.reason == "erasure request"
  end

  defp args(ctx, as) do
    [
      "--tenant",
      ctx.operator.tenant,
      "--email",
      ctx.address,
      "--as",
      as,
      "--reason",
      "erasure request"
    ]
  end

  defp row(person) do
    %{rows: [[row]]} =
      Repo.query!("SELECT row_to_json(p)::text FROM canonical_people p WHERE id = $1::uuid", [
        Ecto.UUID.dump!(person.id)
      ])

    row
  end

  defp scope(person) do
    {:ok, scope} =
      Erasure.scope_by_ref(:data_subject, PersonSeal.scope_ref(person.id), authorize?: false)

    scope
  end

  defp receipts(ctx), do: Ash.read!(PersonErasure, tenant: ctx.operator.tenant, authorize?: false)
end
