defmodule AshEnterprise.Platform.FacadeProfileTest do
  @moduledoc """
  The façade profile (`facade?: true` on `AshEnterprise.Platform.Resource`, ADR 0083): the
  opt-outs are set in one place, the façade declares no rule of its own, and every read and
  write is a call to the source made as the caller.

  The refusals come first. A façade is an easy way to read around a grant, and every way to
  get it wrong shows a value, or another tenant's row, without raising.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Facades.{Licence, WorkItem}

  @number_key "AshEnterprise.Credentialing.Credential#number"
  @provenance ~w(created_on modified_on created_by_id modified_by_id created_on_behalf_by_id
                 modified_on_behalf_by_id overridden_created_on import_sequence_number
                 version_number)a

  setup do
    admin = DailyFixtures.tenant!()
    %{admin: admin}
  end

  describe "a read needs a tenant, and stays inside the viewer's" do
    test "a person with no tenant gets no rows", ctx do
      task!(ctx.admin, "Mine")

      assert {:error, _} = Ash.read(WorkItem, actor: ctx.admin.actor)
    end

    test "a system actor with no tenant gets no rows either", ctx do
      task!(ctx.admin, "Mine")

      assert {:error, _} = Ash.read(WorkItem, actor: SystemActor.seed())
    end

    test "naming another tenant returns no row of either", ctx do
      task!(ctx.admin, "Mine")
      other = DailyFixtures.tenant!()
      task!(other, "Theirs")

      # The source's tenant boundary refuses the actor's authority there, and a refused
      # read is an empty one: neither tenant's rows come back.
      assert {:ok, []} = Ash.read(WorkItem, actor: ctx.admin.actor, tenant: other.tenant)
    end

    test "an instant over a source with no time is refused, never dropped", ctx do
      assert {:error, _} =
               WorkItem
               |> Ash.Query.for_read(:read, %{},
                 actor: ctx.admin.actor,
                 tenant: ctx.admin.tenant,
                 as_of: DateTime.utc_now()
               )
               |> Ash.read()
    end
  end

  describe "the source's grants decide" do
    test "a viewer reads the rows the source would give them, and no others", ctx do
      owner = DailyFixtures.member!(ctx.admin, "Owner", [{Task, :read, :basic}])
      other = DailyFixtures.member!(ctx.admin, "Other", [{Task, :read, :basic}])
      nothing = DailyFixtures.member!(ctx.admin, "Nobody", [])

      mine = task!(owner, "Owner's errand")
      _theirs = task!(other, "Other's errand")

      assert [row] = read!(WorkItem, owner)
      assert row.id == mine.id
      assert row.name == "Owner's errand"
      assert row.state == :new

      assert read!(WorkItem, nothing) == []
      assert length(read!(WorkItem, ctx.admin)) == 2
    end

    test "a filter in the façade's words reaches the source", ctx do
      task!(ctx.admin, "Open one")
      done = task!(ctx.admin, "Done one")
      complete!(done, ctx.admin)

      assert [row] =
               WorkItem
               |> Ash.Query.filter(state == :finished)
               |> Ash.read!(as(ctx.admin))

      assert row.id == done.id
    end
  end

  describe "a secured column stays withheld through a façade" do
    setup ctx do
      clinic =
        Credentialing.register_clinic!(
          "Facade #{System.unique_integer([:positive])}",
          as(ctx.admin)
        )

      clinician =
        Credentialing.register_clinician!(
          %{
            first_name: "Synthetic",
            last_name: "Person",
            job_title: "Nurse",
            clinic_id: clinic.id
          },
          as(ctx.admin)
        )

      number = "SYN-#{System.unique_integer([:positive])}"

      credential =
        Credential
        |> Ash.Changeset.for_create(
          :record,
          %{
            kind: :licence,
            number: number,
            expires_on: ~D[2030-01-31],
            clinician_id: clinician.id
          },
          as(ctx.admin)
        )
        |> Ash.create!()

      %{credential: credential, number: number}
    end

    test "a reader without the column's grant gets the hidden value, not the licence number",
         ctx do
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])

      assert [row] = read!(Licence, reader)
      assert row.id == ctx.credential.id
      assert %Ash.ForbiddenField{field: :licence_number} = row.licence_number
      assert row.expires_on == ctx.credential.expires_on
    end

    test "a filter on the hidden value matches nothing", ctx do
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])

      assert [] =
               Licence
               |> Ash.Query.filter(licence_number == ^ctx.number)
               |> Ash.read!(as(reader))
    end

    test "a sort by the hidden value is refused", ctx do
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])

      assert {:error, _} =
               Licence
               |> Ash.Query.sort(:licence_number)
               |> Ash.read(as(reader))
    end

    test "the holder of the column's grant reads the value", ctx do
      holder =
        DailyFixtures.member!(ctx.admin, "Holder", [
          {Credential, :read, :global},
          {@number_key, :read, :global}
        ])

      assert [%{licence_number: number}] = read!(Licence, holder)
      assert number == ctx.number
    end

    test "a reader with no grant on the source's rows gets no row", ctx do
      nobody = DailyFixtures.member!(ctx.admin, "Nobody", [])

      assert read!(Licence, nobody) == []
    end
  end

  describe "a write is one named source action, run as the viewer" do
    test "finishing a work item completes the source task: one audit row, on the source", ctx do
      task = task!(ctx.admin, "Finish me")
      before = events_for(task, ctx.admin)

      assert %{state: :finished} = write!(WorkItem, :finish, ctx.admin, %{id: task.id})

      assert %{status: :done} = Ash.get!(Task, task.id, as(ctx.admin))

      new = events_for(task, ctx.admin) -- before
      assert [%{action: action}] = new
      assert to_string(action) == "complete"
      assert Enum.all?(new, &(to_string(&1.resource) =~ "Canonical.Task"))
      refute Enum.any?(events_for(task, ctx.admin), &(to_string(&1.resource) =~ "Facades"))
    end

    test "a field another named action accepts is written through that action", ctx do
      task = task!(ctx.admin, "Estimate me")

      assert %{effort_minutes: 45} =
               write!(WorkItem, :set_effort, ctx.admin, %{id: task.id, effort_minutes: 45})

      assert %{estimated_minutes: 45} = Ash.get!(Task, task.id, as(ctx.admin))
    end

    test "the source's own guard still refuses, in the source's words", ctx do
      task = task!(ctx.admin, "Done already")
      complete!(task, ctx.admin)

      assert {:error, error} = write(WorkItem, :finish, ctx.admin, %{id: task.id})
      assert Exception.message(error) =~ "only an open task can be marked done"
    end

    test "a viewer who cannot read the row writes nothing", ctx do
      task = task!(ctx.admin, "Not yours")
      stranger = DailyFixtures.member!(ctx.admin, "Stranger", [{Task, :read, :basic}])

      assert {:error, _} = write(WorkItem, :finish, stranger, %{id: task.id})
      assert %{status: :open} = Ash.get!(Task, task.id, as(ctx.admin))
    end

    test "a write with no tenant is refused", ctx do
      task = task!(ctx.admin, "No tenant")

      assert {:error, _} =
               WorkItem
               |> Ash.ActionInput.for_action(:finish, %{id: task.id}, actor: ctx.admin.actor)
               |> Ash.run_action()

      assert %{status: :open} = Ash.get!(Task, task.id, as(ctx.admin))
    end

    test "an instant on a write is refused before any source action runs", ctx do
      task = task!(ctx.admin, "Back-dated")

      assert {:error, _} =
               WorkItem
               |> Ash.ActionInput.for_action(:finish, %{id: task.id},
                 actor: ctx.admin.actor,
                 tenant: ctx.admin.tenant,
                 as_of: DateTime.utc_now()
               )
               |> Ash.run_action()

      assert %{status: :open} = Ash.get!(Task, task.id, as(ctx.admin))
    end
  end

  describe "the profile" do
    test "sets every opt-out and installs no rule of its own" do
      for facade <- [WorkItem, Licence] do
        assert Ash.DataLayer.data_layer(facade) == Ash.DataLayer.Simple
        assert AshStrangler.Facade in Spark.extensions(facade)

        for {option, value} <- [
              ownership: :none,
              tenant?: false,
              lifecycle?: false,
              audit?: false,
              optimistic_lock?: false,
              facade?: true,
              secured_fields: []
            ] do
          assert Spark.Dsl.Extension.get_opt(facade, [:platform], option, :unset) == value,
                 "#{inspect(facade)} #{option}"
        end

        assert Ash.Resource.Info.authorizers(facade) == []
        assert Ash.Policy.Info.policies(facade) == []
        assert Ash.Policy.Info.field_policies(facade) == []
        assert Ash.Resource.Info.multitenancy_strategy(facade) == nil
        refute AshEvents.Events in Spark.extensions(facade)
        refute AshArchival.Resource in Spark.extensions(facade)
        refute AshStateMachine in Spark.extensions(facade)
        assert AshOpenLineage.Info.lineage_emit_on(facade) == {:ok, []}
      end
    end

    test "adds no provenance column and no version_number the source does not supply" do
      names = WorkItem |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      assert Enum.sort(names) ==
               Enum.sort([:id, :name, :state, :effort_minutes, :due, :recorded_at])

      for column <- @provenance -- [:created_on], do: refute(column in names)

      # `recorded_at` is the source's `created_on`, mapped like any other attribute.
      assert :recorded_at in names
    end

    test "a resource that is not a façade is unchanged" do
      names = Task |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      for column <- @provenance, do: assert(column in names)
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(Task)
      assert Enum.any?(Ash.Policy.Info.policies(Task))
      assert Ash.Resource.Info.multitenancy_strategy(Task) == :attribute
    end

    test "restating an opt-out beside facade?: true is a compile error" do
      assert_raise ArgumentError, ~r/facade\?: true.*audit\?/s, fn ->
        Code.eval_string("""
        defmodule AshEnterprise.Test.Facades.Restated#{System.unique_integer([:positive])} do
          use AshEnterprise.Platform.Resource,
            domain: AshEnterprise.Test.Facades,
            facade?: true,
            audit?: false
        end
        """)
      end
    end
  end

  defp as(member), do: [actor: member.actor, tenant: member.tenant]

  defp read!(resource, member), do: Ash.read!(resource, as(member))

  defp task!(member, title), do: Task.capture!(title, %{}, as(member))

  defp complete!(task, member) do
    task
    |> Ash.Changeset.for_update(:complete, %{}, as(member))
    |> Ash.update!()
  end

  defp write(resource, action, member, input) do
    resource
    |> Ash.ActionInput.for_action(action, input, as(member))
    |> Ash.run_action()
  end

  defp write!(resource, action, member, input) do
    {:ok, result} = write(resource, action, member, input)
    result
  end

  defp events_for(record, member) do
    EventLog
    |> Ash.Query.filter(record_id == ^record.id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(authorize?: false, tenant: member.tenant)
  end
end
