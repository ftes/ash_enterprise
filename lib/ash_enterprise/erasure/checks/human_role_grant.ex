defmodule AshEnterprise.Erasure.Checks.HumanRoleGrant do
  @moduledoc """
  `AshEnterprise.Security.Checks.RoleGrant`, minus the system-actor pass.

  `RoleGrant` treats a system actor as granted, because a system actor is "not
  subject to grants". A shred must be subject to one: it destroys data
  irreversibly, so it is a person's decision with that person's name on it in
  the audit trail — never an Oban job's, a replay's or an agent's. This check is
  therefore false for every system actor (including `ai`, whose context is
  empty) and for every automation principal, including one acting for a person
  (ADR 0043: a principal acting for a person is not that person), and otherwise
  exactly `RoleGrant`: the actor must hold a role granting `write` on the
  resource, `AshEnterprise.Erasure.Scope` for a shred and
  `AshEnterprise.Erasure.PersonErasure` for erasing a person. Both are
  `ownership: :none`, so the only depth that reaches them is `:global`.

  Like `RoleGrant`, it reads only the precomputed
  `AshEnterprise.Security.ActorContext` and never queries.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Checks.RoleGrant

  @impl true
  def describe(_opts),
    do:
      "actor is a person (not a system actor or an automation principal) holding a write grant here"

  # The default expansion re-runs `filter/3` against the authorizer Ash hands
  # the forbidden-error renderer, which carries no action; the verb lookup then
  # crashes and the refusal reads as a BadMapError. The description is the
  # whole story here anyway.
  @impl true
  def expand_description(_actor, _authorizer, opts), do: {:ok, describe(opts)}

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)

    if context.system? or is_nil(context.user_id) or not is_nil(context.automation) do
      false
    else
      RoleGrant.filter(context, authorizer, opts)
    end
  end
end
