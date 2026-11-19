defmodule AshEnterprise.Signatures.Checks.SignerReach do
  @moduledoc """
  A grant path for signature requests: **being asked lets you see the request and act on
  your own row**. Additive, like every grant; it takes nothing away from any other path.

      extra_grants: [{AshEnterprise.Signatures.Checks.SignerReach, via: :request}]

  `via` says where the signer is from the row being authorized, and `actions` which actions
  this path reaches (default `[:read]`):

  | `via` | Filter |
  |---|---|
  | `:signer` | the row is the person's own (`user_id` is the actor) |
  | `:request` | the request has a signer who is the person |
  | `:request_document`, `:completion` | the row's request has a signer who is the person |
  | `:signer_event` | the event is on the person's own signer row |

  ## Who it admits

  A person (`user_id` in the context) whose account is active, acting in their own
  tenant, as `AshEnterprise.Security.Checks.SelfService` admits them. Never a system
  context and never an automation principal, even one acting for the person: signing,
  consenting and declining are the person's own acts (ADR 0074, the package's rule 4).
  Each condition contributes `false` to the union; none is a `forbid_if`.

  ## Never queries

  The person's id, tenant and status are on the actor and its `ActorContext`. The filter
  is part of the read's (or the write's) own query: the `exists` names the signer by
  `user_id` and relies on no other resource's read policy.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  @vias [:signer, :request, :request_document, :completion, :signer_event]

  @impl true
  def describe(opts),
    do: "the actor is a signer of the request (#{opts[:via]}), acting for themselves"

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)
    via = Keyword.fetch!(opts, :via)

    cond do
      via not in @vias -> false
      context.system? -> false
      not is_nil(context.automation) -> false
      is_nil(context.user_id) -> false
      authorizer.action.name not in Keyword.get(opts, :actions, [:read]) -> false
      Map.get(actor, :lifecycle_status) != :active -> false
      not own_tenant?(context, authorizer) -> false
      true -> reach(via, context.user_id)
    end
  end

  defp reach(:signer, user_id), do: expr(user_id == ^user_id)
  defp reach(:request, user_id), do: expr(exists(signers, user_id == ^user_id))
  defp reach(:signer_event, user_id), do: expr(signer.user_id == ^user_id)

  defp reach(via, user_id) when via in [:request_document, :completion],
    do: expr(exists(request.signers, user_id == ^user_id))

  # A call naming no tenant would read across tenants; a call naming another tenant is the
  # tenant boundary's to refuse, and gains nothing here.
  defp own_tenant?(%{organization_id: nil}, _authorizer), do: false

  defp own_tenant?(%{organization_id: organization_id}, authorizer) do
    case tenant(authorizer) do
      nil -> false
      tenant -> to_string(tenant) == to_string(organization_id)
    end
  end

  defp tenant(%{subject: %{to_tenant: tenant}}) when not is_nil(tenant), do: tenant
  defp tenant(%{subject: %{tenant: tenant}}), do: tenant
  defp tenant(_authorizer), do: nil
end
