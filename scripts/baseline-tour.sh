#!/usr/bin/env bash
# The baseline tour: the demo surfaces that exist today, walked by a script on a loopback
# instance, so a later change that breaks one fails here, loudly, before anyone clicks.
#
#   devenv shell -- scripts/baseline-tour.sh
#
# What it walks, in order (each prints PASS or stops the run with FAIL and its reason):
#
#   0. Preflight: the Postgres on $PGPORT belongs to this repository's devenv, the port and the
#      database are the tour's own, and the checkout is clean enough to build.
#   1. MiniZinc and prlimit are on PATH (the planning backend's solver and its resource limit).
#   2. A fresh instance: its own database, migrated and seeded with the demo tenant, served on
#      127.0.0.1 only.
#   3. Demo step 2: /app/explorer, opened from the correlation id of the demo's import batch
#      (the one that produced the golden persons), shows a timeline.
#   4. Demo step 3: /canvas answers, and the inspector's record capabilities carry consequence
#      classes (a destructive one demands confirmation).
#   5. Demo step 4: a planning candidate whose sources moved is refused and marked stale, and
#      nothing is written (this repository's own test for it).
#   6. Demo step 1 and the four-eyes half of step 4: the clinic's labelled simulation run over
#      the visits ahead, and its four-eyes apply with drift refused (the clinic's own tests,
#      from the checkout named by CLINIC_DEMO_DIR).
#
# Environment:
#   TOUR_PORT        the loopback port (default 4391)
#   TOUR_DB          the database, created fresh and dropped at the end; its name must contain
#                    "tour" (default ash_enterprise_tour)
#   TOUR_MINIZINC    require (default) | report. `report` prints the result and carries on, for a
#                    host that has no MiniZinc yet; the absence is still printed.
#   CLINIC_DEMO_DIR  a checkout of the clinic demo at origin/main (required)
#   TOUR_KEEP        1 leaves the instance and database up at the end, for a manual click-through
#
# It never touches another instance, port or database, and stops only the server it started.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${TOUR_PORT:-4391}"
DB="${TOUR_DB:-ash_enterprise_tour}"
MINIZINC="${TOUR_MINIZINC:-require}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/baseline-tour.XXXXXX")"
SERVER_LOG="$LOG_DIR/server.log"
SERVER_PID=""
STEP="preflight"

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$STEP" "$1" >&2; exit 1; }

# Print the failing step with the log to read, whatever stopped the run.
on_exit() {
  status=$?
  stop_server
  if [ "${TOUR_KEEP:-0}" != 1 ] && [ -n "${DB_CREATED:-}" ]; then
    mix ecto.drop --quiet >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    printf '\nThe baseline tour FAILED at step: %s\nLogs: %s\n' "$STEP" "$LOG_DIR" >&2
  else
    printf '\nThe baseline tour passed. Logs: %s\n' "$LOG_DIR"
  fi
}
trap on_exit EXIT

# Only the process this run started: the listener on our port, and only if it runs from this checkout.
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  [ "${TOUR_KEEP:-0}" != 1 ] || return 0
  local pid
  pid="$(listener_pid "$PORT")"
  if [ -n "$pid" ] && [ "$(readlink "/proc/$pid/cwd")" = "$ROOT" ]; then
    kill "$pid" 2>/dev/null || true
  fi
  kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

listener_pid() {
  ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1
}

# --- 0. preflight -----------------------------------------------------------------------------

STEP="0 preflight"
command -v mix >/dev/null || fail "mix is not on PATH: run this inside 'devenv shell --'"
[ -n "${PGPORT:-}" ] || fail "PGPORT is not set: run this inside 'devenv shell --'"
case "$DB" in *tour*) ;; *) fail "TOUR_DB must contain \"tour\" so it can never be a shared database (got $DB)";; esac
[ -n "${CLINIC_DEMO_DIR:-}" ] && [ -d "$CLINIC_DEMO_DIR" ] ||
  fail "CLINIC_DEMO_DIR must name a checkout of the clinic demo (steps 1 and 4 run there)"

pg_pid="$(listener_pid "$PGPORT")"
[ -n "$pg_pid" ] || fail "nothing listens on PGPORT=$PGPORT: 'devenv up -d' first"
pg_cwd="$(readlink "/proc/$pg_pid/cwd" || true)"
case "$pg_cwd" in
  */.devenv/state/postgres) ;;
  *) fail "the Postgres on :$PGPORT runs from '$pg_cwd', not a devenv cluster: another project may own the port";;
esac
[ -z "$(listener_pid "$PORT")" ] || fail "port $PORT is already taken: set TOUR_PORT"
pass "Postgres on :$PGPORT is a devenv cluster ($pg_cwd); port $PORT and database $DB are the tour's own"

# --- 1. MiniZinc ------------------------------------------------------------------------------

STEP="1 minizinc"
if mz="$(command -v minizinc)"; then
  pass "minizinc present: $("$mz" --version 2>&1 | head -n1)"
elif [ "$MINIZINC" = report ]; then
  printf 'WARN  minizinc is NOT on PATH (TOUR_MINIZINC=report: carrying on)\n'
else
  fail "minizinc is not on PATH (planning's real solver tests cannot run); TOUR_MINIZINC=report to carry on without it"
fi
if command -v prlimit >/dev/null; then
  pass "prlimit present"
elif [ "$MINIZINC" = report ]; then
  printf 'WARN  prlimit is NOT on PATH (TOUR_MINIZINC=report: carrying on)\n'
else
  fail "prlimit is not on PATH (the solver's resource limit)"
fi

# --- 2. a fresh loopback instance --------------------------------------------------------------

STEP="2 instance"
export DB_NAME="$DB" PORT="$PORT" PHX_IP=127.0.0.1
{
  mix ecto.drop --quiet || true
  mix ecto.create --quiet
  DB_CREATED=1
  mix ash_enterprise.legacy.setup
  mix ash.setup
  mix ash_enterprise.demo
} >"$LOG_DIR/setup.log" 2>&1 || fail "database setup or demo seed failed; see $LOG_DIR/setup.log"
pass "database $DB migrated and seeded with the demo tenant"

mix phx.server >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
up=""
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/sign-in" 2>/dev/null; then up=1; break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || fail "the server exited at boot; see $SERVER_LOG"
  sleep 2
done
[ -n "$up" ] || fail "the server did not answer on 127.0.0.1:$PORT within 3 minutes; see $SERVER_LOG"
case "$(ss -ltnH "sport = :$PORT" | awk '{print $4}')" in
  127.0.0.1:"$PORT") ;;
  *) fail "the instance is not bound to loopback only";;
esac
pass "instance up on 127.0.0.1:$PORT, loopback only"

# --- 3 and 4. the surfaces ---------------------------------------------------------------------

STEP="3-4 surfaces"
export TOUR_BASE="http://127.0.0.1:$PORT" PGHOST=127.0.0.1
mix run --no-start scripts/baseline_tour.exs

# --- 5. a stale candidate is refused -------------------------------------------------------------

STEP="5 stale candidate"
MIX_TEST_PARTITION=_tour mix test test/ash_enterprise/planning/candidate_apply_test.exs \
  --max-cases 4 >"$LOG_DIR/candidate.log" 2>&1 ||
  fail "the candidate apply tests failed; see $LOG_DIR/candidate.log"
pass "a candidate whose sources moved is refused, marked stale, and nothing is written"

# --- 6. the clinic -------------------------------------------------------------------------------

STEP="6 clinic"
(
  cd "$CLINIC_DEMO_DIR"
  MIX_TEST_PARTITION=_tour mix test \
    test/clinic_demo/business_events_scenarios_test.exs \
    test/clinic_demo/planning/four_eyes_test.exs --max-cases 4
) >"$LOG_DIR/clinic.log" 2>&1 || fail "the clinic tests failed; see $LOG_DIR/clinic.log"
pass "clinic: labelled simulation run, four-eyes apply, drift refused"
