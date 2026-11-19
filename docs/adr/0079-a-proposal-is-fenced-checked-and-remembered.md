# ADR 0079 — A proposal is fenced, checked and remembered

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0047](0047-learning-produces-proposals.md) (learning produces proposals),
  [ADR 0055](0055-consequential-acts-are-governed-invocations.md) (governed invocations; the approval binding, and the
  amendment of 2026-11-12, approval postures), [ADR 0057](0057-actions-declare-their-effects.md) (actions declare their
  effects), [ADR 0058](0058-agent-quality-and-releases.md) (release manifests),
  [ADR 0059](0059-version-number-is-an-optimistic-lock.md) (`human_only`, `machinery_only`, and `engine_only` from ADR
  0069), [ADR 0062](0062-planning-proposes-declarations-and-people-commit.md) (planning proposes; people commit),
  [ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md) (§4, keyed hashes),
  [ADR 0069](0069-a-recipe-runs-on-an-authority-chosen-per-version.md) (authority chosen per version; fail closed),
  [ADR 0070](0070-upstream-first-placement.md) (upstream-first placement),
  [ADR 0080](0080-what-if-is-a-scenario-on-the-simulation-twin.md) (what-if is a scenario; a scenario candidate is never
  applied), [ADR 0082](0082-an-effect-is-an-edit-set.md) (the edit set a proposal form shows)

## Context

A proposal is a row that machinery or a model writes and a person decides. ADR 0047 made that the rule for every
learner, and the platform now has several kinds of proposal, each built on its own. Verified at origin/main
(c1a6a08c) on 2026-11-19:

- **Four state machines.** `SystemOne.FilterProposal` (`proposed`, `refused`, `approved`, `rejected`, `superseded`),
  `SystemOne.QuestionProposal` (`proposed`, `refused`, `confirmed`, `rejected`), `Mdm.MatchCandidate` (`pending`,
  `auto_merged`, `confirmed`, `rejected`, `superseded`, from `AshMdm.Resources`) and `Planning.Candidate`. Only the
  last keeps its axes apart: `AshPlanning.Fragment.Candidate` has `check_status`, `freshness` and `disposition` as
  separate columns, with guards on which move is allowed from which state. The other three put a check outcome
  (`refused`), a machine's act (`auto_merged`, `superseded`) and a person's decision (`approved`, `rejected`) in one
  `status` column.
- **Two fences, built separately.** `Planning.Changes.ApplyCandidate` re-reads every snapshot source's
  `version_number` inside the apply transaction and refuses on drift. A filter run re-checks `queryables_hash`
  (`system_one/filter/runner.ex`). Invocations have a third, the approval binding: `AshAgent.Invocation.Approval`
  (`lib/ash_agent/invocation/approval.ex:187-246`, ash_agent c3bd989, the version this repository locks) recomputes
  an RFC 9396 `authorization_details` digest at decision time and at every claim, and finds the row `stale` with
  `approval_expired`, `target_changed`, `subject_changed`, `manifest_changed` (the active release's digest is not the
  one approved), `approval_changed` or `approved_by_requester`.
- **The snapshot envelope exists.** `AshOpenLineage.Snapshot` carries purpose, `effective_at`, `knowledge_cutoff`,
  `world` (`:operational | :scenario`), the authority it was computed under, inputs as `(resource, id,
  version_number)` plus a content hash, pinned definitions by content hash, and an RFC 8785 digest. It has no
  recheck of its own; each consumer writes one.
- **Approval postures decide who approves.** Since the ADR 0055 amendment of 2026-11-12, `Execution.Authority`
  implements `AshAgent.Approval.Authority` (the tenant's posture, the holders of a role, the administrator role,
  platform operators), and `AshAgent.Invocation.Approval.rule/2` turns a posture and those facts into the candidate
  pool, whether the requester is excluded, and the basis an approval rests on. `Execution.Approval` asks it when a
  task opens, when a decision is applied and at every claim.
- **Who may write each transition is declared, but unevenly.** `Planning.Candidate` declares `machinery_only`
  (`propose`, `record_check`, `mark_stale`, `supersede`) and `human_only` (`approve`, `reject`, `apply`). The other
  three gate their person acts with a `PersonActor` policy, and their machine writes go through the system-actor
  bypass. `auto_merged` is written by the platform system actor (`Mdm.AutoMerge`), which is not `oban`, so it does not
  reach a `machinery_only` action today. No proposal transition is `engine_only`.
- **Nothing remembers a rejection.** A rejected plan, filter or question set can be proposed again by the next run.
  `Canonical.CommitmentScan` makes the action-item sweep read each source once, which is a per-source rule, not a
  per-proposal one. `Mdm.MatchCandidate`'s `one_pair` identity keeps one row per staged row and golden, keyed by the
  staged row's id.
- **A refused apply reads as a person's rejection.** `ApplyCandidate` settles a refused apply as `stale` and then
  `rejected`, as the approving person.

## Decision

**Every kind of proposal carries one shape: a check, a freshness and a disposition, kept apart. Deciding one goes
through the approval machinery the host already has, never a check of its own. Applying one re-validates authority,
sources, definitions and the release in the apply transaction, and refuses with a typed reason. A person's rejection
is remembered by a key, so the same proposal is not put to anyone again unless a person reconsiders it.**

1. **One fragment, in its own package.** The shape is a Spark fragment of `Ash.Resource` in a separate package
   (working name `ash_proposal`), not in a provenance or lineage package and not in the host (ADR 0070). It declares
   attributes, actions, validations and guards only. The host supplies tenancy, ownership, sealing, policies, and the
   `human_only` / `machinery_only` / `engine_only` declaration of every transition. `AshPlanning.Fragment.Candidate` is
   its template and becomes its first consumer. The recheck lives beside the envelope it reads: `recheck/2` in
   `AshOpenLineage.Snapshot`, comparing hashes only (decision 6).

2. **Three axes, kept apart.**

   | Column | Values | Written by |
   |---|---|---|
   | `check` | `unchecked`, `passed`, `failed`, `errored`, `incomplete` | the kind's check (machinery) |
   | `check_code` | the kind's own outcome, as a string (`incorrect`, `checker_failed`, `undecodable`, `review`, …) | with `check` |
   | `freshness` | `current`, `stale` | `mark_stale`, the apply recheck |
   | `stale_reason` | decision 6's vocabulary | with `freshness` |
   | `disposition` | `proposed`, `approved`, `rejected`, `applied`, `superseded`, `suppressed` | decision 4 |
   | `decision_basis` | `person`, `automatic`, or nil while undecided | with `disposition` |
   | `source_key` | a keyed digest (decision 7) | `propose` |
   | `world` | `operational`, `scenario`, from the snapshot | `propose` |
   | `manifest_digest` | the digest of the release active for the proposal's purpose at propose, or nil where the host declares none | `propose` |

   `errored` means no verdict could be produced, and is never `failed` or `passed`. `freshness` means something only
   while the disposition is `proposed` or `approved`, as in the planning fragment: a decided row has nothing left to go
   stale. A kind with no apply step (a filter runs as a separate act; a confirmed question is declared in source by a
   person) ends at `approved`. Whether a `scenario` proposal may be approved or applied is the what-if contract's ([ADR 0080](0080-what-if-is-a-scenario-on-the-simulation-twin.md)), not
   this record's; this record only carries `world`.

3. **Who decides is routed, never re-implemented.** Deciding is an ordinary action on the proposal with an effects
   declaration (ADR 0057). Its approval mode comes from that declaration: `:none` (a person decides on their own
   authority, which is every kind today), `:confirm`, or `:four_eyes` with an `approver_role`. A decision that needs
   approval, or that an agent makes, is a governed invocation (ADR 0055), and who may approve it is
   `AshAgent.Invocation.Approval.rule/2` under the tenant's posture, with the facts `Execution.Authority` answers. The
   fragment holds no approver logic: no candidate list, no requester exclusion, no posture read, no role lookup. A
   host that wants four eyes on adopting a kind declares `:four_eyes` on its approve action; it never writes a second
   check. An agent reaches `approve` or `apply` only through an invocation a person approves, as `Planning.Candidate`
   already requires. The approval basis is the invocation's (`confirm`, `four_eyes`, `small_team`,
   `implementation`); the proposal links the invocation and does not copy it.

4. **Each transition has one kind of writer, declared.**

   | Transition | Moves | Writer |
   |---|---|---|
   | `propose` | creates `proposed`, or `suppressed` (decision 7) | as today per kind (machinery, a person, or a system actor) |
   | `record_check` | `check`, `check_code` | machinery |
   | `mark_stale` | `freshness` to `stale` with a reason | machinery, or the apply recheck's settlement |
   | `approve` | `proposed` → `approved`; needs `check: passed`, `freshness: current` | `human_only` |
   | `reject` | `proposed` or `approved` → `rejected`; writes the rejection key | `human_only` |
   | `apply` | `approved` → `applied`; needs `passed`, `current`, and decision 6 | `human_only`, or an approved invocation |
   | `apply_automatically` | `proposed` → `applied`, basis `automatic` | `machinery_only` or `engine_only` |
   | `supersede` | `proposed` or `approved` → `superseded` | machinery, or a person's edit (decision 5) |
   | `reconsider` | `rejected` → `proposed`; lifts the rejection key | `human_only` (D5) |

   A person's decision (`approve`, `reject`, `reconsider`, a person's `apply`) is never reachable by an engine or the
   system actor. A disposition reached without a person (basis `automatic`) is reachable by nothing else: the grant
   union does not apply to it. The fragment's verifier refuses a transition the host leaves undeclared, and a person's
   transition declared `machinery_only` or `engine_only`. A refused apply is not a rejection: its settlement marks the
   row `stale` with the reason and leaves it `approved`, so it can no longer be applied and suppresses nothing. Only a
   person's `reject` writes a rejection key. This replaces `ApplyCandidate`'s settlement to `rejected`.

5. **A reviewer's edit is a new proposal that passes the same check (D4).** Nothing a reviewer changes is written into
   a proposal in place without the check the original passed. For a plan, the reviewer's edits are pins (assignments
   they fix) and the plan is re-solved with them, so the checker and the independent validator verify what will be
   applied. The result is a new candidate that supersedes the old. A filter edit is already a new version re-run
   through the decode contract (`FilterProposal.edit/3`), and a question confirmed with edited wording is re-validated
   and re-hashed (`QuestionProposal.confirm`). Under four eyes, the person who edited is the requester of the new
   version, so the posture decides whether they may approve it.

6. **Applying re-validates; nothing carries over from propose or approve.** Inside the apply action's transaction,
   before any operational write, the apply re-checks, in this order, and refuses with the first reason that holds:

   | `stale_reason` | Holds when |
   |---|---|
   | `approval_expired`, `target_changed`, `subject_changed`, `manifest_changed`, `approval_changed`, `approved_by_requester` | the decision went through an invocation and `AshAgent.Invocation.Approval.stale_reason/2` returns it |
   | `authority_revoked` | the grant the decision rests on no longer holds: the approving person no longer holds the grant on `approve` (or the approver role the approval named); or the authority the snapshot records is a delegated one (an automation principal's grant, a standing grant) that is revoked, expired or whose publisher is no longer active (ADR 0069, decision 5) |
   | `snapshot_unverifiable` | the snapshot payload is shredded, unreadable, or its digest does not verify |
   | `manifest_changed` | the release active now for the proposal's purpose is not the one `manifest_digest` recorded at propose (the same reason an invocation gives, for the same fact) |
   | `definition_changed` | a pinned definition (model, checker, validator, queryables, declared question) has another content hash |
   | `source_unavailable` | a source is gone, or the applying person cannot read it |
   | `source_changed` | a source's `version_number` moved |

   Authority is judged on the request's `ActorContext` at apply time, and on the approver's current grants, never on
   anything recorded at propose. `Execution.Authority`'s history reads (everyone who ever held a role) keep four eyes
   closed when a holder is removed. They never count as a current grant. A source the applying person cannot read is
   refused exactly as one that is gone, so a refusal does not tell them it exists (as `Execution.StartProcess` does).
   `recheck/2` takes the snapshot and a function that reads each source's current `version_number` as the applying
   person and each definition's current hash; it compares hashes and returns every drifted input, and the apply
   reports the first reason above. Any refusal rolls back every write. After the transaction, `mark_stale` records the
   reason. These checks are validations and changes of the apply action; no policy check queries.

7. **A rejection is remembered (D5).** `source_key` names a proposal independently of its row: for a plan, the binding
   selector and the digest of its assignments; for a match, the golden and the staged row's source identity (not the
   staged row's id, so a restage of the same source row is the same pair); for a filter, the search text's digest and
   the document's digest; for a question set, the policy text's digest and the proposals' digest. It is keyed under
   the subject's erasure scope when its inputs are sealed or guessable (ADR 0067, §4). A `propose` whose key matches a
   `rejected` row in the same tenant is written `suppressed`, pointing at that rejection: listed, never dropped, never
   shown as awaiting a decision. `reconsider` is `human_only`: it returns the rejected row to `proposed`, which must
   then pass `approve`'s guards again, and later proposals with that key are proposed normally. Shredding the scope
   leaves the key unverifiable, so a rejection does not outlive the data it was about.

8. **Adoption is expand, backfill, contract, and no row maps to unknown.**
   - **Expand.** The fragment's columns are added beside each kind's `status`, nullable. Every action that writes
     `status` writes the axes too, so rows written during the window are mapped. Readers keep reading `status`.
   - **Backfill.** One Ash action per kind, modelled on `Canonical.PersonSeal.Backfill`: a dry run that counts rows
     per (old status → new tuple) and writes nothing, then one transaction per row through an update action;
     idempotent, so a rerun skips mapped rows. Every old value maps to exactly one tuple (the table below). A value the
     table does not name stops the backfill with its count, never writes a default. Freshness for `proposed` and
     `approved` rows is computed by the recheck, never defaulted. Rejection keys are written only where the row is
     unambiguously a person's rejection. It is tested on a restored copy of a production backup in a scratch database.
   - **Switch.** Readers move to the axes (the review queue's `status == :pending` becomes `disposition == :proposed`
     with the review band), one deploy cycle runs on both.
   - **Contract.** `status` is dropped as an acknowledged step in `priv/repo/migration-contract-steps.json`, and the
     axes become `NOT NULL`. The truth table is unchanged: the same person acts are person-only, the same four-eyes
     targets are four-eyes, and the same machinery writes what it writes today. Narrowing a writer (decision 4) is a
     separate, named change, never a side effect of adoption.

   | Kind | Old value | `check` (`check_code`) | `freshness` | `disposition` | `decision_basis` | Writer today | After adoption |
   |---|---|---|---|---|---|---|---|
   | Filter proposal | `proposed` | `passed` | computed | `proposed` | nil | a person, or a system actor (`propose` only) | unchanged |
   | Filter proposal | `refused` | `failed` (`undecodable`) | `current` | `proposed` | nil | as `proposed` | unchanged |
   | Filter proposal | `approved` | `passed` | computed (`definition_changed` if the queryables moved) | `approved` | `person` | `PersonActor` | `human_only` |
   | Filter proposal | `rejected` | `passed` | `current` | `rejected` | `person` | `PersonActor` | `human_only` |
   | Filter proposal | `superseded` | `passed` | `current` | `superseded` | nil | a person's edit | unchanged |
   | Question proposal | `proposed` | `passed` | computed | `proposed` | nil | a person, or a system actor | unchanged |
   | Question proposal | `refused` | `failed` (`undecodable`) | `current` | `proposed` | nil | as `proposed` | unchanged |
   | Question proposal | `confirmed` | `passed` | `current` | `approved` | `person` | `PersonActor` | `human_only` |
   | Question proposal | `rejected` | `passed` | `current` | `rejected` | `person` | `PersonActor` | `human_only` |
   | Match candidate | `pending`, no band | `unchecked` | computed | `proposed` | nil | the platform system actor | unchanged |
   | Match candidate | `pending`, band `review` | `passed` (`review`) | computed | `proposed` | nil | the platform system actor | unchanged |
   | Match candidate | `pending`, band `admit` or `omit` | `passed` (`admit`) or `failed` (`omit`) | computed | `proposed` | nil | the platform system actor | unchanged |
   | Match candidate | `auto_merged` | `passed` (`admit`) | `current` | `applied` | `automatic` | the platform system actor (`Mdm.AutoMerge`), through the system-actor bypass | unchanged; `machinery_only` once it runs as `oban` |
   | Match candidate | `confirmed` | `passed` (`review`) | `current` | `applied` | `person` | `PersonActor` | `human_only` |
   | Match candidate | `rejected` | `passed` (`review`) | `current` | `rejected` | `person` | `PersonActor` | `human_only` |
   | Match candidate | `superseded` | as banded | `current` | `superseded` | nil | the platform system actor | unchanged |
   | Plan candidate | `check_status` `correct` / `incorrect` | `passed` / `failed` (`incorrect`) | unchanged | unchanged | `person` when approved, rejected or applied | `machinery_only` | unchanged |
   | Plan candidate | `checker_failed` / `validator_failed` | `errored` (same code) | unchanged | unchanged | as above | `machinery_only` | unchanged |
   | Plan candidate | `unchecked` / `incomplete` | `unchecked` / `incomplete` | unchanged | unchanged | as above | `machinery_only` | unchanged |
   | Plan candidate | `rejected` and `stale` | unchanged | `stale` (`source_changed`) | `rejected` | `person` | `human_only` | unchanged; writes no rejection key |

   A plan candidate that is `rejected` and `stale` may be a person's rejection or the old settlement of a refused
   apply, and the row cannot say which. It keeps both values and writes no rejection key: a plan proposed again is a
   smaller harm than a proposal hidden by a rejection nobody made. `engine_only` appears in no row because no proposal
   transition is written by an engine today; the column exists so that a kind adopted later states it.

## Does it consume ActorContext?

Yes, through ordinary actions. `approve`, `reject`, `reconsider` and a person's `apply` are `human_only`, so only the
calling person's own grants authorize them. Machinery writes `propose`, `record_check`, `mark_stale`, `supersede` and
`apply_automatically` under the declarations above, and the grant union does not reach a `machinery_only` or
`engine_only` one. Who may approve a decision that needs approval is the posture's rule over `Execution.Authority`'s
facts, read with the tenant and no actor, as today. The apply recheck reads sources as the applying person and judges
authority on the request's `ActorContext`; the reads it makes are in validations and changes of the apply action,
never in a policy check.

## Consequences

- One inbox can list every kind with the same three labels, and the posture label the approval rule returns, without
  reading four state machines.
- A refused apply says why, in one vocabulary shared with invocations, and it no longer reads as a person's rejection.
- A person who rejected a proposal is not asked again by the next run. A suppressed re-proposal stays visible.
- A rejection key is a digest of what was proposed. It is keyed under the erasure scope where its inputs are sealed or
  guessable, so it leaks nothing a shred removes, and suppression ends with the data.
- An agent gains no new way to decide: it reaches a decision only through an invocation, under the posture.
- Adoption migrates live rows in four tables. The read-only Proposals tab ships first, the backfill is
  tested on a restored backup, and each kind keeps its old column for one deploy cycle.
- MatchCandidate's statuses live in `ash_mdm`, so that kind's adoption is a package change and a pin bump before the
  host's backfill.
- Forecloses: a kind with its own approver or freshness logic; a reviewer's edit written in place without its check.

## Reversal

Before the contract step, reversal is dropping the new columns and the dual writes; `status` is still authoritative.
After it, the mapping is one-to-one per kind (the basis tells `auto_merged` from `confirmed`), so a reverse backfill
restores `status`. It loses what the old shape cannot hold: `suppressed` rows (reversed as `rejected`, with their
pointer lost), `stale_reason`, and rejection keys. Restoring `ApplyCandidate`'s old settlement is one change. The
fragment package can then be removed from the lock; no other package depends on it until a kind adopts it.
