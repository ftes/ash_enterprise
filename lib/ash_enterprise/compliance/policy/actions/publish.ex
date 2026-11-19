defmodule AshEnterprise.Compliance.Policy.Actions.Publish do
  @moduledoc """
  `Policy.publish`: ingest the bytes, supersede the key's current version, mint the next.

  Runs inside the action's transaction. The key's rows are read `FOR UPDATE`, so two
  publishes of one key take turns; for a key with no rows yet the partial unique index
  is what refuses the second one.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Compliance
  alias AshEnterprise.Compliance.Policy

  @kind "policy"

  @impl true
  def run(input, _opts, context) do
    key = input.arguments.policy_key
    content = input.arguments.content
    sha256 = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    opts = Keyword.take(context |> Ash.Scope.to_opts(), [:actor, :tenant, :authorize?])

    with {:ok, versions} <- lock_versions(key, opts) do
      current = Enum.find(versions, &is_nil(&1.superseded_at))
      publish(current, versions, input.arguments, sha256, opts)
    end
  end

  # The bytes that are already current: nothing to mint.
  defp publish(%Policy{sha256: sha256} = current, _versions, _arguments, sha256, _opts),
    do: {:ok, current}

  defp publish(current, versions, arguments, sha256, opts) do
    with {:ok, document_id} <- ingest(arguments.content, sha256, opts),
         :ok <- supersede(current, opts) do
      Compliance.mint_policy(
        %{
          policy_key: arguments.policy_key,
          title: arguments.title,
          version: next_version(versions),
          document_version_id: document_id,
          sha256: sha256
        },
        opts
      )
    end
  end

  defp lock_versions(key, opts) do
    Policy
    |> Ash.Query.for_read(:versions_of, %{policy_key: key}, opts)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read()
  end

  defp next_version([]), do: 1
  defp next_version([%{version: newest} | _]), do: newest + 1

  defp supersede(nil, _opts), do: :ok

  defp supersede(%Policy{} = current, opts) do
    with {:ok, _} <- Compliance.supersede_policy(current, %{}, opts), do: :ok
  end

  # The evidence store addresses bytes by hash within a tenant, so bytes it already holds
  # (an earlier version being restored) are reused, not ingested twice.
  defp ingest(content, sha256, opts) do
    tenant = Keyword.get(opts, :tenant)

    case AshEvidence.Domain.ingest_document(@kind, content, sha256, tenant: tenant) do
      {:ok, version} -> {:ok, version.id}
      {:error, error} -> existing_or_error(sha256, tenant, error)
    end
  end

  defp existing_or_error(sha256, tenant, error) do
    AshEvidence.DocumentVersion
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read_one()
    |> case do
      {:ok, %{id: id}} -> {:ok, id}
      _ -> {:error, error}
    end
  end
end
