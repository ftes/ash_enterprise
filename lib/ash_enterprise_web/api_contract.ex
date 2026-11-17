defmodule AshEnterpriseWeb.ApiContract do
  @moduledoc """
  The pinned shape of the public API (ADR 0019, amended).

  The JSON:API document (`AshJsonApi.OpenApi`) and the GraphQL schema (`Absinthe`) are
  both generated from the `Accounts` domain. This module renders them in a canonical
  form -- keys sorted, servers stripped -- and compares them with the files committed
  under `priv/api/`:

    * `openapi.json` and `schema.graphql`, the contract callers were promised;
    * `contract.lock.json`, the sha-256 of each, so an edit by hand shows;
    * `deprecations.json`, the announcements (`AshEnterpriseWeb.ApiContract.Deprecations`).

  `mix ash_enterprise.api.contract --check` fails on any drift, and `--write` re-pins
  but refuses a breaking change that no announcement permits. What counts as breaking
  is `AshEnterpriseWeb.ApiContract.Diff`. `docs/runbooks/changing-the-api.md` is the
  procedure.
  """

  alias AshEnterpriseWeb.ApiContract.{Deprecations, Diff}

  # Where the routers are mounted. The served OpenAPI document's paths carry the JSON:API
  # prefix, so the pinned one does too.
  @json_prefix "/api/json"
  @graphql_path "/gql"

  # The router passes the same two strings (`AshEnterpriseWeb.AshJsonApiRouter`), so the
  # document it serves is the pinned one.
  @title "Ash Enterprise API"
  @version "1.0"

  @openapi_file "priv/api/openapi.json"
  @graphql_file "priv/api/schema.graphql"
  @lock_file "priv/api/contract.lock.json"
  @deprecations_file "priv/api/deprecations.json"

  @doc "Where the JSON:API router is mounted."
  def json_prefix, do: @json_prefix

  @doc "Where the GraphQL endpoint is mounted."
  def graphql_path, do: @graphql_path

  @doc "The committed deprecations file, relative to the project root."
  def deprecations_file, do: @deprecations_file

  @doc "The domains the contract covers; the same ones the routers serve."
  def domains, do: [AshEnterprise.Accounts]

  @doc "The OpenAPI document as a plain map: the router's, with the deployment's servers left out."
  @spec openapi_document() :: map()
  def openapi_document do
    [
      domains: domains(),
      open_api_servers: [],
      prefix: @json_prefix,
      open_api_title: @title,
      open_api_version: @version
    ]
    |> AshJsonApi.OpenApi.spec()
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.delete("servers")
  end

  @doc "The OpenAPI document, rendered canonically."
  @spec openapi() :: String.t()
  def openapi, do: canonical_json(openapi_document())

  @doc "The GraphQL schema as SDL."
  @spec graphql_sdl() :: String.t()
  def graphql_sdl,
    do:
      Absinthe.Schema.to_sdl(AshEnterpriseWeb.GraphqlSchema)
      |> String.trim_trailing()
      |> Kernel.<>("\n")

  @doc "The lock for a pair of rendered files: each file's sha-256."
  @spec lock(String.t(), String.t()) :: String.t()
  def lock(openapi, sdl) do
    canonical_json(%{
      @openapi_file => AshOperations.Spec.sha256(openapi),
      @graphql_file => AshOperations.Spec.sha256(sdl)
    })
  end

  @doc "The files this build would pin, by path."
  @spec generated() :: %{String.t() => String.t()}
  def generated do
    openapi = openapi()
    sdl = graphql_sdl()
    %{@openapi_file => openapi, @graphql_file => sdl, @lock_file => lock(openapi, sdl)}
  end

  @doc """
  JSON with every object's keys sorted and `required` lists sorted, two-space indented,
  newline-terminated. The same data always renders to the same bytes.
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(term), do: Jason.encode!(ordered(term, nil), pretty: true) <> "\n"

  defp ordered(map, _key) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), ordered(v, to_string(k))} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list, "required") when is_list(list),
    do: list |> Enum.sort() |> Enum.map(&ordered(&1, nil))

  defp ordered(list, _key) when is_list(list), do: Enum.map(list, &ordered(&1, nil))
  defp ordered(other, _key), do: other

  @doc "Check the committed pin against this build, in `root`. `{:ok, []}` or `{:error, problems}`."
  @spec check(Path.t(), Date.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check(root \\ ".", today \\ Date.utc_today()) do
    generated = generated()

    pinned =
      Map.new(generated, fn {path, _} -> {path, read(Path.join(root, path))} end)

    missing =
      for {path, nil} <- pinned,
          do: "#{path} is missing; run `mix ash_enterprise.api.contract --write`"

    if missing != [] do
      {:error, missing}
    else
      problems =
        lock_problems(pinned) ++
          drift_problems(pinned, generated, root, today) ++
          deprecation_problems(pinned, root)

      if problems == [], do: {:ok, []}, else: {:error, problems}
    end
  end

  # The paths are this module's constants under a root a Mix task or a test passes.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp lock_problems(pinned) do
    expected = lock(pinned[@openapi_file], pinned[@graphql_file])

    if pinned[@lock_file] == expected,
      do: [],
      else: [
        "#{@lock_file} does not match the sha-256 of the pinned files: they were edited by hand"
      ]
  end

  defp drift_problems(pinned, generated, root, today) do
    if Map.take(pinned, [@openapi_file, @graphql_file]) ==
         Map.take(generated, [@openapi_file, @graphql_file]) do
      []
    else
      entries = deprecation_entries(root)
      diff = diff(pinned, generated)

      breaking =
        for f <- Diff.unannounced(diff.breaking, entries, today),
            do:
              "BREAKING #{f.element}: #{f.reason}, and no announced deprecation has reached its sunset"

      [
        "the API no longer matches the pinned contract; run `mix ash_enterprise.api.contract --write`"
        | breaking
      ] ++
        line_diff(pinned[@openapi_file], generated[@openapi_file], @openapi_file) ++
        line_diff(pinned[@graphql_file], generated[@graphql_file], @graphql_file)
    end
  end

  defp deprecation_problems(pinned, root) do
    {entries, _} = Deprecations.read!(Path.join(root, @deprecations_file))
    ids = Diff.element_ids(Jason.decode!(pinned[@openapi_file]), pinned[@graphql_file])
    Enum.map(Deprecations.problems(entries, ids), &"#{@deprecations_file}: #{&1}")
  end

  defp deprecation_entries(root) do
    {entries, _} = Deprecations.read!(Path.join(root, @deprecations_file))
    entries
  end

  @doc "Classify the change from the pinned files to the generated ones."
  @spec diff(map(), map()) :: %{breaking: [Diff.finding()], changed?: boolean()}
  def diff(pinned, generated) do
    Diff.classify(
      {Jason.decode!(pinned[@openapi_file]), pinned[@graphql_file]},
      {Jason.decode!(generated[@openapi_file]), generated[@graphql_file]}
    )
  end

  defp line_diff(same, same, _name), do: []

  defp line_diff(old, new, name) do
    changes =
      old
      |> String.split("\n")
      |> List.myers_difference(String.split(new, "\n"))
      |> Enum.flat_map(fn
        {:del, lines} -> Enum.map(lines, &"-#{&1}")
        {:ins, lines} -> Enum.map(lines, &"+#{&1}")
        {:eq, _} -> []
      end)

    shown = Enum.take(changes, 40)
    more = length(changes) - length(shown)

    ["#{name}:" | shown] ++ if(more > 0, do: ["... and #{more} more changed lines"], else: [])
  end

  @doc """
  Re-pin the contract in `root`.

  Refuses (`{:error, findings}`) when the change is breaking and some removed element
  has no announcement whose sunset has passed. Announcements that now have their
  element gone move to `retired` in `deprecations.json`.
  """
  @spec write(Path.t(), Date.t()) :: {:ok, [String.t()]} | {:error, [Diff.finding()]}
  # sobelow_skip ["Traversal.FileModule"]
  def write(root \\ ".", today \\ Date.utc_today()) do
    generated = generated()
    {entries, retired} = Deprecations.read!(Path.join(root, @deprecations_file))

    pinned =
      for {path, _} <- generated,
          content = read(Path.join(root, path)),
          into: %{},
          do: {path, content}

    refused =
      if Map.has_key?(pinned, @openapi_file) and Map.has_key?(pinned, @graphql_file) do
        pinned |> diff(generated) |> Map.fetch!(:breaking) |> Diff.unannounced(entries, today)
      else
        []
      end

    if refused != [] do
      {:error, refused}
    else
      File.mkdir_p!(Path.join(root, "priv/api"))
      for {path, content} <- generated, do: File.write!(Path.join(root, path), content)

      ids = Diff.element_ids(Jason.decode!(generated[@openapi_file]), generated[@graphql_file])

      {live, gone} =
        Enum.split_with(
          entries,
          &(&1.element == Deprecations.graphql_endpoint_element() or
              MapSet.member?(ids, &1.element))
        )

      done =
        Enum.map(
          gone,
          &%{
            "element" => &1.element,
            "announced" => Date.to_iso8601(&1.announced),
            "sunset" => Date.to_iso8601(&1.sunset),
            "link" => &1.link
          }
        )

      File.write!(Path.join(root, @deprecations_file), Deprecations.encode(live, retired ++ done))

      {:ok, Map.keys(generated)}
    end
  end
end
