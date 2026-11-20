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

  # --- fixtures ---------------------------------------------------------------------

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
      |> Ash.Query.filter(id > ^since and action in [:policy_acknowledged, :policy_published])
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
