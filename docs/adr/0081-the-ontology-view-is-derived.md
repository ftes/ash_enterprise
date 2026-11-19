# ADR 0081 — The ontology view is derived: a generated overlay, a backing facet per resource, and one dataset name per relation

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0012](0012-openlineage-and-marquez.md) (OpenLineage as the schema),
  [ADR 0013](0013-openmetadata-as-catalog.md) (catalogue column names),
  [ADR 0019](0019-api-versioning-as-presentation-contract.md) (the public API is a pinned contract),
  [ADR 0031](0031-the-legacy-estate-is-projected-not-cut-over.md) (the legacy estate is projected, not cut over),
  [ADR 0034](0034-canvas-dev-surface.md) (the canvas, amended below),
  [ADR 0037](0037-projections-are-host-declared.md) (canvas projections, a different sense of the word than the
  `projected` backing kind below),
  [ADR 0070](0070-upstream-first-placement.md) (upstream-first placement; the brake and the UI ladder),
  [ADR 0072](0072-ash-native-tenant-flags.md) (feature flags never authorize),
  [ADR 0073](0073-secured-columns-are-grants.md) (secured columns),
  [ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md) (an ontology façade is a resource over
  resources), [ADR 0078](0078-values-explain-themselves.md) (the value address and its trace references)

## Context

People who build on this platform ask the same questions about the model again and again: what kinds of thing the
application holds, how they link, what can be done to each and with what consequence, and where each one's rows
actually come from. The answers exist, but in many places. Every Ash resource is a type with attributes,
relationships, actions and policies. Some of those resources are not plain tables: a strangled resource reads a legacy
relation through a view, a union resource combines several, a canonical row can be written by a projection from
landed source records, and a golden person's name and email are folded from attribute assertions. Nothing lists, per
resource, which of these it is.

Several surfaces now want that list: a model map that shows each type with where its rows come from, an Explore page
that filters any readable type, a record page that shows each value's sources, a semantic diff of the model on CI,
and an impact report. Each could compute its own view of the model. This record decides that they share one, and what
it is made of.

Verified on 2026-11-19, at this repository's main and the package versions it locks:

- **The model is already machine-readable twice.** `Ash.Info.Manifest` (Ash 3.37.2) produces a language-agnostic
  description of resources, actions, fields, types and filter capabilities. `AshA2ui.Canvas.Graph` builds the
  canvas graph from the canvas registry and keys it by a `revision`: `sha256:` over the canonicalised semantic
  content (nodes sorted by id, edges sorted, metadata restricted to semantic fields), so module definition order
  does not move it.
- **A generated, checked description of storage exists.** `AshEnterprise.Governance.DataInventory` writes
  `docs/data-inventory.json` from the resource declarations, one entry per resource (domain, table, ownership,
  tenancy, sensitive, sealed and secured attributes, API exposure), and CI runs
  `mix ash_enterprise.data_inventory --check`. It describes the code and attests nothing about a running deployment.
- **Where rows come from is declared, but in different packages.** `ash_strangler` declares strangled, union and
  derived resources and reports them through `AshStrangler.Lineage`, `AshStrangler.Union.Info`,
  `AshStrangler.Derived.Info` and `AshStrangler.Estate.Report`. Master data resources are built from `ash_mdm`
  resource macros, and the fold that writes a golden row is `AshEnterprise.Mdm.Refold`. Canonical rows projected
  from landed source records are written by host projectors (`AshEnterprise.Canonical.Projection`).
- **Packages contribute structure that no one records.** Resources here are built from package fragments
  (`AshAgent.Invocation`, `AshAgent.Run`, `AshPlanning.Fragment.Candidate`, `AshJudgments.Ledger.Fragment`,
  `AshEvidence.Assertions.Fragment`, and others) and from package resource macros (`AshMdm.Resources`,
  `AshDiscreteBusinessEvents.Resources`, `AshEvents.Chain.Resources`). Twelve execution sources implement the
  `AshAgent.Execution.Source` behaviour (`AshEnterprise.ExecutionSources`). Spark merges a fragment's sections into
  the resource and keeps no record of which fragments it used, so membership cannot be read back from a compiled
  resource today.
- **Two lineage emitters name the same table differently.** `ash_open_lineage` names a resource's dataset with the
  domain segment as namespace and `table` or `schema.table` as name. `ash_strangler`'s column lineage uses
  `postgres://{host}:{port}` and `schema.table`. Neither includes the database. A strangled resource therefore appears
  as two unjoined datasets. The OpenLineage naming specification (https://openlineage.io/docs/spec/naming) names a
  Postgres dataset by namespace `postgres://{host}:{port}` and name `{database}.{schema}.{table}`.
- **The public API has stable names.** `priv/api/contract.lock.json` pins the generated OpenAPI document and GraphQL
  schema by SHA-256 (ADR 0019, amended 2026-11-17), and a breaking change has to be announced.
- **What a viewer may do is already one read.** `AshAcp.AvailableActions.for_actor/3` prunes candidate actions with
  `Ash.can?`; the web shell and the ACP palette both use it. `AshEnterprise.Surfaces.openable/1` lists the surfaces
  behind an open door over a resource the viewer may read.
- **The canvas is dev-only.** ADR 0034 put `/canvas` behind `:dev_routes` with no audience model, and named the
  registry as the one place an audience would land.

## Decision

**The ontology view of this application is derived from the Ash declarations, never declared beside them. It is one
generated overlay, keyed by a digest of the manifest it was built from. Each resource carries a backing facet that
says where its rows come from, read from declarations that already exist. Every dataset is named by the OpenLineage
Postgres convention. Surfaces that show the overlay are gated by a door and a flag, and read records only as the
viewer.**

1. **Every Ash resource is a type, and nothing else is.** Attributes, relationships, actions, calculations,
   aggregates and policies are the type's properties, links, actions and rules, read through `Ash.Resource.Info`
   and `Ash.Info.Manifest`. There is no separate registry of object types, link types or interfaces. An interface
   is a package fragment, a package resource macro or an Elixir behaviour that resources or their companion modules
   implement.

2. **The carrier is a generated file keyed by a manifest digest.**
   - `docs/ontology.json`, format `ash_enterprise.ontology/1`, generated from the same resource list as the data
     inventory and checked in CI with `--check`, the way `docs/data-inventory.json` is.
   - Its key is a **manifest digest**: `sha256:` over the canonicalised semantic content of `Ash.Info.Manifest` for
     the inventoried resources, built the way `AshA2ui.Canvas.Graph` builds its `revision` (sorted keys, semantic
     fields only, no definition order). The data inventory gains the same digest field, so a consumer can tell that
     the two files describe the same build.
   - The overlay carries what the inventory does not: the backing facet and hop chain (decision 3), action edges
     (effects declaration, posture, signals emitted and listened to, process and job edges), fragment and interface
     membership (decision 6) and identity inputs (decision 7). It never repeats the inventory's classification of
     attributes. The two join on the resource name.
   - It is built from declarations alone. Generating it reads no row, needs no database and runs as no actor.
   - No new package. The generator lives beside `AshEnterprise.Governance.DataInventory`. If a second host needs the
     same generator, it moves to a package under ADR 0070 §4, at that point and not before.

3. **Each resource carries one backing facet.** The facet says where the resource's rows come from. Its kinds:

   | Kind | Means | Read from |
   |---|---|---|
   | `owned` | A table this application writes through the resource's own actions | the default when no other kind is declared |
   | `strangled` | A view or table over a legacy relation, with the strangler phase | `ash_strangler` source declaration and `AshStrangler.Lineage` |
   | `union` | Rows combined from several branches, each with its own phase | `AshStrangler.Union.Info` |
   | `derived` | Zero or more rows produced per source row | `AshStrangler.Derived.Info` |
   | `projected` | Rows a declared projection writes deterministically from recorded sources (landed source records, an event log) | the host's projectors (`AshEnterprise.Canonical.Projection`) and the projection packages' own declarations |
   | `folded` | Values a survivorship fold resolves from assertions | the `ash_mdm` resource declarations and the fold that writes them |
   | `facade` | A resource with no storage of its own that gives a business vocabulary to one or more source resources ([ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md)) | the façade extension's declaration |

   - **`projected` is a data term.** It says a projector writes the rows. It is unrelated to the canvas's
     projections (ADR 0037), which are ways of showing a type.
   - **One kind per resource.** Where more than one applies, the first in this order wins: `facade`, `strangled`,
     `union`, `derived`, `projected`, `folded`, `owned`. A resource whose table it owns but some of whose attributes
     are folded (a golden person) is `folded`, and its hop lists those attributes.
   - **Every kind except `owned` names a hop chain:** the ordered list of what the rows come from, each hop naming
     its source (a resource, or a legacy relation through its twin), its kind, the attributes or columns it carries
     where the declaration says, and the mapping version where the package records one (`ash_strangler`'s
     `mapping_version`). A hop whose source has its own non-`owned` facet continues into it, so a façade over a
     strangled resource walks down to the legacy relation.
   - **Declared, never guessed.** A kind is read from a declaration. A resource with none is `owned`. Where a kind
     has no machine-readable declaration today, the lane that needs it adds one host list, the way
     `AshEnterprise.Governance.DataFlows` lists egress, and a test holds the list against the code (every projector
     the host runs names the resources it writes). Names, modules and table prefixes are never evidence of a kind.
   - **Façades are built, not deferred.** The `facade` kind is in the vocabulary from the start. Its shape is decided
     in [ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md) and built upstream in `ash_strangler` (ADR 0070
     §4, step 2); the overlay reads a façade's declaration as soon as a resource uses it.
   - **Column lineage follows the declaration's precision.** A strangled hop carries column lineage today. Union and
     derived hops are listed without column lineage until `ash_strangler` emits it for them; the overlay says
     "not recorded", never shows an empty edge list as if there were none.

4. **One dataset name per Postgres relation.** An Ash resource's OpenLineage dataset is the Postgres relation that
   stores it, named by the specification's own Postgres convention: namespace `postgres://{host}:{port}` of the
   resource's primary repo, name `{database}.{schema}.{table}`, all three parts always present (schema `public` when
   the resource declares none), names verbatim as declared. The domain segment is the job namespace only and never
   appears in a dataset.
   - **Primary repo.** Host, port and database come from the configuration of the repo the resource writes through,
     not a read replica's, so routing reads to a replica does not rename the dataset.
   - **One override per repo.** Where the configuration carries no host and port (a socket directory), or a
     catalogue knows the database by another address (a connection pooler, internal DNS), the deployment declares
     one namespace per repo. Never per resource and never per call. With neither, the dataset is omitted, not emitted
     under a placeholder namespace.
   - **No relation, no dataset.** Embedded, in-memory and simple-data-layer resources, façades among them, have no
     dataset. How a façade hop appears in lineage is decided in [ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md), under this rule.
   - **Views are named as the relation.** A strangled, union or derived resource names its view; a projected or
     folded resource names its table. The backing facet says which kind it is; the dataset name does not.
   - **Legacy relations** apply the same rule with their twin's own repo and schema, so a legacy table on another
     cluster has its own namespace.
   - **One implementation.** `AshOpenLineage.Info.resource_dataset/1` builds the pair, and every emitter calls it:
     the notifier, `ash_strangler`'s column lineage and every later hop. The change to both packages is a behaviour
     change to a contract hosts depend on, so it lands as its own package pull request with a conformance test of
     fixed expected pairs, and the host's recorded datasets change identity with it.
   - **The overlay stores what the code knows.** `docs/ontology.json` describes the code, so it carries each
     resource's schema and table and the repo module. Host, port and database are deployment configuration and are
     resolved when an event is emitted, never written into the file.

   Worked example: host `db1`, port 5432, database `app`, a resource in schema `accounts` with table `people`, in a
   domain `Directory`. The update job is `(directory, person.update)`; its output dataset is
   `(postgres://db1:5432, app.accounts.people)`; a legacy column it maps from is a field of
   `(postgres://legacy-db:5432, legacy.public.users)`.

5. **Flags gate surfaces and never authorize; each surface names its rung on the UI ladder.**
   - Each surface that shows the overlay declares a flag key, off by default (ADR 0072). A flag decides whether the
     surface is offered. A door on the surface (`AshEnterprise.Surfaces.Doors`, a read grant) decides who may open
     it, and the resources' own policies decide what it shows. A flag that is on gives nobody a permission.
   - What a viewer may do to a type or a record is read through `AshAcp.AvailableActions.for_actor/3` and
     `Ash.can?`, the read the shell and the ACP palette already use. The overlay holds no per-viewer data and no
     surface computes capabilities a second way.
   - Types the viewer may not read are absent from what the surface sends, including diagram text, not shown
     greyed out.
   - The rungs, from ADR 0070 §5, each confirmed or corrected by the surface's gap map before its first commit:

     | Surface | Rung | Why |
     |---|---|---|
     | Model map | U3 for the graph element, already recorded by ADR 0034; U2 for each capability it adds | A canvas is the case U3 names. What it adds (an audience callback, effects and posture on nodes, diagram tabs, a per-cell "why" link, masked hidden fields) goes into `ash_a2ui` first |
     | Explore | U1 | A filtered list over any readable type is a table surface; filters come from the manifest's operators |
     | Record page | U1, falling to U2 for a missing section, timeline or time scrubber component | Panes over one record, each read as the viewer |

6. **Fragment and interface membership is recorded, and unknown is said.** For each resource, the overlay lists
   the package fragments and package resource macros it is built from; for each `AshAgent.Execution.Source`, the
   resource it reads. Spark does not persist fragment membership, so it is derived by comparing the fragment's own
   DSL configuration with the resource's, with a test that fails when a resource names a fragment in its source that
   the derivation does not find. Until that derivation lands, membership reads `unknown`, never an empty list.

7. **Identity inputs are the pinned ones.** A type's stable identity is its resource module and, where it is exposed
   through the public API, the name the API contract pins. The overlay records the digests in
   `priv/api/contract.lock.json`, so a semantic diff or impact report can tell a change to a pinned public name from
   an internal one without re-deriving the API.

### Why this is not a second DSL

ADR 0070 §2 item 4 says never to hide a declaration behind a second DSL. An `ontology do … end` block, or an
attribute on each resource saying what kind of type it is, would be exactly that: a second statement of facts the
strangler declaration, the master data macros, the projection declarations and the resource itself already make. Two
statements of one fact drift, and the second one is the one people stop updating.

So nothing here adds a DSL. Every column of the overlay is read from a declaration that already exists, and the one
new artefact a lane may add is a host list for a mechanism that has no machine-readable declaration yet (decision 3),
which is data a test holds against the code, not a language. The overlay is a view in the database sense: it can be
dropped and regenerated, and nothing reads it to decide behaviour.

### Alternatives considered

- **A semantic-manifest package.** Rejected for now by the rule of two (ADR 0070 §2 item 1): one host generates
  the overlay. The generator moves to a package when a second host needs it.
- **Object types declared in their own registry.** Rejected: it is the second DSL above, and it would let a type
  exist in the view that has no resource behind it.
- **The overlay stored in database tables.** Rejected: it describes the code of one build, not tenant data. A
  stored copy would need its own migrations and could disagree with the running code.
- **A semantic-web serialisation (OWL, RDF) as the carrier.** Not chosen as the carrier, because the readers are
  this application's own surfaces and its CI diff, which read JSON. An export to such a standard, or to a
  catalogue's schema (ADR 0013), is a projection of `docs/ontology.json` and can be added when a consumer asks.
- **Keeping the domain segment as the dataset namespace.** Rejected: it is not the specification's convention, it
  collides with the job namespace, and it cannot join the strangler's column lineage.

## Does it consume ActorContext?

Not to build the overlay: generation reads declarations and runs as no actor.

The surfaces do, in the usual ways. A door reads the viewer's grants from the precomputed context; a flag check
reads the context's resolved `flags` (ADR 0072) and never queries; whether a type is readable is `Ash.can?` on its
primary read, which a filter policy answers without a query; every record a surface shows is read as the viewer,
under the resource's policies and ADR 0073 grants. No policy check reads the overlay.

## Consequences

- One view of the model serves the model map, Explore, the record page, the semantic diff and the impact report.
  A change to a resource changes the digest, and `--check` fails until the overlay is regenerated.
- A strangled resource's notifier event and its column lineage name the same dataset, so a lineage consumer joins
  them into one node.
- Recorded lineage datasets change identity once, when the emitters adopt the rule. Jobs record their latest
  datasets again; tests that assert the old domain-style pairs change with it.
- The deployment has to declare a namespace override wherever its repo configuration has no host and port, or
  lineage omits datasets for that repo.
- The facet is only as precise as the declarations it reads. Union and derived hops show no column lineage until
  the strangler emits it, and membership shows `unknown` until its derivation lands. Both are shown as such.
- The overlay describes the code, not a deployment: it cannot say which tenant holds rows of a type, and a host's
  overlay differs from this repository's.

## Reversal

The overlay is a generated file and a generator. Dropping it means deleting `docs/ontology.json`, its mix task and
its CI check, and the digest field in the data inventory; the surfaces that read it lose their facet and hop
columns and keep working from `Ash.Resource.Info`. The dataset naming rule is reversible only at the cost of a second
identity change in recorded lineage, so a reversal should come with a `SymlinksDatasetFacet` from the new name to the
old for consumers that stored it. Adding a DSL later would need this record superseded and the §2 item 4 argument
answered.
