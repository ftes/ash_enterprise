defmodule AshEnterprise.Mdm.LlmProposerTest do
  @moduledoc """
  The success path of the default LLM proposer, against a stub transport:
  the raw JSON decodes to rules, and the prompt carries masked samples —
  never the operator's raw values.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Mdm.LlmProposer

  setup do
    previous_transport = Application.get_env(:ash_enterprise, :mdm_proposal_transport)

    Application.put_env(:ash_enterprise, :mdm_proposal_transport, __MODULE__.Stub)

    on_exit(fn ->
      if previous_transport do
        Application.put_env(:ash_enterprise, :mdm_proposal_transport, previous_transport)
      else
        Application.delete_env(:ash_enterprise, :mdm_proposal_transport)
      end
    end)

    :ok
  end

  defmodule Stub do
    @moduledoc false
    def resolve(_profile), do: {:ok, :fake_spec, []}

    def generate(_spec, opts, _schema, prompt) do
      # The masking contract: raw values never reach the transport.
      if String.contains?(prompt, "s3cret@x.io") do
        raise "raw sample value leaked into the prompt"
      end

      # The tenant goes to the model-call guard beside the options, never
      # into the prompt.
      if tenant = opts[:tenant], do: send(self(), {:tenant, tenant})

      if String.contains?(prompt, "REFUSE-TENANT") do
        raise AshEnterprise.AI.Models.NotOptedIn,
          label: "SYNTHETIC",
          caller: "system_one.proposal",
          reason: :not_opted_in
      end

      {:ok, ~s({"rules":[{"path":"Email Address","target":"email","op":"trim"}]})}
    end
  end

  @manifest %{
    "target_attributes" => ["name", "email"],
    "observed_schema" => %{"Email Address" => %{}},
    "samples" => %{"Email Address" => "s3cret@x.io"},
    "samples_masked" => %{"Email Address" => "string"}
  }

  test "a refusal by the model-call guard is the proposer's error, not a crash" do
    manifest = Map.put(@manifest, "target_attributes", ["REFUSE-TENANT"])

    assert {:error, message} = LlmProposer.generate(Map.put(manifest, "tenant", "SYNTHETIC-ORG"))
    assert message =~ "opt-in"
    assert_received {:tenant, "SYNTHETIC-ORG"}
  end

  test "the manifest's tenant reaches the guard and stays out of the prompt" do
    assert {:ok, _rules} = LlmProposer.generate(Map.put(@manifest, "tenant", "SYNTHETIC-ORG"))
    assert_received {:tenant, "SYNTHETIC-ORG"}

    assert {:ok, _rules} = LlmProposer.generate(Map.put(@manifest, "tenant", ""))
    refute_received {:tenant, _}
  end

  test "raw JSON decodes to rules through the injected transport" do
    assert {:ok, [%{"path" => "Email Address", "target" => "email", "op" => "trim"}]} =
             LlmProposer.generate(@manifest)
  end
end
