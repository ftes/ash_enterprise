# ADR 0083 — An ontology façade is a resource over resources

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0002](0002-ash-events-over-paper-trail.md) (one central audit log),
  [ADR 0012](0012-openlineage-and-marquez.md) (OpenLineage as the schema),
  [ADR 0031](0031-the-legacy-estate-is-projected-not-cut-over.md) (a resource over a shared relation opts out
  explicitly), [ADR 0049](0049-temporal-resources-are-the-validity-substrate.md) (temporal resources and `as_of`),
  [ADR 0052](0052-self-service-actions.md) (self-service actions, computed resources),
  [ADR 0059](0059-version-number-is-an-optimistic-lock.md) (`version_number`),
  [ADR 0070](0070-upstream-first-placement.md) (upstream-first placement),
  [ADR 0073](0073-secured-columns-are-grants.md) (secured columns),
  [ADR 0081](0081-the-ontology-view-is-derived.md) (the ontology view is derived: the backing facet, the hop chain and
  the dataset naming rule), [ADR 0078](0078-values-explain-themselves.md) (values explain themselves: the address,
  steps and typed gaps), [ADR 0084](0084-eligibility-is-a-conjunct-in-every-grant.md) (a façade inherits its source's
  labels)

## Context

A canonical resource is named for the platform: its attributes, statuses and actions use the platform's words. A
consumer often needs the same rows under another vocabulary: a business's own names for a work item and its states,
or a standard's names for a record, where the standard's shape differs from the canonical one. The consumer wants to
read, filter, sort and sometimes write those rows in its own words, without a second copy of the data and without a
second set of rules about who may see or change it.

The obvious ways to do that each break something this platform depends on:

- **A second AshPostgres resource over the same table** (`postgres do table ... end` with renamed `source:`
  attributes) brings its own policies, not the source's. Field policies and secured-column grants (ADR 0073) are
  declared on the source and do not apply to it, so a column the source withholds reads in clear. Its writes go
  straight to the table, past the source's actions, validations and audit.
- **A database view with INSTEAD OF triggers** (what `ash_strangler` generates over a legacy relation) has the same
  two faults, and more: values the source computes in the BEAM (a sealed value, a calculation) cannot be projected
  into a view, a temporal source's `as_of` has no path through it, and a dependent view blocks column changes to the
  table under it.
- **Each consumer translating in its own code** gives every consumer a different vocabulary for the same model and
  nothing that checks the translation can be written back.

What already exists, verified on 2026-11-19 at this repository's main and the `ash_strangler` version it locks:

- **A computed resource has a precedent.** `AshEnterprise.Execution.Entry` is a platform resource with
  `data_layer: Ash.DataLayer.Simple`: no table, no stored rows, its answers computed from reads made as the caller,
  with explicit opt-outs on the base resource (`ownership: :none`, `tenant?: false`, `lifecycle?: false`,
  `archival?: false`, `audit?: false`). `Platform.Verifiers.SelfServiceActions` already treats a read on a computed
  resource as authorized by construction for that reason (ADR 0052).
- **Opting out is explicit and commented.** `Legacy.User`, a resource over a relation it does not write, opts out of
  audit, the state machine and the optimistic lock, each with a comment saying why (ADR 0031).
- **A mapping grammar with proven reverses exists.** `AshStrangler.Lens` is one structure per mapped attribute,
  built from a closed grammar: tier 1 total (rename, decode, negate, affine and others), tier 2 partial with one more
  declared datum, tier 3 opaque and read-only with a `because:` reason. Each lens carries its forward expression, its
  writes, how invertible it is (`:yes`, `:semi`, `:no`) and its OpenLineage classification (identity,
  transformation, masked, structural). `AshStrangler.MappingVersion` hashes a resource's whole mapping.
- **The lens is bound to legacy twins today.** It renders SQL against a twin relation for views and triggers. A
  spike built lenses over an ordinary Ash resource with the existing constructor and no library change, and used
  them to read, filter, sort and write through a computed resource over the canonical Task. That is the shape this
  record decides.

## Decision

**An ontology façade is an Ash resource with no storage of its own that gives a vocabulary to the rows of a source
resource. It reads by calling the source's read action as the viewer, writes by calling one of the source's named
actions as the viewer, and declares no rule of its own about who may see or change anything. Every fact keeps one
record, on the source.**

1. **One row source, one lens per attribute.**
   - A façade names one **row source**: a resource whose read action supplies its rows, one façade row per source
     row, keyed by the source's primary key through a key lens.
   - Each façade attribute is a lens over a source attribute, or over a calculation, aggregate or relationship the
     source itself declares and loads as the viewer. A value from another resource reaches the façade only through
     the row source's own relationships, calculations and aggregates, so its policies are applied where it is read.
   - The lenses use the strangler's grammar unchanged. A façade adds no combinator.
   - **Estate:** every attribute of the row source is either exposed by a lens, hidden with a `because:` reason, or
     listed as deferred. A source attribute added later fails the check until it is placed.
   - A façade may be the row source of another façade. The chain is read hop by hop, each hop as the viewer; a
     cycle is refused at compile time.

2. **The façade profile on the base resource.** A façade is a platform resource (`AshEnterprise.Platform.Resource`)
   with `data_layer: Ash.DataLayer.Simple` and these opt-outs, each with a comment in the façade saying why:

   | Option | Why the façade opts out |
   |---|---|
   | `ownership: :none` | The source's ownership decides who reaches a row. A façade owner column would be a second answer. |
   | `tenant?: false` | The tenant is carried to the source read (decision 3). A façade `organization_id` would be a column the façade does not store. |
   | `lifecycle?: false` | The lifecycle is the source's. With it off, the state machine is not added either, so `state_machine?` is not set. |
   | `archival?: false` | Nothing is stored, so nothing is archived. Archiving a row is the source's action. |
   | `audit?: false` | The source's action writes the audit event. A façade event would be a second record of one fact. |
   | `lineage?: false` | The source's action emits the run. A façade has no dataset (decision 7). |
   | `optimistic_lock?: false` | The source's update actions carry the lock (ADR 0059). |

   - **No system column the source does not supply.** The base adds provenance columns and `version_number` to
     every resource. On a façade they would read as empty, or as `1`, beside the source's real values. A façade
     either maps them from the source like any other attribute, or does not have them. The base's `facade?: true`
     option sets the profile above and does not add them.
   - **One fact, one audit row, on the source.** A write through a façade leaves exactly one audit event, under the
     source resource and the source action, and none under the façade.

3. **Reads are the source's read, made as the viewer.**
   - The façade's read is a manual read that calls the source's read action with the caller's actor, tenant,
     `authorize?` and `as_of`. The source's policies, field policies and ADR 0073 grants decide which rows and which
     values come back. A façade adds no filter of its own that could widen what the source returns.
   - **The query's filter travels whole.** Ash calls a manual read even when the façade's own policy filter is
     `false`. The manual read applies the whole of `query.filter`, the policy filter included, to the source query.
     A façade read that dropped it would return rows the caller was refused.
   - **A tenant is required.** Over a tenant-scoped source, a read with no tenant is refused, for a person and for a
     system actor alike. A tenant-scoped platform resource is `global?` multitenant, so a source read with no tenant
     would span every tenant.
   - **`as_of` passes through or is refused.** Over a temporal source (ADR 0049) the instant is forwarded to the
     source read. Over a non-temporal source a read with `as_of` is refused. It is never dropped.
   - **Filters push down.** Each reference to a façade attribute is replaced by its lens's forward expression,
     evaluated against the source, so the source's data layer runs the filter. Where the lens is bijective and the
     comparison is `==`, `!=` or `in` against literals, the literal is mapped through the reverse instead, so the
     source compares its own column with no expression around it. A filter through a relationship path or an
     `exists` on a façade is refused.
   - **Sorts push down** the same way: a rename sorts on the source column, any other lens on its forward
     expression. A sort the source refuses (one that reads a secured column, ADR 0073 decision 6) is refused.
   - **Values are computed in the BEAM, over what the source delivered.** The forward lens of a read value is
     evaluated in the BEAM over the values the source read returned. A source value that came back as
     `%Ash.ForbiddenField{}` gives a `%Ash.ForbiddenField{}` façade value, named for the façade attribute. The
     façade never asks the source to compute a lens as a calculation for a read: ADR 0073 records that Ash applies no
     field policy to a column an expression reads, so evaluating over delivered values is what keeps a withheld
     value withheld.
   - **Values the source computes stay the source's.** A sealed value, or any value the source computes in the
     BEAM, reaches a façade only through the source's own calculation, loaded on the source read as the viewer.
     Such a lens is read-only with a `because:` reason.

4. **Every lens is checked without a twin.** The strangler's obligations run against the source resource's own
   declarations: totality of a decode from the source attribute's `one_of` and `allow_nil?`, the round-trip laws by
   grammar, and coverage of required inputs by the write routes (decision 5). The BEAM evaluation of a lens and its
   SQL rendering must agree; property tests hold them together for tier 1 and tier 2.

5. **Writes are a named source action, run as the viewer.**
   - A façade's writes are **generic actions**. Each evaluates the put direction of the lenses it touches (tier 1
     and tier 2) in the BEAM, and turns the result into input for one **named action** of the row source, run with
     the caller's actor, tenant and `as_of`. The source's action, its validations, its guards and its policies
     decide; the façade adds no update branch to the base resource and no permission of its own.
   - **Routes are declared, then checked.** A façade declares which source action carries each writable value: by
     value (a decoded state that one action sets, such as finished through `:complete`) or by acceptance (an
     attribute an action accepts). The verifier checks each route against the action: a by-value route's action
     sets that attribute to that value, an accept route's action accepts it. Routes are never inferred from the
     action at run time.
   - **The row is read first, as the viewer.** A write to a row the caller cannot read is not found, and nothing is
     written.
   - **Refused, with the reason.** A write is refused, before any source action runs, when:
     - the lens is read-only or not invertible (its `because:` text is the message);
     - no route reaches the value (for example a status no source action sets), naming the attribute and value;
     - no source action writes the attribute at all;
     - the change needs two or more source actions. One write is one source action; a caller who wants two makes
       two writes.
   - **The source's own refusals stand.** A source validation or guard that refuses ("only an open task can be
     marked done") is returned as the source raised it, naming the source's field. The façade does not reword it.

6. **A verifier holds the façade to having no rules of its own.** At compile time, a façade is refused if it
   declares:
   - a grant path of its own (`extra_grants`), a field policy, or a secured field (`secured_fields`);
   - an attribute whose `sensitive?` differs from its source attribute's. Sensitivity is inherited, never set;
   - a write route its source action does not carry, or a write that does not name a source action.

   No check here is a `forbid_if`. The façade reaches only what the source's union of grants reaches; it has no
   grants to add to the union and none to subtract.

7. **Lineage names each hop under one rule.**
   - **Datasets follow [ADR 0081](0081-the-ontology-view-is-derived.md).** A Postgres-backed resource's OpenLineage dataset is the relation that stores it:
     namespace `postgres://{host}:{port}` of its primary repo, name `{database}.{schema}.{table}`, with schema
     `public` when none is declared. The domain segment is the job namespace only.
   - **A façade has no dataset.** It stores no relation, so under that rule it names none. It is a hop in the
     overlay's hop chain, backing kind `facade` ([ADR 0081](0081-the-ontology-view-is-derived.md), decision 3), and the hop names its row source by resource.
     Where the row source has a dataset, the hop names that dataset too, so a lineage consumer joins the façade's
     edges to the source's node. The chain continues into the source's own backing facet, so a façade over a
     strangled resource walks down to the legacy relation.
   - **Column edges use the strangler's vocabulary.** Each façade attribute's edge comes from its lens: identity,
     transformation with its subtype, or masked, the OpenLineage `columnLineage` classification the strangler
     already emits. A consumer reads one vocabulary across every hop.
   - **Runs are the source's.** A façade write emits no run of its own: the source action emits it, under the source
     resource's job and dataset. A façade read emits nothing, as no read does.
   - **A mapping version per hop.** A façade's mapping version is a SHA-256 over its canonical lens declarations,
     computed the way `AshStrangler.MappingVersion` computes a strangled resource's. The hop chain carries one
     version per hop, in order, so a consumer can see which hop's meaning changed.

8. **The explain hop.** A façade value has an [ADR 0078](0078-values-explain-themselves.md) address under the façade's own type token. Its explainer
   is the first package explainer to answer for a façade:
   - It reads the source row as the viewer, through the façade's own read, and gives one step: the façade value
     `was_derived_from` the source value's address (or, for a lens over several source attributes, from each of
     them). The step's `plan` is the façade's mapping, identified by its mapping version.
   - It then continues with the source's own explainer, from the source value's address, with the same viewer and
     within the same depth and step bounds. A façade over a façade is two such hops.
   - **Gaps are [ADR 0078](0078-values-explain-themselves.md)'s five, and this record adds none:**

     | Case | Answer |
     |---|---|
     | The source row, or the source value, is one the viewer may not read | `:unreadable`, with no identifier |
     | The source read or the source's explainer errors | `:failed` |
     | The source value was erased | the source explainer's `:erased`, passed through |
     | A lens with no source attribute (a constant or a key) | no gap: one step, `was_generated_by` the façade's mapping |
     | A read-only or non-invertible lens | no gap: the forward direction is known, so the value explains through it; the step's summary carries the lens's `because:` text |
     | A refused write | not an explanation: a refused write leaves no value to explain |

9. **Home: upstream, in `ash_strangler`** (ADR 0070 §4, step 2; the name matches stop condition 3). The lens over
   a resource source, the twin-free obligations, the BEAM evaluator, filter and sort translation, the manual read,
   the write actions, the route verifier, the estate check, the mapping version and the explainer are general and
   carry no product noun, so they belong to the package. This application keeps two things:
   - the `facade?: true` profile on `Platform.Resource` (decision 2), which is host wiring;
   - which façades exist and what their vocabularies are, which is a domain decision (ADR 0070 §2, item 5).

   The package's documentation and usage rules use neutral examples. Two applications build façades on it, which is
   the second use ADR 0070's rule of two asks for.

### Why this is not a second DSL

ADR 0070 §2 item 4 says never to hide a declaration behind a second DSL. A façade states one thing nothing else
states: that a consumer's word for a field is this lens over that source attribute, and that this consumer's write
is that source action. The lens grammar is the strangler's, unchanged, and the façade adds no rule about who may see
or change anything. Everything a façade could be tempted to restate (the source's attributes, its sensitivity, its
actions, its grants) is read from the source, and the verifier refuses a façade that restates it.

### Alternatives considered

- **A second AshPostgres resource over the source table.** Rejected: it brings its own policies, leaves secured and
  sensitive columns unguarded, and writes past the source's actions and audit.
- **A strangler view over an owned table.** Rejected for vocabulary: INSTEAD OF triggers write past the source's
  actions and audit, field policies and grants do not cross a view, BEAM-computed and temporal values do not
  project, and a dependent view blocks column changes to the source. The strangler stays the tool for legacy
  relations the platform does not own.
- **The forward lens computed as a source calculation for reads.** Rejected: an expression calculation over a column
  is not subject to that column's field policy (ADR 0073), so it could return a value the source withholds. The
  calculation form is used only to push filters and sorts down, where the source's own rewrite and refusals apply.
- **A façade with grants of its own.** Rejected: two grant sets for one row drift, and the façade's would be the one
  people stop updating. The union of grants stays at the source.
- **A host-local façade before the package.** Rejected by ADR 0070: it would need an exception row and a second
  implementation to retire. The spike's host code was thrown away.
- **Sequencing two source actions in one façade write.** Rejected for now: one write is one source action, so each
  write leaves one audit event and passes one action's guards.

## Does it consume ActorContext?

Not directly. A façade's read and write are calls to the source made as the caller, and the source's policy checks
read the precomputed context as they always do. The façade declares no policy check, so it adds none that could
query. The tenant refusal (decision 3) reads the call's tenant, not the context.

## Consequences

- A consumer gets the canonical rows in its own words, with filters and sorts running in the database, and with
  exactly the rows and values it could read from the source directly.
- A secured or sensitive value stays as hidden through a façade as at the source. A façade cannot be used to read
  around a grant, and a reviewer can confirm that from the verifier rather than from each façade.
- Every write through a façade is a source action, with one audit event, the source's guards and the source's lock.
  A value a source action cannot set cannot be set through a façade, whatever the façade's vocabulary suggests.
- Ash returns no count for a manual read, and keyset cursors are not translated through a lens. Façade lists page by
  offset until they are.
- The lens grammar is the limit of what a façade can say. A mapping outside it is a read-only source calculation
  with a reason, never a free-form expression with a guessed reverse.
- A façade reads at the current mapping. A past `as_of` gives the source's values as of that instant through
  today's lenses; the mapping version in each explanation says which.

## Reversal

A façade stores nothing, so removing one is deleting its module and, where it was exposed, its routes; no data
migrates and no audit history moves, because it never held any. Removing the mechanism means dropping the
`facade?: true` profile from the base resource and the dependency on the package's façade extension. Consumers would
then translate in their own code again, without the verifier's guarantee.

## Not decided here

- **The façade's own authorization path.** Every row and every write a façade returns is a source call made as the
  caller, so its own actions need no grant. Which mechanism says so is open: self-service (ADR 0052) admits active
  persons only, so automation principals and agents could not use a façade even where the source grants them; a
  delegated path installed by `facade?: true` would admit any principal the source admits, keeping the tenant
  requirement. The spike used self-service and recommends the delegated path.
- **One write action or one per route.** A single generic write action is the smallest surface; one named action
  per route suits effects declarations and action buttons better. Either keeps decision 5.
- **Keyset paging through a lens.**
- **Façades over sources the platform does not write through** (landed records), where an edit would be recorded as
  an assertion with declared precedence rather than as a source action.
- **Strangling one owned resource over another** to evolve a canonical model. This record covers vocabulary over
  the same rows, not a change of the model's own storage.
