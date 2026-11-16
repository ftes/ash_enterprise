defmodule AshEnterprise.Accounts.OidcHttp do
  @moduledoc """
  The HTTP client behind every call the OIDC strategy makes to the identity provider
  (ADR 0071): discovery, the token exchange, the JWKS and userinfo. It is
  `ash_authentication`'s `:http_adapter` (`config/config.exs`), an `Assent.HTTPAdapter`.

  ## Which certificates are trusted

  With no CA file configured, the client's default trust store applies, as it does for any
  other outbound HTTPS call. A deployment whose identity provider has a certificate signed
  by a private certificate authority sets `OIDC_CA_FILE` to a PEM bundle
  (`config/runtime.exs`, read through `AshEnterprise.Secrets.oidc_ca_file/0`). Every
  provider call then trusts the certificates in that bundle, and only those: a bundle that
  should also trust public authorities has to include them.

  Peer verification is never turned off, and there is no option that turns it off. A CA
  file that is configured but missing, unreadable or holds no certificate refuses the call,
  so the sign-in is refused, and an error naming the file is logged. It never falls back to
  the default store or to no verification.

  The file is read on each call, so replacing it needs no restart.
  """

  @behaviour Assent.HTTPAdapter

  require Logger

  alias Assent.HTTPAdapter.HTTPResponse

  @impl Assent.HTTPAdapter
  def request(method, url, body, headers, _opts) do
    case trust() do
      {:ok, transport_opts} -> send_request(method, url, body, headers, transport_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The TLS options the provider calls use: `[]` for the default trust store when no CA file
  is configured, `[cacerts: ders]` from the configured file, or `{:error, reason}` (logged)
  when the configured file cannot be used.
  """
  @spec trust() :: {:ok, keyword()} | {:error, {:oidc_ca_file, String.t(), term()}}
  def trust do
    case AshEnterprise.Secrets.oidc_ca_file() do
      nil -> {:ok, []}
      path -> ca_file_trust(path)
    end
  end

  # `path` is the operator's OIDC_CA_FILE from the runtime configuration, never request input;
  # Sobelow's low-confidence finding is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp ca_file_trust(path) do
    with {:ok, pem} <- File.read(path),
         [_ | _] = ders <- certificates(pem) do
      {:ok, [cacerts: ders]}
    else
      {:error, reason} -> refuse(path, reason)
      [] -> refuse(path, :no_certificates)
    end
  end

  defp certificates(pem) do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
  end

  defp refuse(path, reason) do
    Logger.error(
      "OIDC sign-in refused: the CA file in OIDC_CA_FILE (#{path}) cannot be used " <>
        "(#{format_reason(reason)}). Peer verification is not turned off; fix or unset the file."
    )

    {:error, {:oidc_ca_file, path, reason}}
  end

  defp format_reason(:no_certificates), do: "it holds no PEM certificate"
  defp format_reason(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()

  # Req, with its own retries, redirects, decompression and body decoding off, so the
  # response reaches Assent as the provider sent it and Assent decodes it.
  defp send_request(method, url, body, headers, transport_opts) do
    options =
      [
        method: method,
        url: url,
        headers: headers ++ [Assent.HTTPAdapter.user_agent_header()],
        body: body,
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false
      ] ++ connect_options(transport_opts)

    case Req.request(options) do
      {:ok, response} ->
        {:ok,
         %HTTPResponse{
           http_adapter: __MODULE__,
           request_url: url,
           status: response.status,
           headers: flatten(response.headers),
           body: response.body
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp connect_options([]), do: []
  defp connect_options(transport_opts), do: [connect_options: [transport_opts: transport_opts]]

  defp flatten(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
  end
end
