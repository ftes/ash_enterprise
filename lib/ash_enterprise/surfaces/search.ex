defmodule AshEnterprise.Surfaces.Search do
  @moduledoc """
  Finding a record by what a person knows about it: a business reference (a
  credential's licence number) or a run id (a process run, a lineage run).

  Each registry entry declares the attributes that identify one of its
  records (`searchable`). `find/2` looks the typed value up in every surface
  the actor may open (`AshEnterprise.Surfaces.openable/1`) that declares
  some, as the actor: an authorized read of the surface's resource on its
  primary read action, so a record they may not read is not found. A value
  is only compared with an attribute it casts to, so a licence number never
  reaches a UUID column and a UUID is never compared with a name.

  A hit is a deep link (`/app/r/<surface>/<id>`), which re-authorizes when it
  is opened (`AshEnterprise.Surfaces.Records`), so a list read a moment ago is
  never trusted on its own.

  A surface whose read fails is reported in `failed`, never folded into "no
  match": a search that could not look somewhere says so.

  The casting, reading and reporting are `AshA2ui.Shell.Search`'s; this
  module says which surfaces are searched and maps a hit back to its
  surface.
  """

  alias AshA2ui.Shell.Search, as: ShellSearch
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Surface

  @typedoc "One record found: the surface it opens on, its id, the attribute that matched."
  @type hit :: %{surface: Surface.t(), id: String.t(), field: atom(), path: String.t()}

  @type result :: %{hits: [hit()], failed: [Surface.t()]}

  @doc """
  The records `term` identifies, for `actor`, across `surfaces` (by default
  every surface the actor may open that declares `searchable`). A blank term
  reads nothing.
  """
  @spec find(String.t() | nil, term(), [Surface.t()] | nil) :: result()
  def find(term, actor, surfaces \\ nil) do
    %{hits: hits, failed: failed} =
      ShellSearch.find(
        term,
        Enum.map(surfaces || searchable(actor), &entry/1),
        actor: actor,
        tenant: ActorContext.tenant(actor)
      )

    %{
      hits:
        Enum.map(hits, &%{surface: &1.entry.surface, id: &1.id, field: &1.field, path: &1.path}),
      failed: Enum.map(failed, & &1.surface)
    }
  end

  @doc "The surfaces `actor` may open that declare something to search."
  @spec searchable(term()) :: [Surface.t()]
  def searchable(actor), do: Enum.filter(Surfaces.openable(actor), &(&1.searchable != []))

  @doc """
  `searchable/1` as `AshA2ui.Shell.Search` entries, each carrying its
  surface: what `AshEnterpriseWeb.Shell.searchable/1` hands the shell.
  """
  @spec entries(term()) :: [ShellSearch.entry()]
  def entries(actor), do: Enum.map(searchable(actor), &entry/1)

  defp entry(%Surface{key: key} = surface) do
    %{
      key: key,
      resource: surface.resource,
      fields: surface.searchable,
      path: &"/app/r/#{key}/#{&1}",
      surface: surface
    }
  end
end
