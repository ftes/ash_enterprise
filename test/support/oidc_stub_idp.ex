defmodule AshEnterprise.Test.OidcStubIdp do
  @moduledoc """
  A stand-in OpenID Connect identity provider for tests (ADR 0071), served by Bandit on
  a loopback port, over HTTP or over HTTPS with a certificate from a test-generated
  certificate authority.

  It serves what the strategy calls: the discovery document, the JWKS and the token
  endpoint. The authorization endpoint is never visited: a test reads the `state`, `nonce`
  and `code_challenge` the application put in its redirect, issues a code here with
  `issue_code/3` (the claims its ID token will carry), and calls the application's
  callback itself, as the provider's redirect would.

  The token endpoint behaves as a provider must: it answers each code once (a replayed
  code is `invalid_grant`), and only with the PKCE verifier whose S256 digest is the
  code's challenge.
  """

  @behaviour Plug

  import Plug.Conn

  @client_id "ash-enterprise-test"
  @kid "stub-key"

  @doc "The client id the stub's ID tokens are issued to (`config/test.exs`'s)."
  def client_id, do: @client_id

  @doc """
  Starts a provider under the test's supervisor. `scheme: :https` serves TLS with
  `certfile`/`keyfile`. Returns `%{base_url, state}`; `base_url` is the issuer.
  """
  def start!(opts \\ []) do
    {:ok, state} = Agent.start_link(fn -> %{codes: %{}, base_url: nil} end)
    key = JOSE.JWK.generate_key({:rsa, 2048})
    scheme = Keyword.get(opts, :scheme, :http)

    bandit =
      [
        plug: {__MODULE__, state: state, key: key},
        scheme: scheme,
        ip: :loopback,
        port: 0,
        startup_log: false
      ] ++ Keyword.take(opts, [:certfile, :keyfile])

    server = ExUnit.Callbacks.start_supervised!({Bandit, bandit}, id: make_ref())
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    host = if scheme == :https, do: "localhost", else: "127.0.0.1"
    base_url = "#{scheme}://#{host}:#{port}"
    Agent.update(state, &%{&1 | base_url: base_url})

    %{base_url: base_url, state: state}
  end

  @doc """
  Issues `code` for the PKCE `challenge`; its ID token carries `claims` over the standard
  ones (`iss`, `aud`, `iat`, `exp`).
  """
  def issue_code(%{state: state}, code, challenge, claims) do
    Agent.update(state, &put_in(&1, [:codes, code], %{challenge: challenge, claims: claims}))
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    base_url = Agent.get(opts[:state], & &1.base_url)

    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/openid-configuration"} ->
        json(conn, 200, discovery(base_url))

      {"GET", "/jwks"} ->
        {_fields, public} = opts[:key] |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
        json(conn, 200, %{"keys" => [Map.merge(public, %{"kid" => @kid, "use" => "sig"})]})

      {"POST", "/token"} ->
        token(conn, opts[:state], opts[:key], base_url)

      _other ->
        send_resp(conn, 404, "")
    end
  end

  defp discovery(base_url) do
    %{
      "issuer" => base_url,
      "authorization_endpoint" => base_url <> "/authorize",
      "token_endpoint" => base_url <> "/token",
      "jwks_uri" => base_url <> "/jwks",
      "response_types_supported" => ["code"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["RS256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_basic"],
      "code_challenge_methods_supported" => ["S256"]
    }
  end

  defp token(conn, state, key, base_url) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    # One use per code, as a provider must: taken out before it is checked.
    issued =
      Agent.get_and_update(state, fn s ->
        {get_in(s, [:codes, params["code"]]),
         update_in(s, [:codes], &Map.delete(&1, params["code"]))}
      end)

    cond do
      is_nil(issued) ->
        json(conn, 400, %{"error" => "invalid_grant"})

      pkce(params["code_verifier"]) != issued.challenge ->
        json(conn, 400, %{"error" => "invalid_grant"})

      true ->
        now = System.os_time(:second)

        claims =
          Map.merge(
            %{"iss" => base_url, "aud" => @client_id, "iat" => now, "exp" => now + 300},
            issued.claims
          )

        {_jws, id_token} =
          key
          |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => @kid}, claims)
          |> JOSE.JWS.compact()

        json(conn, 200, %{
          "access_token" => "stub-access-#{System.unique_integer([:positive])}",
          "token_type" => "Bearer",
          "expires_in" => 300,
          "id_token" => id_token
        })
    end
  end

  defp pkce(nil), do: nil
  defp pkce(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
