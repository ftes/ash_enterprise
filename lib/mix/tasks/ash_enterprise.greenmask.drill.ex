defmodule Mix.Tasks.AshEnterprise.Greenmask.Drill do
  @shortdoc "Copies the database through greenmask and proves no planted personal value survives"

  @moduledoc """
  The pseudonymised-copy drill (q55, ADR 0032): take a copy of the configured database
  through greenmask with the committed `greenmask.yml`, restore it into a fresh database, and
  look for what should not be there.

      mix ash_enterprise.greenmask.drill
      mix ash_enterprise.greenmask.drill --require public.users.email --json drill.json
      mix ash_enterprise.greenmask.drill --known-values --source-url "$SOURCE_URL"

  `scripts/greenmask-drill` runs it; `docs/runbooks/production-copy.md` is the procedure
  around it.

  ## Sentinel mode (the default; CI)

  1. **A scratch source.** `<database>_gm_source` is created from the configured database as
     a template, so the configured database is never written.
  2. **Plant sentinels.** Every column `greenmask.yml` transforms gets a sentinel value (one
     random token per run) in every row; a large object gets one; and a control table that
     no position names gets one, because it must pass through and prove the scan sees what
     survives.
  3. **Validate.** `greenmask validate --warnings` against the scratch source: a config whose
     transformer cannot target a column, or that names a column the schema lacks, stops here.
     It never prints row data.
  4. **Copy.** `greenmask dump` with the generated config, `GREENMASK_GLOBAL_SALT` from the
     environment (or a fresh random salt that is never printed), then `greenmask restore`
     into `<database>_gm_copy`.
  5. **Scan.** Every text, JSON and binary column of the copy, every large object and every
     data file of the dump is searched for the token. A hit anywhere but the control table
     is a leak. Every table `greenmask.yml` excludes must have no rows in the copy.

  ## Known-value mode (a deployment's own database)

  `--known-values --source-url URL` reads the source and never writes it: it samples up to
  50 distinct values from every transformed text column, copies through greenmask, and checks
  that none of them is in the same column of the copy. The values stay in memory and are
  never printed; the report carries counts only. The copy is restored into the configured
  database's server, as `<database>_gm_copy`.

  Exits non-zero on any leak, an excluded table with rows, a missing `--require`d column, a
  failed validate, dump or restore, or a control that did not survive. The copy is dropped
  unless `--keep` or the drill failed; the dump directory is always deleted.

  Needs the `greenmask` binary (`GREENMASK` overrides the path), `pg_dump` and
  `pg_restore` no older than the server (`PG_BIN` names their directory), and a role that
  can create databases. Planting runs with `session_replication_role = replica` where the
  role may set it, so guard triggers on the scratch source do not refuse the sentinels.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [
    config: :string,
    keep: :boolean,
    json: :string,
    require: :keep,
    known_values: :boolean,
    source_url: :string
  ]

  @text_types ["text", "character varying", "citext", "character"]
  @json_types ~w(jsonb json)
  @sample 50

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    for app <- [:postgrex, :yaml_elixir], do: {:ok, _} = Application.ensure_all_started(app)

    report = drill(opts)
    print(report)

    if json = opts[:json], do: File.write!(json, Jason.encode_to_iodata!(report, pretty: true))
    unless report.status == "ok", do: exit({:shutdown, 1})
  end

  @doc "Runs the drill and returns its report (see the moduledoc for `opts`)."
  @spec drill(keyword()) :: map()
  def drill(opts) do
    conn = connection_opts()
    plan = plan(opts[:config] || "greenmask.yml")
    database = conn[:database]
    copy = database <> "_gm_copy"
    token = "GMSENTINEL" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    work = Path.join(System.tmp_dir!(), "greenmask-drill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    File.chmod!(work, 0o700)

    {:ok, admin} = Postgrex.start_link(Keyword.put(conn, :database, "postgres"))

    try do
      known_values? = opts[:known_values] == true

      {source, planted, samples} =
        if known_values?,
          do: known_values_source(opts[:source_url], plan),
          else: sentinel_source(admin, conn, plan, token)

      recreate(admin, copy)

      run = %{
        work: work,
        config: runtime_config(work, plan),
        source: source,
        copy: Keyword.put(conn, :database, copy),
        salt: salt()
      }

      steps = copy_through_greenmask(run)

      {:ok, copy_conn} = Postgrex.start_link(run.copy)
      findings = findings(copy_conn, plan, {planted, samples}, token, work, opts)
      GenServer.stop(copy_conn)

      status = status(steps, findings)
      keep? = opts[:keep] == true or status != "ok"
      unless keep?, do: drop(admin, copy)

      %{
        status: status,
        mode: if(known_values?, do: "known_values", else: "sentinel"),
        copy: copy,
        copy_kept: keep?,
        steps: steps,
        planted: Map.new(planted, fn {{t, c}, n} -> {"#{t}.#{c}", n} end),
        excluded_tables: plan.excluded,
        findings: Map.delete(findings, :problems),
        problems: findings.problems
      }
    after
      # The scratch source holds the planted sentinels and nothing else worth keeping.
      unless opts[:known_values], do: drop(admin, database <> "_gm_source")
      File.rm_rf!(work)
      GenServer.stop(admin)
    end
  end

  defp copy_through_greenmask(run) do
    %{
      validate: greenmask(["validate", "--warnings"], run, :source),
      dump: greenmask(["dump"], run, :source),
      restore: greenmask(["restore", "latest"], run, :copy)
    }
  end

  defp status(steps, findings) do
    if Enum.all?(steps, fn {_, step} -> step.exit == 0 end) and findings.problems == [],
      do: "ok",
      else: "failed"
  end

  # The committed config, as the copy will use it: the transformed columns per table, and
  # the tables whose rows stay out.
  defp plan(path) do
    {:ok, %{"dump" => dump}} = YamlElixir.read_from_file(path)

    columns =
      for table <- dump["transformation"] || [],
          transformer <- table["transformers"] do
        {"#{table["schema"]}.#{table["name"]}", transformer["params"]["column"],
         transformer["name"]}
      end

    %{
      path: path,
      columns: columns,
      excluded: get_in(dump, ["pg_dump_options", "exclude-table-data"]) || []
    }
  end

  # --- sentinel mode ---------------------------------------------------------------------

  defp sentinel_source(admin, conn, plan, token) do
    source = conn[:database] <> "_gm_source"
    drop(admin, source)
    Postgrex.query!(admin, ~s[CREATE DATABASE "#{source}" TEMPLATE "#{conn[:database]}"], [])

    {:ok, scratch} = Postgrex.start_link(Keyword.put(conn, :database, source))
    # Guard triggers would refuse a sentinel on a scratch copy; a role that may not set
    # this plants without it, and a refused table fails the drill loudly.
    _ = Postgrex.query(scratch, "SET session_replication_role = replica", [])
    types = column_types(scratch)
    lengths = max_lengths(scratch)

    planted =
      for {table, column, _name} <- plan.columns, into: %{} do
        key = {table, column}
        {key, plant(scratch, table, column, {types[key], lengths[key]}, token)}
      end

    Postgrex.query!(scratch, "SELECT lo_from_bytea(0, convert_to($1, 'UTF8'))", ["#{token}-blob"])

    Postgrex.query!(scratch, "CREATE TABLE public.greenmask_drill_control (note text)", [])

    Postgrex.query!(scratch, "INSERT INTO public.greenmask_drill_control VALUES ($1)", [
      "#{token}:control"
    ])

    GenServer.stop(scratch)
    {Keyword.put(conn, :database, source), planted, %{}}
  end

  defp column_types(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT table_schema || '.' || table_name, column_name,
               CASE WHEN data_type = 'USER-DEFINED' THEN udt_name ELSE data_type END
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        """,
        []
      )

    Map.new(rows, fn [table, column, type] -> {{table, column}, type} end)
  end

  # A varchar(n) column takes at most n characters, so its sentinel is cut to fit.
  defp max_lengths(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT table_schema || '.' || table_name, column_name, character_maximum_length
        FROM information_schema.columns
        WHERE character_maximum_length IS NOT NULL
          AND table_schema NOT IN ('pg_catalog', 'information_schema')
        """,
        []
      )

    Map.new(rows, fn [table, column, length] -> {{table, column}, length} end)
  end

  # One sentinel per row, distinct per row so a unique index still holds, shaped like an
  # address so a column that checks for one accepts it, and cut to a varchar's length.
  # Returns the rows planted.
  defp plant(_conn, _table, _column, {nil, _length}, _token), do: 0

  defp plant(conn, table, column, {type, length}, token) do
    value = sentinel_value(token, length)

    expression =
      cond do
        type in @text_types -> value
        type in @json_types -> "jsonb_build_object('sentinel', #{value})::#{type}"
        type == "bytea" -> "convert_to(#{value}, 'UTF8')"
        true -> nil
      end

    if expression do
      %{num_rows: n} =
        Postgrex.query!(
          conn,
          ~s[UPDATE #{quote_table(table)} SET "#{column}" = #{expression}],
          []
        )

      n
    else
      0
    end
  end

  defp sentinel_value(token, nil), do: "'#{token}-' || md5(random()::text) || '@sentinel.test'"

  defp sentinel_value(token, length),
    do: "left(#{sentinel_value(token, nil)}, #{max(length, String.length(token) + 1)})"

  # --- known-value mode --------------------------------------------------------------------

  defp known_values_source(nil, _plan),
    do: Mix.raise("--known-values needs --source-url (the database to copy, read only)")

  defp known_values_source(url, plan) do
    source = parse_url(url)
    {:ok, conn} = Postgrex.start_link(source)
    Postgrex.query!(conn, "SET default_transaction_read_only = on", [])
    types = column_types(conn)

    samples =
      for {table, column, _name} <- plan.columns,
          types[{table, column}] in @text_types,
          into: %{} do
        %{rows: rows} =
          Postgrex.query!(
            conn,
            ~s[SELECT DISTINCT "#{column}"::text FROM #{quote_table(table)} WHERE "#{column}" IS NOT NULL LIMIT #{@sample}],
            []
          )

        {{table, column}, List.flatten(rows)}
      end

    GenServer.stop(conn)
    {source, Map.new(samples, fn {key, values} -> {key, length(values)} end), samples}
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    [user | password] = String.split(uri.userinfo || "", ":", parts: 2)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: user,
      password: List.first(password),
      database: String.trim_leading(uri.path || "", "/")
    ]
  end

  # --- greenmask ---------------------------------------------------------------------------

  # One greenmask command. `against` names whose password libpq gets: the source for
  # validate and dump, the copy for restore.
  defp greenmask(args, run, against) do
    env = [
      {"DUMP_PG_DUMP_OPTIONS_DBNAME", conninfo(run.source)},
      {"RESTORE_PG_RESTORE_OPTIONS_DBNAME", conninfo(run.copy)},
      {"PGPASSWORD", Map.fetch!(run, against)[:password] || ""},
      {"GREENMASK_GLOBAL_SALT", run.salt}
    ]

    {output, exit} =
      System.cmd(
        System.get_env("GREENMASK", "greenmask"),
        ["--config", run.config, "--log-format", "json" | args],
        env: env,
        stderr_to_stdout: true
      )

    %{exit: exit, errors: errors(output)}
  end

  # greenmask's own error lines (JSON logs). Warnings name columns, never values, and
  # validate is run without --data, so no row reaches the report.
  defp errors(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~s("level":"error") or &1 =~ ~s("level":"fatal")))
    |> Enum.take(20)
  end

  # The salt is key material: from the environment when the operator provides one, else a
  # fresh one for this run. Either way it is never written to the report or the log.
  defp salt do
    System.get_env("GREENMASK_GLOBAL_SALT") ||
      Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end

  defp runtime_config(work, plan) do
    path = Path.join(work, "greenmask-runtime.yml")

    unless File.exists?(path) do
      pg_bin =
        System.get_env("PG_BIN") ||
          (System.find_executable("pg_dump") || Mix.raise("pg_dump is not on PATH"))
          |> Path.dirname()

      File.mkdir_p!(Path.join(work, "tmp"))
      File.mkdir_p!(Path.join(work, "storage"))

      File.write!(path, [
        """
        common:
          pg_bin_path: #{inspect(pg_bin)}
          tmp_dir: #{inspect(Path.join(work, "tmp"))}
        storage:
          type: directory
          directory:
            path: #{inspect(Path.join(work, "storage"))}
        restore:
          pg_restore_options:
            exit-on-error: true
        """,
        File.read!(plan.path)
      ])
    end

    path
  end

  defp conninfo(conn) do
    "host=#{conn[:hostname]} port=#{conn[:port]} user=#{conn[:username]} dbname=#{conn[:database]}"
  end

  # --- findings ----------------------------------------------------------------------------

  defp findings(copy, plan, {planted, samples}, token, work, opts) do
    {leaks, control} =
      if opts[:known_values],
        do: {known_value_hits(copy, samples), 0},
        else: sentinel_hits(copy, token)

    excluded_with_rows =
      for table <- plan.excluded, rows(copy, table) > 0, do: table

    missing =
      for required <- Keyword.get_values(opts, :require),
          [schema, table, column] = String.split(required, ".", parts: 3),
          Map.get(planted, {"#{schema}.#{table}", column}, 0) == 0,
          do: required

    dump = if opts[:known_values], do: %{leaks: 0, control: 1}, else: dump_scan(work, token)

    problems =
      Enum.map(leaks, &"value survived in #{&1}") ++
        Enum.map(excluded_with_rows, &"excluded table has rows in the copy: #{&1}") ++
        Enum.map(missing, &"required column had no rows to plant: #{&1}") ++
        dump_problems(dump) ++
        if(opts[:known_values] != true and control == 0,
          do: ["the control sentinel did not survive: the scan cannot be trusted"],
          else: []
        )

    %{
      leaks: leaks,
      control_hits: control,
      excluded_with_rows: excluded_with_rows,
      dump_files_with_sentinel: dump.leaks,
      dump_files_with_control: dump.control,
      problems: problems
    }
  end

  defp sentinel_hits(copy, token) do
    hits =
      for {{table, column}, type} <- column_types(copy),
          type in @text_types or type in @json_types or type == "bytea",
          count(copy, table, column, type, token) > 0,
          do: "#{table}.#{column}"

    %{rows: [[blobs]]} =
      Postgrex.query!(
        copy,
        "SELECT count(*) FROM pg_largeobject WHERE position(convert_to($1, 'UTF8') in data) > 0",
        [token]
      )

    {control, leaks} =
      Enum.split_with(hits, &String.starts_with?(&1, "public.greenmask_drill_control."))

    leaks = if blobs > 0, do: ["pg_largeobject" | leaks], else: leaks
    {Enum.sort(leaks), length(control)}
  end

  defp count(copy, table, column, type, token) do
    predicate =
      if type == "bytea",
        do: ~s[position(convert_to($1, 'UTF8') in "#{column}") > 0],
        else: ~s["#{column}"::text LIKE '%' || $1 || '%']

    %{rows: [[n]]} =
      Postgrex.query!(copy, "SELECT count(*) FROM #{quote_table(table)} WHERE #{predicate}", [
        token
      ])

    n
  end

  defp known_value_hits(copy, samples) do
    for {{table, column}, values} <- samples,
        values != [],
        survived?(copy, table, column, values),
        do: "#{table}.#{column}"
  end

  defp survived?(copy, table, column, values) do
    %{rows: [[n]]} =
      Postgrex.query!(
        copy,
        ~s[SELECT count(*) FROM #{quote_table(table)} WHERE "#{column}"::text = ANY($1)],
        [values]
      )

    n > 0
  end

  # The rows a table holds of its own. A view (an excluded read model over a table that is
  # transformed) holds none: what it shows is the transformed table under it.
  defp rows(copy, table) do
    case Postgrex.query!(copy, "SELECT relkind::text FROM pg_class WHERE oid = to_regclass($1)", [
           quote_table(table)
         ]) do
      %{rows: [[kind]]} when kind in ["r", "p"] ->
        %{rows: [[n]]} = Postgrex.query!(copy, "SELECT count(*) FROM #{quote_table(table)}", [])
        n

      _view_or_missing ->
        0
    end
  end

  # The control table is dumped as it is, so its file holds `<token>:control`: finding it
  # proves the files were read. A planted value is `<token>-…` (and so is the large
  # object), and only that is a leak.
  defp dump_scan(work, token) do
    contents =
      work
      |> Path.join("storage/**/*.dat.gz")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> :zlib.gunzip()))

    %{
      leaks: Enum.count(contents, &String.contains?(&1, token <> "-")),
      control: Enum.count(contents, &String.contains?(&1, token <> ":control"))
    }
  end

  defp dump_problems(%{leaks: leaks}) when leaks > 0,
    do: ["#{leaks} dump data file(s) contain a planted sentinel"]

  defp dump_problems(%{control: 0}),
    do: ["no dump data file holds the control sentinel: the dump scan cannot be trusted"]

  defp dump_problems(_dump), do: []

  # --- helpers -----------------------------------------------------------------------------

  defp quote_table(table) do
    [schema, name] = String.split(table, ".", parts: 2)
    ~s["#{schema}"."#{name}"]
  end

  defp recreate(admin, database) do
    drop(admin, database)
    Postgrex.query!(admin, ~s[CREATE DATABASE "#{database}"], [])
  end

  defp drop(admin, database),
    do: Postgrex.query!(admin, ~s[DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)], [])

  defp connection_opts do
    config = AshEnterprise.Repo.config()

    [
      hostname: config[:hostname] || "localhost",
      port: config[:port] || 5432,
      username: config[:username],
      password: config[:password],
      database: config[:database]
    ]
  end

  defp print(report) do
    Mix.shell().info("greenmask drill (#{report.mode}): #{report.status}")

    for {step, %{exit: exit, errors: errors}} <- report.steps do
      Mix.shell().info("  #{step}: exit #{exit}")
      for line <- errors, do: Mix.shell().info("    #{line}")
    end

    planted = Enum.count(report.planted, fn {_, n} -> n > 0 end)
    Mix.shell().info("  planted in #{planted} of #{map_size(report.planted)} transformed columns")
    Mix.shell().info("  excluded tables: #{length(report.excluded_tables)}")
    Mix.shell().info("  control hits: #{report.findings.control_hits}")
    for problem <- report.problems, do: Mix.shell().error("  #{problem}")
  end
end
