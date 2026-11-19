# The HTTP half of scripts/baseline-tour.sh: signs in to the tour's loopback instance and walks
# demo steps 2 and 3. Run by the shell script (`mix run --no-start`), never on its own: it reads
# the instance's address from TOUR_BASE and its database from DB_NAME, PGHOST and PGPORT.
#
# Every check raises with what it expected and what it saw, so a broken step stops the run.

defmodule BaselineTour do
  @moduledoc false

  alias AshEnterpriseWeb.CanvasLive

  @admin "demo-admin@example.com"
  # The demo tenant's fixed password: dev and test only (`Platform.Seeder.default_password!/0`),
  # which is where this instance runs.
  @password "password1234"

  def run do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    jar = :ets.new(:tour_jar, [:set, :public])
    base = System.fetch_env!("TOUR_BASE")
    sign_in!(base, jar)
    explorer!(base, jar)
    canvas!(base, jar)
  end

  # --- steps ---------------------------------------------------------------------------------

  defp sign_in!(base, jar) do
    page = get!(base, jar, "/sign-in")
    expect!(page.status == 200, "GET /sign-in", 200, page.status)

    csrf =
      case Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, page.body,
             capture: :all_but_first
           ) do
        [token] -> token
        nil -> raise "sign-in page carries no _csrf_token"
      end

    response =
      request(base, jar, :post, "/auth/user/password/sign_in",
        form: %{"_csrf_token" => csrf, "user[email]" => @admin, "user[password]" => @password}
      )

    expect!(response.status == 302, "sign in as #{@admin}", 302, response.status)

    expect!(
      response.headers["location"] == ["/app"],
      "sign-in redirect",
      "/app",
      response.headers["location"]
    )

    pass("signed in as #{@admin}")
  end

  # Demo step 2: /app/explorer from the correlation id of the import batch that made the demo's
  # golden persons. The golden-record surface answers, and the trace has a timeline, not an
  # error and not the empty state.
  defp explorer!(base, jar) do
    golden = get!(base, jar, "/app/mdm/golden")
    expect!(golden.status == 200, "GET /app/mdm/golden", 200, golden.status)

    correlation_id = import_batch_correlation_id!()
    page = get!(base, jar, "/app/explorer?correlation_id=#{correlation_id}")
    expect!(page.status == 200, "GET /app/explorer?correlation_id=…", 200, page.status)

    refute!(
      page.body =~ ~s(id="explorer-error"),
      "the explorer reported an error for #{correlation_id}"
    )

    refute!(
      page.body =~ ~s(id="timeline-empty"),
      "the explorer's timeline is empty for #{correlation_id}"
    )

    expect!(page.body =~ ~s(id="entry-0"), "a first timeline entry", "id=\"entry-0\"", "none")
    pass("explorer: the import batch's correlation id opens a timeline")
  end

  # Demo step 3: /canvas answers with a graph revision, and a record type's capabilities each
  # carry a consequence class, with a destructive one demanding confirmation. The inspector
  # reads the registry, so the capabilities come from the same call the page's select event
  # makes (`CanvasLive.select/3`); the page itself is fetched over HTTP.
  defp canvas!(base, jar) do
    page = get!(base, jar, "/canvas")
    expect!(page.status == 200, "GET /canvas", 200, page.status)
    expect!(page.body =~ "Revision", "the canvas shows its graph revision", "Revision", "none")

    {:ok, object} = CanvasLive.select("resource:accounts.team", nil, nil)
    capabilities = object.capabilities
    refute!(capabilities == [], "resource:accounts.team has no capabilities")

    for capability <- capabilities do
      refute!(
        is_nil(capability.consequence),
        "capability #{inspect(capability.verb)} has no consequence class"
      )
    end

    refute!(
      Enum.all?(capabilities, &(&1.confirmation != :required)),
      "no capability of resource:accounts.team demands confirmation (destroy should)"
    )

    classes = capabilities |> Enum.map(& &1.consequence) |> Enum.uniq() |> Enum.sort()

    pass(
      "canvas: #{length(capabilities)} record capabilities with consequence classes #{inspect(classes)}"
    )
  end

  # --- plumbing ------------------------------------------------------------------------------

  defp import_batch_correlation_id! do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.get_env("PGHOST", "127.0.0.1"),
        port: String.to_integer(System.fetch_env!("PGPORT")),
        username: System.get_env("DB_USER", "postgres"),
        password: System.get_env("DB_PASSWORD", "postgres"),
        database: System.fetch_env!("DB_NAME")
      )

    result =
      Postgrex.query!(
        conn,
        "SELECT correlation_id FROM mdm_import_batches WHERE correlation_id IS NOT NULL ORDER BY inserted_at DESC LIMIT 1",
        []
      )

    case result.rows do
      [[id]] ->
        Ecto.UUID.cast!(id)

      [] ->
        raise "the demo tenant has no import batch: the golden persons have no correlation id to open"
    end
  end

  defp get!(base, jar, path), do: request(base, jar, :get, path, [])

  defp request(base, jar, method, path, opts) do
    cookie = jar |> :ets.tab2list() |> Enum.map_join("; ", fn {k, v} -> "#{k}=#{v}" end)

    response =
      Req.request!(
        [
          method: method,
          url: base <> path,
          redirect: false,
          retry: false,
          headers: [cookie: cookie]
        ] ++
          opts
      )

    for set_cookie <- List.wrap(response.headers["set-cookie"]) do
      [pair | _] = String.split(set_cookie, ";")
      [key, value] = String.split(pair, "=", parts: 2)
      :ets.insert(jar, {key, value})
    end

    response
  end

  defp expect!(true, _what, _expected, _got), do: :ok

  defp expect!(false, what, expected, got),
    do: raise("#{what}: expected #{inspect(expected)}, got #{inspect(got)}")

  defp refute!(false, _message), do: :ok
  defp refute!(true, message), do: raise(message)

  defp pass(message), do: IO.puts("PASS  #{message}")
end

BaselineTour.run()
