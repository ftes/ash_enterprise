defmodule AshEnterprise.Secrets do
  @moduledoc """
  Resolves `ash_authentication`'s secrets at runtime rather than compile time.

  Reading these from the application environment inside a callback -- instead of
  interpolating them into the DSL -- is what keeps a signing secret out of the
  compiled BEAM files and out of a release image.
  """
  use AshAuthentication.Secret

  @doc """
  The key Ash signs keyset cursors with (`config :ash, :keyset_signing_secret`), derived
  from the endpoint's `secret_key_base` so that Ash never signs with the key Phoenix is
  given. `config/runtime.exs` sets it for a deployment.
  """
  @spec keyset_signing_secret(String.t()) :: String.t()
  def keyset_signing_secret(secret_key_base) when is_binary(secret_key_base) do
    :hmac
    |> :crypto.mac(:sha256, secret_key_base, "ash keyset signing")
    |> Base.encode64(padding: false)
  end

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        AshEnterprise.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:ash_enterprise, :token_signing_secret)
  end

  # The deployment's OpenID Connect identity provider (ADR 0071), from
  # `config :ash_enterprise, :oidc` (set in `config/runtime.exs` from the `OIDC_*`
  # environment). Missing configuration is `:error`, and the sign-in is refused.
  def secret_for(
        [:authentication, :strategies, :oidc, key],
        AshEnterprise.Accounts.User,
        _opts,
        _context
      )
      when key in [:base_url, :client_id, :client_secret, :redirect_uri] do
    with {:ok, config} <- Application.fetch_env(:ash_enterprise, :oidc),
         value when is_binary(value) and value != "" <- Keyword.get(config, key) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  @doc """
  The PEM bundle the identity provider's certificate is verified against
  (`OIDC_CA_FILE`, under `config :ash_enterprise, :oidc`), or nil for the default trust
  store. Read on every provider call by `AshEnterprise.Accounts.OidcHttp`, which refuses
  the call when the file is set but cannot be used.
  """
  @spec oidc_ca_file() :: String.t() | nil
  def oidc_ca_file do
    case Application.get_env(:ash_enterprise, :oidc, []) |> Keyword.get(:ca_file) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end
end
