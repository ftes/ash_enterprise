defmodule AshEnterprise.Observability.SecurityRulesTest do
  @moduledoc """
  The SigNoz rules in `devenv/observability/security/alerts/` against what this application
  sends (q38): the security rules read the audit chain's OTLP log records, never spans, and
  every attribute and value a rule filters on is one `AshEnterprise.Audit.OtlpExport` emits;
  every metric a rule reads is one the application exports.

  This checks the rule files against the exporter's contract. That each rule matches the
  records real actions produce is `AshEnterprise.Bpmn.AlertReviewTest`'s "the SigNoz rules".
  Neither runs SigNoz.
  """

  # Not async: the metrics reporter is a named singleton.
  use ExUnit.Case, async: false

  alias AshEnterprise.Audit.{EventSource, OtlpExport}

  @rules Path.wildcard(
           Path.expand("../../../devenv/observability/security/alerts/*.json", __DIR__)
         )

  defp rules do
    assert @rules != [], "the rules are where the test looks for them"
    Enum.map(@rules, &{Path.basename(&1), &1 |> File.read!() |> Jason.decode!()})
  end

  defp spec(rule),
    do: get_in(rule, ["condition", "compositeQuery", "queries", Access.at(0), "spec"])

  # `key = 'v'` and `key IN ('a', 'b')` clauses joined by AND: the only shapes the rules use.
  defp clauses(expression) do
    for clause <- String.split(expression, " AND ", trim: true) do
      assert [_, key, _op, values] = Regex.run(~r/^\s*([a-z_.]+)\s+(=|IN)\s+(.+?)\s*$/, clause),
             "a clause the test cannot read: #{clause}"

      {key, ~r/'([^']*)'/ |> Regex.scan(values) |> Enum.map(fn [_, value] -> value end)}
    end
  end

  test "the audit-backed rule files query logs, not traces" do
    for {name, rule} <- rules() do
      refute spec(rule)["signal"] == "traces", "#{name} still counts spans"

      case rule["labels"]["category"] do
        "security" ->
          assert rule["alertType"] == "LOGS_BASED_ALERT", name
          assert spec(rule)["signal"] == "logs", name

        "audit" ->
          assert rule["alertType"] == "METRIC_BASED_ALERT", name
          assert spec(rule)["signal"] == "metrics", name

        other ->
          flunk("#{name} has category #{inspect(other)}")
      end
    end

    names = for {_, rule} <- rules(), do: rule["alert"]
    assert length(names) == length(Enum.uniq(names)), "SigNoz provisions a rule by its name"
  end

  test "every attribute a rule filters on is one the exporter emits" do
    allowed = MapSet.new(OtlpExport.attribute_keys())
    closed = OtlpExport.closed_values()

    log_rules = for {name, rule} <- rules(), spec(rule)["signal"] == "logs", do: {name, rule}
    assert length(log_rules) == 4

    for {name, rule} <- log_rules do
      clauses = rule |> spec() |> get_in(["filter", "expression"]) |> clauses()

      for {key, values} <- clauses do
        assert key in allowed, "#{name} filters on #{key}, which no record carries"
        assert values != [], "#{name}: #{key} names no value"

        if allowed_values = closed[key] do
          assert values -- allowed_values == [],
                 "#{name}: #{key} has no value #{inspect(values -- allowed_values)}"
        end
      end

      assert [[resource_name]] = for({"audit.resource", values} <- clauses, do: values),
             "#{name} names exactly one resource"

      resource = Module.concat([resource_name])
      assert Code.ensure_loaded?(resource), "#{name}: #{resource_name} is no module"
      assert EventSource.audited?(resource), "#{name}: #{resource_name} writes no audit events"

      for {"audit.action", actions} <- clauses, action <- actions do
        assert Ash.Resource.Info.action(resource, String.to_existing_atom(action)),
               "#{name}: #{resource_name} has no action #{action}"
      end

      for group <- spec(rule)["groupBy"] do
        assert group["name"] == "service.name" and group["fieldContext"] == "resource",
               "#{name} groups by #{group["name"]}, which only the record's resource carries"
      end
    end
  end

  test "every metric a rule reads is one the application exports" do
    exported = MapSet.new(AshEnterpriseWeb.Telemetry.exported_metrics(), &Enum.join(&1.name, "."))

    metric_rules =
      for {name, rule} <- rules(), spec(rule)["signal"] == "metrics" do
        for aggregation <- spec(rule)["aggregations"] do
          assert aggregation["metricName"] in exported,
                 "#{name} reads #{aggregation["metricName"]}, which is not exported"

          aggregation["metricName"]
        end
      end

    # The reporter that exports them starts with these definitions.
    start_supervised!(
      {AshEnterprise.Telemetry.Metrics,
       metrics: AshEnterpriseWeb.Telemetry.exported_metrics(), vm: false}
    )

    :telemetry.execute(
      AshEnterprise.Audit.ExportWorker.event(),
      %{exported: 1, failed: 0, lag_seconds: 3},
      %{}
    )

    assert metric_rules |> List.flatten() |> Enum.sort() == [
             "ash_enterprise.audit.export.lag_seconds",
             "ash_enterprise.audit.retention.backlog",
             "ash_enterprise.audit.retention.failed"
           ]
  end
end
