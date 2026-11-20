defmodule AshEnterpriseWeb.AcknowledgementDocumentController do
  @moduledoc """
  `/app/acknowledgements/documents/:id`: the original bytes of one document version, to
  the people a signature request names it to.

  The person must be signed in, and must be a signer of a request in their own organization
  that names this version (their own signer rows, `Signer.naming_version`). Anyone else gets the same `404` whether the version exists or not:
  a person who is not asked, a request in another organization, a version nothing names.
  A signed-out visitor is sent to sign in. The bytes are then read under the person's own
  tenant, so another organization's version of the same text is never what is served.

  Text and PDF are served inline; anything else is a download. Nothing is ever served as
  HTML, and the response forbids sniffing and any script or framing of its own.
  """

  use AshEnterpriseWeb, :controller

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.Documents

  def show(conn, %{"id" => id}) do
    case conn.assigns[:current_user] do
      nil -> redirect(conn, to: ~p"/sign-in")
      actor -> serve(conn, actor, id)
    end
  end

  # The body is the bytes of a document the signer is asked to read, and it is never
  # HTML: the type is one of three fixed strings chosen by `content_type/1` (text, PDF,
  # or an opaque download), the response is `nosniff` and its CSP is `sandbox` with no
  # sources. Skipped by name and locally: a path that served `text/html` would be a real
  # finding.
  @sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve(conn, actor, id) do
    tenant = ActorContext.tenant(actor)

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         true <- named_to?(actor, tenant, uuid),
         {:ok, bytes} <- Documents.bytes(uuid, tenant) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", disposition(bytes))
      |> put_resp_content_type(content_type(bytes), nil)
      |> send_resp(200, bytes)
    else
      _ -> not_found(conn)
    end
  end

  # Read as the person, through their own signer rows: the administrator who sent the
  # request, and anyone else a role lets read every document, are not its signers.
  defp named_to?(actor, tenant, version_id) do
    case Signatures.list_my_signers_naming_version(version_id,
           actor: actor,
           tenant: tenant,
           query: [limit: 1]
         ) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp content_type(bytes) do
    cond do
      match?("%PDF-" <> _, bytes) -> "application/pdf"
      Documents.inline_text?(bytes) -> "text/plain; charset=utf-8"
      true -> "application/octet-stream"
    end
  end

  defp disposition(bytes) do
    if content_type(bytes) == "application/octet-stream",
      do: "attachment; filename=\"document\"",
      else: "inline"
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("Not found")
end
