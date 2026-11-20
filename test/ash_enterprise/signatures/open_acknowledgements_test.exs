defmodule AshEnterprise.Signatures.OpenAcknowledgementsTest do
  @moduledoc """
  When the policy review falls due, each person is asked to acknowledge the current policies
  (`AshEnterprise.Signatures.Request.open_acknowledgements`), and the review shows who has
  and has not (`AshEnterprise.Signatures.ReviewStatus`).

  Refusals first: an occurrence that is not the policy review, another organization's, a
  caller with no grant on signature requests, a review with no policy published, people who
  are inactive or belong elsewhere. Then one request per person over every current version,
  a replay that opens nothing, a version published after the review opened, and the next
  period's review.

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
  alias AshEnterprise.Signatures.{Completion, Request, Signer}
  alias AshEnterprise.Test.DailyFixtures

  @template "policy_review_acknowledgement"

  setup do
    admin = tenant!()
    %{admin: admin, staff: colleague!(admin), other_staff: colleague!(admin)}
  end

  describe "refused" do
    test "an occurrence that is not the policy review falling due opens nothing", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")

      vendor = review_due!(ctx.admin, "vendor_review", "2026")
      assert {:error, error} = open(ctx.admin, vendor.id)
      assert Exception.message(error) =~ "not_a_policy_review"

      assert {:error, error} = open(ctx.admin, Ash.UUID.generate())
      assert Exception.message(error) =~ "not_a_policy_review"

      assert requests(ctx.admin) == []
    end

    test "another organization's review is not found, and nothing opens in either", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, @template, "2026")

      elsewhere = tenant!()
      publish!(elsewhere, "acceptable-use", "v1 elsewhere")

      assert {:error, error} = open(elsewhere, review.id)
      assert Exception.message(error) =~ "not_a_policy_review"

      assert requests(ctx.admin) == []
      assert requests(elsewhere) == []
    end

    test "a person with no grant on signature requests cannot open them", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, @template, "2026")

      assert {:error, %Ash.Error.Forbidden{}} = open(ctx.staff, review.id)
      assert requests(ctx.admin) == []
    end

    test "with no policy published nobody is asked", ctx do
      review = review_due!(ctx.admin, @template, "2026")

      assert {:ok, %{"policies" => 0, "opened" => 0}} = open(ctx.admin, review.id)
      assert requests(ctx.admin) == []
      assert {:ok, %{"asked" => 0}} = status(ctx.admin, review.id)
    end

    test "an inactive person and a person of another organization are not asked", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      leaver = DailyFixtures.deactivate!(colleague!(ctx.admin))
      elsewhere = tenant!()
      review = review_due!(ctx.admin, @template, "2026")

      assert {:ok, %{"opened" => 3, "people" => 3}} = open(ctx.admin, review.id)

      asked = ctx.admin |> signers() |> Enum.map(& &1.user_id) |> Enum.sort()

      assert asked ==
               Enum.sort([ctx.admin.user.id, ctx.staff.user.id, ctx.other_staff.user.id])

      refute leaver.user.id in asked
      refute elsewhere.user.id in asked
    end
  end

  describe "opened" do
    test "each person gets one request over every current version, sent in the app", ctx do
      use_policy = publish!(ctx.admin, "acceptable-use", "v1")
      security = publish!(ctx.admin, "information-security", "v1")
      review = review_due!(ctx.admin, @template, "2026")

      assert {:ok, %{"policies" => 2, "people" => 3, "opened" => 3, "cancelled" => 0}} =
               open(ctx.admin, review.id)

      for request <- requests(ctx.admin) do
        assert request.purpose == :acknowledge
        assert request.status == :sent
        assert request.provider == :in_platform
        assert request.occurrence_id == review.id
        assert request.subject_type == Request.acknowledgement()

        assert Enum.map(request.documents, &{&1.position, &1.source_sha256}) ==
                 [{1, use_policy.sha256}, {2, security.sha256}]

        assert [%{status: :notified, order: 1} = signer] = request.signers
        assert request.subject_id == to_string(signer.user_id)
      end

      # Each person sees their own request only.
      assert [mine] = Signatures.list_signers!(opts(ctx.staff))
      assert mine.user_id == ctx.staff.user.id

      assert {:ok, status} = status(ctx.admin, review.id)

      assert status["counts"] == %{
               "acknowledged" => 0,
               "outstanding" => 3,
               "declined" => 0,
               "ended" => 0
             }

      assert status["versions"] == 2
    end

    test "a replay of the review opens nothing new", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, @template, "2026")

      assert {:ok, %{"opened" => 3}} = open(ctx.admin, review.id)
      before = ctx.admin |> requests() |> Enum.map(&{&1.id, &1.status})

      assert {:ok, %{"opened" => 0, "already_asked" => 3, "cancelled" => 0}} =
               open(ctx.admin, review.id)

      # Still nothing after a person has acknowledged.
      acknowledge!(ctx.staff)

      assert {:ok, %{"opened" => 0, "already_asked" => 3}} = open(ctx.admin, review.id)
      assert ctx.admin |> requests() |> Enum.map(& &1.id) == Enum.map(before, &elem(&1, 0))
    end

    test "the review shows who has acknowledged, and an acknowledgement is the person's own",
         ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, @template, "2026")
      {:ok, _} = open(ctx.admin, review.id)

      signed = acknowledge!(ctx.staff)
      assert signed.status == :signed

      assert {:ok, status} = status(ctx.admin, review.id)
      assert status["counts"]["acknowledged"] == 1
      assert status["counts"]["outstanding"] == 2
      assert [%{"user_id" => id, "state" => "signed", "email" => email}] = status["acknowledged"]
      assert id == ctx.staff.user.id
      assert email == to_string(ctx.staff.user.email)

      outstanding = Enum.map(status["outstanding"], & &1["user_id"])
      assert ctx.other_staff.user.id in outstanding
      assert ctx.admin.user.id in outstanding

      text = AshEnterprise.Signatures.ReviewStatus.describe(status)
      assert text =~ "1 of 3 acknowledged"
      assert text =~ to_string(ctx.other_staff.user.email)
      assert text =~ "acknowledges nothing for anyone"

      # A person asked, with no grant on requests, does not read the review's status.
      assert {:error, %Ash.Error.Forbidden{}} = status(ctx.other_staff, review.id)
    end

    test "a version published after the review opened asks again over the new set, and keeps what was acknowledged",
         ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, @template, "2026")
      {:ok, _} = open(ctx.admin, review.id)

      first = acknowledge!(ctx.staff)
      [completion] = completions(ctx.admin, first.request_id)

      v2 = publish!(ctx.admin, "acceptable-use", "v2")

      # The staff member's acknowledgement stands; the two still open are replaced.
      assert {:ok, %{"opened" => 3, "already_asked" => 0, "cancelled" => 2}} =
               open(ctx.admin, review.id)

      kept = Ash.get!(Signer, first.id, authorize?: false, tenant: ctx.admin.tenant)

      assert {kept.status, kept.signed_at, kept.shown_sha256} ==
               {:signed, first.signed_at, first.shown_sha256}

      assert [same] = completions(ctx.admin, first.request_id)
      assert same.record_hash == completion.record_hash

      theirs = requests_of(ctx.admin, ctx.staff)
      assert Enum.map(theirs, & &1.status) == [:completed, :sent]
      assert [_, %{documents: [%{source_sha256: sha}]}] = theirs
      assert sha == v2.sha256

      assert ctx.admin |> requests_of(ctx.other_staff) |> Enum.map(& &1.status) ==
               [:cancelled, :sent]

      # Each person counts once, by the newest request: everyone outstanding over v2.
      assert {:ok, status} = status(ctx.admin, review.id)
      assert status["counts"]["outstanding"] == 3
      assert status["counts"]["acknowledged"] == 0
    end

    test "the next period's review asks everyone again and replaces what is still open", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      this_year = review_due!(ctx.admin, @template, "2026")
      {:ok, _} = open(ctx.admin, this_year.id)
      acknowledge!(ctx.staff)

      next_year = review_due!(ctx.admin, @template, "2027")

      assert {:ok, %{"opened" => 3, "cancelled" => 2}} = open(ctx.admin, next_year.id)

      assert ctx.admin |> requests_of(ctx.staff) |> Enum.map(& &1.status) == [:completed, :sent]

      assert {:ok, %{"counts" => %{"acknowledged" => 1, "ended" => 2}}} =
               status(ctx.admin, this_year.id)

      assert {:ok, %{"counts" => %{"outstanding" => 3}}} = status(ctx.admin, next_year.id)
    end
  end

  # --- fixtures ---------------------------------------------------------------------

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]

  defp publish!(admin, key, text) do
    Compliance.publish_policy!(
      key,
      "SYNTHETIC #{key}",
      "SYNTHETIC #{key} policy, #{text}\n#{admin.tenant}",
      opts(admin)
    )
  end

  defp review_due!(admin, template, period) do
    :ok = Occurrences.review_due(admin.tenant, template, "annual", period)

    Occurrence
    |> Ash.Query.filter(type == "compliance.review_due")
    |> Ash.read!(actor: SystemActor.oban(), tenant: admin.tenant)
    |> Enum.find(&(&1.data["template"] == template and &1.data["period"] == period))
  end

  defp open(who, id), do: Signatures.open_acknowledgements(id, opts(who))
  defp status(who, id), do: Signatures.acknowledgement_review_status(id, opts(who))

  defp requests(admin) do
    Request
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load([:documents, :signers])
    |> Ash.read!(authorize?: false, tenant: admin.tenant)
  end

  defp requests_of(admin, person) do
    admin |> requests() |> Enum.filter(&(&1.subject_id == to_string(person.user.id)))
  end

  defp signers(admin), do: Ash.read!(Signer, authorize?: false, tenant: admin.tenant)

  defp completions(admin, request_id) do
    Completion
    |> Ash.Query.filter(request_id == ^request_id)
    |> Ash.read!(authorize?: false, tenant: admin.tenant)
  end

  # The person's own open row: view, consent, acknowledge.
  defp acknowledge!(person) do
    [signer] =
      person
      |> opts()
      |> Signatures.list_signers!()
      |> Enum.filter(&(&1.status == :notified))

    signer
    |> Signatures.view_signature_request!(opts(person))
    |> Signatures.consent_to_sign!(opts(person))
    |> Signatures.sign_signature_request!(opts(person))
  end
end
