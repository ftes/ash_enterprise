#!/usr/bin/env bash
# Migrations roll back and replay (q43). Every migration newer than the recorded floor
# (priv/repo/REVERSIBLE_SINCE) must reverse through the call a deploy rolls back with,
# AshEnterprise.Release.rollback/3, and replay to the same schema:
#
#   1. migrate to the floor                      -> schema F
#   2. migrate to the newest version             -> schema A
#   3. roll back to the floor, newest first      -> schema M   (M must equal F)
#   4. migrate to the newest version again       -> schema B   (B must equal A)
#
# M != F is a down that runs and leaves something behind (or takes something it should
# not). B != A is an up that is not repeatable. A down that raises fails step 3 and the
# task names its version. Schemas are pg_dump --schema-only; extensions and functions that
# survive a down by design are compared like everything else, so a migration whose down
# cannot restore them belongs below the floor.
#
# The floor is a ratchet, not a promise about history: the generated downs of older
# migrations were never run, some are not inverses, and CLAUDE.md forbids hand-writing
# migrations. Migrations newer than the floor are the ones that are held to reverse.
# docs/runbooks/deploy-and-rollback.md has the policy and how to move the floor.
#
# The checker proves itself first, on fixture migrations (test/fixtures/migrations):
# a raising down, a down that leaves a table behind, and a clean migration as the control.
# A checker that cannot fail would pass whatever the real run showed.
#
#   scripts/migration-round-trip.sh                # self-tests, then the real run
#   scripts/migration-round-trip.sh --self-test    # self-tests only
#
# Uses its own database partition (MIX_TEST_PARTITION, default _round_trip), so it never
# touches the suite's database.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

export MIX_ENV=test
base_partition="${MIX_TEST_PARTITION:-_round_trip}"
export PGPASSWORD="${DB_PASSWORD:-postgres}"
pg() { echo "-h ${PGHOST:-localhost} -p ${PGPORT:-5432} -U ${DB_USER:-postgres}"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fresh_db() { # partition
  export MIX_TEST_PARTITION="$1"
  mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
  mix ecto.create --quiet
}

snapshot() { # name -> $work/name.sql
  # pg_dump of PostgreSQL 18 writes a per-column pg_attver counter that changes on every
  # rewrite of the table; it is not schema, so it is left out of the comparison.
  # shellcheck disable=SC2046
  pg_dump $(pg) --schema-only --no-owner --no-privileges "ash_enterprise_test${MIX_TEST_PARTITION}" |
    grep -v '^--' | grep -v '^\\\(un\)\?restrict ' | grep -v 'SET (pg_attver=' | grep -v '^$' >"$work/$1.sql"
}

migrate() { # repo to path
  local path_opt=""
  [ -z "$3" ] || path_opt=", migrations_path: \"$3\""
  local to_opt=""
  [ -z "$2" ] || to_opt=", to: $2"
  mix run --no-start -e "AshEnterprise.Release.migrate(repos: [$1]$to_opt$path_opt)" >/dev/null
}

# round_trip "Repo|floor|path" ... : returns 1 and says why on the first difference.
round_trip() {
  local spec repo floor path
  for spec in "$@"; do
    IFS='|' read -r repo floor path <<<"$spec"
    migrate "$repo" "$floor" "$path"
  done
  snapshot floor
  for spec in "$@"; do
    IFS='|' read -r repo _ path <<<"$spec"
    migrate "$repo" "" "$path"
  done
  snapshot head

  for spec in "$@"; do
    IFS='|' read -r repo floor path <<<"$spec"
    local path_opt=()
    [ -z "$path" ] || path_opt=(--path "$path")
    if ! mix ash_enterprise.migrations.rollback --repo "$repo" --floor "$floor" "${path_opt[@]}" >"$work/rollback.log" 2>&1; then
      grep -E "failed|rolled back" "$work/rollback.log" >&2 || tail -n 20 "$work/rollback.log" >&2
      echo "round trip failed: a down raised (above)" >&2
      return 1
    fi
  done
  snapshot rolled-back
  if ! diff -u "$work/floor.sql" "$work/rolled-back.sql" >"$work/diff-down.txt"; then
    echo "round trip failed: rolling back to the floor does not give the floor's schema (a down leaves something behind or takes something away):" >&2
    head -n 40 "$work/diff-down.txt" >&2
    return 1
  fi

  for spec in "$@"; do
    IFS='|' read -r repo _ path <<<"$spec"
    migrate "$repo" "" "$path"
  done
  snapshot replayed
  if ! diff -u "$work/head.sql" "$work/replayed.sql" >"$work/diff-up.txt"; then
    echo "round trip failed: the replay is not the schema it replays (an up is not repeatable):" >&2
    head -n 40 "$work/diff-up.txt" >&2
    return 1
  fi
}

# self_test NAME EXPECT(pass|fail) FIXTURE [MESSAGE]
self_test() {
  local name="$1" expect="$2" fixture="$3" message="${4:-}" out
  fresh_db "${base_partition}_self"
  local status=0
  out="$(round_trip "AshEnterprise.Repo|20000101000000|test/fixtures/migrations/$fixture" 2>&1)" || status=$?
  if [ "$expect" = pass ] && [ "$status" -ne 0 ]; then
    echo "self-test '$name': expected the round trip to pass, it failed:" >&2
    echo "$out" >&2
    exit 1
  fi
  if [ "$expect" = fail ]; then
    if [ "$status" -eq 0 ]; then
      echo "self-test '$name': expected the round trip to fail, it passed" >&2
      exit 1
    fi
    if ! grep -qF -- "$message" <<<"$out"; then
      echo "self-test '$name': it failed, but not with '$message':" >&2
      echo "$out" >&2
      exit 1
    fi
  fi
  echo "self-test '$name': ok"
}

# Negative first: the checker must be able to fail before a pass means anything.
self_test "a down that raises names its version" fail raising_down "20000101000001"
self_test "a down that leaves a table behind fails the schema diff" fail leaves_table "fx_leaves"
self_test "a clean migration round-trips" pass clean

[ "${1:-}" != "--self-test" ] || exit 0

fresh_db "$base_partition"
mix ash_enterprise.legacy.setup >/dev/null

specs=()
while read -r repo floor; do
  [ -n "$repo" ] || continue
  specs+=("$repo|$floor|")
done < <(grep -v '^#' priv/repo/REVERSIBLE_SINCE | grep -v '^$')
[ ${#specs[@]} -gt 0 ] || { echo "priv/repo/REVERSIBLE_SINCE names no repo" >&2; exit 1; }

round_trip "${specs[@]}"

mix ecto.drop --quiet --force-drop >/dev/null
echo "migrations roll back and replay: ${specs[*]//|/ from } (floor, then newest, then floor, then newest, same schema each time)"
