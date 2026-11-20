defmodule AshEnterprise.Signatures.ReminderWorkerTest do
  @moduledoc """
  Reminders on the host's schedule (`AshEnterprise.Signatures.ReminderWorker`): a signer a
  request is waiting on hears again once the interval passes with no word, and not before.

  Refusals first: nobody is reminded inside the interval, nor once they have acknowledged or
  declined, nor once their request has ended. Then one reminder after the interval, the next
  only after another, an interval the host sets, and each organization's signers reminded in
  their own organization.

  The clock is passed in (`remind_due/2`), so a test moves it forward instead of waiting;
  when a person was notified is set back on their row the same way.

  SYNTHETIC data only: every person is on `example.test` and every policy is a fixture.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  # Policies are evidence document versions, in the evidence store's own repo.
  @moduletag evidence: true

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1]

  alias AshEnterprise.Automation.{Occurrence, Occurrences}
  alias AshEnterprise.Compliance
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.{ReminderWorker, Request, SignerEvent}

  @day 86_400

  setup do
    admin = tenant!()
    staff = colleague!(admin)

    Compliance.publish_policy!(
      "acceptable-use",
      "SYNTHETIC acceptable use",
      "SYNTHETIC v1",
      opts(admin)
    )

    {:ok, _} = Signatures.open_acknowledgements(review_due!(admin).id, opts(admin))

    %{admin: admin, staff: staff}
  end

  describe "not reminded" do
    test "inside the interval", ctx do
      now = DateTime.utc_now()

      assert %{reminded: 0} = ReminderWorker.remind_due(DateTime.add(now, 6 * @day, :second))
      assert reminded(ctx.admin) == []
    end

    test "once the person has acknowledged or declined", ctx do
      signed = acknowledge!(ctx.staff)
      declined = decline!(ctx.admin)

      backdate!(signed, 30)
      backdate!(declined, 30)

      ReminderWorker.remind_due(DateTime.utc_now())
      assert reminded(ctx.admin) == []
    end

    test "once the request has ended", ctx do
      [signer] = mine(ctx.staff)
      backdate!(signer, 30)

      Request
      |> Ash.get!(signer.request_id, authorize?: false, tenant: ctx.admin.tenant)
      |> Signatures.cancel_signature_request!(opts(ctx.admin))

      ReminderWorker.remind_due(DateTime.utc_now())
      refute signer.id in reminded(ctx.admin)
    end
  end

  describe "reminded" do
    test "once after the interval, and again only after another", ctx do
      [signer] = mine(ctx.staff)
      backdate!(signer, 8)

      now = DateTime.utc_now()

      assert %{reminded: 1, failed: 0} = ReminderWorker.remind_due(now)
      assert reminded(ctx.admin) == [signer.id]

      # The same day, and six days on: nothing.
      assert %{reminded: 0} = ReminderWorker.remind_due(now)
      assert %{reminded: 0} = ReminderWorker.remind_due(DateTime.add(now, 6 * @day, :second))
      assert reminded(ctx.admin) == [signer.id]

      # Eight days on, every waiting signer is due: the staff member again, and the
      # administrator, notified when the review opened, for the first time.
      assert %{reminded: 2} = ReminderWorker.remind_due(DateTime.add(now, 8 * @day, :second))
      assert Enum.count(reminded(ctx.admin), &(&1 == signer.id)) == 2

      # The person is still asked, and can still acknowledge.
      assert acknowledge!(ctx.staff).status == :signed
    end

    test "on the interval the host sets", ctx do
      [signer] = mine(ctx.staff)
      backdate!(signer, 2)

      assert %{reminded: 0} = ReminderWorker.remind_due(DateTime.utc_now())

      assert %{reminded: 1} =
               ReminderWorker.remind_due(DateTime.utc_now(), interval_days: 1)

      assert reminded(ctx.admin) == [signer.id]
    end

    test "every organization's waiting signers, each in their own organization", ctx do
      other = tenant!()
      Compliance.publish_policy!("acceptable-use", "SYNTHETIC", "SYNTHETIC other", opts(other))
      {:ok, _} = Signatures.open_acknowledgements(review_due!(other).id, opts(other))

      later = DateTime.add(DateTime.utc_now(), 8 * @day, :second)
      assert %{reminded: 3} = ReminderWorker.remind_due(later)

      assert length(reminded(ctx.admin)) == 2
      assert length(reminded(other)) == 1
    end

    test "the job runs the day's reminders" do
      assert {:ok, %{reminded: 0, failed: 0}} = ReminderWorker.perform(%Oban.Job{})
    end
  end

  # --- fixtures ---------------------------------------------------------------------

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]

  defp review_due!(admin) do
    :ok = Occurrences.review_due(admin.tenant, "policy_review_acknowledgement", "annual", "2026")

    Occurrence
    |> Ash.Query.filter(type == "compliance.review_due")
    |> Ash.read_one!(actor: SystemActor.oban(), tenant: admin.tenant)
  end

  defp mine(person) do
    person
    |> opts()
    |> Signatures.list_signers!()
    |> Enum.filter(&(&1.status in [:notified, :viewed]))
  end

  # When the person was notified, `days` ago: as if the request had been sent then.
  defp backdate!(signer, days) do
    Ash.Seed.update!(signer, %{
      notified_at: DateTime.add(DateTime.utc_now(), -days * @day, :second)
    })
  end

  defp reminded(admin) do
    SignerEvent
    |> Ash.Query.filter(type == :reminded)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false, tenant: admin.tenant)
    |> Enum.map(& &1.signer_id)
  end

  defp acknowledge!(person) do
    [signer] = mine(person)

    signer
    |> Signatures.view_signature_request!(opts(person))
    |> Signatures.consent_to_sign!(opts(person))
    |> Signatures.sign_signature_request!(opts(person))
  end

  defp decline!(person) do
    [signer] = mine(person)

    signer
    |> Signatures.view_signature_request!(opts(person))
    |> Signatures.decline_signature_request!("SYNTHETIC: declined", opts(person))
  end
end
