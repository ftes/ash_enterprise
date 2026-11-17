# Fails when a CycloneDX SBOM does not cover what mix.lock pins.
#
#   elixir scripts/sbom-covers-lock.exs BOM.json [--lock mix.lock] [--only NAMES_FILE]
#   elixir scripts/sbom-covers-lock.exs BOM.json --npm-lock assets/package-lock.json
#   elixir scripts/sbom-covers-lock.exs --self-test
#
# For every dependency in mix.lock (restricted to the names in NAMES_FILE, one
# per line, when given -- CI passes the production dependencies) the BOM must
# list a component of that name recorded at the locked version (a Hex package)
# or at the locked commit (a git dependency). A dependency that is absent, or
# present at a different version or commit, is named and the script exits 1.
#
# This is the drift check: a BOM generator that silently skips git
# dependencies, or a BOM built from a stale lock, fails here rather than
# passing as "an SBOM was produced". It reads the lock and the BOM only; it
# needs no Mix project and no network.
#
# With --npm-lock the same is done for an npm package-lock.json: every
# non-dev, non-link package in the lockfile must be in the BOM at its version.

defmodule SbomCoversLock do
  @moduledoc false

  def main(["--self-test"]), do: self_test()

  def main([bom | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest, strict: [lock: :string, only: :string, npm_lock: :string])

    only =
      opts[:only] && opts[:only] |> File.read!() |> String.split("\n", trim: true) |> MapSet.new()

    result =
      case opts[:npm_lock] do
        nil -> check(File.read!(bom), File.read!(opts[:lock] || "mix.lock"), only)
        npm -> check_npm(File.read!(bom), File.read!(npm))
      end

    case result do
      {:ok, count} ->
        IO.puts("SBOM covers all #{count} locked dependencies")

      {:error, problems} ->
        Enum.each(problems, &IO.puts(:stderr, "SBOM gap: " <> &1))
        System.halt(1)
    end
  end

  def main(_),
    do:
      (
        IO.puts(:stderr, "usage: see the header of this file")
        System.halt(2)
      )

  # Returns {:ok, checked_count} or {:error, [problem]}.
  def check(bom_json, lock_text, only \\ nil) do
    components = bom_json |> JSON.decode!() |> Map.get("components", [])
    # mix.lock quotes its keys, which the evaluator warns about for every entry.
    {{lock, _}, _} = Code.with_diagnostics(fn -> Code.eval_string(lock_text) end)

    wanted =
      for {name, entry} <- lock,
          only == nil or MapSet.member?(only, to_string(name)),
          do: {to_string(name), pin(entry)}

    problems =
      for {name, pin} <- wanted, problem = problem(name, pin, components), do: problem

    case problems do
      [] -> {:ok, length(wanted)}
      _ -> {:error, problems}
    end
  end

  # npm: packages in the lockfile that ship to the browser bundle (not dev-only,
  # not workspace links) must be in the BOM at the locked version.
  def check_npm(bom_json, lock_json) do
    components = bom_json |> JSON.decode!() |> Map.get("components", []) |> flatten()
    packages = lock_json |> JSON.decode!() |> Map.get("packages", %{})

    wanted =
      for {path, meta} <- packages,
          path != "",
          !(meta["dev"] || meta["link"]),
          do: {path |> String.split("node_modules/") |> List.last(), meta["version"]}

    wanted = Enum.uniq(wanted)

    problems =
      for {name, version} <- wanted,
          not Enum.any?(components, &(npm_name(&1) == name and &1["version"] == version)),
          do:
            "npm #{name}@#{version} is locked but missing from the BOM (or recorded at another version)"

    if problems == [], do: {:ok, length(wanted)}, else: {:error, problems}
  end

  # cyclonedx-npm records a scoped package as group "@scope" and name "pkg",
  # and nests the packages a package bundles under that package.
  defp npm_name(%{"group" => group, "name" => name}) when group not in [nil, ""],
    do: group <> "/" <> name

  defp npm_name(c), do: c["name"]

  defp flatten(components), do: Enum.flat_map(components, &[&1 | flatten(&1["components"] || [])])

  defp pin({:hex, _, version, _, _, _, _, _}), do: {:version, version}
  defp pin({:git, _url, commit, _opts}), do: {:commit, commit}
  defp pin(other), do: {:unknown, inspect(other)}

  defp problem(name, {:unknown, what}, _), do: "#{name}: unrecognised lock entry #{what}"

  defp problem(name, pin, components) do
    named = Enum.filter(components, &(&1["name"] == name))

    cond do
      named == [] -> "#{name} is locked but missing from the BOM"
      Enum.any?(named, &matches?(&1, pin)) -> nil
      true -> "#{name} is in the BOM at #{recorded(named)}, but mix.lock pins #{describe(pin)}"
    end
  end

  defp matches?(c, {:version, v}), do: c["version"] == v
  defp matches?(c, {:commit, sha}), do: sha in haystack(c)

  # Where a generator may have put a git commit: the version, the purl, or a
  # property value. Whole-string and `@sha` / `#sha` tails count; a substring of
  # some other token does not.
  defp haystack(c) do
    props = for p <- c["properties"] || [], do: p["value"]
    raw = [c["version"], c["purl"] | props]
    tails = for s <- raw, is_binary(s), t <- String.split(s, ["@", "#", "?", "&", "="]), do: t
    Enum.filter(raw, &is_binary/1) ++ tails
  end

  defp recorded(named), do: named |> Enum.map(&"#{&1["version"]}") |> Enum.join(", ")
  defp describe({:version, v}), do: "version #{v}"
  defp describe({:commit, sha}), do: "commit #{String.slice(sha, 0, 12)}"

  defp self_test do
    sha = String.duplicate("a", 40)

    lock =
      ~s(%{jason: {:hex, :jason, "1.4.5", "x", [:mix], [], "hexpm", "y"}, first_party: {:git, "https://example.invalid/fp.git", "#{sha}", []}})

    bom = fn comps -> JSON.encode!(%{"components" => comps}) end
    jason = %{"name" => "jason", "version" => "1.4.5", "purl" => "pkg:hex/jason@1.4.5"}
    fp = %{"name" => "first_party", "version" => sha, "purl" => "pkg:github/example/fp@#{sha}"}

    assert!(
      match?({:error, [m]} when is_binary(m), check(bom.([jason]), lock)),
      "a BOM missing one dependency is refused"
    )

    {:error, [missing]} = check(bom.([jason]), lock)

    assert!(
      missing =~ "first_party" and missing =~ "missing",
      "the refusal names the missing dependency"
    )

    other = %{
      fp
      | "version" => String.duplicate("b", 40),
        "purl" => "pkg:github/example/fp@" <> String.duplicate("b", 40)
    }

    {:error, [drift]} = check(bom.([jason, other]), lock)

    assert!(
      drift =~ "first_party" and drift =~ "commit",
      "a git dependency at another commit is refused"
    )

    stale = %{jason | "version" => "1.4.4"}
    {:error, [old]} = check(bom.([stale, fp]), lock)
    assert!(old =~ "jason" and old =~ "1.4.4", "a Hex package at another version is refused")

    assert!(check(bom.([jason, fp]), lock) == {:ok, 2}, "a complete BOM is accepted")

    assert!(
      check(bom.([jason]), lock, MapSet.new(["jason"])) == {:ok, 1},
      "dependencies outside the --only list are not required"
    )

    npm_lock =
      JSON.encode!(%{
        "packages" => %{
          "" => %{},
          "node_modules/left" => %{"version" => "1.0.0"},
          "node_modules/x/node_modules/right" => %{"version" => "2.0.0"},
          "node_modules/@scope/scoped" => %{"version" => "3.0.0"},
          "node_modules/devonly" => %{"version" => "9.0.0", "dev" => true}
        }
      })

    left = %{"name" => "left", "version" => "1.0.0"}
    right = %{"name" => "right", "version" => "2.0.0"}
    scoped = %{"group" => "@scope", "name" => "scoped", "version" => "3.0.0"}

    {:error, [npm_missing]} = check_npm(bom.([left, scoped]), npm_lock)

    assert!(
      npm_missing =~ "right@2.0.0",
      "an npm BOM missing a nested package is refused, naming it"
    )

    {:error, [npm_other]} =
      check_npm(bom.([left, scoped, %{right | "version" => "2.0.1"}]), npm_lock)

    assert!(npm_other =~ "right@2.0.0", "an npm package at another version is refused")

    {:error, [npm_scope]} =
      check_npm(bom.([left, right, %{scoped | "group" => "@other"}]), npm_lock)

    assert!(
      npm_scope =~ "@scope/scoped@3.0.0",
      "a scoped package under another scope is refused"
    )

    assert!(
      check_npm(bom.([Map.put(left, "components", [right]), scoped]), npm_lock) == {:ok, 3},
      "a complete npm BOM is accepted, nested components counted, dev-only packages not required"
    )

    IO.puts("sbom-covers-lock self-test: ok")
  end

  defp assert!(true, _), do: :ok

  defp assert!(false, what),
    do:
      (
        IO.puts(:stderr, "self-test FAILED: " <> what)
        System.halt(1)
      )
end

SbomCoversLock.main(System.argv())
