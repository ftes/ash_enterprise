defmodule Mix.Tasks.AshEnterprise.Migrations.Rollback do
  @shortdoc "Rolls a repo back to its reversible floor, one migration at a time"

  @moduledoc """
  Rolls every applied migration newer than a floor back, newest first, through
  `AshEnterprise.Release.rollback/3` -- the call a deploy makes at 3am -- and names
  the migration whose `down` failed.

      mix ash_enterprise.migrations.rollback --floor 20261105033324
      mix ash_enterprise.migrations.rollback --repo AshEvidence.Repo --floor 20261101122916
      mix ash_enterprise.migrations.rollback --floor 20000101000000 --path test/fixtures/migrations/clean

  The floor stays applied. `scripts/migration-round-trip.sh` is the caller: it migrates,
  snapshots the schema, runs this, replays, and compares. `docs/runbooks/deploy-and-rollback.md`
  says what the floor is.

  Exits 1, naming the version, when a `down` raises.
  """

  use Mix.Task

  alias AshEnterprise.Release

  @requirements ["app.config"]

  @switches [repo: :string, floor: :string, path: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    repo = Module.concat([opts[:repo] || "AshEnterprise.Repo"])
    floor = opts |> Keyword.fetch!(:floor) |> String.to_integer()
    path_opts = if opts[:path], do: [migrations_path: opts[:path]], else: []

    Application.load(:ash_enterprise)
    {:ok, applied, _} = Ecto.Migrator.with_repo(repo, &applied_versions(&1, opts[:path]))

    newer = applied |> Enum.filter(&(&1 > floor)) |> Enum.sort(:desc)

    for version <- newer do
      try do
        Release.rollback(repo, version, path_opts)
        Mix.shell().info("rolled back #{version}")
      rescue
        error ->
          Mix.shell().error("down of #{version} failed: #{Exception.message(error)}")
          exit({:shutdown, 1})
      end
    end

    Mix.shell().info("#{repo} rolled back #{length(newer)} migration(s) to floor #{floor}")
  end

  # Versions that are applied and have a migration file: a version in the table with no file
  # (the other repo's, when two repos share the table) cannot be rolled back from here.
  defp applied_versions(repo, path) do
    paths = if path, do: [path], else: [Ecto.Migrator.migrations_path(repo)]

    for {:up, version, _name} <- Ecto.Migrator.migrations(repo, paths), do: version
  end
end
