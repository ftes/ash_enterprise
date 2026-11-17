defmodule AshEnterprise.Audit.OtlpExport do
  @moduledoc """
  One committed audit event as one OpenTelemetry log record: the body of an OTLP/HTTP JSON
  `POST /v1/logs` (`AshEnterprise.Audit.ExportWorker` sends it).

  Pure: no reads, no clock but the one passed in.

  ## What a record carries, and nothing else

  A fixed allowlist of structural fields. Every key below is one of `attribute_keys/0`, and
  `test/ash_enterprise/audit/otlp_export_test.exs` checks that no other key and no value of
  an event's `data`, `changed_attributes` or `metadata` leaves:

  | Attribute | From the event | Type |
  |---|---|---|
  | `audit.resource` | `resource`, short form (`AshEnterprise.Security.UserRole`) | string |
  | `audit.action` | `action` | string |
  | `audit.action_type` | `action_type` (`create`, `update`, `destroy`) | string |
  | `audit.actor_id` | `user_id`, when a person acted | string |
  | `audit.system_actor` | `metadata["system_actor"]`, when a system actor did | string |
  | `audit.tenant_id` | `organization_id`; absent on the chain with no tenant | string |
  | `audit.sequence` | `sequence`, the event's place in its chain | int |
  | `audit.hash` | `hash` | string |
  | `audit.previous_hash` | `previous_hash` | string |
  | `correlation_id` | `correlation_id`, the operation the event belongs to | string |

  The record's time is the event's `occurred_at`. Its body is `"<resource>.<action>"`.
  Never `record_id`, `data`, `changed_attributes` or any other metadata value: the export
  says that something happened and who did it, and the chain in the database stays the
  only place that says to what.

  ## Structural fields of a few resources

  A resource whose audited rows are themselves made of closed sets may add those fields, so
  a rule can count them. Each value is checked against its resource's own closed set and
  left out when it is not one, so free text can never travel this way:

  | Resource | Attributes |
  |---|---|
  | `AshEnterprise.Security.AuthenticationEvent` | `audit.authentication.door`, `audit.authentication.outcome`, `audit.authentication.reason` |

  ## Delivery and its dedupe key

  The worker delivers at least once: a batch acknowledged by the endpoint whose cursor
  update then fails is sent again. `(audit.tenant_id, audit.sequence, audit.hash)` names one
  event exactly, so a consumer can drop the repeat.
  """

  alias AshEnterprise.Security.AuthenticationEvent

  @scope "ash_enterprise.audit"

  @base_keys ~w(
    audit.resource audit.action audit.action_type audit.actor_id audit.system_actor
    audit.tenant_id audit.sequence audit.hash audit.previous_hash correlation_id
  )

  @authentication_keys ~w(
    audit.authentication.door audit.authentication.outcome audit.authentication.reason
  )

  @authentication_resource inspect(AuthenticationEvent)

  @doc "Every attribute key a record may carry."
  @spec attribute_keys() :: [String.t()]
  def attribute_keys, do: @base_keys ++ @authentication_keys

  @doc """
  The values a structural attribute may take, for the attributes that have a closed set.
  A rule filtering on one of these may name only these values.
  """
  @spec closed_values() :: %{String.t() => [String.t()]}
  def closed_values do
    %{
      "audit.action_type" => ~w(create update destroy),
      "audit.authentication.door" => Enum.map(AuthenticationEvent.doors(), &to_string/1),
      "audit.authentication.outcome" => Enum.map(AuthenticationEvent.outcomes(), &to_string/1),
      "audit.authentication.reason" => Enum.map(AuthenticationEvent.reasons(), &to_string/1)
    }
  end

  @doc "The instrumentation scope every record is sent under."
  def scope, do: @scope

  @doc """
  The OTLP/HTTP JSON body for `events`, all of one chain. Options: `:service_name`
  (default `"ash_enterprise"`), `:now` (the observed time).
  """
  @spec request_body([struct()], keyword()) :: map()
  def request_body(events, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    %{
      "resourceLogs" => [
        %{
          "resource" => %{
            "attributes" =>
              attributes(%{
                "service.name" => Keyword.get(opts, :service_name, "ash_enterprise"),
                "service.namespace" => "ash_enterprise"
              })
          },
          "scopeLogs" => [
            %{
              "scope" => %{"name" => @scope},
              "logRecords" => Enum.map(events, &log_record(&1, now))
            }
          ]
        }
      ]
    }
  end

  @doc "One event as one OTLP log record (`observed` is when it was read for export)."
  @spec log_record(struct(), DateTime.t()) :: map()
  def log_record(event, observed \\ DateTime.utc_now()) do
    %{
      "timeUnixNano" => nanos(event.occurred_at),
      "observedTimeUnixNano" => nanos(observed),
      "severityNumber" => 9,
      "severityText" => "INFO",
      "body" => %{
        "stringValue" => resource_name(event.resource) <> "." <> to_string(event.action)
      },
      "attributes" => event |> fields() |> attributes()
    }
  end

  @doc "The allowlisted fields of one event, as a flat map of attribute key to value."
  @spec fields(struct()) :: %{String.t() => String.t() | integer()}
  def fields(event) do
    resource = resource_name(event.resource)

    %{
      "audit.resource" => resource,
      "audit.action" => to_string(event.action),
      "audit.action_type" => to_string(event.action_type),
      "audit.actor_id" => event.user_id,
      "audit.system_actor" => metadata(event, "system_actor"),
      "audit.tenant_id" => event.organization_id,
      "audit.sequence" => event.sequence,
      "audit.hash" => event.hash,
      "audit.previous_hash" => event.previous_hash,
      "correlation_id" => event.correlation_id
    }
    |> Map.merge(structural(resource, event))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, scalar(value)} end)
  end

  # A sign-in's door, outcome and reason: each a member of AuthenticationEvent's own closed
  # set, or left out.
  defp structural(@authentication_resource, event) do
    data = event.data || %{}
    closed = closed_values()

    for {key, field} <- [
          {"audit.authentication.door", "door"},
          {"audit.authentication.outcome", "outcome"},
          {"audit.authentication.reason", "reason"}
        ],
        value = data |> Map.get(field) |> closed_value(closed[key]),
        into: %{},
        do: {key, value}
  end

  defp structural(_resource, _event), do: %{}

  defp closed_value(nil, _allowed), do: nil

  defp closed_value(value, allowed) do
    value = to_string(value)
    if value in allowed, do: value
  end

  defp metadata(event, key) do
    case event.metadata do
      %{^key => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp scalar(value) when is_integer(value), do: value
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value), do: to_string(value)

  defp attributes(map) do
    map
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => any_value(value)} end)
  end

  # OTLP JSON encodes a 64-bit integer as a decimal string.
  defp any_value(value) when is_integer(value), do: %{"intValue" => Integer.to_string(value)}
  defp any_value(value), do: %{"stringValue" => value}

  defp nanos(%DateTime{} = at), do: at |> DateTime.to_unix(:nanosecond) |> Integer.to_string()

  @doc """
  The short name of a resource as the event records it (`AshEnterprise.Security.Role`),
  the spelling `AshEnterprise.Audit.EventSource` gives a guard.
  """
  @spec resource_name(atom() | String.t()) :: String.t()
  def resource_name(resource) when is_atom(resource), do: inspect(resource)

  def resource_name(resource) when is_binary(resource),
    do: String.replace_prefix(resource, "Elixir.", "")
end
