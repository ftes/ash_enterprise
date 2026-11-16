defmodule AshEnterprise.Test.BoundedReads do
  @moduledoc """
  Finds every list surface the application exposes and says which of them could
  return a whole table.

  A surface is a JSON:API index route, a GraphQL list query, a GraphQL to-many
  relationship field or an AshAi read tool, in any configured domain or on any of
  its resources. Each names a read action; `problem/2` says what is wrong with that
  action for that surface, or `nil` when the surface is bounded, and `problem/1`
  adds what is wrong with the surface itself:

    * a JSON:API index or GraphQL list must name a read that pages whether or not
      the client asks (`required?` or `paginate_by_default?`), with a
      `default_limit` no larger than its `max_page_size`. ash_json_api pages only
      when the request carries page parameters, so anything less serves the table
      to a client that sends none.
    * an AshAi read tool always passes a limit (the agent's, or the action's
      `default_limit`, or 25), clamped to `max_page_size` only when the action
      pages. So the read must page, with a `default_limit` and a `max_page_size`;
      otherwise an agent's `limit` goes through unclamped. A manual read is
      reported too: AshAi hands its limit to code that may ignore it, so each one
      must be listed, with the bound it applies itself, where the check is run.
    * a GraphQL to-many relationship field (a `has_many` or `many_to_many` of a
      type, to a type) must page (`paginate_relationship_with`): unpaged it is a
      plain list, whose `limit` argument no `max_page_size` clamps, so one page of a
      list query can carry a whole child table. Its read must name a `default_limit`
      and a `max_page_size`.
  """

  alias Ash.Resource.Actions.Read

  @type surface_kind :: :json_api_index | :graphql_list | :graphql_relationship | :ash_ai_tool

  @type surface :: %{
          required(:kind) => surface_kind(),
          required(:domain) => module(),
          required(:resource) => module(),
          required(:name) => String.t(),
          required(:action) => struct() | nil,
          optional(:strategy) => atom() | nil
        }

  @doc """
  Every JSON:API index, GraphQL list, GraphQL to-many relationship field and AshAi
  read tool in `domains`.
  """
  @spec surfaces([module()]) :: [surface()]
  def surfaces(domains \\ Application.fetch_env!(:ash_enterprise, :ash_domains)) do
    Enum.flat_map(domains, fn domain ->
      json_api_indexes(domain) ++
        graphql_lists(domain) ++ graphql_relationships(domain) ++ ash_ai_reads(domain)
    end)
    |> Enum.uniq_by(&{&1.kind, &1.resource, &1.name})
  end

  defp json_api_indexes(domain) do
    resource_routes =
      Enum.flat_map(Ash.Domain.Info.resources(domain), fn resource ->
        Spark.Dsl.Extension.get_entities(resource, [:json_api, :routes])
        |> Enum.map(&Map.put(&1, :resource, resource))
      end)

    for route <- AshJsonApi.Domain.Info.routes(domain) ++ resource_routes,
        route.type == :index do
      surface(:json_api_index, domain, route.resource, "index #{route.route}", route.action)
    end
  end

  defp graphql_lists(domain) do
    resource_queries =
      Enum.flat_map(Ash.Domain.Info.resources(domain), fn resource ->
        Spark.Dsl.Extension.get_entities(resource, [:graphql, :queries])
        |> Enum.map(&Map.put(&1, :resource, resource))
      end)

    for query <- AshGraphql.Domain.Info.queries(domain) ++ resource_queries,
        query.type == :list do
      surface(:graphql_list, domain, query.resource, "list #{query.name}", query.action)
    end
  end

  # The relationship fields AshGraphql puts on a type: its public relationships (or the
  # ones it names) whose destination has a type too.
  defp graphql_relationships(domain) do
    for resource <- Ash.Domain.Info.resources(domain),
        graphql_type?(resource),
        name <- graphql_relationship_names(resource),
        relationship = Ash.Resource.Info.relationship(resource, name),
        relationship.cardinality == :many,
        graphql_type?(relationship.destination) do
      action =
        if relationship.read_action,
          do: Ash.Resource.Info.action(relationship.destination, relationship.read_action),
          else: Ash.Resource.Info.primary_action(relationship.destination, :read)

      %{
        kind: :graphql_relationship,
        domain: domain,
        resource: resource,
        name: "field #{name}",
        action: action,
        strategy: AshGraphql.Resource.relationship_pagination_strategy(resource, name, action)
      }
    end
  end

  defp graphql_type?(resource),
    do:
      AshGraphql.Resource in Spark.extensions(resource) and
        not is_nil(AshGraphql.Resource.Info.type(resource))

  defp graphql_relationship_names(resource) do
    shown = AshGraphql.Resource.Info.show_fields(resource)
    hidden = AshGraphql.Resource.Info.hide_fields(resource) || []

    case AshGraphql.Resource.Info.relationships(resource) do
      nil -> resource |> Ash.Resource.Info.public_relationships() |> Enum.map(& &1.name)
      names -> names
    end
    |> Enum.filter(&((is_nil(shown) or &1 in shown) and &1 not in hidden))
  end

  defp ash_ai_reads(domain) do
    resource_tools =
      Enum.flat_map(Ash.Domain.Info.resources(domain), fn resource ->
        resource |> AshAi.Info.tools() |> Enum.map(&Map.put(&1, :resource, resource))
      end)

    for tool <- AshAi.Info.tools(domain) ++ resource_tools,
        action = Ash.Resource.Info.action(tool.resource, tool.action),
        match?(%Read{}, action) do
      surface(:ash_ai_tool, domain, tool.resource, "tool #{tool.name}", tool.action)
    end
  end

  defp surface(kind, domain, resource, name, action_name) do
    %{
      kind: kind,
      domain: domain,
      resource: resource,
      name: name,
      action: Ash.Resource.Info.action(resource, action_name)
    }
  end

  @doc "What lets `surface` return an unbounded result, or `nil` when nothing does."
  @spec problem(surface()) :: String.t() | nil
  def problem(%{kind: :graphql_relationship, strategy: strategy})
      when strategy in [nil, :none],
      do: "a plain list: its limit is not clamped, and one page can carry the whole child table"

  def problem(%{kind: kind, action: action}), do: problem(kind, action)

  @doc "What lets this surface return an unbounded result, or `nil` when nothing does."
  @spec problem(surface_kind(), struct() | nil) :: String.t() | nil
  def problem(_kind, %Read{manual: manual}) when not is_nil(manual),
    do: "a manual read: whatever bound it has is its own code's"

  def problem(_kind, %Read{pagination: pagination}) when pagination in [nil, false],
    do: "does not page"

  def problem(kind, %Read{pagination: pagination})
      when kind in [:json_api_index, :graphql_list] do
    if pagination.required? or pagination.paginate_by_default? do
      page_size_problem(pagination)
    else
      "pages only when asked: a request without page parameters gets every row"
    end
  end

  def problem(kind, %Read{pagination: pagination})
      when kind in [:ash_ai_tool, :graphql_relationship],
      do: page_size_problem(pagination)

  def problem(_kind, other), do: "not a read action: #{inspect(other)}"

  defp page_size_problem(%{default_limit: nil}), do: "names no default_limit"

  defp page_size_problem(%{max_page_size: nil}),
    do: "names no max_page_size: a client may ask for any page size"

  defp page_size_problem(%{default_limit: limit, max_page_size: max}) when limit > max,
    do: "default_limit #{limit} is above max_page_size #{max}"

  defp page_size_problem(_pagination), do: nil
end
