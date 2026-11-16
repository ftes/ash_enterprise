defmodule AshEnterpriseWeb.ApiSurfacesTest do
  @moduledoc """
  Tests the properties of the public API surfaces that are easy to regress and
  expensive to get wrong.

  These are not "does the endpoint respond" smoke tests. Each one asserts a
  security property that would fail *silently* if the wiring drifted.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  alias AshEnterprise.Test.DailyFixtures

  describe "JSON:API" do
    test "an unauthenticated read returns an empty collection, not a 403", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/teams")

      # This is the behaviour that matters. Ash FILTERS read actions rather than
      # forbidding them, so a caller sees the subset they may see -- here, none.
      #
      # A 403 would be worse in two ways: it confirms the collection exists, and
      # it pushes clients toward treating authorization failures as exceptional
      # rather than as ordinary empty results.
      assert %{"data" => []} = json_response(conn, 200)
    end

    # An index pages whether or not the client asks (`:list`, required paging): a client
    # that sends no page parameters gets the first page and a link, not the table.
    test "an unpaged GET /api/json/teams never returns the whole table: at most 50 rows and a next link" do
      admin = DailyFixtures.tenant!()
      DailyFixtures.teams!(admin, 60)

      body = admin.user |> bearer() |> get("/api/json/teams") |> json_response(200)

      assert length(body["data"]) == 50
      assert is_binary(body["links"]["next"]), "no next link: #{inspect(body["links"])}"

      first_ids = body["data"] |> Enum.map(& &1["id"]) |> MapSet.new()

      rest =
        admin.user
        |> bearer()
        |> get(URI.parse(body["links"]["next"]) |> then(&"#{&1.path}?#{&1.query}"))
        |> json_response(200)

      assert rest["data"] != []
      assert MapSet.disjoint?(first_ids, rest["data"] |> Enum.map(& &1["id"]) |> MapSet.new())
    end

    test "page[limit]=10000 is clamped to 250, not honoured" do
      admin = DailyFixtures.tenant!()
      DailyFixtures.teams!(admin, 260)

      body =
        admin.user |> bearer() |> get("/api/json/teams?page[limit]=10000") |> json_response(200)

      assert length(body["data"]) == 250
    end

    test "publishes an OpenAPI document covering exactly the exposed resources", %{conn: conn} do
      # NOTE: ash_json_api serves the OpenAPI document with a 200 and a valid
      # JSON body but sets NO content-type header, so `json_response/2` refuses
      # it. Decode the body directly rather than working around it by loosening
      # the assertion. Worth knowing if a client's tooling rejects the document.
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/json/open_api")

      assert response.status == 200

      paths =
        response.resp_body
        |> Jason.decode!()
        |> Map.fetch!("paths")
        |> Map.keys()
        |> Enum.sort()

      assert "/api/json/teams" in paths
      assert "/api/json/business_units" in paths

      # Exposure is opt-in per resource. Nothing from the Security or Audit
      # domains may appear here: a filterable public API over the authorization
      # tables is a map of the security model, and over the audit log it
      # discloses records the caller cannot otherwise read.
      refute Enum.any?(paths, &String.contains?(&1, "role"))
      refute Enum.any?(paths, &String.contains?(&1, "privilege"))
      refute Enum.any?(paths, &String.contains?(&1, "access_grant"))
      refute Enum.any?(paths, &String.contains?(&1, "audit"))
    end
  end

  describe "GraphQL" do
    test "exposes the declared queries and nothing from Security or Audit", %{conn: conn} do
      fields =
        conn
        |> post("/gql", %{query: "{ __schema { queryType { fields { name } } } }"})
        |> json_response(200)
        |> get_in(["data", "__schema", "queryType", "fields"])
        |> Enum.map(& &1["name"])

      assert "listTeams" in fields
      assert "listBusinessUnits" in fields

      refute Enum.any?(fields, &String.contains?(String.downcase(&1), "role"))
      refute Enum.any?(fields, &String.contains?(String.downcase(&1), "audit"))
    end

    test "a list that names no page gets 50 rows, not the table" do
      admin = DailyFixtures.tenant!()
      DailyFixtures.teams!(admin, 60)

      results =
        admin.user
        |> bearer()
        |> post("/gql", %{query: "{ listTeams { results { id } } }"})
        |> json_response(200)
        |> get_in(["data", "listTeams", "results"])

      assert length(results) == 50
    end

    # A type's to-many relationship field is a page too (`PagedGraphqlRelationships`):
    # unpaged, one page of a list query carried every child, and the field's `limit` was
    # honoured whatever it was.
    test "a nested has_many field is a page: an asked-for size is clamped, and none gets 50" do
      admin = DailyFixtures.tenant!()
      root = admin.user.owning_business_unit_id

      %Ash.BulkResult{status: :success} =
        1..260
        |> Enum.map(&%{name: "Child #{&1}", parent_business_unit_id: root})
        |> Ash.bulk_create(AshEnterprise.Accounts.BusinessUnit, :create,
          authorize?: false,
          tenant: admin.tenant,
          return_errors?: true
        )

      children = fn field ->
        admin.user
        |> bearer()
        |> post("/gql", %{
          query:
            ~s|{ listBusinessUnits(filter: {id: {eq: "#{root}"}}) { results { #{field} { results { id } } } } }|
        })
        |> json_response(200)
        |> get_in(["data", "listBusinessUnits", "results"])
        |> then(fn [unit] -> get_in(unit, ["childBusinessUnits", "results"]) end)
      end

      # The field is a keyset page (`KeysetPageOfBusinessUnit`), sized by `first`.
      assert length(children.("childBusinessUnits(first: 1000000)")) == 250
      assert length(children.("childBusinessUnits")) == 50
    end

    # The websocket used to connect anyone, with no actor and no tenant, beside an
    # HTTP path that authenticates a bearer token. Nothing subscribed through it,
    # so it is gone; these fail when subscriptions come back without a socket that
    # authenticates the way `/gql` does.
    test "has no websocket: nothing connects outside the authenticated HTTP path",
         %{conn: conn} do
      paths = Enum.map(AshEnterpriseWeb.Endpoint.__sockets__(), &elem(&1, 0))

      refute Enum.any?(paths, &String.starts_with?(&1, "/ws/gql"))

      for transport <- ["/ws/gql/websocket", "/ws/gql/longpoll"] do
        assert get(conn, transport).status == 404
      end
    end

    test "declares no subscriptions, so it needs no socket", %{conn: conn} do
      assert %{"data" => %{"__schema" => %{"subscriptionType" => nil}}} =
               conn
               |> post("/gql", %{query: "{ __schema { subscriptionType { name } } }"})
               |> json_response(200)
    end
  end

  # GraphiQL and Swagger UI are interactive pages over the whole API. They are mounted
  # only where `dev_routes` is set, which the test env, like a release, leaves unset.
  describe "the API explorers" do
    test "are not mounted without dev_routes" do
      refute Application.get_env(:ash_enterprise, :dev_routes)

      plugs = Enum.map(AshEnterpriseWeb.Router.__routes__(), & &1.plug)

      refute Absinthe.Plug.GraphiQL in plugs
      refute OpenApiSpex.Plug.SwaggerUI in plugs
    end

    test "their paths fall through to the APIs, which serve no explorer", %{conn: conn} do
      # Each explorer sat ahead of its scope's catch-all; without it the path is the API's.
      assert %{plug: Absinthe.Plug} = route_info("GET", "/gql/playground")
      assert %{plug: AshEnterpriseWeb.AshJsonApiRouter} = route_info("GET", "/api/json/swaggerui")

      for path <- ["/gql/playground", "/api/json/swaggerui"] do
        conn = get(conn, path)

        refute conn.resp_body =~ ~r/graphiql|swagger-ui/i,
               "#{path} served an explorer page: #{String.slice(conn.resp_body, 0, 200)}"

        refute (get_resp_header(conn, "content-type") |> List.first() || "") =~ "text/html"
      end
    end

    test "the OpenAPI document stays mounted: it is part of the API" do
      assert %{plug: AshEnterpriseWeb.AshJsonApiRouter} = route_info("GET", "/api/json/open_api")
    end

    test "are compiled only under the dev_routes flag, so the dev server keeps them" do
      # Source-level, like the /canvas check: between the nearest `dev_routes`
      # conditional above each forward and the forward itself, nothing closes it.
      source = File.read!("lib/ash_enterprise_web/router.ex")
      guard = "if Application.compile_env(:ash_enterprise, :dev_routes) do"

      for forward <- [~s(forward "/playground"), ~s(forward "/swaggerui")] do
        [head, _] = String.split(source, forward, parts: 2)
        assert head =~ guard, "#{forward} is not inside a dev_routes conditional"

        inside = head |> String.split(guard) |> List.last()
        refute inside =~ ~r/^ {0,4}end$/m, "#{forward} is outside its dev_routes conditional"
      end
    end
  end

  # The JSON APIs are bearer only and serve no page, so they carry headers that keep a
  # browser from sniffing, framing or rendering a response as anything but JSON.
  describe "security headers" do
    test "a JSON:API response carries them, unauthenticated or with a bearer", %{conn: conn} do
      anonymous =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/teams")

      assert %{"data" => []} = json_response(anonymous, 200)
      assert_api_headers(anonymous)

      %{user: user} = AshEnterprise.Test.DailyFixtures.tenant!()
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

      authenticated =
        build_conn()
        |> put_req_header("accept", "application/vnd.api+json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/json/teams")

      assert %{"data" => [_ | _]} = json_response(authenticated, 200)
      assert_api_headers(authenticated)
      refute Map.has_key?(authenticated.private, :plug_session)
    end

    test "the OpenAPI document carries them", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/api/json/open_api")

      assert conn.status == 200
      assert_api_headers(conn)
    end

    test "a GraphQL response carries them", %{conn: conn} do
      conn = post(conn, "/gql", %{query: "{ __typename }"})

      assert %{"data" => %{"__typename" => _}} = json_response(conn, 200)
      assert_api_headers(conn)
      refute Map.has_key?(conn.private, :plug_session)
    end
  end

  describe "MCP" do
    test "rejects an actorless request outright rather than returning empty results",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{})

      # Policies already fail closed, so an anonymous caller would read nothing.
      # We still reject at the door: an MCP endpoint that accepts anonymous
      # connections and quietly returns nothing looks like a working integration
      # with no data, and the natural next step for whoever is debugging that is
      # to relax authorization until data appears.
      assert conn.status == 401
      assert %{"error" => "unauthenticated"} = Jason.decode!(conn.resp_body)
    end

    test "mcp responses carry nosniff, x-frame-options DENY and the API CSP", %{conn: conn} do
      refused =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{})

      assert refused.status == 401
      assert_api_headers(refused)

      %{user: user} = DailyFixtures.tenant!()
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

      for path <- ["/mcp", "/legacy/mcp"] do
        listed =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> token)
          |> post(path, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

        assert %{"result" => %{"tools" => [_ | _]}} = json_response(listed, 200)
        assert_api_headers(listed)
        refute Map.has_key?(listed.private, :plug_session)
      end
    end

    # The streamable transport answers some requests with an event stream. The headers are
    # set before it starts, and the stream still arrives whole.
    test "an mcp event stream carries the same headers and still streams", %{conn: conn} do
      %{user: user} = DailyFixtures.tenant!()
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
      version = "2026-07-28"

      streamed =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("mcp-protocol-version", version)
        |> put_req_header("mcp-method", "subscriptions/listen")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "subscriptions/listen",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      assert streamed.status == 200
      assert [content_type] = get_resp_header(streamed, "content-type")
      assert content_type =~ "text/event-stream"
      assert streamed.resp_body =~ "notifications/subscriptions/acknowledged"
      assert streamed.resp_body =~ ~s("id":7)
      assert_api_headers(streamed)
    end
  end

  # The dev-only surfaces (/admin, /dev/dashboard, /clarity, /canvas, the explorers) are
  # compiled in under `dev_routes`, which config/dev.exs turns on unless the build sets
  # DEV_ROUTES=false: an instance that runs the dev configuration for other people builds
  # without them.
  describe "dev_routes" do
    test "dev_routes is switchable at compile time and on by default in dev" do
      dev = Config.Reader.read!("config/dev.exs", env: :dev)
      assert get_in(dev, [:ash_enterprise, :dev_routes]) == true

      for {value, expected} <- [{"false", false}, {"0", false}, {"true", true}, {"", true}] do
        assert with_env("DEV_ROUTES", value, fn ->
                 "config/dev.exs"
                 |> Config.Reader.read!(env: :dev)
                 |> get_in([:ash_enterprise, :dev_routes])
               end) == expected,
               "DEV_ROUTES=#{inspect(value)}"
      end

      # Read when the router compiles, not at runtime: every guard is a compile_env.
      source = File.read!("lib/ash_enterprise_web/router.ex")
      refute source =~ ~r/Application\.get_env\(:ash_enterprise, :dev_routes/
      assert source =~ "if Application.compile_env(:ash_enterprise, :dev_routes) do"

      # A release never reads config/dev.exs, so nothing else turns them on.
      for file <- ["config/config.exs", "config/prod.exs", "config/runtime.exs"] do
        refute File.read!(file) =~ "dev_routes", "#{file} sets dev_routes"
      end
    end
  end

  defp bearer(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end

  defp route_info(method, path),
    do: Phoenix.Router.route_info(AshEnterpriseWeb.Router, method, path, "localhost")

  defp assert_api_headers(conn) do
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'none'"
    assert csp =~ "frame-ancestors 'none'"
  end
end
