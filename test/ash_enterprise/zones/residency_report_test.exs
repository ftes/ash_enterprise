defmodule AshEnterprise.Zones.ResidencyReportTest do
  # Not async: `targets/0` reads application config.
  use ExUnit.Case, async: false

  alias AshEnterprise.Governance.DataFlows
  alias AshEnterprise.Zones.{ResidencyReport, Zone}

  @moduletag :tmp_dir

  @today ~D[2026-11-16]

  defp zone(id, review_by \\ "2027-02-01") do
    {:ok, zone} =
      Zone.from_map(%{
        "id" => id,
        "jurisdiction" => "CA-ON",
        "classification_ceiling" => "customer_confidential",
        "declared_by" => "Test Operator",
        "declared_at" => "2026-11-01",
        "review_by" => review_by
      })

    zone
  end

  defp target(id, kind, host, extra \\ []) do
    Map.merge(
      %{id: id, kind: kind, host: host, register_id: nil, inherits: nil},
      Map.new(extra)
    )
  end

  defp targets do
    [
      target("database", :store, "db.internal"),
      target("oban", :store, "db.internal", inherits: "database"),
      target("telemetry_exporter", :egress, "otel.example.org",
        register_id: :observability_exporter
      )
    ]
  end

  defp build(stores, zones, opts \\ []) do
    ResidencyReport.build([targets: targets(), stores: stores, zones: zones, on: @today] ++ opts)
  end

  defp verdicts(report), do: Map.new(report.rows, &{&1.id, &1.verdict})

  test "with no zone declared every store is reported unknown and --check fails" do
    report = build(%{}, [])

    assert %{"database" => :unknown, "oban" => :unknown, "telemetry_exporter" => :leaves_zone} =
             verdicts(report)

    refute report.ok?
  end

  test "a store mapped to an undeclared zone fails the check" do
    report = build(%{"database" => "nowhere", "telemetry_exporter" => "nowhere"}, [zone("eu-1")])

    assert %{"database" => :undeclared_zone, "oban" => :undeclared_zone} = verdicts(report)
    refute report.ok?
  end

  test "a zone past its review date fails the check" do
    report =
      build(%{"database" => "eu-1", "telemetry_exporter" => "eu-1"}, [zone("eu-1", "2026-11-15")])

    assert %{"database" => :lapsed, "oban" => :lapsed, "telemetry_exporter" => :lapsed} =
             verdicts(report)

    refute report.ok?
  end

  test "a declaration that matches no target is reported and fails the check" do
    report = build(%{"database" => "eu-1", "telemtry_exporter" => "eu-1"}, [zone("eu-1")])

    assert report.unrecognised == ["telemtry_exporter"]
    refute report.ok?
  end

  test "a configured egress host with no store declaration is reported as leaving the zone" do
    report = build(%{"database" => "eu-1"}, [zone("eu-1")])

    assert %{"database" => :in_zone, "oban" => :in_zone, "telemetry_exporter" => :leaves_zone} =
             verdicts(report)

    refute report.ok?

    loopback =
      ResidencyReport.build(
        targets: [target("integration_broker", :egress, "127.0.0.1")],
        stores: %{},
        zones: [],
        on: @today
      )

    assert [%{verdict: :co_located}] = loopback.rows
    assert loopback.ok?

    blocked =
      ResidencyReport.build(
        targets: [target("model_hosted", :egress, "provider default", blocked?: true)],
        stores: %{},
        zones: [],
        on: @today
      )

    assert [%{verdict: :blocked}] = blocked.rows
    assert blocked.ok?
  end

  test "a fully declared deployment lists the repo, Oban and the telemetry exporter under its zone" do
    report =
      build(%{"database" => "eu-1", "telemetry_exporter" => "eu-1"}, [zone("eu-1")])

    assert report.ok?
    assert report.unrecognised == []
    assert Enum.all?(report.rows, &(&1.zone == "eu-1" and &1.verdict == :in_zone))
    assert Enum.map(report.rows, & &1.id) == ["database", "oban", "telemetry_exporter"]

    text = ResidencyReport.render(report)
    assert text =~ "oban"
    assert text =~ "zone=eu-1"
  end

  test "oban can be mapped on its own, and then it does not inherit the database", %{} do
    report =
      build(%{"database" => "eu-1", "oban" => "elsewhere", "telemetry_exporter" => "eu-1"}, [
        zone("eu-1")
      ])

    assert %{"database" => :in_zone, "oban" => :undeclared_zone} = verdicts(report)
  end

  describe "load_stores/1" do
    test "reads the target to zone map", %{tmp_dir: dir} do
      path = Path.join(dir, "stores.json")
      File.write!(path, ~s({"stores": {"database": {"zone": "eu-1"}}}))
      assert ResidencyReport.load_stores(path) == %{"database" => "eu-1"}
      assert ResidencyReport.load_stores(nil) == %{}
    end

    test "refuses a missing file, a wrong shape and an entry with no zone", %{tmp_dir: dir} do
      assert_raise ArgumentError, ~r/cannot read/, fn ->
        ResidencyReport.load_stores(Path.join(dir, "absent.json"))
      end

      wrong = Path.join(dir, "wrong.json")
      File.write!(wrong, ~s([1, 2]))
      assert_raise ArgumentError, ~r/must be/, fn -> ResidencyReport.load_stores(wrong) end

      no_zone = Path.join(dir, "nozone.json")
      File.write!(no_zone, ~s({"stores": {"database": {}}}))

      assert_raise ArgumentError, ~r/needs a "zone"/, fn ->
        ResidencyReport.load_stores(no_zone)
      end
    end
  end

  describe "targets/0" do
    test "always has the database and Oban, and names register rows that exist" do
      ids = Enum.map(ResidencyReport.targets(), & &1.id)
      assert "database" in ids and "oban" in ids

      register = MapSet.new(DataFlows.all(), & &1.id)

      for %{register_id: id} <- ResidencyReport.targets(), id != nil do
        assert id in register
      end
    end

    test "a configured telemetry endpoint appears as an egress destination" do
      previous = Application.get_env(:opentelemetry_exporter, :otlp_endpoint)

      Application.put_env(
        :opentelemetry_exporter,
        :otlp_endpoint,
        "https://otel.example.org:4318"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:opentelemetry_exporter, :otlp_endpoint, previous),
          else: Application.delete_env(:opentelemetry_exporter, :otlp_endpoint)
      end)

      assert %{kind: :egress, host: "otel.example.org"} =
               Enum.find(ResidencyReport.targets(), &(&1.id == "telemetry_exporter"))
    end
  end
end
