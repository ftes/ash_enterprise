defmodule AshEnterprise.Signatures.Calculations.PolicyDocuments do
  @moduledoc """
  What the signer's request asks them to read, as text for the acknowledgement surface.

    * `kind: :titles`: one line, the policies by name and version
      (`Acceptable use, version 2; Code of conduct, version 1`). On the person's list.
    * `kind: :documents`: each document's title, version, the SHA-256 of the bytes the
      request names, where the original is served, and the words of a text policy. Only
      once the person has opened the request (`viewed` or later): before that, a line
      saying to open it. This is what they read before consenting.

  The documents are the ones the request named when it was sent, so a later version of a
  policy never changes what an earlier request shows. Read once per batch of rows, scoped by
  the rows' own request ids (`AshEnterprise.Signatures.Documents`).
  """

  use Ash.Resource.Calculation
  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Signatures.Documents

  @impl true
  def init(opts) do
    if opts[:kind] in [:titles, :documents],
      do: {:ok, opts},
      else: {:error, "kind must be :titles or :documents"}
  end

  @impl true
  def load(_query, _opts, _context), do: [:request_id, :status]

  @impl true
  def calculate(records, opts, context) do
    kind = opts[:kind]

    by_request =
      records
      |> Enum.map(& &1.request_id)
      |> Documents.for_requests(context.tenant, text?: kind == :documents)

    Enum.map(records, fn signer ->
      entries = Map.get(by_request, signer.request_id, [])
      render(kind, signer, entries)
    end)
  end

  defp render(:titles, _signer, entries),
    do: Enum.map_join(entries, "; ", &title/1)

  defp render(:documents, %{status: status}, _entries) when status in [:pending, :notified],
    do: dgettext("default", "Open the documents to read them.")

  defp render(:documents, _signer, entries) do
    Enum.map_join(entries, "\n\n", &document/1)
  end

  defp title(%{title: nil, sha256: sha256}),
    do: dgettext("default", "Document %{sha}", sha: short(sha256))

  defp title(%{title: title, version: version}),
    do: dgettext("default", "%{title}, version %{version}", title: title, version: version)

  defp document(entry) do
    header =
      dgettext("default", "%{title}\nSHA-256: %{sha256}\nThe original: %{path}",
        title: title(entry),
        sha256: entry.sha256,
        path: Documents.path(entry.version_id)
      )

    if entry.text, do: header <> "\n\n" <> entry.text, else: header
  end

  defp short(sha256), do: String.slice(sha256, 0, 12)
end
