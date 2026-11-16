defmodule AshEnterprise.AI.RequestClassifierOptInTest do
  @moduledoc """
  The helper console's prompt actions (`AshEnterprise.AI.RequestClassifier`)
  carry their tenant to the model-call guard (`AshEnterprise.AI.Disclosure`),
  so a hosted interpreter model is refused for a tenant without a recorded
  sub-processor opt-in before any request is built. The vendor is never
  reached: the refusal happens in the guard, ahead of the transport.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.AI.Interpreter
  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.AI.Models.NotOptedIn
  alias AshEnterprise.AI.RequestClassifier
  alias AshEnterprise.Platform.SystemActor

  @hosted "anthropic:claude-haiku-4-5-20251001"

  setup do
    previous_config = Application.get_env(:ash_enterprise, :ai)
    previous_key = System.get_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:ash_enterprise, :ai, previous_config),
        else: Application.delete_env(:ash_enterprise, :ai)

      if previous_key,
        do: System.put_env("ANTHROPIC_API_KEY", previous_key),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    Application.put_env(:ash_enterprise, :ai, interpreter_model: @hosted)
    # A key that looks real, so the console's key check passes and the guard
    # is what answers. Nothing is sent with it.
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-SYNTHETIC-not-a-real-key")

    organization =
      Organization
      |> Ash.Changeset.for_create(
        :create,
        %{unique_name: "classifier-#{System.unique_integer([:positive])}", name: "Probe"},
        actor: SystemActor.seed()
      )
      |> Ash.create!()

    %{organization: organization}
  end

  defp calls, do: Ash.read!(ModelCall, authorize?: false)

  # The guard raises inside the prompt action, before AshAi reaches the
  # transport; Ash surfaces it from the action call. The refusal is what is
  # asserted, whatever error class wraps it.
  defp refusal(fun) do
    fun.()
    flunk("the prompt action was not refused")
  rescue
    error in [ExUnit.AssertionError] -> reraise error, __STACKTRACE__
    error -> Exception.message(error)
  end

  test "interpreting a request for a tenant without an opt-in refuses before calling the vendor",
       %{organization: organization} do
    assert {:error, message} =
             Interpreter.interpret("SYNTHETIC show me the users", nil, organization.id)

    assert message =~ "sub-processor opt-in"
    # The console says so before it tries: no call was attempted at all.
    assert calls() == []

    # The prompt action itself, reached directly, is refused in the guard with
    # the tenant on the record.
    message =
      refusal(fn ->
        RequestClassifier.interpret_request("SYNTHETIC show me the users",
          tenant: organization.id
        )
      end)

    assert message =~ inspect(NotOptedIn)
    assert message =~ "has not recorded a sub-processor opt-in"

    assert [call] = calls()
    assert call.caller == "ai.interpret_request"
    assert call.outcome == :refused
    assert call.residency == :outside_zone
    assert call.organization_id == organization.id
  end

  test "composing a table for a tenant without an opt-in is refused in the guard too",
       %{organization: organization} do
    assert refusal(fn ->
             RequestClassifier.compose_surface("SYNTHETIC a table of logins", %{locale: "en"},
               tenant: organization.id
             )
           end) =~ "has not recorded a sub-processor opt-in"

    assert [%{caller: "ai.compose_surface", outcome: :refused, organization_id: org_id}] =
             calls()

    assert org_id == organization.id
  end

  test "with no tenant the prompt action is refused as tenantless" do
    assert refusal(fn -> RequestClassifier.interpret_request("SYNTHETIC anything") end) =~
             "the call names no tenant"

    assert [%{outcome: :refused, organization_id: nil}] = calls()
  end
end
