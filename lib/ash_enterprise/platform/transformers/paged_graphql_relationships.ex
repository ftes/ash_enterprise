defmodule AshEnterprise.Platform.Transformers.PagedGraphqlRelationships do
  @moduledoc """
  Pages every to-many relationship a platform resource shows over GraphQL.

  AshGraphql exposes each public relationship whose destination has a GraphQL type as a
  field of the type. A `has_many` or `many_to_many` with no `paginate_relationship_with`
  entry is a plain list read through the destination's read action, and its `limit`
  argument is a query limit that no `max_page_size` clamps. So a list query that returns
  one page of business units could still carry every child of each, and
  `childBusinessUnits(limit: 1000000)` would be honoured.

  This sets `paginate_relationship_with` to `:keyset` for each such relationship the
  resource has not named itself. The field becomes a page: the destination read's
  `default_limit` when the client asks for none, never more than its `max_page_size`
  (both set by `AshEnterprise.Platform.Transformers.DefaultPagination`).
  `test/ash_enterprise/platform/bounded_reads_test.exs` checks every GraphQL to-many
  relationship field pages.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    if AshGraphql.Resource in Transformer.get_persisted(dsl, :extensions, []) do
      declared = Transformer.get_option(dsl, [:graphql], :paginate_relationship_with, [])

      shown? = shown_fn(dsl)

      paged =
        for %{cardinality: :many, public?: true, name: name} <-
              Transformer.get_entities(dsl, [:relationships]),
            shown?.(name),
            not Keyword.has_key?(declared, name),
            do: {name, :keyset}

      {:ok,
       Transformer.set_option(dsl, [:graphql], :paginate_relationship_with, declared ++ paged)}
    else
      {:ok, dsl}
    end
  end

  # Whether the type shows the relationship as a field: the `relationships` list when it
  # is given, `show_fields` when given, and never one in `hide_fields`. AshGraphql warns
  # about a paginated relationship it does not show.
  defp shown_fn(dsl) do
    listed = Transformer.get_option(dsl, [:graphql], :relationships)
    shown = Transformer.get_option(dsl, [:graphql], :show_fields)
    hidden = Transformer.get_option(dsl, [:graphql], :hide_fields) || []

    fn name ->
      (is_nil(listed) or name in listed) and (is_nil(shown) or name in shown) and
        name not in hidden
    end
  end
end
