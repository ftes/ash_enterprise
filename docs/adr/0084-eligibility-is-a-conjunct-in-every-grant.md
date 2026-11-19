# ADR 0084 — Eligibility is a conjunct in every grant: information-flow labels without `forbid_if`

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0003](0003-attribute-multitenancy.md) (attribute multitenancy, `global? true`),
  [ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md) (a zone's classification ceiling; leaving
  the zone is a disclosure), [ADR 0059](0059-version-number-is-an-optimistic-lock.md) (`human_only`),
  [ADR 0063](0063-declared-operations-are-a-package.md) (declared operations and the disclosure gate),
  [ADR 0070](0070-upstream-first-placement.md) (upstream-first placement),
  [ADR 0073](0073-secured-columns-are-grants.md) (secured columns are grants),
  [ADR 0075](0075-outbound-webhooks-are-a-declared-operation.md) (outbound webhooks),
  [ADR 0078](0078-values-explain-themselves.md) (an explanation reads as the viewer),
  [ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md) (a façade reads its source as the viewer), and
  [manifesto 03](../manifesto/03-authorization-is-data.md) (authorization is data)

## Context

Authorization here is a pure union of grants (manifesto 03). A grant says who may reach which rows, and nothing a
grant says depends on the data in a row beyond where the row sits: its owner, its business unit, its tenant. Some data
needs a second, mandatory rule. Board papers should stay with the people cleared to read board papers, whatever role
grants reach the table. Personnel case notes should not reach a reader because a manager shared the row. A summary of
a confidential document should be as confidential as the document. The standard names for this are mandatory access
control and information-flow labels: Bell–LaPadula for confidentiality ("no read up") and Biba for integrity, its
dual.

The usual way to write a mandatory rule is a deny: `forbid_if row.level > actor.clearance`. Here that is ruled out.
Manifesto 03 forbids `forbid_if` for row access (`03-authorization-is-data.md:97-99`), because one deny breaks
additivity and makes grants order-dependent.

Pieces of a label already exist, but they don't share an order. Verified on 2026-11-19, there are eight classification
vocabularies:

1. The data inventory's attribute classes: `sensitive`, `sealed` and `unclassified`
   (`Governance.DataInventory`).
2. The egress register's `data_classes`: `account_identity`, `personal_data`, `tenant_business_content` and so on
   (`Governance.DataFlows`, `data_flows.ex:49-60`).
3. Zones' `DataClass`, a total order, `public < synthetic < internal < customer_confidential`, with a zone's
   `classification_ceiling` checked at admission (`zones/types/data_class.ex`, `Zones.Admission`).
4. Copy dispositions from `ash_greenmask`: `transform`, `keep ... because:` and `exclude_data because:`, in 40
   `greenmask` blocks.
5. From `ash_judgments`: a question's `pii :none | :minimised` (where `:minimised` requires a state projection), the
   envelope/payload split, and a profile's residency class (`:in_cluster | :sub_processor`).
6. From `ash_compliance`: an environment's `data_ceiling` (`:synthetic | :pseudonymised`) and its `zone`
   (`boundary.ex:109-114`).
7. From `ash_operations`: an operation's `discloses?` and the resource's `disclosure_gate`.
8. From `ash_agent`: a run's `tainted?`, set once an open-world call has answered it. It is recorded and never
   enforced (`run.ex:109-111,449`).

Tenancy has a related gap. Attribute multitenancy is `global? true`, so a read with no tenant is allowed
(`platform/transformers/add_system_attributes.ex:257-263`, ADR 0003). A call with no tenant is never foreign
(`security/checks/foreign_tenant.ex:52-73`), and a `:global` grant's filter is `true`
(`security/checks/role_grant.ex:131-132`). Tenant isolation therefore rests on the plug that sets the tenant and on
the foreign-tenant policy. It is not a condition inside the grants. A person's context is built in one tenant, and a
`:global` grant in it means "everything in the tenant", yet nothing in the grant's filter says which tenant.

## Decision

**A row is visible when some grant reaches it and the reader is eligible for it. Eligibility goes inside every grant,
as a positive conjunct, rather than over the union as a deny.**

    visible = (g1 ∪ g2 ∪ … ∪ gn) ∩ eligible
            = (g1 ∩ eligible) ∪ (g2 ∩ eligible) ∪ … ∪ (gn ∩ eligible)

Intersection distributes over union, so the two lines are the same set. The second line is the one built. Every check
stays `authorize_if`, and no grant path gains a `forbid_if`.

### Why this keeps manifesto 03

Manifesto 03 protects three properties. Each still holds:

- **Additive in grants.** Adding a grant adds a disjunct, `g ∩ eligible`. A disjunct can only add rows.
- **Additive in clearance.** `eligible` is monotone in the reader's clearance. A higher level or another compartment
  makes the conjunct true on more rows and false on none. So granting a clearance, like granting a role, can only add
  access.
- **Order-free.** A union is commutative. The conjunct reads only the row and the reader's precomputed clearance. It
  never reads another grant, so no grant path can change what another grant gives.

One meaning does change, and it is stated rather than hidden. A `:global` read grant now means "every row in the
tenant that I am eligible for", the way it already means "every row in the tenant" and not "every row". Dataverse's
sentence that a broad grant cannot be taken back from a single record still holds of grants. A label is not a grant
taken back. It is a property of the row, the way the row's tenant is, and it narrows by data just as tenancy does.
Manifesto 03 already allows narrowing that is not a `forbid_if`: `human_only`, `machinery_only` and `engine_only` each
limit how far an existing path reaches (`03-authorization-is-data.md:157-166`). Eligibility limits which rows any path
reaches, by a rule every path shares.

This is the shape ADR 0073 gave secured columns. A secured column is read only through a grant that names it. A
labelled row or column is read only through a grant held by a reader whose clearance covers its label.

### The decisions

1. **The label is a lattice of three parts.** A label is `%Label{level, compartments, integrity}`.
   - **Level** is a total order, seeded from Zones' `DataClass`: `public < synthetic < internal <
     customer_confidential`. `DataClass` becomes the level type, so `within_ceiling?/2` and zone admission read the
     same order the conjunct reads. A deployment that needs another level adds it to that one type.
   - **Compartments** is a set of need-to-know names, such as `board` or `personnel`. A reader must hold every
     compartment on a row to read it. A row with no compartments needs none.
   - **Integrity** is `trusted` or `tainted` (decision 9). It never narrows a read.

   **Join:** the label of something made from several inputs is their join: the highest level, the union of
   compartments, and `tainted` if any input is tainted. **Order:** `a ≤ b` when `a`'s level is at or below `b`'s and
   `a`'s compartments are a subset of `b`'s. The bottom label is `public` with no compartments, and every reader is
   eligible for it.

2. **The conjunct is installed by the platform base, inside every grant.** `AshEnterprise.Security.Policies` emits
   each grant path in the union as `authorize_if {Security.Checks.Eligible, grant: Check}`. That covers `RoleGrant`,
   `SharedWithActor`, `HierarchyGrant`, `SelfService` and every `extra_grants:` path. `Eligible` is a filter check
   that ANDs the inner check's answer with the row's eligibility:
   - an inner filter is ANDed with the eligibility filter;
   - an inner `true` from a simple check becomes the eligibility filter;
   - an inner `false` stays `false`.

   The field policies the base writes for `secured_fields` (ADR 0073) are wrapped the same way, so a column grant
   also reaches only eligible rows. A verifier refuses a platform resource, including one with `policies?: false`
   that copies the set by hand, if its grant union holds an `authorize_if` that is not wrapped. The bypasses (both
   engines and the system actor) and the tenant-boundary policy are unchanged. A generic action has no row, so its
   conjunct is only the tenancy part, and a generic action that reads labelled rows reads them as its actor, through
   the conjunct.

   For a labelled resource, the eligibility filter is

       organization_id == ^ctx.organization_id
       and classification in ^ctx.clearance.levels
       and compartments ⊆ ^ctx.clearance.compartments

   `classification in ^levels` uses the precomputed list of levels at or below the reader's clearance, so the
   database never compares an enum by order. The subset test is the array containment operator. The base indexes
   `(organization_id, classification)` with a b-tree and `compartments` with a GIN index.

3. **Clearances are precomputed into `ActorContext`, and no check queries.** A clearance is a level
   and a set of compartments held by a role, as data an administrator edits, beside the role's privileges. An actor's
   clearance is the join across every role it holds, directly or through a team, so taking on a role can only raise
   it. `ActorContext` gains `clearance: %{level, levels, compartments}`, built in the same pass that reads role
   assignments. That adds one read of the roles already found to the build. It is a fixed cost per request, like the
   build's other reads, and never a query per check or per row. An automation principal's context is `intersect/2`
   of its own and its requester's, and for clearances that is the lattice meet: the lower level and the common
   compartments. The Administrator role holds the top level and every compartment, as it holds every secured column
   (ADR 0073, decision 4). The seeded roles carry `internal` and no compartments. Every reader is cleared at least to
   the bottom label. A context that fails to build carries the bottom label only, so the conjunct fails closed.

4. **Tenancy is folded into eligibility.** On a tenant-scoped resource, the conjunct includes
   `organization_id == ^ctx.organization_id` for a person or an automation principal, whatever tenant the call names.
   A call with no tenant, which `global? true` allows, then reaches only the reader's own tenant's rows through any
   grant. A `:global` grant means "everything in my tenant" in the filter itself, not only by the plug's convention.
   `ForeignTenant` stays: it refuses a call that names another tenant, which the conjunct would only turn into an
   empty read. Cross-tenant work stays where ADR 0003 put it, with system actors, who are not subject to grants and
   so not to the conjunct. A resource that is not tenant-scoped has no tenancy part. Before this lands, the host
   lane's gap map lists every path where a person or an automation principal makes a call with no tenant (jobs, tool
   calls, façade reads, saved-set replay, `explain`) and tests that path with no tenant.

5. **Labels live on rows and columns, opt in per resource, and are never optional on a labelled resource.**
   - A resource opts in by declaring `classified`. The base then adds `classification` (the level, `NOT NULL`, with
     the resource's declared default) and `compartments` (an array, default empty).
   - A column may carry a fixed label of its own in the same declaration. A value's label is the join of its row's
     label and its column's label.
   - A labelled column is guarded by a field policy wrapped as in decision 2.
   - A resource that declares no labels gets only the tenancy part of the conjunct, so nothing else changes until a
     resource opts in.
   - Rules for writing labels:
     - A write may set or raise a label only within the writer's own clearance. This is a validation on the action,
       so nobody writes a row they could not read back.
     - Lowering a label is only `declassify` (decision 7).
     - A missing, unknown or unreadable label fails closed. The column is non-null, an unknown compartment is one no
       reader holds, and an error building the filter is `false`.

6. **Labels propagate only at declared boundaries.** A derived row's label is the join of its inputs' labels. The
   boundaries are:
   - folds into a golden record;
   - business-event mapping runs;
   - projections;
   - judgment outputs, which take the label of the subject state the question read;
   - agent run outputs, which take the join of what the run read, and its taint;
   - façade reads, which inherit their sources' labels because they read the source as the viewer;
   - exports and model calls, which are egress (decision 7).

   A resource built on one of those derivations declares where its label comes from (`derives_labels_from`) or that
   its label is fixed, with `because:`. A derivation that reads a labelled resource and declares neither fails a
   compile-time verifier. **Arbitrary Elixir is not tracked.** If a custom change reads a labelled value and writes
   it somewhere undeclared, nothing sees it. The docs say so, and the data inventory reports any resource whose
   recorded lineage inputs carry a label it lacks.

7. **Egress has ceilings, and only a person lowers a label.**
   - **Ceilings.** Every path in the egress register (`Governance.DataFlows`) has a ceiling, which is a label.
     Sending is allowed when the label of what is sent is at or below the ceiling. The check is a validation on the
     egress action: on the model-call guard, the disclosure gate, the webhook fan-out, the CSV export, mail and the
     provider proxy. It is a precondition of an act, not row access, the same way ADR 0077 uses a validation on its
     admit action. A refusal is typed and carries `because:`. A zone's `classification_ceiling` is the ceiling of
     the model calls into that zone.
   - **Declassify.** Lowering a stored row's label is a `declassify` action that the base adds to a labelled
     resource. It is `human_only`, so no engine or system actor reaches it (ADR 0059). It requires a non-empty
     `because:`, and it is audited with the label before and after. It is granted like a secured column, by a
     privilege named for it (`"<Resource>#declassify"`). The declassifier must already be eligible for the row's
     current label.
   - **Sanitisers.** A derivation may also declare, in code and with `because:`, that its output
     label is lower than the join of its inputs. Examples are a copy transform that replaces a value, and a judgment
     projection that minimises what a model sees. That is a sanitiser, reviewed in code review the way a greenmask
     `keep ... because:` is now. It is never a runtime act on a stored row.

8. **The eight vocabularies map onto the lattice.** These are the proposed mappings. The host lane settles them.

   | Vocabulary | Maps to |
   |---|---|
   | Inventory `sensitive` / `sealed` / `unclassified` | Kept. They say how a value is handled (redacted from logs, sealed under an erasure scope), not who may read it. The inventory reports each attribute's label beside them |
   | Egress `data_classes` | Kept as the description of what a path carries. Each path gains a ceiling (decision 7) |
   | Zones `DataClass` and `classification_ceiling` | `DataClass` becomes the level order. A zone's ceiling is an egress ceiling |
   | Copy dispositions (`transform`, `keep`, `exclude_data`) | The sanitisers of the copy boundary: `transform` lowers the column for the copy, `keep ... because:` passes it at its label, and `exclude_data` sends nothing |
   | Judgments `pii`, envelope/payload, residency | `pii :minimised` is a sanitiser on the model-call boundary, and the projection is its declaration. The envelope fields carry no payload-derived label. Residency stays a separate destination check (ADR 0042), because it limits where data goes, not who reads it |
   | Environment `data_ceiling` and `zone` | The ceiling of a copy into that environment: `:synthetic` is the level `synthetic`, and `:pseudonymised` means every column above `synthetic` passed a copy sanitiser |
   | Operations `discloses?` and `disclosure_gate` | A disclosing operation has a ceiling, and the gate checks it before any byte leaves. A non-disclosing operation sends identifiers and paging only, and needs none |
   | Agent `tainted?` | The integrity part (decision 9) |

   Secured columns (ADR 0073) are not a vocabulary. They are a grant by name, and they stay one. A column can be
   both secured and labelled, and then it needs both.

9. **Integrity is the dual, and it guards inputs, not reads.**
   - A value is `tainted` when content from outside the application entered it. At first, the only source is an
     agent run that is `tainted?`. Its outputs carry the taint through the join.
   - A consuming action may declare an input high-integrity. Examples are an input to a decision, and a judgment
     admitted as a fact. Such an action refuses a tainted value, with a validation and `because:`. That is Biba's
     "no read down", applied where data is consumed.
   - An `endorse` action clears the taint. Like `declassify`, it is `human_only`, audited and requires `because:`.
   - Integrity never narrows what a person may read.

10. **The mechanics are a package, and the wiring stays here.** A separate package,
    `ash_information_flow`, holds what has no host dependency:
    - the label type, the join and the order;
    - the Spark DSL (`classified`, `derives_labels_from`, an egress `ceiling`);
    - the derivation verifier;
    - the egress-gate behaviour with its typed refusal;
    - the builder for the eligibility filter.

    This repository holds the wiring:
    - the `Eligible` wrapper and its verifier;
    - the `ActorContext` clearances;
    - the role clearance columns;
    - the label columns and their indexes;
    - the ceilings on the egress register;
    - the `declassify` and `endorse` actions;
    - the vocabulary mappings.

    The package's second consumer is any Ash application with a role model that wants labels without denies.

## Does it consume ActorContext?

Yes. The clearance is precomputed on the context, beside the grants, by one more fixed read in the build. The
conjunct reads the context and the row, and nothing else. `intersect/2` takes the meet of two clearances, as it
already takes the intersection of two grant sets.

## Consequences

- **Every platform resource is touched once.** The wrapper goes into the policy set every resource inherits. The
  tenancy part applies to every tenant-scoped resource from the day it lands. A property test in the host lane shows
  two things: adding a grant or a clearance never removes a visible row, and reordering the grant paths never changes
  the answer. Security sign-off precedes the merge.
- **A `:global` grant is narrower on a labelled resource**, and that is the point. An administrator who wants a role
  to read everything gives it the clearance as well as the grant. The Administrator role already holds both.
- **Labels add a query term and an index.** The conjunct is plain SQL (`=`, `IN`, `<@`), and its indexes are
  declared by the base. A query-plan check on a large table is part of the host lane.
- **Façades, explain and saved sets inherit the conjunct.** They read the source as the viewer, so they cannot read
  wider than the viewer. A façade does not declare labels of its own: it inherits them, as it inherits `sensitive?`.
- **Bypasses are still bypasses.** An engine or a system actor reads past the conjunct, as it reads past grants. What
  it then writes for a person to read is a derivation (decision 6) or an egress (decision 7). An engine that copies a
  labelled value into an undeclared place is the untracked Elixir that decision 6 names.
- **A relabelled source does not relabel what was already derived from it.** A derived row keeps the label it was
  written with until it is derived again. Projections that replay pick up the new label. For other derived rows, the
  data inventory reports the difference, and the record says so.
- **A hidden cell in an export is marked, not blanked.** The CSV export writes a redaction marker where it now
  writes `""`, so a reader can tell a hidden value from an empty one.
- **Manifesto 03 gains a dated amendment on acceptance.** It says: "Eligibility is a conjunct inside every grant, not
  a deny over the union. Grants and clearances stay additive and order-free, a `:global` grant reaches the rows of
  its tenant that the reader is eligible for, and only a person lowers a label (ADR 0084)."

## Alternatives considered

- **A deny over the union** (`forbid_if` on the label). It is ruled out by manifesto 03, for the reason the manifesto
  gives.
- **One extra policy after the union** (`policy always() do authorize_if Eligible end`). Ash ANDs applicable policies,
  so this computes the same set, without a `forbid_if`. It is not chosen for two reasons. First, the union stops being
  a complete statement of reach: "who can see this row" needs a second step outside the grants. Second, the field
  policies the base writes for secured columns would need a parallel rule. Wrapping each grant keeps one place, the
  grant, that says everything about reach, as ADR 0073 does for columns.
- **Labels as more privileges** (a privilege per level or compartment). A privilege grants a verb on a resource.
  Clearance is about the row's data, across every resource, so a privilege per level would have to be granted per
  resource and kept in step by hand.

## Reversal

Removing labels means removing the wrapper from the policy set. The grants are unchanged underneath, so every grant
then reaches what it reached before. The label columns can stay, unread, until a migration drops them. Unfolding
tenancy (decision 4) removes the tenancy part from the wrapper, and isolation goes back to the plug and `ForeignTenant`.
The egress ceilings are validations, and each can be dropped on its own.
