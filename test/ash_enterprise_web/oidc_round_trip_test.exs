defmodule AshEnterpriseWeb.OidcRoundTripTest do
  @moduledoc """
  Sign-in through the deployment's OpenID Connect identity provider, end to end over
  HTTP (ADR 0071): `/auth/user/oidc` redirects to the provider with a state, a nonce and
  a PKCE challenge; the provider's callback is checked and the code exchanged at a stub
  provider (`AshEnterprise.Test.OidcStubIdp`) that serves discovery, JWKS and token.

  Every attempt is recorded at the `oidc` door, including the ones the protocol refuses
  before the sign-in action runs, by a closed reason and never with the email.

  The provider's certificate: `OIDC_CA_FILE` is proved on a real TLS handshake against a
  stub served with a certificate from a certificate authority generated here. With the
  CA file the sign-in completes; with the default trust store, or a CA file that is
  missing, it is refused.

  The provider configuration is application environment: not async.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.AuthenticationEvent
  alias AshEnterprise.Test.OidcStubIdp

  @password "oidc-round-trip-1234"

  setup do
    previous = Application.fetch_env!(:ash_enterprise, :oidc)
    on_exit(fn -> Application.put_env(:ash_enterprise, :oidc, previous) end)
    %{oidc: previous}
  end

  defp use_provider(idp, extra \\ []) do
    config =
      :ash_enterprise
      |> Application.fetch_env!(:oidc)
      |> Keyword.put(:base_url, idp.base_url)
      |> Keyword.delete(:ca_file)
      |> Keyword.merge(extra)

    Application.put_env(:ash_enterprise, :oidc, config)
  end

  describe "refused by the protocol" do
    setup do
      idp = OidcStubIdp.start!()
      use_provider(idp)
      %{idp: idp, user: provision!()}
    end

    test "a forged state is refused and recorded at the oidc door, with no email",
         %{conn: conn, idp: idp, user: user} do
      {conn, request} = start_sign_in(conn)
      code = issue(idp, request, user)

      conn = callback(conn, %{"code" => code, "state" => "forged-#{request.state}"})

      assert_refused(conn)
      assert [%{outcome: :refused, reason: :invalid_state, user_id: nil}] = oidc_events()
      refute_spelled_anywhere(to_string(user.email))
    end

    test "a callback with no sign-in started in this browser is refused and recorded",
         %{conn: conn} do
      conn = callback(conn, %{"code" => "any", "state" => "any"})

      assert_refused(conn)
      assert [%{reason: :invalid_state, user_id: nil}] = oidc_events()
    end

    test "a wrong nonce is refused and recorded", %{conn: conn, idp: idp, user: user} do
      {conn, request} = start_sign_in(conn)
      code = issue(idp, request, user, %{"nonce" => "not-the-session-nonce"})

      conn = callback(conn, %{"code" => code, "state" => request.state})

      assert_refused(conn)
      assert [%{reason: :invalid_nonce, user_id: nil}] = oidc_events()
      refute_spelled_anywhere(to_string(user.email))
    end

    test "a code issued for another PKCE challenge is refused and recorded",
         %{conn: conn, idp: idp, user: user} do
      {conn, request} = start_sign_in(conn)
      code = issue(idp, %{request | challenge: "another-challenge"}, user)

      conn = callback(conn, %{"code" => code, "state" => request.state})

      assert_refused(conn)
      assert [%{reason: :code_rejected}] = oidc_events()
    end

    test "a replayed code is refused and recorded", %{conn: conn, idp: idp, user: user} do
      {conn, request} = start_sign_in(conn)
      code = issue(idp, request, user)
      assert_admitted(callback(conn, %{"code" => code, "state" => request.state}))

      {replay, request} = start_sign_in(build_conn())
      replay = callback(replay, %{"code" => code, "state" => request.state})

      assert_refused(replay)
      assert [%{outcome: :signed_in}, %{reason: :code_rejected, user_id: nil}] = oidc_events()
    end

    test "an error from the provider is refused and recorded without its message",
         %{conn: conn} do
      {conn, request} = start_sign_in(conn)

      conn =
        callback(conn, %{
          "error" => "access_denied",
          "error_description" => "provider-says-no-#{System.unique_integer([:positive])}",
          "state" => request.state
        })

      assert_refused(conn)
      assert [%{reason: :provider_error, user_id: nil} = event] = oidc_events()
      refute inspect(event) =~ "provider-says-no"
    end
  end

  describe "admitted" do
    test "a verified, confirmed, active user is admitted end to end through the stub provider",
         %{conn: conn} do
      idp = OidcStubIdp.start!()
      use_provider(idp)
      user = provision!()

      {conn, request} = start_sign_in(conn)
      code = issue(idp, request, user)
      conn = callback(conn, %{"code" => code, "state" => request.state})

      assert_admitted(conn)
      assert {:ok, %{"sub" => subject}} = conn |> get_session("user_token") |> peek()
      assert subject =~ user.id
      assert [%{outcome: :signed_in, user_id: user_id}] = oidc_events()
      assert user_id == user.id
    end
  end

  describe "OIDC_CA_FILE" do
    setup do
      dir = Path.join(System.tmp_dir!(), "oidc-ca-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      pki = pki!(dir)
      idp = OidcStubIdp.start!(scheme: :https, certfile: pki.certfile, keyfile: pki.keyfile)
      %{idp: idp, ca_file: pki.ca_file, dir: dir, user: provision!()}
    end

    test "a missing file refuses sign-in, says so in the log, and never falls back",
         %{conn: conn, idp: idp, dir: dir} do
      missing = Path.join(dir, "no-such-ca.pem")
      use_provider(idp, ca_file: missing)

      log = capture_log(fn -> assert_refused(get(conn, ~p"/auth/user/oidc")) end)

      assert log =~ "OIDC_CA_FILE"
      assert log =~ missing
      assert [%{reason: :provider_unreachable, user_id: nil}] = oidc_events()
    end

    test "a file with no certificate in it refuses sign-in",
         %{conn: conn, idp: idp, dir: dir} do
      empty = Path.join(dir, "empty.pem")
      File.write!(empty, "not a certificate\n")
      use_provider(idp, ca_file: empty)

      log = capture_log(fn -> assert_refused(get(conn, ~p"/auth/user/oidc")) end)

      assert log =~ "no PEM certificate"
      assert [%{reason: :provider_unreachable}] = oidc_events()
    end

    test "without the CA file the provider's certificate is not trusted, and sign-in is refused",
         %{conn: conn, idp: idp} do
      use_provider(idp)

      capture_log(fn -> assert_refused(get(conn, ~p"/auth/user/oidc")) end)

      assert [%{reason: :provider_unreachable, user_id: nil}] = oidc_events()
    end

    test "with the CA file the TLS handshake verifies and the sign-in completes",
         %{conn: conn, idp: idp, ca_file: ca_file, user: user} do
      use_provider(idp, ca_file: ca_file)

      {conn, request} = start_sign_in(conn)
      assert request.authorize =~ idp.base_url <> "/authorize"

      code = issue(idp, request, user)
      conn = callback(conn, %{"code" => code, "state" => request.state})

      assert_admitted(conn)
      assert [%{outcome: :signed_in}] = oidc_events()
    end
  end

  # --- helpers ----------------------------------------------------------------

  # The request phase: the application's redirect to the provider, and what it carries.
  defp start_sign_in(conn) do
    conn = get(conn, ~p"/auth/user/oidc")
    assert conn.status == 302, "no redirect to the provider: #{inspect(conn.resp_body)}"

    [location] = get_resp_header(conn, "location")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["nonce"])

    {conn,
     %{
       authorize: location,
       state: query["state"],
       nonce: query["nonce"],
       challenge: query["code_challenge"]
     }}
  end

  defp issue(idp, request, user, claims \\ %{}) do
    code = "code-#{System.unique_integer([:positive])}"

    claims =
      Map.merge(
        %{
          "sub" => "subject-#{System.unique_integer([:positive])}",
          "email" => to_string(user.email),
          "email_verified" => true,
          "nonce" => request.nonce
        },
        claims
      )

    OidcStubIdp.issue_code(idp, code, request.challenge, claims)
    code
  end

  # The provider's redirect back, in the same browser (its session cookie).
  defp callback(conn, params) do
    conn |> recycle() |> get(~p"/auth/user/oidc/callback", params)
  end

  defp assert_refused(conn) do
    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "identity provider"
    assert is_nil(get_session(conn, "user_token"))
  end

  defp assert_admitted(conn) do
    assert redirected_to(conn) == ~p"/app"
    assert is_binary(get_session(conn, "user_token"))
  end

  defp peek(token), do: AshAuthentication.Jwt.peek(token)

  defp provision! do
    Seeder.provision_user!(
      "oidc-trip-#{System.unique_integer([:positive])}@example.test",
      @password
    )
  end

  defp oidc_events do
    AuthenticationEvent
    |> Ash.Query.filter(door == :oidc)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(actor: SystemActor.sign_in())
  end

  defp refute_spelled_anywhere(fragment) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM audit_events
        WHERE strpos(data::text || changed_attributes::text || metadata::text, $1) > 0
        """,
        [fragment]
      )

    assert count == 0, "#{count} audit event(s) spell #{inspect(fragment)}"
  end

  # A certificate authority and a server certificate it signed for `localhost`, written as
  # PEM files: the CA alone (what OIDC_CA_FILE names), and the server's certificate and key.
  # The server's key is RSA by name: with pkix_test_data's default peer key the server
  # finds no cipher suite it can offer and every handshake ends in insufficient_security.
  defp pki!(dir) do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          peer: [key: {:rsa, 2048, 65_537}, extensions: [san]]
        },
        client_chain: %{root: [key: {:rsa, 2048, 65_537}], peer: []}
      })

    ca_file = Path.join(dir, "ca.pem")
    certfile = Path.join(dir, "server.pem")
    keyfile = Path.join(dir, "server-key.pem")

    File.write!(
      ca_file,
      pem(for der <- client[:cacerts], do: {:Certificate, der, :not_encrypted})
    )

    File.write!(certfile, pem([{:Certificate, server[:cert], :not_encrypted}]))

    {key_type, key_der} = server[:key]
    File.write!(keyfile, pem([{key_type, key_der, :not_encrypted}]))

    %{ca_file: ca_file, certfile: certfile, keyfile: keyfile}
  end

  defp pem(entries), do: :public_key.pem_encode(entries)
end
