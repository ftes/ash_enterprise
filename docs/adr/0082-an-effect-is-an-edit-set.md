# ADR 0082 — An effect is an edit set: pure previews, a declared write footprint, and the edits in the review packet

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0002](0002-ash-events-over-paper-trail.md) (one central audit log),
  [ADR 0055](0055-consequential-acts-are-governed-invocations.md) (governed invocation, the target digest),
  [ADR 0057](0057-actions-declare-their-effects.md) (the effects declaration),
  [ADR 0058](0058-agent-quality-and-releases.md) (effect-free evaluation, and why it is not a rolled-back transaction),
  [ADR 0059](0059-version-number-is-an-optimistic-lock.md) (`version_number` as an optimistic lock),
  [ADR 0062](0062-planning-proposes-declarations-and-people-commit.md) (planning proposes, people commit),
  [ADR 0073](0073-secured-columns-are-grants.md) (secured columns),
  [ADR 0079](0079-a-proposal-is-fenced-checked-and-remembered.md) (a proposal is fenced, checked and remembered),
  [manifesto 03](../manifesto/03-authorization-is-data.md) (authorization is a union of grants)

## Context

A person who approves an act is shown what was asked for, not what it would write. The review packet
(`AshEnterprise.Execution.ReviewPacket`) shows the target, its effects declaration, the arguments, the approval digest,
whether the approval is still current, the evidence and the decisions. An approval binds the arguments
([ADR 0055](0055-consequential-acts-are-governed-invocations.md)), and the reviewer is left to work out from them which
rows change and how.

Two pieces are missing, and each is useful without the other.

**Nothing says what an action may write.** The effects declaration
([ADR 0057](0057-actions-declare-their-effects.md), `AshAgent.Effects.Effect`) says whether an action is read-only,
destructive, idempotent or open-world, and who approves it. It has no field for the resources it writes. An action's
own resource is obvious; the rest is not. A change module, a hook or a generic action's implementation can call any
other action, and an inline signal listener writes inside the emitter's transaction. A reviewer, a model map or an
impact check cannot find those writes without reading the code.

**Nothing computes the writes before they happen, except in two places.** Verified on 2026-11-19:

- **Planning** turns a candidate's sealed solver result into task assignments (`Planning.Lowering.assignments/2`),
  and `Candidate.apply` writes exactly those through `Canonical.Task`'s `:schedule` and `:unschedule` actions, after
  rechecking each source row's `version_number` (`Planning.Changes.ApplyCandidate`). The assignments are computed
  without writing anything. They are not shown as edits.
- **Master data** computes what a merge would resolve to, "written to nothing" (`Mdm.Refold.preview_merge/4`), and the
  merge itself uses it (`Mdm.Changes.MergeInto`).

`Intervention.simulate` (`Execution.Actions.SimulateRerun`) answers whether a rerun is allowed and what it would wait
for. It does not compute writes.

The other way to see what an action writes is to run it in a transaction and roll the transaction back. This
repository has already declined that once: an evaluation run "does not use a rolled-back transaction, because
`before_transaction` hooks and notifiers fire anyway" ([ADR 0058](0058-agent-quality-and-releases.md)). Other things
escape a rollback too:

- `before_transaction` and `after_transaction` hooks run outside the transaction, and an outbound call made in one
  stays made.
- PostgreSQL never reclaims a `nextval` when its transaction aborts.
- Work handed to another process (a job, a signal delivered other than inline, a message) is not undone with it.
- The action runs with the authority to write. Run as the reviewer, a reviewer who may not make the write sees a
  refusal instead of a preview. Run as anyone else, the preview shows the reviewer what that other actor's grants
  can see.

## Decision

**An effect is described as an edit set. An action declares the resources it may write. A target that can compute
its edits without running declares a pure preview, and the review packet shows the result. Nothing is previewed by
running the action and rolling it back. The write footprint is checked by tests, CI and telemetry, and never refused
at runtime.**

1. **An edit set is a list of record edits.** Each edit says:

   | Key | Meaning |
   |---|---|
   | `resource` | the Ash resource written |
   | `record_id` | the primary key; `nil` for a create whose key is assigned when it runs |
   | `action_type` | `create`, `update` or `destroy` |
   | `action` | the action that makes the write |
   | `changes` | per attribute, `old` and `new`; on a create `old` is absent, and on a destroy `changes` is empty |

   These are the fields the audit log records for every write (`resource`, `record_id`, `action`, `action_type`,
   `changed_attributes`; [ADR 0002](0002-ash-events-over-paper-trail.md)), plus the old value. That is what lets
   decision 4's test compare a preview with what the apply recorded. A link is not a separate kind of edit. A link
   that is a foreign key is an update of that attribute, and one through a join resource is a create or a destroy of
   the join row. A surface names it as a link from the relationship declaration.

   An edit set is a description and is never applied. Applying runs the action, which re-authorizes and rechecks
   its preconditions. That is why the shape is not a JSON Patch (RFC 6902): a patch is an instruction to apply, and
   its `test` operation would turn a reviewer's view of an old value into a write condition.

   It is plain data, encodable as JSON, so a package can produce one without depending on another.

2. **A pure preview never runs the action.** A target may declare a preview: a function of the action's input and
   records it reads as the viewer. It writes nothing, opens no transaction, calls nothing outside the application,
   and runs none of the action's changes, hooks or notifiers. Given the same input and the same records, it returns
   the same edit set.

   A target without a declared preview has no preview. "No preview" is never shown as "no changes": an empty edit
   set means that a preview ran and computed no edits.

3. **No rolled-back preview.** The escape channels in the Context rule it out, for the same reason as in
   [ADR 0058](0058-agent-quality-and-releases.md). A general preview by rollback would need its own ADR. That ADR would
   have to inventory every escape channel per target and run the preview with `authorize?: true` as the viewer. It is
   not planned.

4. **A preview is tested against its apply.** Each target with a preview has a property test. On the same records,
   the edit set the preview returns must equal the writes the apply makes, compared through what the apply recorded
   in the audit log. A preview must also stay inside the action's footprint (decision 5).

   Where it can, the action writes what its preview computed, from the same pure function, so the two cannot drift.
   Planning already works this way: the assignments `Candidate.apply` writes are the ones lifted from the sealed
   result.

5. **An action declares its write footprint.** The effects declaration gains `edits`, a list of resources and the
   action types the action may run on them. Planning's apply, if it were declared, would read:

   ```elixir
   effects do
     action :apply, kind: :edit, approval: :none, intent: :execute,
       edits: [{AshEnterprise.Canonical.Task, [:update]}]
   end
   ```

   The parts that can be derived are added without being declared:
   - the action's own resource and type;
   - the destinations of its `manage_relationship` changes, with every type their options allow;
   - the resources and action types of inline signal listeners;
   - foreign keys whose `references` delete or nilify rows in the database.

   The declaration covers the rest: writes made by change modules, hooks and generic action implementations that
   call other actions. A footprint names resources and action types, not action names. It is what a reviewer reads
   ("updates Task"), and it survives renaming an action. Writes made in another process belong to whatever runs them.

6. **The footprint is checked by tests, CI and telemetry.**
   - **A verifier** refuses an `edits` entry that names something other than an Ash resource, or an action type the
     resource does not have. Like the other effects verifiers, it fails `mix compile --warnings-as-errors`.
   - **A test helper** runs a function and fails if any write made through an Ash action in that process falls
     outside the footprint. It reads Ash's own write telemetry (`create`, `update`, `destroy` and their bulk forms).
     The platform's own machinery (the audit log, the lineage store, the invocation row the executor writes) is a
     fixed list the host passes once, reviewed as code. A preview runs under the same helper with an empty
     footprint.
   - **CI** on `ci/**` runs the governed targets' tests under the helper. An undeclared write fails the branch.
   - **Telemetry.** While the invocation executor runs a target, a write outside its footprint emits a telemetry
     event naming the target, the resource and the action type. It never carries values. The write goes ahead.

7. **The footprint is never refused at runtime.** There are three reasons:
   - A footprint describes code. It is not a permission. Who may write what is the union of grants
     ([manifesto 03](../manifesto/03-authorization-is-data.md)). A runtime refusal would be a second, subtractive
     authorization model, which is what the rule against `forbid_if` keeps out.
   - The observation is incomplete (see Consequences). A refusal would promise a guarantee the check cannot keep, and
     it would fail closed exactly when a declaration is out of date, turning a stale line of DSL into an outage.
   - The fix for a wrong footprint is a one-line declaration. The place to catch it is before merge.

8. **The review packet carries the edit set for targets with a pure preview.** The packet gains an `edits` section
   between `arguments` and `digest`. It is computed when the packet is read, as the viewer, from the invocation's
   recorded arguments, and it is never stored. It says what the act would write if it ran now, and when that was
   computed. Its values follow the packet's existing rule that what cannot be established is unknown, never empty:
   - `{:ok, edit_set}`;
   - `:no_preview` for a target that declares none;
   - `{:unknown, reason}` for arguments that were erased or cannot be read, a record the preview could not read, or a
     preview that raised.

   An old or new value the viewer may not read is carried as hidden (`%Ash.ForbiddenField{}`, as
   [ADR 0073](0073-secured-columns-are-grants.md) reads a secured column). It is never shown as `nil`. The `target`
   section already shows the effects declaration, so the footprint appears there. The same edit set is what the
   planning, steward and proposal forms show for a pure-preview act that is not an invocation.

## Does it consume ActorContext?

The footprint does not. Like the rest of the effects declaration
([ADR 0057](0057-actions-declare-their-effects.md)), it is compile-time DSL that states what an action does, not who
may do it.

A preview reads as the viewer, through the same policies as any read built from the viewer's `ActorContext`, and adds
nothing to it. A reviewer who may not read a record the act would change sees that record's values as hidden, or
the section as unknown. They never see more than their grants allow.

No policy check gains a query, and nothing here is a `forbid_if`: the footprint never decides access, and a preview
is a read.

## Consequences

- A reviewer of a target with a pure preview sees the rows and values the act would write. For any other target,
  they see its footprint and "no preview", never an empty list.
- **A footprint can miss writes, and the check says which kinds it cannot see.**
  - Writes not made through an Ash action: a raw `Repo` call, a SQL statement, a database trigger. For example, a
    change on the business unit resource rewrites its subtree's paths with one SQL `UPDATE`
    (`Accounts.Changes.MaintainBusinessUnitPath`). Those rows are the action's own resource, so the footprint holds,
    but the helper never sees them.
  - AshCredo ships a `RepoCallInResource` check that flags a raw `Repo` call inside a resource. It is off by default,
    and this repository does not turn it on.
  - Database cascades are covered by derivation from `references`, not by observation.
- **The target digest changes when a target gains `edits` or a preview.** Its effects declaration is part of the
  target digest ([ADR 0055](0055-consequential-acts-are-governed-invocations.md)), so pending approvals for that
  target go stale once. The new keys are written into the digested map only when set, as `posture_floor` is. A
  target that declares neither keeps its digest.
- A preview is per-target work. Unless it shares its function with the apply, it is a second copy of the action's
  logic. The property test in decision 4 keeps the two in step and fails when they drift.
- A packet with an `edits` section costs one preview per read: reads as the viewer, no writes, no lock.
- An edit set computed when the packet is read can differ from what runs later. Preconditions on named subjects
  ([ADR 0059](0059-version-number-is-an-optimistic-lock.md)) refuse a run whose subject moved, and other rows can
  still change in between.

## Reversal

To drop the review packet's section, remove one section from `ReviewPacket`; nothing is stored. To drop the
footprint, remove `edits` from the declarations. The verifier, the helper and the telemetry handler then have nothing
to check, and target digests return to what they were before (pending approvals go stale once more). Previews are
ordinary functions and can stay as advice on the forms. Adopting a rolled-back preview is not a reversal of this
record; it needs the separate record that decision 3 describes.

## Not decided here

- Whether an approval binds a digest of the edit set the approver was shown, so that an apply that would write
  something else is stale.
- Footprints by action name rather than by action type.
- A general preview by rollback (decision 3).
- Revert and compensation; `compensate_with` stays reserved
  ([ADR 0057](0057-actions-declare-their-effects.md)).
- Turning on AshCredo's `RepoCallInResource` check here.
