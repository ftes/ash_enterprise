# Runbook: residency for a deployment we operate

Where does the data rest, and where can it go? This runbook is how a deployment answers that, and how it keeps the
answer true. The rule it checks is [ADR 0042](../adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md); the
code is `AshEnterprise.Zones.ResidencyReport`.

## The model: one deployment per jurisdiction

A deployment has one database, and that database is physically in one place. The place is the deployment's declared
zone. Data that must stay in another jurisdiction is held by a separate deployment in that jurisdiction, not by a
second region of this one. Tenancy inside the database is attribute-based, so the report says nothing about which
tenant's rows are where: the claim it supports is "this deployment, in this zone, reaches these destinations".

## Declare it

1. Declare each zone in a JSON file (`priv/zones/examples/ontario.json` is the shape) and list the files in
   `ZONE_DECLARATIONS`. Set `CANONICAL_ZONE` to the zone the database is in.
2. Map the deployment's stores and egress destinations to zone ids in a second JSON file named by
   `STORE_DECLARATIONS`:

   ```json
   {"stores": {
     "database": {"zone": "example-ontario"},
     "telemetry_exporter": {"zone": "example-ontario"}
   }}
   ```

   Keep both files with the deployment, never in this repository: they describe your infrastructure.

A zone past its `review_by` date lapses, and so does everything mapped to it, until someone renews the declaration.

## Read the report

    mix ash_enterprise.residency            # print it
    mix ash_enterprise.residency --check    # exit non-zero on a failing verdict

Run it in the deployment's own environment: it reads the running configuration. Each line is one target with a
verdict.

| Target | What it is |
|---|---|
| `database` | the application database (also holds the evidence tables) |
| `oban` | the job queue; rides the same database and inherits its declaration unless you map it separately |
| `telemetry_exporter` | the OTLP endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT`) |
| `lineage_collector` | the OpenLineage endpoint, once `http_base_url` is set |
| `integration_broker` | the OAuth broker (`NANGO_BASE_URL`) |
| `credential_registry` | the credential registry, once its base URL is set |
| `model_in_zone` | the in-zone generative profile (`S1_GEN_BASE_URL`) |
| `model_hosted` | hosted models; `blocked` while `REQUIRE_IN_ZONE_MODELS` refuses them |

| Verdict | Meaning | `--check` |
|---|---|---|
| `in_zone` | mapped to a declared zone that has not lapsed | passes |
| `co_located` | an egress host on the loopback interface | passes |
| `blocked` | the flow guard refuses calls to it | passes |
| `unknown` | a store with no zone mapped | fails |
| `leaves_zone` | an egress host nobody declared inside a zone | fails |
| `undeclared_zone` | mapped to a zone id no declaration defines | fails |
| `lapsed` | mapped to a zone past its review date | fails |

A mapping that names no target of this deployment is printed as `unrecognised` and fails too, so a misspelt id
cannot hide a store.

Each egress target names the row of the egress register (`docs/data-inventory.json`, `egress_register`) that says what
it can carry. The report decides where a destination is; the register decides what may go there.

## What it does not cover

- An endpoint that is hard-coded rather than configured. The register's coverage check
  (`mix ash_enterprise.data_inventory --check`) is what catches a new egress path in code.
- Outbound webhooks and the error tracker: neither has deployment configuration of its own yet. They join the report
  when they do.
- Admission of raw provider payloads on the Nango land path: that is separate work and not claimed here.
