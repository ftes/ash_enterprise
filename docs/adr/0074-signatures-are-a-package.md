# ADR 0074 — Signatures are a package (`ash_signatures`): a request over hashed document versions, signed in-platform, with providers behind one asynchronous seam

- **Status:** accepted (2026-11-16); package built 2026-11-17; second use instantiated here 2026-11-20 (`AshEnterprise.Signatures`: the five resources, the policy review's fan-out and reminders, controls projected from acknowledgements, version 2 asking everyone again)
- **Date:** 2026-11-16
- **Related:** [ADR 0020](0020-tamper-evident-audit-log.md) (tamper-evident audit),
  [0024](0024-audit-retention-and-erasure.md) (crypto-shredding),
  [0035](0035-compliance-is-projected-from-events.md) (compliance is projected from events),
  [0044](0044-documents-are-addressed-atoms-evidence-is-an-assertion.md) (documents are addressed atoms),
  [0055](0055-consequential-acts-are-governed-invocations.md) (governed invocations),
  [0056](0056-the-ash-agent-package.md) (a package the host instantiates),
  [0057](0057-actions-declare-their-effects.md) (effects),
  [0063](0063-declared-operations-are-a-package.md) (declared operations),
  [0070](0070-upstream-first-placement.md) (upstream-first placement)

## Context

Two uses need a person to sign or acknowledge a specific document and need a record that proves it:

- **A downstream host's contract execution.** A draft contract is signed by two parties in order, then executes. The
  host decided on 2026-11-16 to run the signing itself, as a simple electronic signature, with no third-party
  e-signature provider. A customer's own provider is an adapter built later, when one is asked for.
- **This repository's policy acknowledgement.** The `soc2` pack's yearly review
  (`priv/packs/soc2/policy_review_acknowledgement.bpmn`) records one administrator's "completed" on a task. It does
  not record which person acknowledged which version of which policy.

Both need the same mechanism: a request over exact document versions, people who act in order, a trail of what each
person saw and did, and one completion record. Under [ADR 0070](0070-upstream-first-placement.md) a second named use
moves the mechanism up a layer. The contract use is written down in the host's own decision record and tickets, and
the acknowledgement use is a ticket here. So it starts as a package rather than as host code
that is later copied.

What already exists:

- `AshEvidence.DocumentVersion` holds immutable bytes and their SHA-256, has no update action, and is unique on the
  hash per tenant ([ADR 0044](0044-documents-are-addressed-atoms-evidence-is-an-assertion.md)).
- Every write through `Platform.Resource` lands in the tenant's hash chain ([ADR 0020](0020-tamper-evident-audit-log.md)).
- `ash_agent` carries the governed-invocation fragment and the effects extension ([ADR 0055](0055-consequential-acts-are-governed-invocations.md),
  [0057](0057-actions-declare-their-effects.md)).
- `AshEnterprise.Erasure.Changes.SealUnderScope` seals named fields under an erasure scope ([ADR 0024](0024-audit-retention-and-erasure.md)).

No open standard covers a signing request, its signers and their routing. The shape below follows what hosted
e-signature APIs have in common: documents, recipients, a routing order and events. It is our own model, not a standard.

## Decision

**A public MIT package, `ash_signatures`, owns the signing mechanism. It ships resource fragments, a state machine, a
provider behaviour and two providers that make no network call. The host owns every decision.**

1. **Fragments, instantiated by the host** on its own base resource, as `ash_agent` and `ash_evidence` are
   ([ADR 0056](0056-the-ash-agent-package.md)). The package has no policies, no tenancy of its own and no HTTP.
   - **Request.** The subject (`subject_type`, `subject_id`), `purpose` (`:execute` or `:acknowledge`), routing
     (`:sequential`, the only routing either use needs), the provider key copied at send, the provider's reference,
     and `documents_digest`: one hash over the ordered document SHA-256s and the signers' roles and order.
   - **Request document.** The `DocumentVersion` the signers are shown, its position, and the signed result's version
     once there is one.
   - **Signer.** Role (a host key), order, status, and the signer's name, email, IP address and user agent.
   - **Signer event.** Append-only: `viewed`, `consented`, `signed`, `declined`, `changes_requested`, `reminded`,
     `withdrawn`. Each carries the time, the route (`:in_platform` or `:upload`) and, for a signature, the SHA-256 of
     the version that signer was shown. An uploaded signed copy is a `signed` event on the `:upload` route with no
     signer.
   - **Completion.** A canonical record of the request, its signers by reference, the hash of every event, the source
     and signed hashes, and the tenant chain's head at completion. `record_hash` covers it.
2. **States.** A request is `draft`, `sent`, `partially_signed`, `completed`, `returned` (a decline or a change
   request), `recalled`, `cancelled`, `expired` or `superseded` (a paper copy arrived). A signer is `pending`,
   `notified`, `viewed`, `signed`, `declined`, `changes_requested` or `withdrawn`. The host maps `completed` and
   `returned` to its own actions; the package never changes the subject itself.
3. **One provider behaviour, asynchronous:** `create`, `lookup`, `observe`, `fetch`, `void` and `remind`. Create returns
   a reference, state is observed, and an unknown outcome is reconciled by `lookup` before any retry
   ([ADR 0055](0055-consequential-acts-are-governed-invocations.md)). Two providers ship:
   - **In-platform.** The signer acts on a surface the host renders. `create` and `observe` are local writes.
   - **Upload.** A person downloads the document, it is signed on paper, and the signed copy is uploaded.

   `lookup` and `remind` have one real caller each today. The behaviour keeps them because a hosted provider needs
   exactly this shape, and a later adapter (an `ash_operations` declared operation, [ADR 0063](0063-declared-operations-are-a-package.md))
   should change no caller. That is the one place this record goes past ADR 0070's "no speculative options".
4. **The first signed copy completes the request.** Arrivals are deduplicated by SHA-256 on the subject. A later copy
   is recorded as an event and never completes the request a second time.
5. **What survives erasure.** Hashes, roles, order, event types, times and `record_hash` are kept. Signer name,
   email, IP address, user agent and reasons are payload fields that the host seals under an erasure scope. Whether
   a document version outlives an erasure request is the host's retention decision, not the package's.
6. **The host keeps the decisions:** who may send, the consent and authority wording, branding, locale, reminder
   timing, retention, and how a signer is identified. Send, remind, recall and cancel are host actions with an
   effects declaration, run as governed invocations. Signing is a person's act: no automation principal signs.
7. **Not in the package now.** These have one use or none, so they stay out until a second one is named:
   - the email-link signer principal (the contract host's door for signers without an account, which starts as that
     host's code under ADR 0070 section 4);
   - PDF stamping and the rendered certificate (the contract host has its own PDF writer; acknowledgement needs neither);
   - cryptographic seals (PAdES), timestamps (RFC 3161), remote signing keys (CSC);
   - hosted providers (DocuSign, Adobe and others), and publishing copies to a customer's document store.

### Gap map

Checked against the code on 2026-11-16 by reading it. The package's first pull request
([lukegalea/ash_signatures#1](https://github.com/lukegalea/ash_signatures/pull/1)) checks the package's rows in
`test/ash_signatures/gap_map_test.exs`: the source hash copied from the version, the link from draft to signed
version, the states, the fields marked for sealing, the append-only event log and the provider behaviour. The host
rows (the audit chain, governed invocations and sealing) were unverified until this repository instantiated the
fragments (ADR 0070 section 3). It did on 2026-11-20, and `test/ash_enterprise/signatures/` now calls each of
them: sealing and the erase test in `signatures_test.exs`, and a version 2 policy asking a person again, with
their version 1 acknowledgement kept, in `policy_reacknowledgement_test.exs`.

| Part | Expressible | Needs a host swap | Missing upstream | Evidence |
|---|---|---|---|---|
| Immutable document bytes and hash | yes | | | `AshEvidence.DocumentVersion` (`ingest`, `unique_content`) |
| Link from a draft version to its signed version | | | yes: the request document row holds both ids | `DocumentVersion` has no derivation link |
| Audit trail of each write | yes | | | `Platform.Resource` writes land in the chain (ADR 0020) |
| Governed send, recall, cancel and remind | yes | host declares effects | | `ash_agent` invocation fragment and `AshAgent.Effects` |
| States | yes | | | `ash_state_machine` |
| Sealing signer personal data | | yes: host change | | `AshEnterprise.Erasure.Changes.SealUnderScope` |
| Request, signer, event and completion fragments | | | yes: this package | none exists |
| Provider behaviour, in-platform and upload providers | | | yes: this package | none exists |
| Signing surface | | yes: host renders | | each host's own UI |

## Consequences

**Made easy.** The policy review can name each person, each policy version and when they acknowledged it, and the
`soc2` pack's controls can be projected from those events rather than from one administrator's "completed"
([ADR 0035](0035-compliance-is-projected-from-events.md)). The contract host gets the same trail without writing its
own request model. A hosted provider later is one adapter and a binding.

**Made hard.** A new public package to keep: its fragments, state machine, usage rules and test app. Two hosts move in
step on its releases.

**Not provided.** Signing for people without an account, seals, timestamps and hosted providers (item 7). A
signature here is a simple electronic signature: identity is the person's sign-in or, in the contract host, possession
of an email address.

## Reversal

The exposure is the fragments each host instantiates and the two providers. To drop the package, copy the fragments
into the hosts that use them and keep their tables. The records already written stay valid, because the completion
record and the events are plain rows in each host's audit chain. Revisit if an upstream Ash package for signing appears
that does what this does.
