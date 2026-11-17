defmodule AshEnterprise.Erasure.Changes.ErasePerson do
  @moduledoc """
  The work of `AshEnterprise.Erasure.PersonErasure`'s `erase`, in the action's own
  transaction, before the receipt is inserted: a failure anywhere adds an error and the
  whole transaction rolls back, shreds and deletes included.

  ## Locks, in the order every person path takes them

  The tenant's audit-log lock, then the address's own lock (the one the projectors'
  upsert takes, `AshEnterprise.Canonical.PersonSeal.lock_address!/2`), then the goldens
  in id order (`AshEnterprise.Mdm.Refold.lock!/2`). The address lock is taken before the
  people are found, so a projection of the same address waits for the erase and then,
  finding no index, creates a new person under a new scope: the erased row is never
  resurrected.

  ## Order

  Derived joins, attribute statements and staged rows are deleted; each person is blanked;
  survivors are refolded without the erased statements (`materialize_held: false`, as an
  unmerge does, so a value the survivor took from the erased record is not kept as a held
  statement); last, each live scope is shredded as the person asking, so the shred is
  authorized and attributed as theirs.

  Runs only after authorization: Ash checks the policies before any `before_action` hook.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Canonical.{ConversationParticipant, EventAttendee, Person, PersonSeal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.BlindIndex
  alias AshEnterprise.Erasure.PersonErasure.Subject
  alias AshEnterprise.Mdm.{AttributeAssertion, Refold}
  alias AshEnterprise.Repo.AdvisoryLock

  @residuals [
    "Backups, WAL and replicas taken before this erase keep the rows until they age out; " <>
      "they hold only wrapped keys for what was sealed.",
    "MDM raw landings (mdm_source_records) are not reached: the source rows stay as landed.",
    "Audit events written before addresses were sealed (merge provenance) and the audit " <>
      "events of MDM staging (StagedRecord.mapped) keep their plaintext: the audit log is " <>
      "immutable.",
    "Message and calendar event rows stay, with their foreign keys to the blanked person; " <>
      "their content is sealed under its connection's scope, not this person's.",
    "There is no request intake or deadline clock: this act records when it ran, not when " <>
      "it was asked for."
  ]

  @account_residual "A sign-in account with this address exists in the tenant: its row is " <>
                      "untouched. Offboard it separately."

  @doc "What every erase does not reach (the receipt also names an account when it found one)."
  def residuals, do: @residuals

  @impl true
  def change(changeset, _opts, context) do
    if changeset.valid? do
      Ash.Changeset.before_action(changeset, &erase(&1, context.actor))
    else
      changeset
    end
  end

  defp erase(changeset, actor) do
    tenant = to_string(changeset.to_tenant || changeset.tenant)
    email = Ash.Changeset.get_argument(changeset, :email)
    reason = Ash.Changeset.get_attribute(changeset, :reason)

    AdvisoryLock.xact_lock_audit_log!(Person, tenant)
    PersonSeal.lock_address!(tenant, BlindIndex.of(tenant, email))

    subject = Subject.find(tenant, email)
    ids = Enum.map(subject.people, & &1.id)
    Refold.lock!(tenant, ids ++ subject.survivor_ids)

    with :ok <- forget(EventAttendee, tenant, ids),
         :ok <- forget(ConversationParticipant, tenant, ids),
         :ok <- erase_assertions(tenant, subject.assertion_ids),
         :ok <- each(subject.staged_records, &erase_staged(&1, tenant)),
         :ok <- each(subject.people, &blank(&1, tenant)),
         :ok <- each(subject.survivor_ids, &refold(&1, tenant)),
         {:ok, shredded} <-
           shred(Subject.active(subject.scopes ++ subject.account_scopes), reason, actor) do
      changeset
      |> Ash.Changeset.force_change_attribute(:shredded_scope_ids, shredded)
      |> Ash.Changeset.force_change_attribute(:counts, Subject.counts(subject))
      |> Ash.Changeset.force_change_attribute(:residuals, residuals(subject))
      |> Ash.Changeset.force_change_attribute(:completed_at, DateTime.utc_now())
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp residuals(%Subject{account?: true}), do: @residuals ++ [@account_residual]
  defp residuals(_subject), do: @residuals

  # --- deletes -------------------------------------------------------------------

  defp forget(_resource, _tenant, []), do: :ok

  defp forget(resource, tenant, person_ids) do
    resource
    |> Ash.Query.filter(person_id in ^person_ids)
    |> bulk_destroy(:forget, tenant)
  end

  defp erase_assertions(_tenant, []), do: :ok

  defp erase_assertions(tenant, ids) do
    AttributeAssertion
    |> Ash.Query.filter(id in ^ids)
    |> bulk_destroy(:erase, tenant)
  end

  defp bulk_destroy(query, action, tenant) do
    case Ash.bulk_destroy(query, action, %{},
           tenant: tenant,
           authorize?: false,
           return_errors?: true,
           strategy: [:atomic, :stream]
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, failure(query.resource, errors)}
    end
  end

  defp erase_staged(staged, tenant) do
    Ash.destroy(staged, action: :erase, tenant: tenant, authorize?: false)
  end

  # --- people --------------------------------------------------------------------

  defp blank(person, tenant) do
    person
    |> Ash.Changeset.for_update(:erase, %{}, tenant: tenant, authorize?: false)
    |> Ash.update(tenant: tenant, authorize?: false)
  end

  defp refold(golden_id, tenant) do
    Refold.refold!(tenant, golden_id, materialize_held: false)
    :ok
  end

  # --- shreds --------------------------------------------------------------------

  defp shred(scopes, reason, actor) do
    scopes
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while({:ok, []}, fn scope, {:ok, done} ->
      case Erasure.shred_scope(scope, scope.ref, reason, actor: actor) do
        {:ok, shredded} -> {:cont, {:ok, [shredded.id | done]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:ok, _result} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp failure(resource, errors) do
    Ash.Error.Changes.InvalidChanges.exception(
      message:
        "could not delete #{inspect(resource)} rows for the erase " <>
          "(#{length(List.wrap(errors))} error(s))"
    )
  end
end
