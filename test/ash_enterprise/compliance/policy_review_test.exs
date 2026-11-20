defmodule AshEnterprise.Compliance.PolicyReviewTest do
  @moduledoc """
  The `soc2` pack's policy review (`priv/packs/soc2/policy_review_acknowledgement.bpmn`),
  installed, published and run: when the year's review falls due, each person is asked to
  acknowledge the current policies, and the administrator's review task shows who has and
  has not. Closing it records the administrator's decision and acknowledges nothing for
  anyone.

  Refusals first: the drafts a pack installs run nothing, the recipe cannot be published
  plainly because its first step acts, and a recipe runner with no role asks nobody. Then the
  review as an administrator publishes it.

  SYNTHETIC data only: every person is on `example.test` and every policy is a fixture.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  require Ash.Query

  # Policies are evidence document versions, in the evidence store's own repo.
  @moduletag evidence: true

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, colleague!: 2]

  alias AshEnterprise.Automation.Occurrence
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance, Subscription}
  alias AshEnterprise.Compliance
  alias AshEnterprise.Compliance.{Policy, ScheduledReviewWorker}
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.{Request, RequestDocument, Signer}
  alias AshEnterprise.Test.Execution.Authority, as: Grants

  @pack "soc2"
  @process "soc2.policy_review_acknowledgement"
  @recipe "soc2.policy_review_acknowledgement.due"

  # What the recipe runner holds: it reads the review and the policies, and opens requests.
  @runner_grants [
    {Occurrence, :read, :global},
    {Policy, :read, :global},
    {Request, :read, :global},
    {Request, :create, :global},
    {Request, :write, :global},
    {RequestDocument, :read, :global},
    {RequestDocument, :create, :global},
    {Signer, :read, :global},
    {Signer, :create, :global}
  ]

  setup do
    admin = tenant!()
    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

    Compliance.publish_policy!(
      "acceptable-use",
      "SYNTHETIC acceptable use",
      "SYNTHETIC acceptable use policy, v1",
      opts(admin)
    )

    %{
      admin: admin,
      tenant: admin.tenant,
      reviewer: colleague!(admin, admin?: true),
      staff: colleague!(admin)
    }
  end

  describe "refused" do
    test "nothing runs from the drafts a pack installs", ctx do
      assert {:ok, _} = ScheduledReviewWorker.perform(%Oban.Job{})
      sweep!(ctx.tenant)

      assert all(Occurrence, ctx.tenant) == []
      assert all(Request, ctx.tenant) == []
    end

    test "the recipe cannot be published plainly: its first step acts, and a person grants that",
         ctx do
      opts = [actor: ctx.admin.actor, tenant: ctx.tenant]
      [process] = drafts(Definition, @process, ctx.tenant)
      Definition.publish!(process, opts)

      [recipe] = drafts(Subscription, @recipe, ctx.tenant)
      assert {:error, error} = Subscription.publish(recipe, opts)
      assert Exception.message(error) =~ "service"

      # Nor does the job runner grant it: publish_granted is a person's act.
      assert {:error, %Ash.Error.Forbidden{}} =
               Subscription.publish_granted(recipe,
                 actor: SystemActor.process(),
                 tenant: ctx.tenant
               )
    end

    test "a recipe runner with no role asks nobody, and the review does not open", ctx do
      publish!(ctx, grants?: false)

      assert {:ok, _} = ScheduledReviewWorker.perform(%Oban.Job{})
      sweep!(ctx.tenant)
      assert_raise RuntimeError, &advance!/0

      assert all(Request, ctx.tenant) == []
      assert open_reviews(ctx.tenant) == []
    end
  end

  describe "published by the administrator" do
    test "the due review asks everyone, the task shows who has acknowledged, and closing it acknowledges nothing",
         ctx do
      publish!(ctx)

      assert {:ok, _} = ScheduledReviewWorker.perform(%Oban.Job{})
      sweep!(ctx.tenant)
      advance!()

      # The step ran once, as the recipe runner acting for the administrator.
      assert [%{status: :succeeded}] = invocations(ctx.tenant)

      # One request per person, the review's subject its occurrence.
      requests = all(Request, ctx.tenant)
      assert length(requests) == 3
      [instance] = all(Instance, ctx.tenant)
      assert Enum.all?(requests, &(&1.occurrence_id == instance.subject_id))
      assert Enum.all?(requests, &(&1.status == :sent and &1.purpose == :acknowledge))

      # The administrator's task lists everyone outstanding.
      assert [review] = open_reviews(ctx.tenant)
      assert review.name == "Review the policies and who has acknowledged them"

      detail = detail(review, ctx.reviewer)
      assert detail =~ "0 of 3 acknowledged · 3 outstanding"
      assert detail =~ to_string(ctx.staff.user.email)

      assert label(review, ctx.reviewer) == "Policy review · #{Date.utc_today().year}"

      # The staff member acknowledges; the task shows it.
      acknowledge!(ctx.staff)
      detail = detail(review, ctx.reviewer)
      assert detail =~ "1 of 3 acknowledged · 2 outstanding"
      assert detail =~ "Acknowledged (1):\n  #{ctx.staff.user.email} (signed"

      # The reviewer closes the review with two people outstanding: they stay outstanding.
      assert {:ok, _} = work(review, :claim_task, %{}, ctx.reviewer, ctx.tenant)

      assert {:ok, _} =
               work(review, :complete_task, %{outcome: "completed"}, ctx.reviewer, ctx.tenant)

      advance!()

      assert [%{status: :completed}] = all(Instance, ctx.tenant)

      assert {:ok, status} =
               Signatures.acknowledgement_review_status(instance.subject_id, opts(ctx.admin))

      assert status["counts"] == %{
               "acknowledged" => 1,
               "outstanding" => 2,
               "declined" => 0,
               "ended" => 0
             }

      assert ctx.admin.user.id in Enum.map(status["outstanding"], & &1["user_id"])
    end
  end

  # --- fixtures ---------------------------------------------------------------------

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]

  # The review goes live only this way: a person publishes the process, then the recipe with
  # publish_granted, and the tenant gives the recipe runner a role.
  defp publish!(ctx, options \\ []) do
    opts = [actor: ctx.admin.actor, tenant: ctx.tenant]

    [process] = drafts(Definition, @process, ctx.tenant)
    Definition.publish!(process, opts)

    [recipe] = drafts(Subscription, @recipe, ctx.tenant)
    Subscription.publish_granted!(recipe, opts)

    if Keyword.get(options, :grants?, true),
      do: Grants.automation_role!(ctx.admin, :recipe_runner, @runner_grants)
  end

  defp drafts(resource, key, tenant) do
    resource
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp all(resource, tenant), do: Ash.read!(resource, authorize?: false, tenant: tenant)

  # The sweep as production runs it: the first advance is a job that runs once the instance
  # and its dispatch row have committed together.
  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end
  end

  defp advance! do
    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end
  end

  defp invocations(tenant) do
    Invocation
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read!(actor: SystemActor.oban(), tenant: tenant)
  end

  defp open_reviews(tenant) do
    HumanTask
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp detail(task, person) do
    task
    |> Ash.load!(:subject_detail, actor: person.actor, tenant: person.tenant)
    |> Map.fetch!(:subject_detail)
  end

  defp label(task, person) do
    task
    |> Ash.load!(:subject_label, actor: person.actor, tenant: person.tenant)
    |> Map.fetch!(:subject_label)
  end

  defp work(task, action, args, person, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(action, Map.put(args, :record_id, task.id),
      actor: person.actor,
      tenant: tenant
    )
    |> Ash.run_action()
  end

  defp acknowledge!(person) do
    [signer] = Signatures.list_signers!(opts(person))

    signer
    |> Signatures.view_signature_request!(opts(person))
    |> Signatures.consent_to_sign!(opts(person))
    |> Signatures.sign_signature_request!(opts(person))
  end
end
