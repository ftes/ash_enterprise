defmodule AshEnterprise.Zones.ResidencyReport do
  @moduledoc """
  Where this deployment's data rests and where it can go, against the zones it
  declared ([ADR 0042](../../../docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)).

  The model is one deployment per jurisdiction: the database's physical region is
  the deployment's declared zone, and every other store or destination the
  deployment is configured to reach is either declared to be in a zone or
  reported as outside it. Tenancy inside the database is attribute-based; this
  report says nothing about which tenant's rows are where.

  ## Targets

  `targets/0` reads the running configuration, so a destination switched on by an
  environment variable shows up without anyone editing a list:

    * `database` (a store) and `oban` (a store that rides the same database and
      inherits its declaration);
    * `telemetry_exporter`, `lineage_collector`, `integration_broker`,
      `credential_registry`, `model_in_zone` and `model_hosted` (egress
      destinations), each only while it is configured. Each names the row of the
      egress register (`AshEnterprise.Governance.DataFlows`) that describes what it
      can carry, so there is one list of egress paths, not two.

  A host that is loopback is `co_located`: it shares the deployment's machine and
  leaves nothing. Any other egress host needs a declaration.

  ## Declarations

  The deployment maps target ids to zone ids in a JSON file, named by
  `STORE_DECLARATIONS` (like a zone declaration it describes the deployment's own
  infrastructure, so it lives with the deployment, never in this repository):

      {"stores": {"database": {"zone": "eu-1"}, "telemetry_exporter": {"zone": "eu-1"}}}

  ## Verdicts

  | Verdict | Meaning | `--check` |
  |---|---|---|
  | `in_zone` | mapped to a declared zone whose review date has not passed | passes |
  | `co_located` | an egress host on the loopback interface | passes |
  | `blocked` | the hosted model target while `REQUIRE_IN_ZONE_MODELS` refuses it | passes |
  | `unknown` | a store nobody has mapped to a zone | fails |
  | `leaves_zone` | an egress host nobody has declared to be inside a zone | fails |
  | `undeclared_zone` | mapped to a zone id that no zone declaration defines | fails |
  | `lapsed` | mapped to a zone whose declaration is past its review date | fails |

  A declaration naming a target the deployment does not have is reported as
  `unrecognised` and fails the check too, so a typo cannot hide a store.
  """

  alias AshEnterprise.Zones
  alias AshEnterprise.Zones.Zone

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Zones).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @type verdict ::
          :in_zone | :co_located | :blocked | :unknown | :leaves_zone | :undeclared_zone | :lapsed

  @type target :: %{
          required(:id) => String.t(),
          required(:kind) => :store | :egress,
          required(:host) => String.t() | nil,
          required(:register_id) => atom() | nil,
          required(:inherits) => String.t() | nil,
          optional(:blocked?) => boolean()
        }

  @failing [:unknown, :leaves_zone, :undeclared_zone, :lapsed]

  @doc "The configured declaration file path, or nil."
  @spec declaration_source() :: String.t() | nil
  def declaration_source do
    :ash_enterprise |> Application.get_env(__MODULE__, []) |> Keyword.get(:stores)
  end

  @doc """
  Reads the declared `target id => zone id` map from `path` (default: the
  configured file; nil means nothing is declared). Raises on an unreadable file
  or one that is not the documented shape.
  """
  @spec load_stores(String.t() | nil) :: %{String.t() => String.t()}
  def load_stores(path \\ declaration_source())
  def load_stores(nil), do: %{}
  def load_stores(""), do: %{}

  def load_stores(path) do
    with {:ok, body} <- read(path),
         {:ok, %{"stores" => stores}} when is_map(stores) <- Jason.decode(body) do
      Map.new(stores, fn
        {id, %{"zone" => zone}} when is_binary(zone) and zone != "" ->
          {id, zone}

        {id, _} ->
          raise ArgumentError, "store declaration #{inspect(id)} in #{path} needs a \"zone\""
      end)
    else
      {:error, reason} ->
        raise ArgumentError, "cannot read store declarations #{path}: #{inspect(reason)}"

      _ ->
        raise ArgumentError,
              ~s(store declarations #{path} must be {"stores": {id: {"zone": ...}}})
    end
  end

  # The path is the operator's own `STORE_DECLARATIONS` setting (or a test's), never
  # request input; if request input ever reaches this function, that is a real finding.
  @sobelow_skip ["Traversal.FileModule"]
  defp read(path), do: File.read(path)

  @doc "The stores and egress destinations this deployment is configured with."
  @spec targets() :: [target()]
  def targets do
    [
      store("database", repo_host(), nil),
      %{store("oban", repo_host(), nil) | inherits: "database"},
      egress(
        "telemetry_exporter",
        env(:opentelemetry_exporter, :otlp_endpoint),
        :observability_exporter
      ),
      egress("lineage_collector", env(:ash_open_lineage, :http_base_url), :lineage_collector),
      egress(
        "integration_broker",
        AshEnterprise.Integration.Nango.Proxy.base_url(),
        :integration_provider_proxy
      ),
      egress("credential_registry", registry_url(), nil)
    ]
    |> Kernel.++(model_targets())
    |> Enum.reject(
      &(is_nil(&1.host) and &1.kind == :egress and not Map.get(&1, :blocked?, false))
    )
  end

  @doc """
  The report: every target with its verdict, plus declarations that match no
  target. Options override the configured inputs: `:targets`, `:stores`
  (`id => zone id`), `:zones` and `:on` (the date reviews are checked against).
  """
  @spec build(keyword()) :: %{rows: [map()], unrecognised: [String.t()], ok?: boolean()}
  def build(opts \\ []) do
    targets = Keyword.get_lazy(opts, :targets, &targets/0)
    stores = Keyword.get_lazy(opts, :stores, &load_stores/0)
    zones = opts |> Keyword.get_lazy(:zones, &Zones.all/0) |> Map.new(&{&1.id, &1})
    on = Keyword.get_lazy(opts, :on, &Date.utc_today/0)

    rows = Enum.map(targets, &row(&1, stores, zones, on))
    known = MapSet.new(targets, & &1.id)
    unrecognised = stores |> Map.keys() |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()

    %{
      rows: rows,
      unrecognised: unrecognised,
      ok?: unrecognised == [] and Enum.all?(rows, &pass?/1)
    }
  end

  @doc "Whether the row's verdict passes `--check`."
  @spec pass?(map()) :: boolean()
  def pass?(%{verdict: verdict}), do: verdict not in @failing

  @doc "The report as text, one line per target."
  @spec render(map()) :: String.t()
  def render(%{rows: rows, unrecognised: unrecognised}) do
    lines =
      for r <- rows do
        zone = r.zone || "-"
        host = r.host || "-"

        "#{String.pad_trailing(r.id, 22)} #{String.pad_trailing(to_string(r.kind), 7)} #{String.pad_trailing(to_string(r.verdict), 16)} zone=#{zone} host=#{host}"
      end

    extra =
      Enum.map(
        unrecognised,
        &"unrecognised declaration: #{&1} matches no target of this deployment"
      )

    Enum.join(lines ++ extra, "\n")
  end

  defp row(target, stores, zones, on) do
    {zone_id, via} = declared_zone(target, stores)
    zone = zone_id && Map.get(zones, zone_id)

    verdict =
      cond do
        Map.get(target, :blocked?, false) -> :blocked
        zone_id == nil -> unmapped(target)
        zone == nil -> :undeclared_zone
        Zone.lapsed?(zone, on) -> :lapsed
        true -> :in_zone
      end

    %{
      id: target.id,
      kind: target.kind,
      host: target.host,
      register_id: target.register_id,
      zone: zone_id,
      jurisdiction: zone && zone.jurisdiction,
      review_by: zone && zone.review_by,
      via: via,
      verdict: verdict
    }
  end

  defp declared_zone(%{inherits: parent, id: id}, stores) when is_binary(parent) do
    case Map.fetch(stores, id) do
      {:ok, zone} -> {zone, id}
      :error -> {Map.get(stores, parent), parent}
    end
  end

  defp declared_zone(%{id: id}, stores), do: {Map.get(stores, id), id}

  defp unmapped(%{kind: :store}), do: :unknown
  defp unmapped(%{host: host}), do: if(loopback?(host), do: :co_located, else: :leaves_zone)

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp store(id, host, register_id),
    do: %{id: id, kind: :store, host: host, register_id: register_id, inherits: nil}

  defp egress(id, url, register_id),
    do: %{id: id, kind: :egress, host: host_of(url), register_id: register_id, inherits: nil}

  defp model_targets do
    ai = Application.get_env(:ash_enterprise, :ai, [])
    in_zone = Keyword.get(ai, :in_zone_generative)

    [
      egress("model_in_zone", in_zone && Keyword.get(in_zone, :base_url), :model_calls_guarded),
      %{
        id: "model_hosted",
        kind: :egress,
        host: "provider default",
        register_id: :model_calls_guarded,
        inherits: nil,
        blocked?: Keyword.get(ai, :require_in_zone_models) == true
      }
    ]
  end

  defp registry_url do
    settings =
      Application.get_env(:ash_enterprise, AshEnterprise.Credentialing.RegistryApi.Transport, [])

    Keyword.get(settings, :base_url)
  end

  defp repo_host do
    config = Application.get_env(:ash_enterprise, AshEnterprise.Repo, [])

    case config[:url] do
      url when is_binary(url) and url != "" -> host_of(url)
      _ -> config[:hostname] && to_string(config[:hostname])
    end
  end

  defp env(app, key), do: Application.get_env(app, key)

  defp host_of(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp host_of(_), do: nil
end
