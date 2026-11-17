defmodule AshEnterprise.Audit.OtlpExportTest do
  @moduledoc """
  Committed audit events reach the deployment's OTLP log endpoint as log records
  (`AshEnterprise.Audit.ExportWorker`, `AshEnterprise.Audit.OtlpExport`; q38).

  Refusals and failures first: nothing configured exports nothing, a rolled-back write and a
  replay export nothing, a record carries no value of what was written, one tenant's batch
  holds only its own events, and an endpoint that refuses leaves the cursor and records why.
  Then what goes: each record's hash, previous hash and sequence are the chain's, and the
  chain still verifies.

  The endpoint is a `Req.Test` stub; nothing leaves the test. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Audit

  alias AshEnterprise.Audit.{
    ClearRecordsForReplay,
    EventLog,
    ExportCursor,
    ExportWorker,
    OtlpExport
  }

  alias AshEnterprise.Audit.OtlpExport.Client
  alias AshEnterprise.Platform.{Correlation, Seeder, SystemActor}
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.AuthenticationEvent

  @endpoint "http://collector.test:4318"

  setup do
    Correlation.start_new()
    %{tasks_before: MapSet.new(Task.Supervisor.children(AshEnterprise.TaskSupervisor))}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp tenant! do
    n = unique()

    seeded =
      Seeder.seed_tenant(
        name: "SYNTHETIC Otlp Org #{n}",
        unique_name: "otlp-#{n}",
        email: "otlp-person-#{n}@example.test"
      )

    %{tenant: seeded.organization.id, organization: seeded.organization, user: seeded.user}
  end

  defp create_bu!(name, tenant) do
    BusinessUnit
    |> Ash.Changeset.for_create(:create, %{name: name},
      authorize?: false,
      tenant: tenant,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  # The endpoint answers 200 and sends each decoded body to the test.
  defp accept! do
    test = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)
  end

  defp refuse!(status) do
    test = self()

    Req.Test.stub(Client, fn conn ->
      send(test, :attempted)
      Plug.Conn.send_resp(conn, status, "SYNTHETIC unavailable")
    end)
  end

  defp export!(opts \\ []),
    do: ExportWorker.run(Keyword.merge([endpoint: @endpoint, settle_seconds: 0], opts))

  defp posted do
    receive do
      {:posted, "/v1/logs", body} -> [body | posted()]
    after
      0 -> []
    end
  end

  defp records(bodies) do
    for body <- bodies,
        resource_logs <- body["resourceLogs"],
        scope_logs <- resource_logs["scopeLogs"],
        record <- scope_logs["logRecords"],
        do: record
  end

  defp attrs(record) do
    Map.new(record["attributes"], fn %{"key" => key, "value" => value} ->
      {key, value["stringValue"] || String.to_integer(value["intValue"])}
    end)
  end

  defp cursor(chain), do: Audit.export_cursor!(chain, actor: SystemActor.oban())

  defp events(tenant) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp await_tasks(%{tasks_before: before}) do
    for pid <- Task.Supervisor.children(AshEnterprise.TaskSupervisor),
        not MapSet.member?(before, pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> flunk("a recording task did not finish")
      end
    end

    :ok
  end

  # ── nothing configured ───────────────────────────────────────────────────

  describe "with no endpoint configured" do
    test "no endpoint configured exports nothing and errors nothing" do
      tenant!()
      Req.Test.stub(Client, fn _conn -> flunk("nothing is posted without an endpoint") end)

      assert {:ok, :not_configured} = ExportWorker.run()
      assert {:ok, :not_configured} = ExportWorker.run(endpoint: "")
      assert {:ok, :not_configured} = perform_job()

      assert Audit.list_export_cursors!(actor: SystemActor.oban()) == []
    end
  end

  defp perform_job, do: ExportWorker.perform(%Oban.Job{args: %{}})

  # ── what never goes ───────────────────────────────────────────────────────

  describe "what is not exported" do
    test "an event's log record carries no attribute value or personal field" do
      ctx = tenant!()
      accept!()

      role_name = "SYNTHETIC Wilhelmina Quixote #{unique()}"

      AshEnterprise.Security.Role
      |> Ash.Changeset.for_create(:create, %{name: role_name},
        authorize?: false,
        actor: SystemActor.seed(),
        tenant: ctx.tenant
      )
      |> Ash.create!()

      assert {:ok, %{exported: exported, failed: []}} = export!()
      assert exported > 0

      bodies = posted()
      records = records(bodies)
      assert length(records) == exported

      allowed = MapSet.new(OtlpExport.attribute_keys())

      for record <- records do
        keys = record |> attrs() |> Map.keys() |> MapSet.new()

        assert MapSet.subset?(keys, allowed),
               "unexpected keys: #{inspect(MapSet.difference(keys, allowed))}"
      end

      encoded = Jason.encode!(bodies)

      for value <- [
            to_string(ctx.user.email),
            role_name,
            "Wilhelmina",
            ctx.organization.name,
            ctx.organization.unique_name
          ] do
        refute encoded =~ value, "#{value} left in an exported record"
      end

      # No record id: an event about a row other than its actor's or its tenant's never
      # names that row.
      for event <- events(ctx.tenant),
          event.record_id not in [event.user_id, event.organization_id] do
        refute encoded =~ to_string(event.record_id)
      end

      # The role's creation is there, as a resource and an action, and nothing more.
      assert Enum.any?(records, fn record ->
               attrs = attrs(record)

               attrs["audit.resource"] == "AshEnterprise.Security.Role" and
                 attrs["audit.action"] == "create" and attrs["audit.tenant_id"] == ctx.tenant
             end)
    end

    test "a structural field outside its resource's closed set is left out" do
      event = %EventLog{
        resource: AuthenticationEvent,
        action: :record,
        action_type: :create,
        sequence: 7,
        occurred_at: DateTime.utc_now(),
        data: %{"door" => "password", "outcome" => "refused", "reason" => "SYNTHETIC free text"},
        metadata: %{"system_actor" => "auth", "correlation_id" => "c", "secret" => "s3cr3t"}
      }

      fields = OtlpExport.fields(event)

      assert fields["audit.authentication.door"] == "password"
      assert fields["audit.authentication.outcome"] == "refused"
      refute Map.has_key?(fields, "audit.authentication.reason")
      refute Jason.encode!(OtlpExport.log_record(event)) =~ "s3cr3t"
      refute Jason.encode!(OtlpExport.log_record(event)) =~ "SYNTHETIC free text"
    end

    test "a rolled-back write exports nothing" do
      ctx = tenant!()
      accept!()
      assert {:ok, %{failed: []}} = export!()
      _ = posted()
      before = cursor(ctx.tenant)

      assert {:error, :rolled_back} =
               Repo.transaction(fn ->
                 create_bu!("SYNTHETIC rolled back #{unique()}", ctx.tenant)
                 Repo.rollback(:rolled_back)
               end)

      assert {:ok, %{exported: 0, failed: []}} = export!()
      assert posted() == []
      assert cursor(ctx.tenant).last_sequence == before.last_sequence
    end

    test "a replay exports nothing new" do
      previous = Application.get_env(:ash_enterprise, ClearRecordsForReplay)
      on_exit(fn -> Application.put_env(:ash_enterprise, ClearRecordsForReplay, previous) end)

      # A chain of business units alone, so the replay covers its whole log.
      org = Ash.UUID.generate()
      Audit.start_export_cursor!(org, actor: SystemActor.oban())
      create_bu!("SYNTHETIC Root #{unique()}", org)
      create_bu!("SYNTHETIC Branch #{unique()}", org)

      accept!()
      assert {:ok, %{failed: []}} = export!()
      assert posted() |> records() |> Enum.count(&(attrs(&1)["audit.tenant_id"] == org)) == 2

      Application.put_env(:ash_enterprise, ClearRecordsForReplay,
        allow?: true,
        resources: [BusinessUnit]
      )

      assert :ok =
               EventLog
               |> Ash.ActionInput.for_action(:replay, %{},
                 actor: SystemActor.replay(),
                 authorize?: false
               )
               |> Ash.run_action()

      assert {:ok, %{exported: 0, failed: []}} = export!()
      assert posted() == []
    end
  end

  # ── one chain, one tenant ─────────────────────────────────────────────────

  describe "tenant chains" do
    test "another tenant's events carry their own tenant id only" do
      a = tenant!()
      b = tenant!()
      create_bu!("SYNTHETIC A #{unique()}", a.tenant)
      create_bu!("SYNTHETIC B #{unique()}", b.tenant)
      accept!()

      assert {:ok, %{failed: []}} = export!()

      a_sequences = a.tenant |> events() |> MapSet.new(& &1.sequence)
      b_sequences = b.tenant |> events() |> MapSet.new(& &1.sequence)

      for body <- posted() do
        tenants =
          body
          |> List.wrap()
          |> records()
          |> Enum.map(&attrs(&1)["audit.tenant_id"])
          |> Enum.uniq()

        assert length(tenants) == 1, "one request holds one chain, got #{inspect(tenants)}"

        sequences = body |> List.wrap() |> records() |> MapSet.new(&attrs(&1)["audit.sequence"])

        case tenants do
          [tenant] when tenant == a.tenant ->
            assert MapSet.subset?(sequences, a_sequences)
            assert MapSet.disjoint?(sequences, b_sequences)

          [tenant] when tenant == b.tenant ->
            assert MapSet.subset?(sequences, b_sequences)
            assert MapSet.disjoint?(sequences, a_sequences)

          _other ->
            :ok
        end
      end

      assert cursor(a.tenant).exported_count == MapSet.size(a_sequences)
      assert cursor(b.tenant).exported_count == MapSet.size(b_sequences)
    end
  end

  # ── failure ──────────────────────────────────────────────────────────────

  describe "an exporter outage" do
    test "an exporter outage does not fail the write and is recorded" do
      ctx = tenant!()
      ref = :telemetry_test.attach_event_handlers(self(), [ExportWorker.failed_event()])
      refuse!(503)

      assert %BusinessUnit{} = create_bu!("SYNTHETIC written while down #{unique()}", ctx.tenant)

      assert {:ok, %{exported: 0, failed: failed}} = export!()
      assert ctx.tenant in failed
      assert_received :attempted

      down = cursor(ctx.tenant)
      assert down.last_sequence == 0
      assert down.exported_count == 0
      assert %DateTime{} = down.failing_since
      assert down.last_error == "http 503"

      chain = ctx.tenant

      assert_received {[:ash_enterprise, :audit, :export, :failed], ^ref, %{count: 1},
                       %{chain: ^chain, reason: "http 503"}}

      # Still down, by a transport error: the cursor stays, the first failure's time is kept.
      Req.Test.stub(Client, &Req.Test.transport_error(&1, :econnrefused))
      assert {:ok, %{failed: failed}} = export!()
      assert ctx.tenant in failed
      still = cursor(ctx.tenant)
      assert still.failing_since == down.failing_since
      assert still.last_error == "transport: econnrefused"

      # Recovered: the backlog goes once, and the failure clears.
      accept!()
      assert {:ok, %{failed: []}} = export!()
      sent = posted() |> records() |> Enum.filter(&(attrs(&1)["audit.tenant_id"] == ctx.tenant))
      assert length(sent) == length(events(ctx.tenant))

      up = cursor(ctx.tenant)
      assert up.failing_since == nil
      assert up.last_error == nil
      assert up.exported_count == length(sent)

      assert {:ok, %{exported: 0}} = export!()
      assert posted() == []
    end

    test "a cursor's writes are the export machinery's alone" do
      ctx = tenant!()
      accept!()
      assert {:ok, _} = export!()
      cursor = cursor(ctx.tenant)

      for actor <- [nil, SystemActor.seed(), SystemActor.process()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Audit.advance_export_cursor(cursor, 0, 0, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Audit.start_export_cursor(Ash.UUID.generate(), actor: actor)
      end
    end
  end

  # ── what goes ────────────────────────────────────────────────────────────

  describe "what is exported" do
    test "a record's hash matches the chain" do
      ctx = tenant!()
      create_bu!("SYNTHETIC hashed #{unique()}", ctx.tenant)
      accept!()

      assert {:ok, %{failed: []}} = export!()

      exported =
        posted()
        |> records()
        |> Enum.map(&attrs/1)
        |> Enum.filter(&(&1["audit.tenant_id"] == ctx.tenant))
        |> Map.new(&{&1["audit.sequence"], &1})

      chain = events(ctx.tenant)
      assert map_size(exported) == length(chain)

      for event <- chain do
        record = Map.fetch!(exported, event.sequence)
        assert record["audit.hash"] == event.hash
        assert record["audit.previous_hash"] == event.previous_hash
        assert record["audit.resource"] == OtlpExport.resource_name(event.resource)
        assert record["audit.action"] == to_string(event.action)
      end

      assert %{findings: []} = AshEvents.Chain.verify(EventLog, ctx.tenant)
    end

    test "a refused sign-in reaches the chain with no tenant with its door, outcome and reason",
         env do
      ctx = tenant!()

      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:error, _} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 "email" => to_string(ctx.user.email),
                 "password" => "SYNTHETIC-not-the-password"
               })

      await_tasks(env)
      accept!()

      # Inside the settle window, the chain with no tenant waits.
      assert {:ok, _} = export!(settle_seconds: 3_600)

      refused = fn records ->
        records
        |> Enum.map(&attrs/1)
        |> Enum.filter(
          &(&1["audit.resource"] == inspect(AuthenticationEvent) and
              &1["audit.authentication.outcome"] == "refused")
        )
      end

      assert posted() |> records() |> refused.() == []

      assert %ExportCursor{} = cursor(nil)

      # Past it, the refusal goes, with no tenant id.
      assert {:ok, %{failed: []}} = export!()

      assert [refusal] = posted() |> records() |> refused.()

      assert refusal["audit.authentication.door"] == "password"
      assert refusal["audit.authentication.outcome"] == "refused"
      assert refusal["audit.authentication.reason"] == "wrong_password"
      refute Map.has_key?(refusal, "audit.tenant_id")
    end
  end
end
