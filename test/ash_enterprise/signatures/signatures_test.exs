defmodule AshEnterprise.Signatures.SignaturesTest do
  @moduledoc """
  The `ash_signatures` fragments on the platform base (ADR 0074): a request to acknowledge
  exact document versions, a signer who is a user of the organization, the events and the
  completion.

  Phrased first as what must not happen: an automation principal signing or consenting,
  another person reading or acting on someone's row, another organization seeing anything,
  an event or completion written or changed through a grant, a signer who is not an active
  user here, a reminder from anyone but the job runner. Then the acknowledgement itself,
  and an erasure that leaves the hashes, times and completion record whole.

  SYNTHETIC data only: every person is on `example.test` and every document is a fixture.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures,
    only: [tenant!: 0, tenant!: 1, member!: 3, deactivate!: 1]

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Platform.{AutomationPrincipal, SystemActor}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.{ChainHead, Completion, Signer, SignerEvent}

  @moduletag evidence: true

  setup do
    admin = tenant!(operator?: true)

    %{
      admin: admin,
      signer: member!(admin, "Staff #{System.unique_integer([:positive])}", []),
      colleague: member!(admin, "Staff #{System.unique_integer([:positive])}", [])
    }
  end

  describe "refused" do
    test "an automation principal acting for the signer can neither consent nor sign", ctx do
      signer_row = sent!(ctx.admin, ctx.signer)
      viewed = Signatures.view_signature_request!(signer_row, opts(ctx.signer))

      robot = acting_for(ctx.signer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.consent_to_sign(viewed, actor: robot, tenant: ctx.signer.tenant)

      consented = Signatures.consent_to_sign!(viewed, opts(ctx.signer))

      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.sign_signature_request(consented,
                 actor: robot,
                 tenant: ctx.signer.tenant
               )

      for actor <- SystemActor.all() do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Signatures.sign_signature_request(consented,
                   actor: actor,
                   tenant: ctx.signer.tenant
                 ),
               "#{actor.name} signed for a person"
      end

      assert reload(consented).status == :viewed
      assert reload(consented).signed_at == nil
    end

    test "another person can neither read nor act on someone's row; the administrator cannot sign it",
         ctx do
      signer_row = sent!(ctx.admin, ctx.signer)

      assert Signatures.list_signers!(opts(ctx.colleague)) == []
      assert {:error, _} = Signatures.get_signer(signer_row.id, opts(ctx.colleague))
      assert Signatures.list_signature_requests!(opts(ctx.colleague)) == []
      assert Signatures.list_signature_documents!(opts(ctx.colleague)) == []

      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.view_signature_request(signer_row, opts(ctx.colleague))

      viewed = Signatures.view_signature_request!(signer_row, opts(ctx.signer))
      consented = Signatures.consent_to_sign!(viewed, opts(ctx.signer))

      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.sign_signature_request(consented, opts(ctx.colleague))

      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.decline_signature_request(consented, "SYNTHETIC: not mine",
                 actor: ctx.colleague.actor,
                 tenant: ctx.colleague.tenant
               )

      # The tenant's Administrator reads every row, and still cannot take the person's act.
      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.sign_signature_request(consented, opts(ctx.admin))

      assert reload(consented).status == :viewed
    end

    test "another organization sees nothing and can act on nothing", ctx do
      signer_row = sent!(ctx.admin, ctx.signer)
      elsewhere = tenant!()

      for list <- [
            &Signatures.list_signature_requests!/1,
            &Signatures.list_signature_documents!/1,
            &Signatures.list_signers!/1,
            &Signatures.list_signer_events!/1,
            &Signatures.list_signature_completions!/1
          ] do
        assert list.(opts(elsewhere)) == []
      end

      assert {:error, _} = Signatures.get_signer(signer_row.id, opts(elsewhere))

      # Naming the request's own tenant reads nothing and acts on nothing.
      assert Signatures.list_signers!(actor: elsewhere.actor, tenant: ctx.admin.tenant) == []

      assert {:error, %Ash.Error.Forbidden{}} =
               Signatures.view_signature_request(signer_row,
                 actor: elsewhere.actor,
                 tenant: ctx.admin.tenant
               )

      assert reload(signer_row).status == :notified
    end

    test "events and completions are append-only: no update or destroy, and no grant writes one",
         ctx do
      for resource <- [SignerEvent, Completion] do
        types = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.uniq()
        assert Enum.sort(types) == [:create, :read], "#{inspect(resource)} has #{inspect(types)}"
      end

      signer_row = sent!(ctx.admin, ctx.signer)

      # The Administrator holds every grant on the resource, and still cannot forge an event.
      assert {:error, %Ash.Error.Forbidden{}} =
               SignerEvent
               |> Ash.Changeset.for_create(
                 :record,
                 %{request_id: signer_row.request_id, signer_id: signer_row.id, type: :signed},
                 opts(ctx.admin)
               )
               |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               Completion
               |> Ash.Changeset.for_create(
                 :record,
                 %{request_id: signer_row.request_id, record: %{"forged" => true}},
                 opts(ctx.admin)
               )
               |> Ash.create()
    end

    test "a signer must be an active user of the organization, and is never taken from a typed name or email",
         ctx do
      request = draft!(ctx.admin, [version!(ctx.admin, "SYNTHETIC policy A v1")])
      elsewhere = tenant!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               add_signer(ctx.admin, request, elsewhere.user.id)

      assert Exception.message(error) =~ "not an active user of this organization"

      leaver = deactivate!(member!(ctx.admin, "Leaver #{System.unique_integer([:positive])}", []))

      assert {:error, %Ash.Error.Invalid{}} = add_signer(ctx.admin, request, leaver.user.id)

      # The fragment's own `add` takes a name and an email and no person: closed to every
      # grant, and refused for want of a person even where it is reached.
      refute Ash.can?({Signer, :add}, ctx.admin.actor, tenant: ctx.admin.tenant)

      assert {:error, _} =
               Signer
               |> Ash.Changeset.for_create(
                 :add,
                 %{
                   request_id: request.id,
                   role: :staff,
                   order: 1,
                   name: "SYNTHETIC Someone",
                   email: "someone@example.test"
                 },
                 opts(ctx.admin)
               )
               |> Ash.create()
    end

    test "only the job runner reminds; nobody reminds a signer whose turn it is not", ctx do
      signer_row = sent!(ctx.admin, ctx.signer)

      for actor <- [ctx.admin.actor, ctx.signer.actor, SystemActor.process()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Signatures.remind_signer(signer_row, actor: actor, tenant: ctx.admin.tenant)
      end

      reminded = Signatures.remind_signer!(signer_row, oban(ctx))
      assert [:reminded] == event_types(reminded)

      signed = acknowledge!(ctx.signer, reminded)

      assert {:error, %Ash.Error.Invalid{} = error} = Signatures.remind_signer(signed, oban(ctx))
      assert Exception.message(error) =~ "only the signer whose turn it is"
    end
  end

  describe "an acknowledgement" do
    test "the person acknowledges exact versions; the event, the request and the completion record them",
         ctx do
      versions = [
        version!(ctx.admin, "SYNTHETIC acceptable use policy, version 1"),
        version!(ctx.admin, "SYNTHETIC information security policy, version 1")
      ]

      signer_row = sent!(ctx.admin, ctx.signer, versions)
      assert signer_row.status == :notified

      # The person sees their own row and the request's documents.
      assert [%{id: id}] = Signatures.list_signers!(opts(ctx.signer))
      assert id == signer_row.id

      assert ctx.signer
             |> opts()
             |> Signatures.list_signature_documents!()
             |> Enum.map(& &1.source_sha256)
             |> Enum.sort() == versions |> Enum.map(& &1.sha256) |> Enum.sort()

      signed =
        acknowledge!(ctx.signer, signer_row,
          ip_address: "192.0.2.10",
          user_agent: "SYNTHETIC browser"
        )

      shown = AshSignatures.Digest.shown(Enum.map(versions, & &1.sha256))
      assert signed.status == :signed
      assert signed.shown_sha256 == shown

      events = events(signed)
      assert Enum.map(events, & &1.type) == [:viewed, :consented, :signed]
      assert %{sha256: ^shown, route: :in_platform} = List.last(events)

      request = Signatures.get_signature_request!(signed.request_id, opts(ctx.admin))
      assert request.purpose == :acknowledge
      assert request.status == :completed

      [completion] = completions(ctx.admin, request.id)
      assert AshSignatures.Completion.intact?(completion)
      assert completion.chain_head
      assert completion.chain_head in chain_hashes(ctx.admin.tenant)

      assert completion.record["events"] |> Enum.map(& &1["event_hash"]) ==
               Enum.map(events, & &1.event_hash)

      # The person reads their own events and the completion of the request they were on.
      assert length(Signatures.list_signer_events!(opts(ctx.signer))) == 3
      assert [_] = Signatures.list_signature_completions!(opts(ctx.signer))
      assert Signatures.list_signer_events!(opts(ctx.colleague)) == []
    end

    test "the person's email and the event's personal fields are sealed; erasing the person leaves the hashes, times and record whole",
         ctx do
      signer_row = sent!(ctx.admin, ctx.signer)

      signed =
        acknowledge!(ctx.signer, signer_row,
          ip_address: "192.0.2.44",
          user_agent: "SYNTHETIC browser"
        )

      loaded =
        Ash.load!(signed, [:email, :recorded?], authorize?: false, tenant: ctx.admin.tenant)

      assert loaded.email == ctx.signer.email
      assert loaded.recorded?

      {:ok, scope} =
        Erasure.scope_by_ref(:data_subject, SealingScope.scope_ref(ctx.signer.user.id),
          authorize?: false
        )

      assert signed.erasure_scope_id == scope.id

      before_events = events(signed)
      assert Enum.all?(before_events, &(&1.erasure_scope_id == scope.id))

      [%{type: :viewed} = viewed | _] =
        Ash.load!(before_events, [:ip_address, :user_agent],
          authorize?: false,
          tenant: ctx.admin.tenant
        )

      assert {viewed.ip_address, viewed.user_agent} == {"192.0.2.44", "SYNTHETIC browser"}

      [completion] = completions(ctx.admin, signed.request_id)

      assert {:ok, _receipt} =
               Erasure.erase_person(ctx.signer.email, ctx.signer.email, "SYNTHETIC: erasure test",
                 actor: ctx.admin.actor,
                 tenant: ctx.admin.tenant
               )

      erased =
        signed
        |> reload()
        |> Ash.load!([:email, :recorded?], authorize?: false, tenant: ctx.admin.tenant)

      assert Shredded.shredded?(erased.email)
      refute erased.recorded?

      assert {erased.status, erased.signed_at, erased.shown_sha256} ==
               {signed.status, signed.signed_at, signed.shown_sha256}

      after_events =
        signed
        |> events()
        |> Ash.load!([:ip_address, :user_agent, :reason, :recorded?],
          authorize?: false,
          tenant: ctx.admin.tenant
        )

      for event <- after_events, field <- [:ip_address, :user_agent] do
        assert Shredded.shredded?(Map.fetch!(event, field)), "#{event.type} #{field}"
      end

      assert Enum.map(after_events, &{&1.id, &1.event_hash, &1.occurred_at, &1.sha256}) ==
               Enum.map(before_events, &{&1.id, &1.event_hash, &1.occurred_at, &1.sha256})

      [after_completion] = completions(ctx.admin, signed.request_id)
      assert after_completion.record_hash == completion.record_hash
      assert after_completion.record == completion.record
      assert AshSignatures.Completion.intact?(after_completion)
    end

    # Once the scope is shredded every other field the event hash covers is still in plain
    # text, so a hash with no secret in it would confirm a guess at the erased ones: an
    # IPv4 address is 2^32 candidates and a browser's user agent one of a few.
    test "after erasing the person, the stored hashes cannot confirm a guess at what was erased",
         ctx do
      ip = "198.51.100.77"
      agent = "Mozilla/5.0 (X11; Linux x86_64)"
      signer_row = sent!(ctx.admin, ctx.signer)
      signed = acknowledge!(ctx.signer, signer_row, ip_address: ip, user_agent: agent)

      before_events =
        signed
        |> events()
        |> Ash.load!([:ip_address, :user_agent, :reason, :salt],
          authorize?: false,
          tenant: ctx.admin.tenant
        )

      # While the scope is live the hash verifies, salt and all.
      for event <- before_events, event.ip_address == ip do
        assert is_binary(event.salt)
        assert AshSignatures.SignerEvent.Changes.Hash.hash(event) == event.event_hash
      end

      assert {:ok, _receipt} =
               Erasure.erase_person(ctx.signer.email, ctx.signer.email, "SYNTHETIC: erasure test",
                 actor: ctx.admin.actor,
                 tenant: ctx.admin.tenant
               )

      erased =
        signed
        |> events()
        |> Ash.load!([:salt], authorize?: false, tenant: ctx.admin.tenant)

      assert erased |> Enum.filter(&(&1.type in [:viewed, :consented, :signed])) != []

      for event <- erased, event.type in [:viewed, :consented, :signed] do
        assert Shredded.shredded?(event.salt)

        # What a reader still holds, with the true values guessed exactly.
        guess = %{
          request_id: event.request_id,
          signer_id: event.signer_id,
          type: event.type,
          route: event.route,
          sha256: event.sha256,
          ip_address: ip,
          user_agent: agent,
          reason: nil,
          occurred_at: event.occurred_at
        }

        refute AshSignatures.Digest.sha256_hex(guess) == event.event_hash
      end
    end

    test "the chain head is the tenant's last audit hash", ctx do
      [last | _] = chain_hashes(ctx.admin.tenant)
      assert ChainHead.head(ctx.admin.tenant) == last
      assert ChainHead.head(Ash.UUID.generate()) == nil
    end
  end

  # --- fixtures ---------------------------------------------------------------------

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]
  defp oban(ctx), do: [actor: SystemActor.oban(), tenant: ctx.admin.tenant]

  defp version!(admin, text) do
    bytes = "#{text}\n#{System.unique_integer([:positive])}"
    sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    AshEvidence.Domain.ingest_document!("policy", bytes, sha256, tenant: to_string(admin.tenant))
  end

  defp draft!(admin, versions) do
    request =
      Signatures.draft_signature_request!(
        %{
          subject_type: "synthetic_policy_set",
          subject_id: Ash.UUID.generate(),
          purpose: :acknowledge
        },
        opts(admin)
      )

    versions
    |> Enum.with_index(1)
    |> Enum.each(fn {version, position} ->
      Signatures.add_signature_document!(
        %{request_id: request.id, source_version_id: version.id, position: position},
        opts(admin)
      )
    end)

    request
  end

  defp add_signer(admin, request, user_id),
    do:
      Signatures.add_signer(
        %{request_id: request.id, role: :staff, order: 1, user_id: user_id},
        opts(admin)
      )

  defp sent!(admin, member, versions \\ nil) do
    versions = versions || [version!(admin, "SYNTHETIC policy A v1")]
    request = draft!(admin, versions)
    {:ok, signer} = add_signer(admin, request, member.user.id)
    Signatures.send_signature_request!(request, opts(admin))
    reload(signer)
  end

  defp acknowledge!(member, signer, inputs \\ []) do
    inputs = Map.new(inputs)

    signer
    |> Signatures.view_signature_request!(inputs, opts(member))
    |> Signatures.consent_to_sign!(inputs, opts(member))
    |> Signatures.sign_signature_request!(inputs, opts(member))
  end

  defp reload(signer),
    do: Ash.get!(Signer, signer.id, authorize?: false, tenant: signer.organization_id)

  defp events(signer) do
    SignerEvent
    |> Ash.Query.filter(signer_id == ^signer.id)
    |> Ash.Query.sort(occurred_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false, tenant: signer.organization_id)
  end

  defp event_types(signer), do: signer |> events() |> Enum.map(& &1.type)

  defp completions(admin, request_id) do
    Completion
    |> Ash.Query.filter(request_id == ^request_id)
    |> Ash.read!(authorize?: false, tenant: admin.tenant)
  end

  defp chain_hashes(tenant) do
    EventLog
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.hash)
  end

  # An automation principal acting for `member`, on the intersection of the two contexts.
  defp acting_for(member) do
    AutomationPrincipal.acting(
      AutomationPrincipal.evidence_admitter(),
      member.user.id,
      "policy-acknowledger",
      ActorContext.intersect(
        ActorContext.build(member.user, tenant: member.tenant),
        ActorContext.build_automation(:evidence_admitter, member.tenant)
      )
    )
  end
end
