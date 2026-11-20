defmodule AshEnterprise.Signatures.PolicyReacknowledgementTest do
  @moduledoc """
  Version 2, end to end (ECL-64 item 9): the real fan-out when the review falls due, a
  person's acknowledgement, a new policy version, the fan-out again, and the controls
  projected from the acknowledgement events.

  Failures first. A person whose version-1 acknowledgement is edited, lost or replaced is
  a failure, and so is a person version 2 does not reopen: they must be asked again, and
  their controls must go out until they acknowledge version 2.

  SYNTHETIC data only: every person is on `example.test` and every policy is a fixture.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  # Policies are evidence document versions, in the evidence store's own repo.
  @moduletag evidence: true

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1]

  alias AshCompliance.Resources.Finding
  alias AshCompliance.Testing
  alias AshEnterprise.Automation.{Occurrence, Occurrences}
  alias AshEnterprise.Compliance
  alias AshEnterprise.Compliance.EventLog
  alias AshEnterprise.Compliance.PolicyAcknowledgementProjector, as: Projector
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.{Completion, Request, Signer, SignerEvent}

  @controls ["CC1.1", "CC2.2", "CC5.3"]
  @template "policy_review_acknowledgement"

  setup do
    admin = tenant!()

    %{
      admin: admin,
      alice: colleague!(admin),
      bob: colleague!(admin),
      marker: marker()
    }
  end

  describe "version 1 is never edited or lost" do
    test "after version 2 the signer, its events and the completion read exactly as before",
         ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)

      first = acknowledge!(ctx.alice)
      before = snapshot(ctx.admin, first)

      publish!(ctx.admin, "acceptable-use", "v2")
      {:ok, %{"opened" => 3, "cancelled" => 2}} = open(ctx.admin, review.id)

      assert snapshot(ctx.admin, first) == before
      assert before.signer.status == :signed
      assert [_completion] = before.completions
      assert before.events != []
    end

    test "the version-1 request keeps naming the version-1 bytes it showed", ctx do
      v1 = publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)
      first = acknowledge!(ctx.alice)

      publish!(ctx.admin, "acceptable-use", "v2")
      {:ok, _} = open(ctx.admin, review.id)

      kept = Ash.get!(Signer, first.id, authorize?: false, tenant: ctx.admin.tenant)
      assert kept.shown_sha256 == first.shown_sha256

      [old, _new] = requests_of(ctx.admin, ctx.alice)
      assert [%{source_sha256: sha}] = old.documents
      assert sha == v1.sha256
    end
  end

  describe "version 2 reopens everyone" do
    test "a person who acknowledged version 1 is asked again, and is out until they acknowledge version 2",
         ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, %{"opened" => 3}} = open(ctx.admin, review.id)

      # Nobody has acknowledged: unknown, never a pass.
      seen = project!(ctx.marker)
      assert statuses(ctx.alice) == uniform(:unknown)

      first = acknowledge!(ctx.alice)
      seen = project!(seen)
      assert statuses(ctx.alice) == uniform(:compliant)
      # Bob was asked and has not acknowledged: unknown, not a pass.
      assert statuses(ctx.bob) == uniform(:unknown)

      v2 = publish!(ctx.admin, "acceptable-use", "v2")
      assert v2.version == 2

      # Publishing alone already puts Alice out.
      seen = project!(seen)
      assert statuses(ctx.alice) == uniform(:noncompliant)

      # The fan-out asks her again, over version 2 only.
      assert {:ok, %{"opened" => 3}} = open(ctx.admin, review.id)

      assert [%{status: :completed}, %{status: :sent} = fresh] =
               requests_of(ctx.admin, ctx.alice)

      assert [%{source_sha256: sha}] = fresh.documents
      assert sha == v2.sha256

      # Asking is not acknowledging: still out.
      seen = project!(seen)
      assert statuses(ctx.alice) == uniform(:noncompliant)

      second = acknowledge!(ctx.alice)
      assert second.status == :signed
      assert second.request_id == fresh.id
      refute second.id == first.id
      project!(seen)
      assert statuses(ctx.alice) == uniform(:compliant)

      # Bob never acknowledged either version: still not a pass.
      assert statuses(ctx.bob) == uniform(:unknown)
    end

    test "acknowledging version 1 again does not satisfy version 2", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)
      acknowledge!(ctx.alice)

      publish!(ctx.admin, "acceptable-use", "v2")
      {:ok, _} = open(ctx.admin, review.id)

      # Only one row is open for her, and it is over version 2.
      open_rows =
        ctx.alice
        |> opts()
        |> Signatures.list_signers!()
        |> Enum.filter(&(&1.status == :notified))

      assert [_one] = open_rows

      project!(ctx.marker)
      assert statuses(ctx.alice) == uniform(:noncompliant)
    end
  end

  describe "publishing version 2 asks again by itself" do
    test "everyone is asked over version 2 without another call to the fan-out", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)
      acknowledge!(ctx.alice)

      v2 = publish!(ctx.admin, "acceptable-use", "v2")
      reask!()

      for person <- [ctx.alice, ctx.bob, ctx.admin] do
        assert [%{status: :sent} = fresh] =
                 ctx.admin |> requests_of(person) |> Enum.filter(&(&1.status == :sent))

        assert fresh.occurrence_id == review.id
        assert [%{source_sha256: sha}] = fresh.documents
        assert sha == v2.sha256
      end

      # The version-1 acknowledgement is kept.
      assert [%{status: :completed} | _] = requests_of(ctx.admin, ctx.alice)
    end

    test "with no review fallen due yet nobody is asked, and the publish still stands", ctx do
      v1 = publish!(ctx.admin, "acceptable-use", "v1")
      reask!()

      assert requests_of(ctx.admin, ctx.alice) == []
      assert [%{id: id}] = Compliance.current_policies!(opts(ctx.admin))
      assert id == v1.id
    end

    test "the review does not count a version-1 acknowledgement once version 2 is current",
         ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)
      acknowledge!(ctx.alice)

      {:ok, before} = Signatures.acknowledgement_review_status(review.id, opts(ctx.admin))
      assert before["counts"]["acknowledged"] == 1

      # Version 2 is current and nobody has been asked over it yet.
      publish!(ctx.admin, "acceptable-use", "v2")

      {:ok, status} = Signatures.acknowledgement_review_status(review.id, opts(ctx.admin))
      assert status["counts"]["acknowledged"] == 0
      assert to_string(ctx.alice.user.id) in Enum.map(status["outstanding"], & &1["user_id"])
    end
  end

  describe "people who come into scope after a publish" do
    test "a person reactivated after version 2 is out, not still in on version 1", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)
      acknowledge!(ctx.alice)
      seen = project!(ctx.marker)
      assert statuses(ctx.alice) == uniform(:compliant)

      lifecycle!(ctx.alice, :deactivate)
      publish!(ctx.admin, "acceptable-use", "v2")
      lifecycle!(ctx.alice, :activate)

      project!(seen)
      assert statuses(ctx.alice) == uniform(:noncompliant)
    end

    test "a person who joins after the policies were published is unknown, never absent",
         ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      carol = colleague!(ctx.admin)

      project!(ctx.marker)
      assert statuses(carol) == uniform(:unknown)
      # Bob was there at the publish: the same.
      assert statuses(ctx.bob) == uniform(:unknown)
    end

    test "a person asked by the fan-out has a finding even with no other event", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      carol = colleague!(ctx.admin)
      # Only the events written from here on count.
      seen = marker()

      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)

      project!(seen)
      assert statuses(carol) == uniform(:unknown)
    end
  end

  # A person who signs while version 2 is being published must not be recorded as holding
  # the current versions on a snapshot that still shows version 1. Both writes take the
  # tenant's audit lock before they work out anyone's standing, so the second waits for
  # the first to commit and reads what it wrote.
  describe "a sign during a publish" do
    test "a sign takes the tenant's lock before it reads the policies", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")
      review = review_due!(ctx.admin, "2026")
      {:ok, _} = open(ctx.admin, review.id)

      [signer] =
        ctx.alice
        |> opts()
        |> Signatures.list_signers!()
        |> Enum.filter(&(&1.status == :notified))

      consented =
        signer
        |> Signatures.view_signature_request!(opts(ctx.alice))
        |> Signatures.consent_to_sign!(opts(ctx.alice))

      queries =
        capture_queries(fn -> Signatures.sign_signature_request!(consented, opts(ctx.alice)) end)

      assert_locked_before(queries, ~s(FROM "compliance_policies"))
    end

    test "a publish takes the tenant's lock before it reads anyone's acknowledgements", ctx do
      publish!(ctx.admin, "acceptable-use", "v1")

      queries = capture_queries(fn -> publish!(ctx.admin, "acceptable-use", "v2") end)

      assert_locked_before(queries, ~s(FROM "signature_signers"))
    end
  end

  # --- fixtures ---------------------------------------------------------------------

  defp capture_queries(fun) do
    id = "policy-lock-order-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      id,
      [:ash_enterprise, :repo, :query],
      fn _event, _measurements, meta, _config -> send(me, {:query, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:query, query} -> collect([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_locked_before(queries, read) do
    lock = Enum.find_index(queries, &(&1 =~ "pg_advisory_xact_lock"))
    first_read = Enum.find_index(queries, &(&1 =~ read))

    assert is_integer(first_read), "expected a read #{read}"
    assert is_integer(lock), "expected the tenant's advisory lock"
    assert lock < first_read
  end

  # Runs what a publish enqueued: asking everyone again over the new set.
  defp reask! do
    Oban.drain_queue(queue: :default, with_safety: false)
  end

  defp lifecycle!(member, action) do
    AshEnterprise.Accounts.User
    |> Ash.get!(member.user.id, authorize?: false)
    |> Ash.Changeset.for_update(action, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]

  defp uniform(status), do: Map.new(@controls, &{&1, status})

  defp publish!(admin, key, text) do
    Compliance.publish_policy!(
      key,
      "SYNTHETIC #{key}",
      "SYNTHETIC #{key} policy, #{text}\n#{admin.tenant}",
      opts(admin)
    )
  end

  defp review_due!(admin, period) do
    :ok = Occurrences.review_due(admin.tenant, @template, "annual", period)

    Occurrence
    |> Ash.Query.filter(type == "compliance.review_due")
    |> Ash.read!(actor: SystemActor.oban(), tenant: admin.tenant)
    |> Enum.find(&(&1.data["template"] == @template and &1.data["period"] == period))
  end

  defp open(who, id), do: Signatures.open_acknowledgements(id, opts(who))

  defp requests_of(admin, person) do
    Request
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load([:documents, :signers])
    |> Ash.read!(authorize?: false, tenant: admin.tenant)
    |> Enum.filter(&(&1.subject_id == to_string(person.user.id)))
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

  defp snapshot(admin, signer) do
    reload = &Ash.read!(&1, authorize?: false, tenant: admin.tenant)

    %{
      signer: Ash.get!(Signer, signer.id, authorize?: false, tenant: admin.tenant),
      events:
        SignerEvent
        |> Ash.Query.filter(signer_id == ^signer.id)
        |> Ash.Query.sort(id: :asc)
        |> reload.()
        |> Enum.map(&Map.take(&1, [:id, :type, :occurred_at, :record_hash])),
      completions:
        Completion
        |> Ash.Query.filter(request_id == ^signer.request_id)
        |> reload.()
        |> Enum.map(&Map.take(&1, [:id, :record_hash]))
    }
  end

  defp marker do
    case EventLog
         |> Ash.Query.sort(id: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one!(authorize?: false) do
      nil -> 0
      event -> event.id
    end
  end

  # Folds the policy events after `since` into findings and returns the last event's id.
  defp project!(since) do
    events =
      EventLog
      |> Ash.Query.filter(
        id > ^since and
          action in [:policy_acknowledged, :policy_published, :policy_scope_entered]
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(authorize?: false)

    :ok =
      Testing.drain_sync(
        Projector,
        Enum.map(events, fn event ->
          %{
            id: event.id,
            practice_id: event.practice_id,
            user_id: event.user_id,
            occurred_at: event.occurred_at,
            metadata: event.metadata,
            resource: event.resource,
            action: event.action,
            action_type: event.action_type
          }
        end)
      )

    case List.last(events) do
      nil -> since
      event -> event.id
    end
  end

  defp statuses(member) do
    Finding
    |> Ash.Query.filter(subject_type == "user" and subject_id == ^to_string(member.user.id))
    |> Ash.Query.filter(control_id in ^@controls)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.control_id, &1.status})
  end
end
