defmodule AshEnterprise.Signatures.Documents do
  @moduledoc """
  What a signer is shown, read for one batch of signer rows: the documents each signer's
  request names, the policy each document is a version of, and (for text) the words.

  The rows come from the person's own authorized read, so this reads what the request names
  without authorizing a second time, scoped by the request ids of those rows and the
  organization's tenant. Nothing here is a policy check; it feeds calculations
  (`AshEnterprise.Signatures.Calculations.PolicyDocuments`).

  Text is shown inline only when the bytes are UTF-8 with no control bytes and short; any
  other document is served by the bytes route
  (`AshEnterpriseWeb.AcknowledgementDocumentController`) and named, not rendered.
  """

  require Ash.Query

  alias AshEnterprise.Compliance.Policy
  alias AshEnterprise.Signatures.RequestDocument
  alias AshEvidence.DocumentVersion

  @max_inline_bytes 20_000

  @type entry :: %{
          version_id: String.t(),
          sha256: String.t(),
          title: String.t() | nil,
          version: pos_integer() | nil,
          text: String.t() | nil
        }

  @doc "The route that serves one document version's bytes to a signer of a request naming it."
  @spec path(String.t()) :: String.t()
  def path(version_id), do: "/app/acknowledgements/documents/" <> version_id

  @doc """
  Entries per request id, in the request's document order: `%{request_id => [entry]}`.
  Pass `text?: true` to read the words of text documents.
  """
  @spec for_requests([String.t()], term(), keyword()) :: %{String.t() => [entry()]}
  def for_requests(request_ids, tenant, opts \\ []) do
    request_ids = Enum.uniq(request_ids)

    documents =
      if request_ids == [] do
        []
      else
        RequestDocument
        |> Ash.Query.filter(request_id in ^request_ids)
        |> Ash.Query.sort(position: :asc)
        |> Ash.read!(authorize?: false, tenant: tenant)
      end

    version_ids = documents |> Enum.map(& &1.source_version_id) |> Enum.uniq()
    policies = policies(version_ids, tenant)
    texts = if Keyword.get(opts, :text?, false), do: texts(version_ids, tenant), else: %{}

    documents
    |> Enum.group_by(& &1.request_id, fn document ->
      policy = Map.get(policies, document.source_version_id)

      %{
        version_id: document.source_version_id,
        sha256: document.source_sha256,
        title: policy && policy.title,
        version: policy && policy.version,
        text: Map.get(texts, document.source_version_id)
      }
    end)
  end

  @doc "The bytes of one version, read under the organization's tenant, or `:error`."
  @spec bytes(String.t(), term()) :: {:ok, binary()} | :error
  def bytes(version_id, tenant) do
    DocumentVersion
    |> Ash.Query.filter(id == ^version_id)
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %DocumentVersion{bytes: bytes}} -> {:ok, bytes}
      _ -> :error
    end
  end

  @doc "True when the bytes are short UTF-8 text a surface may show inline."
  @spec inline_text?(binary()) :: boolean()
  def inline_text?(bytes) do
    byte_size(bytes) <= @max_inline_bytes and String.valid?(bytes) and
      not String.contains?(bytes, <<0>>)
  end

  defp policies([], _tenant), do: %{}

  defp policies(version_ids, tenant) do
    Policy
    |> Ash.Query.filter(document_version_id in ^version_ids)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Map.new(&{&1.document_version_id, &1})
  end

  defp texts([], _tenant), do: %{}

  defp texts(version_ids, tenant) do
    DocumentVersion
    |> Ash.Query.filter(id in ^version_ids)
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&inline_text?(&1.bytes))
    |> Map.new(&{&1.id, &1.bytes})
  end
end
