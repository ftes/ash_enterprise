defmodule Mix.Tasks.AshEnterprise.Residency do
  @shortdoc "Report where this deployment's data rests and where it can go"

  @moduledoc """
  Lists every store and egress destination the running configuration reaches,
  with the declared zone it is in (`AshEnterprise.Zones.ResidencyReport`).

      mix ash_enterprise.residency            # print the report
      mix ash_enterprise.residency --check    # also exit non-zero on any failing verdict

  Reads `ZONE_DECLARATIONS` and `STORE_DECLARATIONS` from the environment the
  task runs in; run it in the deployment's own environment. See
  `docs/runbooks/residency.md`.
  """

  use Mix.Task

  alias AshEnterprise.Zones.ResidencyReport

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [check: :boolean])

    report = ResidencyReport.build()
    Mix.shell().info(ResidencyReport.render(report))

    if opts[:check] && not report.ok? do
      Mix.shell().error("\nResidency check failed: see the failing verdicts above.")
      exit({:shutdown, 1})
    end
  end
end
