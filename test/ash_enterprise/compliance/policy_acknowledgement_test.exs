defmodule AshEnterprise.Compliance.PolicyAcknowledgementTest do
  @moduledoc """
  CC1.1, CC2.2 and CC5.3 projected from acknowledgement events (ADR 0035): a person is in
  while they hold a signed acknowledgement of the current version of every current policy.

  Phrased first as what must not count: no acknowledgement, an acknowledgement of something
  that is no policy, a request to execute rather than acknowledge, a decline, another
  person's acknowledgement, another organization's, part of the current set. Then the
  acknowledgement itself, and version 2 putting the person out again with version 1 kept.

  SYNTHETIC data only: every person is on `example.test` and every policy is a fixture.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, tenant!: 1, member!: 3]

  alias AshCompliance.Resources.Finding
  alias AshCompliance.Testing
  alias AshEnterprise.Compliance
  alias AshEnterprise.Compliance.{EventLog, PolicyAcknowledgement}
  alias AshEnterprise.Compliance.PolicyAcknowledgementProjector, as: Projector
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.{Completion, Signer}

  @controls ["CC1.1", "CC2.2", "CC5.3"]

  # Policy bytes live in the evidence store's own repo.
  @moduletag evidence: true

  setup do
    admin = tenant!(operator?: true)

    %{
      admin: admin,
      person: member!(admin, "Staff #{System.unique_integer([:positive])}", []),
      colleague: member!(admin, "Staff #{System.unique_integer([:positive])}", []),
      marker: marker()
    }
  end

  describe "what does not put a person in" do
    test "a person who never acknowledged is unknown on every criterion, never compliant",
         ctx do
      publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      project!(ctx.marker)

      assert statuses(ctx.person) == unknown_everywhere()
      assert PolicyAcknowledgement.standing(ctx.admin.tenant, ctx.person.user.id).facts == []
    end

    test "with no policy published there is nothing to hold, and that is unknown, not a pass",
         ctx do
      standing = PolicyAcknowledgement.standing(ctx.admin.tenant, ctx.person.user.id)

      assert standing.acknowledged_current_policies == nil
      assert standing.facts == []
      assert standing.current == []
    end

    test "acknowledging a document that is no policy records nothing", ctx do
      publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      marker = marker()

      other = document!(ctx.admin, "SYNTHETIC meeting notes")
      signer = sent!(ctx.admin, ctx.person, [other.id])
      acknowledge!(ctx.person, signer)

      assert events_since(marker, ctx.person) == []
      assert PolicyAcknowledgement.standing(ctx.admin.tenant, ctx.person.user.id).facts == []
    end

    test "signing a request to execute, not acknowledge, records nothing", ctx do
      policy = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      marker = marker()

      signer = sent!(ctx.admin, ctx.person, [policy.document_version_id], purpose: :execute)
      acknowledge!(ctx.person, signer)

      assert events_since(marker, ctx.person) == []
      project!(ctx.marker)
      assert statuses(ctx.person) == unknown_everywhere()
    end

    test "declining is not acknowledging", ctx do
      policy = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      marker = marker()

      signer = sent!(ctx.admin, ctx.person, [policy.document_version_id])
      viewed = Signatures.view_signature_request!(signer, opts(ctx.person))

      Signatures.decline_signature_request!(viewed, "SYNTHETIC: not today", opts(ctx.person))

      assert events_since(marker, ctx.person) == []
      project!(ctx.marker)
      assert statuses(ctx.person) == unknown_everywhere()
    end

    test "another person's acknowledgement does not count for me", ctx do
      policy = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")

      acknowledge!(ctx.colleague, sent!(ctx.admin, ctx.colleague, [policy.document_version_id]))
      project!(ctx.marker)

      assert statuses(ctx.colleague) == compliant_everywhere()
      assert statuses(ctx.person) == unknown_everywhere()
    end

    test "another organization's policies and acknowledgements are not mine", ctx do
      elsewhere = tenant!()
      their_person = member!(elsewhere, "Staff #{System.unique_integer([:positive])}", [])

      theirs = publish!(elsewhere, "acceptable-use", "SYNTHETIC acceptable use v1")
      acknowledge!(their_person, sent!(elsewhere, their_person, [theirs.document_version_id]))

      publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1, here")
      project!(ctx.marker)

      assert statuses(their_person) == compliant_everywhere()
      assert statuses(ctx.person) == unknown_everywhere()

      # Their people were evaluated under their organization only.
      assert their_person |> findings() |> Enum.all?(&(&1.organization_id == elsewhere.tenant))
      assert findings_in(ctx.admin.tenant, their_person) == []
    end

    test "acknowledging part of the current set is out", ctx do
      use_policy = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      publish!(ctx.admin, "data-handling", "SYNTHETIC data handling v1")

      acknowledge!(ctx.person, sent!(ctx.admin, ctx.person, [use_policy.document_version_id]))
      project!(ctx.marker)

      assert statuses(ctx.person) == noncompliant_everywhere()
    end

    test "the policy criteria stay out of the organization's compliance bundle and the KYC projector",
         ctx do
      policy = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      acknowledge!(ctx.person, sent!(ctx.admin, ctx.person, [policy.document_version_id]))

      [event | _] = events_since(ctx.marker, ctx.person)

      refute AshEnterprise.Compliance.Projector.needs_current_state?(event)
      assert AshEnterprise.Compliance.Projector.handle_event(event, nil) == :skip

      kyc_gaps = Enum.map(AshEnterprise.Compliance.KycRules.__bundle__().rules, & &1.outcome.gap)
      assert Enum.filter(@controls, &(&1 in kyc_gaps)) == []
    end
  end

  describe "acknowledging the current policies" do
    test "a person who acknowledges every current policy is in on CC1.1, CC2.2 and CC5.3",
         ctx do
      use_policy = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      data_policy = publish!(ctx.admin, "data-handling", "SYNTHETIC data handling v1")
      marker = marker()

      signer =
        sent!(ctx.admin, ctx.person, [
          use_policy.document_version_id,
          data_policy.document_version_id
        ])

      signed = acknowledge!(ctx.person, signer)

      events = events_since(marker, ctx.person)
      assert Enum.map(events, & &1.metadata["control_id"]) |> Enum.sort() == @controls
      assert Enum.all?(events, &(&1.action == :policy_acknowledged))

      [event | _] = events
      assert event.data["request_id"] == signed.request_id

      assert event.data["policies"] |> Enum.map(&{&1["policy_key"], &1["version"], &1["sha256"]}) ==
               [
                 {"acceptable-use", 1, use_policy.sha256},
                 {"data-handling", 1, data_policy.sha256}
               ]

      project!(ctx.marker)
      assert statuses(ctx.person) == compliant_everywhere()
    end

    test "publishing version 2 puts the person out, keeps version 1's acknowledgement, and acknowledging version 2 puts them back in",
         ctx do
      v1 = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v1")
      first = acknowledge!(ctx.person, sent!(ctx.admin, ctx.person, [v1.document_version_id]))
      seen = project!(ctx.marker)
      assert statuses(ctx.person) == compliant_everywhere()

      [completion_before] = completions(ctx.admin, first.request_id)

      v2 = publish!(ctx.admin, "acceptable-use", "SYNTHETIC acceptable use v2")
      assert v2.version == 2
      seen = project!(seen)

      assert statuses(ctx.person) == noncompliant_everywhere()

      # Version 1's acknowledgement is untouched.
      kept = Ash.get!(Signer, first.id, authorize?: false, tenant: ctx.admin.tenant)
      assert kept.status == :signed
      assert kept.signed_at == first.signed_at
      assert kept.shown_sha256 == first.shown_sha256
      assert [completion_after] = completions(ctx.admin, first.request_id)
      assert completion_after.record_hash == completion_before.record_hash

      acknowledge!(ctx.person, sent!(ctx.admin, ctx.person, [v2.document_version_id]))
      project!(seen)

      assert statuses(ctx.person) == compliant_everywhere()

      [finding | _] = findings(ctx.person)
      assert finding.resolved_at != nil
    end
  end

  # --- helpers ---------------------------------------------------------------------------

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]

  defp publish!(admin, key, text) do
    Compliance.publish_policy!(key, "SYNTHETIC #{key}", "#{text}\n", opts(admin))
  end

  defp document!(admin, text) do
    bytes = "#{text}\n#{System.unique_integer([:positive])}"
    sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    AshEvidence.Domain.ingest_document!("policy", bytes, sha256, tenant: to_string(admin.tenant))
  end

  defp sent!(admin, member, version_ids, overrides \\ []) do
    request =
      Signatures.draft_signature_request!(
        %{
          subject_type: "synthetic_policy_set",
          subject_id: Ash.UUID.generate(),
          purpose: Keyword.get(overrides, :purpose, :acknowledge)
        },
        opts(admin)
      )

    version_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {version_id, position} ->
      Signatures.add_signature_document!(
        %{request_id: request.id, source_version_id: version_id, position: position},
        opts(admin)
      )
    end)

    signer =
      Signatures.add_signer!(
        %{request_id: request.id, role: :staff, order: 1, user_id: member.user.id},
        opts(admin)
      )

    Signatures.send_signature_request!(request, opts(admin))
    Ash.get!(Signer, signer.id, authorize?: false, tenant: admin.tenant)
  end

  defp acknowledge!(member, signer) do
    signer
    |> Signatures.view_signature_request!(opts(member))
    |> Signatures.consent_to_sign!(opts(member))
    |> Signatures.sign_signature_request!(opts(member))
  end

  defp completions(admin, request_id) do
    Completion
    |> Ash.Query.filter(request_id == ^request_id)
    |> Ash.read!(authorize?: false, tenant: admin.tenant)
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

  defp events_since(marker, member) do
    EventLog
    |> Ash.Query.filter(
      id > ^marker and action in [:policy_acknowledged, :policy_published] and
        metadata["subject_id"] == ^to_string(member.user.id)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.action == :policy_acknowledged))
  end

  # Folds the policy events after `since` into findings, in order, and returns the last
  # event's id: the next call starts there, so no event is projected twice.
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

  defp findings(member) do
    Finding
    |> Ash.Query.filter(subject_type == "user" and subject_id == ^to_string(member.user.id))
    |> Ash.Query.filter(control_id in ^@controls)
    |> Ash.read!(authorize?: false)
  end

  defp findings_in(organization_id, member) do
    member |> findings() |> Enum.filter(&(&1.organization_id == organization_id))
  end

  defp statuses(member) do
    member |> findings() |> Map.new(&{&1.control_id, &1.status})
  end

  defp unknown_everywhere, do: Map.new(@controls, &{&1, :unknown})
  defp compliant_everywhere, do: Map.new(@controls, &{&1, :compliant})
  defp noncompliant_everywhere, do: Map.new(@controls, &{&1, :noncompliant})
end
