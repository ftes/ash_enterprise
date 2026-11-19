# ADR 0080 — What-if is a scenario on the simulation twin, and every act carries its execution context

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0058](0058-agent-quality-and-releases.md) (effect-free evaluation runs, and why they do not use a
  rolled-back transaction), [ADR 0055](0055-consequential-acts-are-governed-invocations.md) (a consequential act is a
  governed invocation), [ADR 0043](0043-automation-authority-is-a-grant.md) (the automation principal and the
  intersection rule), [ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md) (snapshots pin what
  produced a record), [ADR 0077](0077-a-candidate-is-judged-against-recorded-history.md) (a candidate is judged
  against recorded history), [ADR 0078](0078-values-explain-themselves.md) (every explanation step carries its execution
  context), [ADR 0079](0079-a-proposal-is-fenced-checked-and-remembered.md) (a proposal records its world)

## Context

People ask "what if": what would the schedule look like with one more clinician, what would this plan do if demand
doubled, what would a new band table admit. Several parts of this repository and the packages it depends on already
answer a version of that question, each with its own word for "this is not the real thing". Nothing says how those
words relate, what a not-real run may touch, or how a what-if result is kept from being applied as if it were real.

Verified on 2026-11-19, at this repository's main and the package versions it locks:

- **Seven vocabularies say "not live", in five shapes.**
  1. `ash_planning` (`lib/ash_planning/fragment/run.ex:151-162`): a planning run has
     `world: :operational | :scenario` and a `scenario_ref` naming the scenario a `:scenario` run is about.
  2. `ash_agent` (`lib/ash_agent/run.ex:370`, `lib/ash_agent/invocation.ex:586`): an agent run and each of its tool
     calls have `mode: :live | :shadow | :eval`.
  3. `ash_discrete_business_events` (README, "The simulation twin"): a ledger is emitted with a `SimulationEvent` twin
     in its own table. Twin rows carry `simulated: true` and a required `simulation_run` label, and a simulation drain
     keys its checkpoints `sim:<name>.<region>:<run>`. There is no `world` attribute: the twin is the label.
  4. System One banding (`lib/ash_enterprise/system_one/banding/step.ex:59`; the `ash_judgments` banding fragment):
     `mode: :live | :shadow`, recorded on the banding row. Beneath it, the `ash_judgments` cache has
     `:live | :replay | :shadow`, where a `:shadow` observation "never materialise[s] into facts".
  5. Quality suite runs (`lib/ash_enterprise/quality/suite_run.ex:17,193`): `mode: :offline | :shadow | :adhoc`, each
     running its cases as agent runs in `:eval` or `:shadow`. (ADR 0058 also lists a `replay` mode, recorded there as
     not yet built.)
  6. `Intervention.simulate` (`lib/ash_enterprise/execution/actions/simulate_rerun.ex`): what a rerun would do now,
     checked as the person asking, creating nothing.
  7. `ash_paper` (`lib/ash_paper/snapshot.ex:23,40`): a render's snapshot has `world`, `:operational` by default. The
     field is `AshOpenLineage.Snapshot`'s, typed `:operational | :scenario`, and it is inside the snapshot's digest.
- **This application has `:eval` and `:shadow`, and no `:scenario`.** `AshEnterprise.Execution.Identity`
  (`lib/ash_enterprise/execution/identity.ex:70,174`) runs an `:eval` or `:shadow` agent run as the `evaluator`
  automation principal, whatever its version was published to run as.
- **Effects outside live are suppressed in one place.** A tool call of an `:eval` or `:shadow` agent run is never
  claimed unless its target is a read that stays inside the application; any other call is answered from the run's
  fixtures and marked `simulated` (`ash_agent`, `lib/ash_agent/invocation.ex`, "Invocations of a run that is not
  live"). Two other paths reach outside without an invocation: a BPMN service task calls the host's
  `AshBpmn.ActionInvoker` (`lib/ash_bpmn/action_invoker.ex`), which receives no execution context, and an
  `ash_operations` operation called directly (`lib/ash_operations/run.ex`) hands its request to the transport with no
  notion of one.
- **Banding does not consult its mode before materialising.** `Banding.Step` records `:mode` on the banding row and
  then routes every band to the materialiser. Nothing calls it with `:shadow` today, so no shadow fact exists, but
  nothing stops one.
- **A scenario plan can be applied as live.** A planning `Candidate` (`lib/ash_planning/fragment/candidate.ex`) has no
  `world`; `:propose` takes the run id, and `:apply` checks disposition, correctness and freshness, never the run's
  world.
- **Simulation runs share projection rows.** The twin keeps two runs' events and checkpoints apart, but a projector's
  grain function (`projections/drain.ex`, `apply_event/2`) maps both runs' events to the same grain row, so two
  replications overwrite each other.
- **Simulated candidates are not compared on common random numbers.** Two candidate plans simulated against the same
  scenario draw independent randomness, so a difference between them mixes the plans' effect with sampling noise.
  Common random numbers, with a dedicated stream per source of randomness, is the standard remedy (A. M. Law,
  *Simulation Modeling and Analysis*, the chapter on variance-reduction techniques).
- **Two mechanisms look like scenario engines and are not.**
  - A transaction rolled back at the end: ADR 0058 (lines 60-64) rejects it for effect-free runs "because
    `before_transaction` hooks and notifiers fire anyway". The same holds for a what-if.
  - AshEvents replay: it requires a `ClearRecordsForReplay` module that clears the resources' records before replaying
    into them (`ash_events` at the locked `bd5f497`, `usage-rules.md:46-58`). Replay rebuilds the live tables in place.
- **There is no shadow-projection mechanism to build on.** `ash_events_projections` documents versioned blue/green
  rebuilds (`lib/ash_events/projections/rebuilder.ex:32-41`) and its registry defines `bump_version`
  (`registry.ex:63-72`), but nothing calls it: a rebuild truncates and replays in place, the blue/green path is a
  docstring, and the tutorial on it is a scaffold. Its `TimeTravel` and `Operations.Verify` replay the log in memory,
  for one grain or for a diff against the live table.

## Decision

**A what-if is a run in the `:scenario` execution context over the simulation twin. Every act carries one of four
execution contexts, set by the machinery that started it and never by its input. Outside `:live` nothing reaches
outside the application and nothing is written to operational state, and a scenario's result is never applied: taking
it live is a new live act.**

1. **The vocabulary is closed: `:live | :scenario | :eval | :shadow`.** Each changes one thing about the act:

   | Context | Inputs | Definition | Runs as | Writes |
   |---|---|---|---|---|
   | `:live` | the real ones | the published one | its authority | operational state |
   | `:scenario` | a declared hypothetical over the real ones | the published one, or a candidate | the person asking | only rows labelled with the scenario |
   | `:shadow` | the real ones, beside live work | a candidate | the `evaluator` principal | only rows labelled shadow |
   | `:eval` | fixtures | a candidate | the `evaluator` principal, in the evaluation tenant | only the run's own records |

   A preview that runs nothing (`Intervention.simulate`, `AshDecisions.Trial`) is a read, not a context: it executes
   nothing and records nothing.

2. **Set by machinery, inherited, never raised.** A context is set where a run starts: from a planning run's `world`,
   an agent run's `mode`, a simulation run's label, a suite run's mode. Everything the run causes inherits it. No action
   accepts it as an input on a child, and no child is ever more live than its parent.

3. **Stamped on invocations and audit first; a policy-visible check later.** An invocation records it in the `mode`
   it already has. The platform stamps it into audit event metadata as `execution_context`, beside the correlation id.
   An audit event written before this, or by a path that has not adopted it, reads as "not recorded", never as
   `:live`. Exposing it to policies as a check is a later decision; a context never authorizes anything, it only
   refuses.

4. **The seven vocabularies map onto it, and keep their names.**

   | Vocabulary | Values | Context |
   |---|---|---|
   | planning run `world` | `:operational`, `:scenario` | `:live`, `:scenario` |
   | agent run and invocation `mode` | `:live`, `:shadow`, `:eval` | the same |
   | simulation twin | real ledger; twin row with `simulation_run` | `:live`; `:scenario` |
   | banding `mode` | `:live`, `:shadow` | the same |
   | suite run `mode` | `:offline`, `:shadow`, `:adhoc` | `:eval`, `:shadow`, `:eval` (an `:adhoc` run never satisfies a gate) |
   | `Intervention.simulate` | — | a read; no context |
   | document snapshot `world` | `:operational`, `:scenario` | `:live`, `:scenario` |

   `:operational` is not renamed to `:live`: `world` is part of `AshOpenLineage.Snapshot`'s digest, and renaming it
   would change the digest of every snapshot already stored. The `ash_judgments` cache modes say where an answer
   comes from (the model, the ledger, a candidate instrument), not where its effects go; they compose with a context
   rather than map onto it.

5. **Outside `:live`, nothing reaches outside and nothing feeds operational state.**
   - An agent tool call is answered from fixtures, as today.
   - A BPMN service task's `ActionInvoker` receives the context and, outside `:live`, refuses with a typed error or
     calls a stub the process declares for that action.
   - An `ash_operations` call made outside an invocation reads the context and, outside `:live`, refuses or answers
     from a declared fixture.
   - A `:shadow` banding records its band and materialises no fact.
   - A missing, unknown or unreadable context refuses: it is never assumed live. A host stamps `:live` explicitly at
     the points where live work starts. Because a library that refused an unstamped call would refuse every existing
     caller, the library changes ship with the host's stamping, as a contract change announced to its consumers first.

6. **A scenario result is never applied.** A planning candidate's `world` is copied from its run at `:propose` and is
   not an input. `:apply` refuses a `:scenario` candidate with `scenario_world`. No action changes a candidate's world.
   To act on what a scenario showed, a person starts an operational run, which may pin the scenario's choices, and its
   candidate is checked, approved and applied like any other.

7. **No rolled-back transaction and no in-place replay serve as a scenario engine**, for the two reasons in Context.
   A scenario writes only labelled rows, and a rebuilt projection is built beside the live one, never over it.

8. **Simulation projections key on the run.** A projector over the twin declares itself a simulation projection, and
   its grain includes the simulation run; a verifier refuses a simulation projection whose grain lacks it. Two runs
   produce two sets of rows.

9. **Candidates are compared on common random numbers.** Every random draw in a simulation is seeded by
   `(subject, random_stream_id, replication_id)`: the entity the draw is about, the named source of randomness, and the
   replication. The same draw comes out whichever candidate is simulated, and different replications draw
   differently. A draw without a `random_stream_id` is refused rather than defaulted. The seed derivation and the
   generator are recorded on the simulation run, so a run can be reproduced.

10. **The scenario ladder is the plan of record.** Each rung is usable on its own:

    | Rung | Status at 2026-11-19 | Next |
    |---|---|---|
    | R0 as-of read | Working, narrowly: the temporal resources (`CalendarEvent`, `SourceIdentity`, `SystemOne.Fact`) | — |
    | R1 simulation twin | Working: separate table, run label, namespaced checkpoints | — |
    | R2 isolated projection | Not built (see Context) | `ash_events_projections` builds a versioned projection from the log while the current one serves, verifies it against the live one, and promotes it atomically and reversibly |
    | R3 candidate compare | Working for decisions (`AshDecisions.Replay`); unsound for simulated plans | Decisions 6 and 9 |
    | R4 model-version snapshot | The release manifest exists, without kinds for mappings or planning models | Those kinds, in a later change |
    | R5 data branch | Not built | Later: a database clone, masked by `ash_greenmask` |

## Does it consume ActorContext?

Yes, without changing it. A `:scenario` run reads the real inputs as the person asking, through the usual grants, and
writes rows they may write; a person who cannot read a schedule cannot simulate it. `:eval` and `:shadow` runs keep
executing as the `evaluator` principal (ADR 0043's intersection rule), whose roles exist only in the evaluation
tenant. The execution context adds no grant and no check that queries: it is a value on the run, read where an effect
would happen, and it only ever refuses.

## Consequences

- A what-if result cannot become live by accident: the guard is on the apply action, and the only road to live is a
  new live run.
- "What would this have done" is a query: over an agent run's invocations, a scenario's labelled rows, or a shadow
  banding's bands.
- Every place that reaches outside has to know its context. Two library paths (BPMN service tasks, direct operation
  calls) and the banding step change, and a host stamps `:live` where live work starts. Until it does, those paths
  refuse; that is the cost of never assuming live.
- Simulation projections hold one row set per run, so twin tables grow with replications and need a retention rule
  when a host runs many.
- Common random numbers make simulated candidates comparable at the price of declaring a stream for every source of
  randomness.
- The first host to adopt the guard, per-run rows and common random numbers is the clinic demo application.
- Four words for "not live" remain in package APIs. The mapping, not a rename, is what makes them one vocabulary.

## Reversal

- **The vocabulary** is a value on runs and audit metadata. Dropping it removes the stamp and the refusals in the BPMN
  invoker, operations and banding; the per-package words still work, without a shared meaning.
- **The apply guard** is one validation on `:apply` and one copied attribute on `:propose`. Removing them lets a
  scenario candidate be applied again, which is the defect this fixes.
- **Common random numbers** is the seeding function. Reverting to independent draws keeps simulations working and makes
  candidate comparisons noisy again; runs record their seeding, so old runs stay reproducible.
- **R2 on a shadow projection** could instead replay the log in memory with `TimeTravel` and `Verify`, which is cheaper
  to build and costs O(events) per read. Switching is a change to the rung's engine; nothing else here depends on which
  one it is.
