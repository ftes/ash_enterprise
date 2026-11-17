defmodule AshEnterprise.Erasure.ErasePersonTest do
  @moduledoc """
  Erasing a person by their address (`AshEnterprise.Erasure.PersonErasure`, ADR 0024):
  one transaction that shreds the person's own scopes, blanks the row, deletes their MDM
  statements, staged rows and derived joins, and writes a receipt that names nobody.

  Phrased first as what must not happen: an erase by anyone but a granted person, an
  unconfirmed one, one that reaches another tenant, a fixture value left readable, a
  receipt holding the address, a half-done erase, a resurrected row. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, tenant!: 1, member!: 3]

  alias AshEnterprise.Assistant.Thread
  alias AshEnterprise.Audit.Verify

  alias AshEnterprise.Canonical.{
    CalendarEvent,
    Conversation,
    ConversationParticipant,
    Derive,
    EventAttendee,
    Message,
    Person,
    PersonSeal
  }

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{BlindIndex, Changes.ErasePerson, PersonErasure, Scope, Shredded}
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Mdm.{AttributeAssertion, StagedRecord}
  alias AshEnterprise.Platform.{AutomationPrincipal, SystemActor}
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.ActorContext

  setup do
    operator = tenant!(operator?: true)
    unique = System.unique_integer([:positive])

    %{
      operator: operator,
      unique: unique,
      address: "Erase.Fixture-#{unique}@erase-person.synthetic.test",
      name: "Erasable Fixture #{unique}"
    }
  end

  describe "refused" do
    test "refused for an actor holding no grant, for a tenant Administrator, and for every system actor and engine",
         ctx do
      person = person!(ctx.operator, ctx.address, ctx.name)
      before = snapshot(ctx, person)

      nobody = member!(ctx.operator, "Nothing", [])
      assert {:error, %Ash.Error.Forbidden{}} = erase(ctx, ctx.address, nobody.actor)

      # The tenant's own Administrator holds every grant the auto-grant gives, and
      # person erasures are not among them.
      other = tenant!()
      other_person = person!(other, ctx.address, ctx.name)

      assert {:error, %Ash.Error.Forbidden{}} =
               Erasure.erase_person(ctx.address, ctx.address, "test",
                 actor: other.actor,
                 tenant: other.tenant
               )

      for actor <- SystemActor.all() do
        assert {:error, %Ash.Error.Forbidden{}} = erase(ctx, ctx.address, actor),
               "#{actor.name} erased a person"
      end

      # An engine-marked call is judged by its actor: the engines have no bypass here.
      for flag <- [:ash_bpmn?, :ash_decisions?] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 PersonErasure
                 |> Ash.Changeset.for_create(
                   :erase,
                   %{email: ctx.address, confirm: ctx.address, reason: "test"},
                   actor: SystemActor.system(),
                   tenant: ctx.operator.tenant,
                   context: %{private: %{flag => true}}
                 )
                 |> Ash.create()
      end

      # An automation principal carrying the operator's own grants is still not a person.
      for principal <- AutomationPrincipal.all() do
        context = %{ActorContext.for_actor(ctx.operator.actor) | automation: principal.name}

        acting = %{
          principal
          | id: ctx.operator.user.id,
            __ash_enterprise_context__: context
        }

        assert {:error, %Ash.Error.Forbidden{}} = erase(ctx, ctx.address, acting)
      end

      # The operator's authority applies only in the tenant it was built for.
      assert {:error, %Ash.Error.Forbidden{}} =
               Erasure.erase_person(ctx.address, ctx.address, "test",
                 actor: ctx.operator.actor,
                 tenant: other.tenant
               )

      assert snapshot(ctx, person) == before
      assert Ash.reload!(other_person, tenant: other.tenant, authorize?: false).name == ctx.name
      assert receipts(ctx.operator.tenant) == []
    end

    test "confirm must match, and the request is refused otherwise", ctx do
      person = person!(ctx.operator, ctx.address, ctx.name)
      before = snapshot(ctx, person)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Erasure.erase_person(
                 ctx.address,
                 "someone-else-#{ctx.unique}@erase-person.synthetic.test",
                 "test",
                 actor: ctx.operator.actor,
                 tenant: ctx.operator.tenant
               )

      assert Exception.message(error) =~ "confirm"
      refute Exception.message(error) =~ ctx.address

      assert {:error, %Ash.Error.Invalid{}} =
               Erasure.erase_person("   ", "   ", "test",
                 actor: ctx.operator.actor,
                 tenant: ctx.operator.tenant
               )

      assert snapshot(ctx, person) == before
      assert receipts(ctx.operator.tenant) == []

      # Case and surrounding space aside, the confirmation matches.
      assert {:ok, %PersonErasure{}} =
               Erasure.erase_person(ctx.address, "  " <> String.upcase(ctx.address), "test",
                 actor: ctx.operator.actor,
                 tenant: ctx.operator.tenant
               )
    end
  end

  describe "missing and unknown" do
    test "an address no person carries erases nothing and the receipt says so", ctx do
      person = person!(ctx.operator, ctx.address, ctx.name)
      before = snapshot(ctx, person)
      unknown = "nobody-#{ctx.unique}@erase-person.synthetic.test"

      assert {:ok, receipt} = erase(ctx, unknown, ctx.operator.actor)

      assert receipt.shredded_scope_ids == []
      assert receipt.counts |> Map.values() |> Enum.all?(&(&1 == 0))
      assert receipt.residuals == ErasePerson.residuals()
      assert snapshot(ctx, person) == before
    end
  end

  describe "tenancy" do
    test "the same address in another tenant is untouched", ctx do
      other = tenant!(operator?: true)
      mine = person!(ctx.operator, ctx.address, ctx.name)
      theirs = person!(other, ctx.address, ctx.name)
      staged!(other, ctx.address, ctx.name)

      assert {:ok, _receipt} = erase(ctx, ctx.address, ctx.operator.actor)

      assert %Shredded{} = reload(ctx.operator, mine).email
      theirs = reload(other, theirs)
      assert to_string(theirs.email) == ctx.address
      assert theirs.name == ctx.name
      assert scope!(theirs).status == :active

      assert Person.by_address!(ctx.address, tenant: other.tenant, authorize?: false).id ==
               theirs.id

      assert [_, _] = assertions(other.tenant, [theirs.id])
      assert [_] = StagedRecord |> Ash.read!(tenant: other.tenant, authorize?: false)
    end
  end

  describe "after erase" do
    # No fixture name or address is readable in canonical_people,
    # mdm_attribute_assertions or mdm_staged_records, and no audit event spells
    # either; mix ash_enterprise.audit.verify still passes; message and event rows
    # and their foreign keys survive.
    test "nothing spells the person, the audit chain verifies, and their correspondence survives",
         ctx do
      other_address = "other-#{ctx.unique}@erase-person.synthetic.test"
      other_name = "Absorbed Fixture #{ctx.unique}"

      survivor = person!(ctx.operator, ctx.address, ctx.name)
      loser = person!(ctx.operator, other_address, other_name)
      merge!(ctx.operator, loser, survivor)
      staged!(ctx.operator, ctx.address, ctx.name)

      %{conversation: conversation, message: message, event: event} =
        correspondence!(ctx.operator, survivor)

      assert {:ok, receipt} = erase(ctx, ctx.address, ctx.operator.actor)

      # Both records of the person: the golden and the one merged into it.
      survivor = reload(ctx.operator, survivor)
      loser = reload(ctx.operator, loser)

      for person <- [survivor, loser] do
        assert person.name == nil
        assert scope!(person).status == :shredded
        assert %{email_bidx: nil, legacy_email: nil} = stored(person)
        assert person.merge_provenance == nil
      end

      assert %Shredded{} = survivor.email

      assert Enum.sort(receipt.shredded_scope_ids) ==
               Enum.sort([scope!(survivor).id, scope!(loser).id])

      assert Person.by_address!(ctx.address, tenant: ctx.operator.tenant, authorize?: false) ==
               nil

      assert assertions(ctx.operator.tenant, [survivor.id, loser.id]) == []

      spelled = [ctx.address, other_address, ctx.name, other_name]

      for table <- ["canonical_people", "mdm_attribute_assertions", "mdm_staged_records"] do
        refute_table_spells(table, spelled)
      end

      # The audit log: nothing but the staging events spells the person, and those are
      # the disclosed residual (StagedRecord.mapped is audited in plaintext).
      refute_audit_spells(spelled, except: StagedRecord)
      assert audit_spells?(ctx.address, StagedRecord, :stage)
      refute audit_spells?(ctx.address, StagedRecord, :erase)

      assert Verify.report(ctx.operator.tenant).status == :ok

      # The correspondence stays, pointing at the blanked person; the derived joins go.
      assert Ash.get!(Message, message.id, tenant: ctx.operator.tenant, authorize?: false).sender_id ==
               survivor.id

      assert Ash.get!(Conversation, conversation.id,
               tenant: ctx.operator.tenant,
               authorize?: false
             )

      assert Ash.get!(CalendarEvent, event.id, tenant: ctx.operator.tenant, authorize?: false).organizer_id ==
               survivor.id

      assert joins(EventAttendee, ctx.operator.tenant, survivor.id) == []
      assert joins(ConversationParticipant, ctx.operator.tenant, survivor.id) == []

      assert receipt.counts["people"] == 2
      assert receipt.counts["merged_records"] == 1
      assert receipt.counts["staged_records"] == 1
      assert receipt.counts["attendances"] == 1
      assert receipt.counts["participations"] == 1
    end

    test "an address merged away erases the absorbed record and refolds its survivor without it",
         ctx do
      survivor_address = "survivor-#{ctx.unique}@erase-person.synthetic.test"
      survivor = person!(ctx.operator, survivor_address, nil)
      loser = person!(ctx.operator, ctx.address, ctx.name)
      merge!(ctx.operator, loser, survivor)

      # The survivor took the loser's name in the fold.
      assert reload(ctx.operator, survivor).name == ctx.name

      assert {:ok, receipt} = erase(ctx, ctx.address, ctx.operator.actor)

      loser = reload(ctx.operator, loser)
      survivor = reload(ctx.operator, survivor)

      assert scope!(loser).status == :shredded
      assert PersonSeal.prior_email(loser.merge_provenance) == nil
      assert receipt.counts["survivors_refolded"] == 1

      # The survivor keeps its own address and scope, and loses what came from the loser.
      assert to_string(survivor.email) == survivor_address
      assert scope!(survivor).status == :active
      assert survivor.name == nil
      refute_table_spells("canonical_people", [ctx.address, ctx.name])
      refute_table_spells("mdm_attribute_assertions", [ctx.address, ctx.name])
    end

    test "a person written before the seal is found by the old column and blanked", ctx do
      legacy = person!(ctx.operator, nil, ctx.name)

      Repo.query!("UPDATE canonical_people SET email = $2 WHERE id = $1::uuid", [
        Ecto.UUID.dump!(legacy.id),
        ctx.address
      ])

      assert {:ok, receipt} = erase(ctx, ctx.address, ctx.operator.actor)

      assert receipt.counts["people"] == 1
      assert reload(ctx.operator, legacy).name == nil
      refute_table_spells("canonical_people", [ctx.address, ctx.name])
    end

    test "a sign-in account with the address has its own scopes shredded, and its row is a stated residual",
         ctx do
      member = member!(ctx.operator, "Member", [])
      {:ok, thread} = Thread.start("A question", actor: member.actor, tenant: member.tenant)

      {:ok, requester} =
        Erasure.ensure_scope(:data_subject, SealingScope.scope_ref(member.user.id), %{},
          actor: SystemActor.system()
        )

      assert {:ok, receipt} = erase(ctx, member.email, ctx.operator.actor)

      assert receipt.counts["account_scopes"] == 2
      assert Erasure.get_scope!(requester.id, authorize?: false).status == :shredded
      assert Erasure.get_scope!(thread.erasure_scope_id, authorize?: false).status == :shredded
      assert List.last(receipt.residuals) =~ "account"

      assert {:ok, %{email: email}} =
               AshEnterprise.Accounts.get_user(member.user.id, authorize?: false)

      assert to_string(email) == member.email
    end
  end

  describe "the receipt" do
    test "the receipt exists, is audited, and holds no address, blind index or key material",
         ctx do
      person = person!(ctx.operator, ctx.address, ctx.name)
      scope = scope!(person)
      %{rows: [[wrapped]]} = Repo.query!(key_sql(), [Ecto.UUID.dump!(scope.id)])
      bidx = BlindIndex.of(ctx.operator.tenant, ctx.address)

      assert {:ok, receipt} = erase(ctx, ctx.address, ctx.operator.actor, "erasure request 7")

      assert [%PersonErasure{id: id}] = receipts(ctx.operator.tenant)
      assert id == receipt.id
      assert receipt.reason == "erasure request 7"
      assert receipt.completed_at
      assert receipt.shredded_scope_ids == [scope.id]
      assert receipt.created_by_id == ctx.operator.user.id
      assert receipt.residuals == ErasePerson.residuals()

      # The key is gone.
      assert %{rows: []} = Repo.query!(key_sql(), [Ecto.UUID.dump!(scope.id)])

      %{rows: [[row]]} =
        Repo.query!(
          "SELECT row_to_json(r)::text FROM erasure_person_erasures r WHERE id = $1::uuid",
          [Ecto.UUID.dump!(receipt.id)]
        )

      %{rows: events} =
        Repo.query!(
          "SELECT row_to_json(e)::text FROM audit_events e WHERE record_id = $1::uuid",
          [Ecto.UUID.dump!(receipt.id)]
        )

      assert [[event]] = events
      assert event =~ "AshEnterprise.Erasure.PersonErasure"

      for text <- [row, event], secret <- secrets(ctx, bidx, wrapped) do
        refute String.contains?(String.downcase(text), String.downcase(secret)),
               "the receipt or its audit event spells #{inspect(secret)}"
      end
    end
  end

  describe "atomic" do
    test "a failure part-way rolls everything back: no scope shredded, no row deleted", ctx do
      other_address = "other-#{ctx.unique}@erase-person.synthetic.test"
      survivor = person!(ctx.operator, ctx.address, ctx.name)
      loser = person!(ctx.operator, other_address, "Absorbed #{ctx.unique}")
      merge!(ctx.operator, loser, survivor)
      staged!(ctx.operator, ctx.address, ctx.name)
      correspondence!(ctx.operator, survivor)

      # The receipt is the last write: refuse it at the database, so the failure comes
      # after the deletes, the blanking and every shred have run. The constraint is
      # rolled back with the test's own transaction.
      Repo.query!(
        "ALTER TABLE erasure_person_erasures ADD CONSTRAINT refuse_for_test CHECK (false) NOT VALID"
      )

      before = %{
        survivor: snapshot(ctx, survivor),
        loser: snapshot(ctx, loser),
        staged: StagedRecord |> Ash.read!(tenant: ctx.operator.tenant, authorize?: false),
        attendances: joins(EventAttendee, ctx.operator.tenant, survivor.id),
        participations: joins(ConversationParticipant, ctx.operator.tenant, survivor.id)
      }

      assert {:error, _error} =
               (try do
                  erase(ctx, ctx.address, ctx.operator.actor)
                rescue
                  error -> {:error, error}
                end)

      assert snapshot(ctx, survivor) == before.survivor
      assert snapshot(ctx, loser) == before.loser
      assert scope!(survivor).status == :active
      assert scope!(loser).status == :active

      assert StagedRecord |> Ash.read!(tenant: ctx.operator.tenant, authorize?: false) ==
               before.staged

      assert joins(EventAttendee, ctx.operator.tenant, survivor.id) == before.attendances

      assert joins(ConversationParticipant, ctx.operator.tenant, survivor.id) ==
               before.participations

      assert receipts(ctx.operator.tenant) == []
    end
  end

  describe "afterwards" do
    test "a later projection of the same address creates a new person under a new scope; the erased row is not resurrected",
         ctx do
      erased = person!(ctx.operator, ctx.address, ctx.name)
      assert {:ok, _receipt} = erase(ctx, ctx.address, ctx.operator.actor)

      again = person!(ctx.operator, ctx.address, "Returned #{ctx.unique}")

      assert again.id != erased.id
      assert scope!(again).id != scope!(erased).id
      assert scope!(again).status == :active
      assert to_string(again.email) == ctx.address

      erased = reload(ctx.operator, erased)
      assert erased.name == nil
      assert %Shredded{} = erased.email
      assert %{email_bidx: nil} = stored(erased)

      assert Person.by_address!(ctx.address, tenant: ctx.operator.tenant, authorize?: false).id ==
               again.id
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp erase(ctx, email, actor, reason \\ "erase person test") do
    Erasure.erase_person(email, email, reason, actor: actor, tenant: ctx.operator.tenant)
  end

  defp owner(user) do
    %{
      owner_id: user.id,
      owner_type: :user,
      owning_user_id: user.id,
      owning_business_unit_id: user.owning_business_unit_id
    }
  end

  # A projected person, with the attribute statements a projector writes.
  defp person!(%{user: user, tenant: tenant}, email, name) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(user), %{
        email: email,
        name: name,
        statement_source: "erase_person_test",
        statement_observed_at: DateTime.utc_now()
      }),
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(upsert?: true, upsert_identity: :unique_email_bidx, upsert_fields: [:name])
  end

  defp merge!(%{tenant: tenant}, loser, survivor) do
    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp staged!(%{tenant: tenant}, email, name) do
    StagedRecord
    |> Ash.Changeset.for_create(
      :stage,
      %{
        batch_id: Ash.UUID.generate(),
        source_record_id: Ash.UUID.generate(),
        mapped: %{"email" => email, "name" => name},
        status: :staged
      },
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  # A conversation, a message the person sent, and an event they organize and attend,
  # under a connection scope as a projector writes them.
  defp correspondence!(%{user: user, tenant: tenant}, person) do
    {:ok, connection} =
      Erasure.ensure_scope(
        :connection,
        "test:erase-person-#{System.unique_integer([:positive])}",
        %{},
        actor: SystemActor.oban()
      )

    conversation =
      Conversation
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner(user), %{
          subject: "Quarterly review",
          participants: %{},
          external_system: "gmail",
          external_id: "conv-#{System.unique_integer([:positive])}",
          erasure_scope_id: connection.id
        }),
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!()

    message =
      Message
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner(user), %{
          body: "See you there",
          sent_at: DateTime.utc_now(),
          direction: :inbound,
          external_system: "gmail",
          external_id: "msg-#{System.unique_integer([:positive])}",
          conversation_id: conversation.id,
          sender_id: person.id,
          erasure_scope_id: connection.id
        }),
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!()

    starts_at = DateTime.add(DateTime.utc_now(), 60, :minute)

    event =
      CalendarEvent
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner(user), %{
          title: "Planning",
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 30, :minute),
          status: :confirmed,
          external_system: "test",
          external_id: "evt-#{System.unique_integer([:positive])}",
          organizer_id: person.id,
          erasure_scope_id: connection.id
        }),
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!()

    :ok = Derive.participants(conversation, [person.id], tenant)
    :ok = Derive.attendees(event, [%{person_id: person.id, response_status: :accepted}], tenant)

    %{conversation: conversation, message: message, event: event}
  end

  defp reload(%{tenant: tenant}, person),
    do: Ash.reload!(person, tenant: tenant, authorize?: false)

  defp scope!(person) do
    {:ok, %Scope{} = scope} =
      Erasure.scope_by_ref(:data_subject, PersonSeal.scope_ref(person.id), authorize?: false)

    scope
  end

  defp stored(person) do
    %{rows: [[bidx, legacy]]} =
      Repo.query!("SELECT email_bidx, email FROM canonical_people WHERE id = $1::uuid", [
        Ecto.UUID.dump!(person.id)
      ])

    %{email_bidx: bidx, legacy_email: legacy}
  end

  # The person's row and statements, and their scope's state.
  defp snapshot(ctx, person) do
    %{rows: [[row]]} =
      Repo.query!("SELECT row_to_json(p)::text FROM canonical_people p WHERE id = $1::uuid", [
        Ecto.UUID.dump!(person.id)
      ])

    %{
      row: row,
      scope: scope!(person).status,
      assertions: assertions(ctx.operator.tenant, [person.id]) |> Enum.map(& &1.id) |> Enum.sort()
    }
  end

  defp assertions(tenant, golden_ids) do
    AttributeAssertion
    |> Ash.Query.filter(golden_id in ^golden_ids)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp joins(resource, tenant, person_id) do
    resource
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp receipts(tenant), do: PersonErasure |> Ash.read!(tenant: tenant, authorize?: false)

  defp key_sql, do: "SELECT wrapped_key FROM erasure_keys WHERE scope_id = $1::uuid"

  defp secrets(ctx, bidx, wrapped) do
    [
      ctx.address,
      BlindIndex.normalize(ctx.address),
      Base.encode16(bidx, case: :lower),
      Base.encode64(bidx),
      Base.encode16(wrapped, case: :lower),
      Base.encode64(wrapped)
    ]
  end

  defp refute_table_spells(table, strings) do
    %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t")
    text = rows |> List.flatten() |> Enum.join("\n") |> String.downcase()

    for string <- strings do
      refute String.contains?(text, String.downcase(string)), "#{table} spells #{inspect(string)}"
    end
  end

  defp refute_audit_spells(strings, except: resource) do
    %{rows: rows} =
      Repo.query!("SELECT row_to_json(e)::text FROM audit_events e WHERE e.resource <> $1", [
        to_string(resource)
      ])

    assert rows != []
    text = rows |> List.flatten() |> Enum.join("\n") |> String.downcase()

    for string <- strings do
      refute String.contains?(text, String.downcase(string)),
             "audit_events spells #{inspect(string)}"
    end
  end

  defp audit_spells?(string, resource, action) do
    %{rows: rows} =
      Repo.query!(
        "SELECT row_to_json(e)::text FROM audit_events e WHERE e.resource = $1 AND e.action = $2",
        [to_string(resource), to_string(action)]
      )

    rows
    |> List.flatten()
    |> Enum.any?(&String.contains?(String.downcase(&1), String.downcase(string)))
  end
end
