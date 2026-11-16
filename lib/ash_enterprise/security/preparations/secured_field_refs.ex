defmodule AshEnterprise.Security.Preparations.SecuredFieldRefs do
  @moduledoc """
  A filter on a secured column matches only where the reader may see the column.

  A field policy (`AshEnterprise.Platform.Resource`'s `secured_fields`) withholds the
  column's value from the results, and Ash rewrites a filter a client supplied
  (`Ash.Query.filter_input/2`) the same way. A filter the application builds for a
  person is trusted as written, though: a search box that becomes
  `contains(number, ^text)`, or a lookup through a relationship such as
  `credential.number == ^number`, would answer "which row has this number" for someone
  who may not read the number. That is the column, leaked one question at a time.

  So every read of a platform resource that is authorized rewrites each reference to a
  secured column in its filter, on the resource or across a relationship, to
  `if <the column is visible on this row>, do: column, else: nil`, which is what Ash
  does for a client's filter. The visibility is the column grant's own filter
  (`{AshEnterprise.Security.Checks.RoleGrant, field: name}`), read from the precomputed
  `AshEnterprise.Security.ActorContext`: no query. A reader holding the grant at
  `:global`, a system actor, and a read with `authorize?: false` are left as written.

  It runs as a `before_action` hook, after every filter, preparation and policy has been
  applied, so a filter added after the action was built is covered too.

  Two uses of a secured column cannot be rewritten that way, and are refused with an
  `Ash.Error.Invalid` naming the column, for a reader who does not see the column on
  every row (a grant below `:global` included):

    * a sort that reads it, directly, across a relationship, or through a calculation or
      an aggregate. A sort orders the rows by the value, so the order would answer what
      the field policy withholds, and a keyset cursor built over it would let a reader
      search the hidden values page by page. Ash's keyset cursors are signed as well
      (`config :ash, :keyset_signing_secret`), so a cursor the reader wrote is refused
      whatever it sorts by.
    * a filter on a calculation or an aggregate that reads it. The data layer evaluates
      the expression, where the field policy does not apply.
  """

  use Ash.Resource.Preparation

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  alias AshEnterprise.Security.Checks.RoleGrant

  # It reads the actor's precomputed context and the query, never the clock, and adds
  # nothing a point in time would change.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def prepare(query, _opts, context) do
    if Map.get(context, :authorize?, false) do
      actor = Map.get(context, :actor)
      Ash.Query.before_action(query, &hide(&1, actor))
    else
      query
    end
  end

  @doc false
  @spec hide(Ash.Query.t(), term()) :: Ash.Query.t()
  def hide(%Ash.Query{} = query, actor) do
    case refusals(query, actor) do
      [] -> rewrite(query, actor)
      errors -> Ash.Query.add_error(query, errors)
    end
  end

  defp rewrite(%Ash.Query{filter: nil} = query, _actor), do: query

  defp rewrite(%Ash.Query{} = query, actor) do
    filter =
      Ash.Filter.map(query.filter, &replace(&1, query.resource, query.action, actor))

    if filter == query.filter do
      query
    else
      {:ok, hydrated} =
        Ash.Filter.hydrate_refs(filter, %{resource: query.resource, public?: false})

      %{query | filter: hydrated}
    end
  end

  defp replace(
         %Ash.Query.Ref{attribute: %Ash.Resource.Attribute{name: name}, relationship_path: path} =
           ref,
         resource,
         action,
         actor
       ) do
    target = Ash.Resource.Info.related(resource, path)

    if target && name in secured_fields(target) do
      action = if path == [], do: action, else: Ash.Resource.Info.primary_action(target, :read)

      case RoleGrant.filter(actor, %{resource: target, action: action}, field: name) do
        true ->
          {:halt, ref}

        visible ->
          visible = Ash.Filter.move_to_relationship_path(visible, path)
          {:halt, expr(if ^visible, do: ^ref, else: nil)}
      end
    else
      {:halt, ref}
    end
  end

  # A related `exists` refers to the related resource; an unrelated one to its own.
  defp replace(%Ash.Query.Exists{related?: true} = exists, resource, _action, actor) do
    target = Ash.Resource.Info.related(resource, exists.at_path ++ exists.path)
    {:halt, %{exists | expr: map_within(exists.expr, target, actor)}}
  end

  defp replace(%Ash.Query.Exists{resource: target} = exists, _resource, _action, actor) do
    {:halt, %{exists | expr: map_within(exists.expr, target, actor)}}
  end

  defp replace(other, _resource, _action, _actor), do: other

  defp map_within(expr, nil, _actor), do: expr

  defp map_within(expr, target, actor) do
    Ash.Filter.map(
      expr,
      &replace(&1, target, Ash.Resource.Info.primary_action(target, :read), actor)
    )
  end

  # --- what is refused ----------------------------------------------------------------

  defp refusals(query, actor) do
    sorts =
      for {target, name, _derived?} <- sort_reads(query),
          not everywhere?(actor, target, name, query) do
        Ash.Error.Query.UnsortableField.exception(
          resource: query.resource,
          field: name,
          reason: :secured
        )
      end

    filters =
      for {target, name, true} <- secured_reads(query.filter, query.resource),
          not everywhere?(actor, target, name, query) do
        Ash.Error.Query.InvalidFilterReference.exception(field: name)
      end

    Enum.uniq(sorts ++ filters)
  end

  defp sort_reads(%Ash.Query{sort: sort, resource: resource}) do
    sort
    |> List.wrap()
    |> Enum.flat_map(fn
      {field, _order} -> sort_field_reads(field, resource)
      field -> sort_field_reads(field, resource)
    end)
    |> Enum.uniq()
  end

  defp sort_field_reads(field, resource) when is_atom(field) do
    if field in secured_fields(resource),
      do: [{resource, field, false}],
      else: declared_reads(resource, field, [])
  end

  defp sort_field_reads(field, resource), do: secured_reads(field, resource)

  # Whether `actor` sees `name` on every row of `target`: the column's grant at `:global`,
  # or a system actor. A grant that reaches only some rows still sees an order over all.
  defp everywhere?(actor, target, name, query) do
    action =
      if target == query.resource,
        do: query.action,
        else: Ash.Resource.Info.primary_action(target, :read)

    RoleGrant.filter(actor, %{resource: target, action: action}, field: name) == true
  end

  @doc """
  Every secured column `expr` reads, evaluated on `resource`, as
  `{resource holding it, column, derived?}`. `derived?` is true when the read is inside a
  calculation or an aggregate, which the filter rewrite does not reach. A module
  calculation is opaque here; ADR 0073 says one that derives from a secured column reads
  it through the reader.
  """
  @spec secured_reads(term(), module()) :: [{module(), atom(), boolean()}]
  def secured_reads(expr, resource), do: expr |> walk(resource, [], false) |> Enum.uniq()

  defp walk(_expr, nil, _path, _derived?), do: []

  defp walk(
         %Ash.Query.Ref{attribute: attribute, relationship_path: rel},
         resource,
         path,
         derived?
       ) do
    case attribute do
      %Ash.Query.Calculation{} -> walk(attribute, resource, path ++ rel, true)
      %Ash.Query.Aggregate{} -> walk(attribute, resource, path ++ rel, true)
      %Ash.Resource.Calculation{} -> walk(attribute, resource, path ++ rel, true)
      %Ash.Resource.Aggregate{} -> walk(attribute, resource, path ++ rel, true)
      %{name: name} -> named_reads(resource, path ++ rel, name, derived?)
      name when is_atom(name) -> named_reads(resource, path ++ rel, name, derived?)
      _other -> []
    end
  end

  defp walk(
         %Ash.Query.Calculation{module: Ash.Resource.Calculation.Expression, opts: opts},
         resource,
         path,
         _derived?
       ),
       do: walk(opts[:expr], resource, path, true)

  defp walk(%Ash.Query.Calculation{}, _resource, _path, _derived?), do: []

  defp walk(
         %Ash.Resource.Calculation{calculation: {Ash.Resource.Calculation.Expression, opts}},
         resource,
         path,
         _derived?
       ),
       do: walk(opts[:expr], resource, path, true)

  defp walk(%Ash.Resource.Calculation{}, _resource, _path, _derived?), do: []

  defp walk(%Ash.Query.Aggregate{} = aggregate, resource, path, _derived?) do
    target =
      case aggregate.query do
        %Ash.Query{resource: target} -> target
        _none -> Ash.Resource.Info.related(resource, path ++ aggregate.relationship_path)
      end

    filter = with %Ash.Query{filter: filter} <- aggregate.query, do: filter
    aggregate_reads(target, aggregate.field) ++ walk(filter, target, [], true)
  end

  defp walk(%Ash.Resource.Aggregate{} = aggregate, resource, path, _derived?) do
    target =
      if aggregate.related?,
        do: Ash.Resource.Info.related(resource, path ++ aggregate.relationship_path),
        else: aggregate.resource

    aggregate_reads(target, aggregate.field) ++ walk(aggregate.filter, target, [], true)
  end

  defp walk(%Ash.Query.Exists{related?: true} = exists, resource, path, derived?),
    do: walk(exists.expr, resource, path ++ exists.at_path ++ exists.path, derived?)

  defp walk(%Ash.Query.Exists{} = exists, _resource, _path, derived?),
    do: walk(exists.expr, exists.resource, [], derived?)

  defp walk(%Ash.Query{}, _resource, _path, _derived?), do: []

  defp walk(%_{} = struct, resource, path, derived?),
    do: struct |> Map.from_struct() |> Map.values() |> walk(resource, path, derived?)

  defp walk(map, resource, path, derived?) when is_map(map),
    do: map |> Map.values() |> walk(resource, path, derived?)

  defp walk(list, resource, path, derived?) when is_list(list),
    do: Enum.flat_map(list, &walk(&1, resource, path, derived?))

  defp walk(tuple, resource, path, derived?) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk(resource, path, derived?)

  defp walk(_other, _resource, _path, _derived?), do: []

  # A reference by name: a secured column, or a calculation or aggregate the resource
  # declares, which is walked for what it reads.
  defp named_reads(resource, path, name, derived?) do
    case Ash.Resource.Info.related(resource, path) do
      nil ->
        []

      target ->
        if name in secured_fields(target),
          do: [{target, name, derived?}],
          else: declared_reads(target, name, [])
    end
  end

  defp declared_reads(resource, name, path) do
    cond do
      calculation = Ash.Resource.Info.calculation(resource, name) ->
        walk(calculation, resource, path, true)

      aggregate = Ash.Resource.Info.aggregate(resource, name) ->
        walk(aggregate, resource, path, true)

      true ->
        []
    end
  end

  defp aggregate_reads(nil, _field), do: []

  defp aggregate_reads(target, field) when is_atom(field) and not is_nil(field) do
    if field in secured_fields(target),
      do: [{target, field, true}],
      else: declared_reads(target, field, [])
  end

  defp aggregate_reads(target, %{} = field), do: walk(field, target, [], true)
  defp aggregate_reads(_target, _field), do: []

  defp secured_fields(resource) do
    if AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
      do: Spark.Dsl.Extension.get_opt(resource, [:platform], :secured_fields, []),
      else: []
  end
end
