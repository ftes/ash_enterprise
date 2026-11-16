defmodule Mix.Tasks.AshEnterprise.Migrations.Sql do
  @shortdoc "Writes the SQL each migration newer than a floor runs, one file per version"

  @moduledoc """
  Ecto migrations are Elixir, and a SQL linter reads SQL. This applies every migration newer
  than a floor, one at a time, and writes the statements each one sent to the database to
  `<out>/<version>.sql`.

      mix ash_enterprise.migrations.sql --floor 20261105033324 --out tmp/migration-sql
      mix ash_enterprise.migrations.sql --floor 20000101000000 --path test/fixtures/migrations/drop_column --out tmp/sql

  The database is first migrated to the floor, so each migration runs on the schema it was
  written for. Statements are read from the repo's query telemetry while the migrator runs
  with `log_migrations_sql` on; the migrator's own bookkeeping (`schema_migrations`) is left out.
  `scripts/migration-lint.sh` runs Squawk over the result.

  This leaves the database at the newest version: point it at a scratch database.
  """

  use Mix.Task

  alias AshEnterprise.Release

  @requirements ["app.config"]

  @switches [repo: :string, floor: :string, path: :string, out: :string]

  @table :ash_enterprise_migration_sql

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    repo = Module.concat([opts[:repo] || "AshEnterprise.Repo"])
    floor = opts |> Keyword.fetch!(:floor) |> String.to_integer()
    out = Keyword.fetch!(opts, :out)
    path = opts[:path]
    path_opts = if path, do: [migrations_path: path], else: []

    Application.load(:ash_enterprise)
    File.mkdir_p!(out)

    versions =
      ((path && [path]) || repo_paths(repo))
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.exs")))
      |> Enum.map(
        &(&1
          |> Path.basename()
          |> String.split("_", parts: 2)
          |> hd()
          |> String.to_integer())
      )
      |> Enum.filter(&(&1 > floor))
      |> Enum.sort()

    :ok = Release.migrate([repos: [repo], to: floor] ++ path_opts)

    :ets.new(@table, [:named_table, :public, :duplicate_bag])
    handler = "ash-enterprise-migration-sql-#{System.unique_integer([:positive])}"

    :telemetry.attach(handler, event(repo), &__MODULE__.record/4, nil)

    try do
      for version <- versions do
        :ets.delete(@table, :current)
        :ets.insert(@table, {:current, version})

        :ok =
          Release.migrate(
            [repos: [repo], to: version, migrator_opts: [log_migrations_sql: :debug]] ++ path_opts
          )
      end
    after
      :telemetry.detach(handler)
    end

    write(out, versions)

    Mix.shell().info(
      "wrote the SQL of #{length(versions)} migration(s) newer than #{floor} to #{out}"
    )
  end

  @doc false
  def record(_event, _measurements, %{query: query}, _config) do
    case :ets.lookup(@table, :current) do
      [{:current, version}] ->
        unless bookkeeping?(query), do: :ets.insert(@table, {version, query})

      [] ->
        :ok
    end
  end

  def record(_event, _measurements, _metadata, _config), do: :ok

  # The migrator's own statements, and the transaction frame around the migration.
  defp bookkeeping?(query) do
    String.contains?(query, "schema_migrations") or
      query in ["begin", "commit", "rollback"] or
      String.starts_with?(query, "SELECT pg_try_advisory")
  end

  defp write(out, versions) do
    for version <- versions do
      statements = for {_version, query} <- :ets.lookup(@table, version), do: query

      File.write!(
        Path.join(out, "#{version}.sql"),
        Enum.map_join(statements, "\n", &(&1 <> ";")) <> "\n"
      )
    end
  end

  defp event(repo), do: Keyword.fetch!(repo.config(), :telemetry_prefix) ++ [:query]

  defp repo_paths(repo), do: [Ecto.Migrator.migrations_path(repo)]
end
