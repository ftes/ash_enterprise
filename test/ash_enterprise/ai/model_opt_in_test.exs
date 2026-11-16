defmodule AshEnterprise.AI.ModelOptInTest do
  @moduledoc """
  The tenant's recorded sub-processor opt-in, enforced at the one model-call
  guard every AI path passes (`AshEnterprise.AI.Models`, ADR 0026 as amended,
  ADR 0042): a model outside the zone is called only for a tenant that has
  recorded the opt-in, or with no tenant from a declared tenantless caller,
  and never under `REQUIRE_IN_ZONE_MODELS`. In-zone calls need no opt-in.
  Every call, refused ones included, is recorded with its tenant and never
  with its content.

  The refusals come first. Synthetic prompts only; no model runs (a fake
  downstream module stands in for ReqLLM and reports whether it was reached).
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.AI.Disclosure
  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.AI.Models
  alias AshEnterprise.AI.Models.GuardedReqLLM
  alias AshEnterprise.AI.Models.NotOptedIn
  alias AshEnterprise.AI.Models.OutsideZone
  alias AshEnterprise.L10n.Translator
  alias AshEnterprise.Platform.SystemActor

  @hosted "anthropic:claude-haiku-4-5-20251001"
  @base_url "http://in-zone.test:8000/v1"
  @model "synthetic/in-zone-model"
  @prompt "SYNTHETIC: the quarterly figures for the opt-in probe"

  defmodule FakeReqLLM do
    @moduledoc false
    # Stands in for ReqLLM: tells the test process it was reached, which is
    # exactly what a refusal must prevent.
    def generate_object(model, _context, _schema, opts) do
      send(:model_opt_in_test, {:sent, :generate_object, model, opts})
      {:ok, %{object: %{"ok" => true}, usage: %{input_tokens: 9, output_tokens: 2}}}
    end

    def generate_text(model, _context, opts) do
      send(:model_opt_in_test, {:sent, :generate_text, model, opts})
      {:error, %RuntimeError{message: "SYNTHETIC provider error echoing the prompt"}}
    end

    def stream_text(model, _context, opts) do
      send(:model_opt_in_test, {:sent, :stream_text, model, opts})
      {:error, %RuntimeError{message: "SYNTHETIC stream error"}}
    end
  end

  setup do
    Process.register(self(), :model_opt_in_test)
    previous = Application.get_env(:ash_enterprise, :ai)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, :ai, previous),
        else: Application.delete_env(:ash_enterprise, :ai)
    end)

    Application.put_env(:ash_enterprise, :ai, [])
    :ok
  end

  defp configure(opts), do: Application.put_env(:ash_enterprise, :ai, opts)

  defp in_zone(extra \\ []),
    do: [in_zone_generative: [model: @model, base_url: @base_url, zone: "test-zone"]] ++ extra

  defp organization!(opted_in? \\ false) do
    organization =
      Organization
      |> Ash.Changeset.for_create(
        :create,
        %{unique_name: "optin-#{System.unique_integer([:positive])}", name: "Opt-in probe"},
        actor: SystemActor.seed()
      )
      |> Ash.create!()

    if opted_in?,
      do:
        organization
        |> Ash.Changeset.for_update(:update, %{sub_processor_opt_in: true},
          actor: SystemActor.seed()
        )
        |> Ash.update!(),
      else: organization
  end

  defp hosted_object(opts) do
    GuardedReqLLM.generate_object(
      @hosted,
      @prompt,
      %{},
      Keyword.merge([caller: "test.opt_in", downstream: FakeReqLLM], opts)
    )
  end

  defp calls, do: Ash.read!(ModelCall, authorize?: false)

  describe "refused before anything is sent" do
    test "an outside-zone call for a tenant that has not opted in is refused and nothing is sent" do
      organization = organization!()

      error = assert_raise NotOptedIn, fn -> hosted_object(tenant: organization.id) end
      assert error.reason == :not_opted_in
      assert Exception.message(error) =~ "opt-in"

      refute_received {:sent, _, _, _}

      assert [call] = calls()
      assert call.outcome == :refused
      assert call.residency == :outside_zone
      assert call.organization_id == organization.id
      assert call.error_class == inspect(NotOptedIn)
    end

    test "an outside-zone call with no tenant is refused" do
      error = assert_raise NotOptedIn, fn -> hosted_object([]) end
      assert error.reason == :no_tenant

      # A tenant written as nil is no tenant either.
      assert_raise NotOptedIn, fn -> hosted_object(tenant: nil) end

      refute_received {:sent, _, _, _}
      assert [%{outcome: :refused, organization_id: nil}, %{outcome: :refused}] = calls()
    end

    test "an unknown tenant is refused" do
      assert_raise NotOptedIn, fn -> hosted_object(tenant: Ash.UUID.generate()) end
      assert_raise NotOptedIn, fn -> hosted_object(tenant: "not-an-organization") end
      refute_received {:sent, _, _, _}
    end

    test "another tenant's opt-in does not admit this tenant's call" do
      _opted_in = organization!(true)
      other = organization!()

      assert_raise NotOptedIn, fn -> hosted_object(tenant: other.id) end
      refute_received {:sent, _, _, _}
      assert [%{outcome: :refused, organization_id: organization_id}] = calls()
      assert organization_id == other.id
    end

    test "under REQUIRE_IN_ZONE_MODELS an opted-in tenant is refused" do
      organization = organization!(true)
      configure(in_zone(require_in_zone_models: true))

      assert_raise OutsideZone, fn -> hosted_object(tenant: organization.id) end
      refute_received {:sent, _, _, _}

      assert [%{outcome: :refused, error_class: error_class, organization_id: organization_id}] =
               calls()

      assert error_class == inspect(OutsideZone)
      assert organization_id == organization.id
    end

    test "a stream for a tenant that has not opted in is refused too" do
      organization = organization!()

      assert_raise NotOptedIn, fn ->
        GuardedReqLLM.stream_text(@hosted, @prompt,
          caller: "test.opt_in",
          tenant: organization.id,
          downstream: FakeReqLLM
        )
      end

      refute_received {:sent, _, _, _}
      assert [%{operation: :stream_text, outcome: :refused}] = calls()
    end

    test "Models.call refuses a tenant without an opt-in before its request function runs" do
      organization = organization!()

      assert_raise NotOptedIn, fn ->
        Models.call(
          Models.resolve(@hosted),
          "test.opt_in",
          :generate_object,
          @prompt,
          [tenant: organization.id],
          fn _opts -> send(:model_opt_in_test, :request_ran) end
        )
      end

      refute_received :request_ran
    end
  end

  describe "tenantless callers" do
    test "a declared tenantless caller may reach a hosted model and nothing else may" do
      # The deployment's list: the catalogue translator, which sends only this
      # repository's own strings.
      assert Models.tenantless_callers() == [Translator.ReqLLM.caller()]

      assert {:ok, _} =
               hosted_object(caller: Translator.ReqLLM.caller())

      assert_received {:sent, :generate_object, _, opts}
      refute Keyword.has_key?(opts, :tenant)
      refute Keyword.has_key?(opts, :caller)

      assert_raise NotOptedIn, fn -> hosted_object(caller: "test.not_declared") end
      refute_received {:sent, _, _, _}

      assert [%{outcome: :refused, caller: "test.not_declared"}] =
               Enum.filter(calls(), &(&1.outcome == :refused))

      assert Models.check(Models.resolve(@hosted), Translator.ReqLLM.caller()) == :ok

      assert {:error, %NotOptedIn{reason: :no_tenant}} =
               Models.check(Models.resolve(@hosted), "test.not_declared")
    end

    test "the translator is refused under REQUIRE_IN_ZONE_MODELS, before any request" do
      configure(require_in_zone_models: true)

      request = %{
        locale: "fr",
        domain: "default",
        nplurals: 2,
        glossary: %{},
        items: [%{id: "1", msgid: "SYNTHETIC"}]
      }

      assert {:error, %OutsideZone{}} = Translator.ReqLLM.translate(request, model: @hosted)
    end
  end

  describe "admitted" do
    test "an in-zone call needs no opt-in" do
      configure(in_zone())
      organization = organization!()

      for tenant <- [organization.id, nil] do
        assert {:ok, _} =
                 GuardedReqLLM.generate_object(AshEnterprise.AI.model(), @prompt, %{},
                   caller: "test.in_zone",
                   tenant: tenant,
                   downstream: FakeReqLLM
                 )

        assert_received {:sent, :generate_object, _, _}
      end

      assert [_, _] = calls()
      assert Enum.all?(calls(), &(&1.outcome == :ok and &1.residency == :in_zone))

      assert Enum.map(calls(), & &1.organization_id) |> Enum.sort() ==
               Enum.sort([organization.id, nil])
    end

    test "an opted-in tenant's outside-zone call is made and recorded with its tenant" do
      organization = organization!(true)
      other = organization!(true)

      assert {:ok, _} = hosted_object(tenant: organization.id)
      assert_received {:sent, :generate_object, _, opts}
      refute Keyword.has_key?(opts, :tenant)

      assert [call] = calls()
      assert call.outcome == :ok
      assert call.residency == :outside_zone
      assert call.organization_id == organization.id
      assert {call.input_tokens, call.output_tokens} == {9, 2}

      # The tenant's own answer to "what did a model outside our zone see".
      assert [disclosed] =
               ModelCall.disclosures!(tenant: organization.id, authorize?: false)

      assert disclosed.id == call.id
      assert ModelCall.disclosures!(tenant: other.id, authorize?: false) == []
      assert ModelCall.disclosures!(authorize?: false) == []
    end

    test "an in-zone call is not a disclosure" do
      configure(in_zone())
      organization = organization!()

      assert {:ok, _} =
               GuardedReqLLM.generate_object(AshEnterprise.AI.model(), @prompt, %{},
                 tenant: organization.id,
                 downstream: FakeReqLLM
               )

      assert [%{organization_id: organization_id}] = calls()
      assert organization_id == organization.id
      assert ModelCall.disclosures!(tenant: organization.id, authorize?: false) == []
    end

    test "an AshAi prompt action's tenant reaches the guard beside its caller" do
      flow = %AshAi.Actions.Prompt.FlowState{
        tenant: "SYNTHETIC-TENANT",
        req_llm_opts: [caller: "x"]
      }

      assert Disclosure.stamp(flow, %{}).req_llm_opts == [tenant: "SYNTHETIC-TENANT", caller: "x"]
    end
  end

  describe "the record" do
    test "a call record holds no prompt, output or error message" do
      organization = organization!(true)

      assert {:ok, _} = hosted_object(tenant: organization.id)

      assert {:error, _} =
               GuardedReqLLM.generate_text(@hosted, @prompt,
                 caller: "test.opt_in",
                 tenant: organization.id,
                 downstream: FakeReqLLM
               )

      assert_raise NotOptedIn, fn -> hosted_object(tenant: organization!().id) end

      records = calls()
      assert length(records) == 3

      for record <- records do
        refute inspect(Map.from_struct(record)) =~ "SYNTHETIC"
      end

      assert Enum.find(records, &(&1.outcome == :error)).error_class == "RuntimeError"

      # Structural by declaration, not by luck: no attribute could hold one.
      names = ModelCall |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      for content <- [:prompt, :messages, :input, :output, :response, :content, :error_message] do
        refute content in names
      end
    end
  end
end
