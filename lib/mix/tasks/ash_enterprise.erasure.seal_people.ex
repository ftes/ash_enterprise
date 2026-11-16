defmodule Mix.Tasks.AshEnterprise.Erasure.SealPeople do
  @shortdoc "Seals every person's address under their own erasure scope (ADR 0024)"
  @moduledoc """
  The backfill for sealed people (`AshEnterprise.Canonical.PersonSeal.Backfill`):
  each `Canonical.Person` written before addresses were sealed gets its own
  erasure scope, its address sealed under it, its blind index, and its
  plaintext column blanked; a merge's prior address is sealed too.

      # What a run would seal: writes nothing, opens no scope
      mix ash_enterprise.erasure.seal_people

      # Seal
      mix ash_enterprise.erasure.seal_people --apply

      # One tenant only
      mix ash_enterprise.erasure.seal_people --apply --tenant <organization uuid>

  Prints counts only, never values:

    * `people`: rows that need sealing;
    * `sealed`: addresses sealed (on a dry run, to seal);
    * `provenance`: merge provenances whose prior address is sealed and whose
      merged values are dropped (on a dry run, to rewrite).

  A second run finds nothing to do. Run it once after deploying the expand
  migration, before the contract migration drops the plaintext column; until
  it runs, an unsealed person is found by the projectors through the old
  column and sealed then. Boots only the repo (iron law #23).
  """

  use Mix.Task

  alias AshEnterprise.Canonical.PersonSeal.Backfill
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]

  @switches [apply: :boolean, tenant: :string]

  @impl Mix.Task
  def run(argv) do
    {flags, _args, _invalid} = OptionParser.parse(argv, strict: @switches)
    apply? = Keyword.get(flags, :apply, false)

    Helpers.boot_repo()
    Helpers.load_domain_resources()

    counts = Backfill.run(apply?: apply?, tenant: Keyword.get(flags, :tenant))

    Mix.shell().info(
      if(apply?, do: "Sealed people.", else: "Dry run: nothing written.") <>
        Enum.map_join([:people, :sealed, :provenance], "", fn key ->
          "\n  #{key}: #{Map.fetch!(counts, key)}"
        end)
    )
  end
end
