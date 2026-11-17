# Runbook: changing the public API

The JSON:API routes and the GraphQL schema are generated from the resources, and the shape callers were
promised is pinned in `priv/api/`. A resource change that moves that shape fails CI until the pin is
moved on purpose. This is the procedure ([ADR 0019](../adr/0019-api-versioning-as-presentation-contract.md),
amended 2026-11-17).

| File | What it is |
|---|---|
| `priv/api/openapi.json` | the OpenAPI document `/api/json/open_api` serves, minus servers, keys sorted |
| `priv/api/schema.graphql` | the GraphQL schema as SDL |
| `priv/api/contract.lock.json` | the sha-256 of those two files; a hand edit fails the check |
| `priv/api/deprecations.json` | what has been announced, and what has been retired |

## The change is additive

A new route, a new optional attribute, a new GraphQL type or field, a new optional argument, a new
route that requires a body (nobody sends one yet).

```bash
mix ash_enterprise.api.contract --write
git add priv/api
```

Commit the re-pin with the resource change, so the diff of `priv/api/` is the review of what callers see.

## The change is breaking

Breaking means a caller that worked can stop working: a removed route, property, GraphQL type, field,
argument or enum value; a changed type; a property, query parameter or argument newly required of a
caller; an argument or input field newly non-null. `mix ash_enterprise.api.contract --write` refuses it
and lists each element.

1. **Announce** each element in `priv/api/deprecations.json`:

   ```json
   {
     "deprecations": [
       {
         "element": "route:get /api/json/teams/{}",
         "announced": "2026-11-17",
         "sunset": "2027-03-01",
         "link": "https://example.com/notices/teams-by-id"
       }
     ],
     "retired": []
   }
   ```

   The element is the id `--write` printed. Route ids use `{}` for every path parameter
   (`route:get /api/json/teams/{}`), because the name of a path parameter is not part of the contract.
   `endpoint:graphql` deprecates the whole GraphQL endpoint. The `link` is an `https` URL a caller can
   read to learn what to do instead. The sunset must be at least **90 days** after `announced`; the check
   fails a shorter one.
2. **Keep the element** in the API, and ship. From the next deploy a request for the route (or the
   GraphQL endpoint, for `endpoint:graphql`) answers with `Deprecation`, `Sunset` and `Link` headers.
   Properties, GraphQL fields and arguments have no route to carry the headers: say so in the notice.
3. **Wait for the sunset.** `--write` refuses the removal until the date has passed.
4. **Remove it** from the resource and run `mix ash_enterprise.api.contract --write`. The announcement
   moves from `deprecations` to `retired`, which keeps the record and stops the check looking for it.

## What the check says

`mix ash_enterprise.api.contract --check` (CI and `scripts/pre-ci`) fails when

- a pinned file does not match its sha-256 in `contract.lock.json` (edited by hand: run `--write`);
- the API generated now differs from the pin. The failure prints the changed lines, and marks
  `BREAKING` each change no announcement permits yet;
- `deprecations.json` names an element the pinned contract does not hold, announces with less than the
  minimum notice, announces one element twice, or carries a link that is not `https`.

## Notes

- The pin is generated on the CI Elixir and OTP versions and normalized (keys sorted, `required` lists
  sorted, servers removed), so it should not flap. If it does, that is a bug in
  `AshEnterpriseWeb.ApiContract.canonical_json/1`.
- Anything that changes an exposed resource or an Accounts action (a field policy, an identity change, a
  new action on a routed resource) can move the pin. Run `--write` when `--check` says it has.
- A caller cannot pin a version and be served that version's shape. That is `ash_api_versioning`, still
  proposed in ADR 0019.
