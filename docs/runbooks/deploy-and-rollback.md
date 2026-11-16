# Deploying and rolling back

What a deploy does to the schema, how a migration is reversed, what is checked before a migration ships, and what none
of it proves. Companion to `backup-and-restore.md`: a rollback undoes a schema change; a restore brings back data.

## A deploy is three separate steps

1. **Build** the release (or, for a source deployment, update and compile the checkout).
2. **Migrate**, as a step of its own, before the new code serves: `bin/migrate`, which calls
   `AshEnterprise.Release.migrate/0`. It runs every pending migration of every repo in `:ecto_repos` and skips what
   has run, so it is safe on every deploy.
3. **Start** the new code.

Migrate and start are separate so a failed migration stops the deploy before anything new is serving.

## Rolling back a migration

```
bin/ash_enterprise eval 'AshEnterprise.Release.rollback(AshEnterprise.Repo, 20261105033324)'
```

`rollback/2` takes an explicit version, deliberately: no default of "one step". The version is rolled back too, and
everything after it, newest first. Roll back the code first (or at the same time): old code against a newer schema is
the situation the lint below exists to make survivable, not one to stay in.

From a source checkout, `mix ash_enterprise.migrations.rollback --floor VERSION` rolls everything newer than VERSION
back one migration at a time and names the migration whose `down` failed.

## The reversibility floor

`priv/repo/REVERSIBLE_SINCE` names, per repo, a migration version. Every migration **newer** than it must reverse
through `Release.rollback/3` and replay to the same schema. CI holds it to that (`scripts/migration-round-trip.sh`,
step "Migrations roll back and replay"):

1. migrate to the floor and snapshot the schema (F);
2. migrate to the newest version and snapshot (A);
3. roll back to the floor, newest first, through `Release.rollback/3`, and snapshot: it must equal F;
4. migrate again and snapshot: it must equal A.

A `down` that raises fails step 3 and the failure names its version; a `down` that runs and leaves something behind
fails the comparison. The script proves itself first on fixture migrations (`test/fixtures/migrations`): a raising
down, a down that leaves a table behind, and a clean control.

**Why a floor and not "everything".** Older generated `down` bodies were never run before this check. Some are not
inverses, and `CLAUDE.md` forbids hand-writing migrations, so the floor sits at the oldest version from which every
later migration reverses (found by rolling back one migration at a time on a scratch database). Migrations at or
below the floor are not claimed reversible. The floor moves **down** by making older downs pass (regenerate, do not
hand-edit). It never moves **up** to excuse a new migration: fix the migration before it ships.

Extensions and functions installed by early migrations survive a `down` by design, which is why the floor sits
after them: the comparison is of whole schemas, not of "no tables".

`AshEvidence.Repo` migrations are owned by the `ash_evidence` package; they are applied by the same migrate step but
are not part of the round trip. A `down` failing there is an `ash_evidence` change.

## Squawk: what a migration may not do to the node still running

`scripts/migration-lint.sh` (CI step "Migration SQL lint (Squawk)") captures the SQL of every migration newer than the
floor (`mix ash_enterprise.migrations.sql`) and runs a pinned Squawk over it. Every finding prints. These **block**,
because they break a node running the previous release against the new schema:

- `ban-drop-column`, `ban-drop-table`
- `renaming-column`, `renaming-table`
- `changing-column-type`
- `adding-required-field`, `adding-not-nullable-field`

Everything else (indexes without `CONCURRENTLY`, foreign keys, missing timeouts, "robust statement" style) warns:
Ash codegen produces those on every migration.

**A deliberate contract step.** Removing something is the last step of expand/contract: ship the change that stops
reading it, deploy, and only then drop it. Acknowledge that step in `priv/repo/migration-contract-steps.json`, one
entry per version and rule, with the Plane ticket and a one-line reason. The entry is reviewed in the commit or PR
that adds it; it is not signed by a person's name.

## Rehearsing a rollback on real data

`mix ash_enterprise.backup.drill --rollback-to VERSION` (or `latest`) restores a dump into a fresh database as the
drill always does, then, **on the copy only**, rolls back to VERSION and applies everything again, and compares every
table's row count with the restored copy's. It also checks the source's `schema_migrations` did not change. A `down`
that destroys rows fails the drill. CI runs it with `latest` on the seeded database; run it with the version before a
release's first migration before shipping that release. On a deployment, run it against a restored copy, never the
live database.

## What none of this proves

- **Rolling deploys.** Nothing here runs an old release and a new one against one schema at once. Squawk's blocking
  rules are the static stand-in for that property, not a test of it. A single node that is stopped and started on
  deploy has a gap no migration discipline closes: measure it with a `/health` probe across the restart (once a
  second) and report the number, which is not zero.
- **Data.** A `down` that drops a column or table gives the structure back, not the rows. The drill measures this on
  a copy; a rollback in production loses whatever the undone migration had added.
- **Irreversible acts.** An erasure shred (`crypto-shredding.md`) is not undone by a rollback or a restore of an older
  dump.
- **Anything at or below the floor.**
