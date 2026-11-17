defmodule Mix.Tasks.AshEnterprise.Api.Contract do
  @shortdoc "Pin the public API contract, or check that it has not drifted"

  @moduledoc """
  The OpenAPI document and the GraphQL schema are committed under `priv/api/`.

      mix ash_enterprise.api.contract --check   # fail on any drift from the pin
      mix ash_enterprise.api.contract --write   # re-pin the contract

  `--check` fails when the API generated from the resources differs from the pin, when
  a pinned file was edited by hand (`contract.lock.json`), and when
  `priv/api/deprecations.json` names something the contract does not hold.

  `--write` refuses a breaking change (a removed route, property, GraphQL field or
  argument, a changed type, something newly required of a caller) unless
  `deprecations.json` announced it and its sunset has passed. An additive change
  re-pins freely. See `docs/runbooks/changing-the-api.md`.
  """

  use Mix.Task

  alias AshEnterpriseWeb.ApiContract

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [check: :boolean, write: :boolean])
    Mix.Task.run("compile")

    cond do
      opts[:check] -> check()
      opts[:write] -> write()
      true -> Mix.raise("pass --check or --write")
    end
  end

  defp check do
    case ApiContract.check() do
      {:ok, _} ->
        Mix.shell().info("The API matches the pinned contract in priv/api/.")

      {:error, problems} ->
        Mix.shell().error(
          "\nThe API contract check failed:\n\n" <>
            Enum.map_join(problems, "\n", &"  #{&1}") <> "\n"
        )

        exit({:shutdown, 1})
    end
  end

  defp write do
    case ApiContract.write() do
      {:ok, paths} ->
        Mix.shell().info("Pinned " <> Enum.join(Enum.sort(paths), ", ") <> ".")

      {:error, refused} ->
        lines = Enum.map_join(refused, "\n", &"  #{&1.element}: #{&1.reason}")

        Mix.shell().error("""

        Not pinned: these changes break callers and no announcement permits them.

        #{lines}

        Announce each in priv/api/deprecations.json (at least #{ApiContract.Deprecations.minimum_notice_days()} days before its sunset),
        keep it until the sunset has passed, then remove it. See docs/runbooks/changing-the-api.md.
        """)

        exit({:shutdown, 1})
    end
  end
end
