defmodule AshEnterprise.AI.Disclosure do
  @moduledoc """
  Puts the tenant an AshAi prompt action runs for beside its caller, so the
  model-call guard (`AshEnterprise.AI.Models`) decides on that tenant's
  recorded opt-in and stamps the call record with it.

  A prompt action names its caller in `req_llm_opts`, which are fixed when
  the resource compiles; the tenant is known only per call. AshAi's
  `transform_flow` hook receives the flow with the action's actor and tenant
  already on it, so this copies the tenant into the options the guarded
  client reads:

      run prompt(&AshEnterprise.AI.model/0,
            req_llm: AshEnterprise.AI.Models.GuardedReqLLM,
            req_llm_opts: [caller: "ai.interpret_request"],
            transform_flow: &AshEnterprise.AI.Disclosure.stamp/2,
            ...)

  An action called with no tenant is stamped with none, and the guard then
  refuses any model outside the zone unless the caller is a declared
  tenantless caller.
  """

  alias AshAi.Actions.Prompt.FlowState

  @doc "The flow, with its tenant in `req_llm_opts` as `tenant:`."
  @spec stamp(FlowState.t(), term()) :: FlowState.t()
  def stamp(%FlowState{tenant: tenant, req_llm_opts: opts} = flow, _context) do
    %{flow | req_llm_opts: Keyword.put(opts || [], :tenant, tenant)}
  end
end
