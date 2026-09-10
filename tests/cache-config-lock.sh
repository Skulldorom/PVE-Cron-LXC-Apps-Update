#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

FAKE_BIN="$TMPDIR/bin"
LOG_DIR="$TMPDIR/log"
UPSTREAM_LOG_DIR="$TMPDIR/upstream-logs"
STATUS_FILE="$TMPDIR/status"
CACHE_DIR="$TMPDIR/cache"
LOCK_FILE="$TMPDIR/run.lock"
CONFIG_FILE="$TMPDIR/config.conf"
mkdir -p "$FAKE_BIN" "$LOG_DIR" "$UPSTREAM_LOG_DIR" "$CACHE_DIR"

# Fake curl that records requested URL and serves a configurable payload.
cat >"$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
MODE="${CURL_MODE:-ok}"
out=""
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) [ -n "${2:-}" ] && echo "$2" >>"${HC_LOG:-/dev/null}"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
echo "${args[*]}" >>"${CURL_LOG:-/dev/null}"
case "$MODE" in
  fail) exit 22 ;;
  empty) : >"$out"; exit 0 ;;
  html) printf '<html><body>error</body></html>\n' >"$out"; exit 0 ;;
  *)
    cat >"$out" <<'UPSTREAM'
#!/usr/bin/env bash
set -uo pipefail
mkdir -p "$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR"
log="$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR/$(date '+%Y%m%d_%H%M%S').log"
echo "Update started" >"$log"
echo "Container ${var_container:-none}: updated"
echo "Full log: $log"
exit 0
UPSTREAM
    ;;
esac
exit 0
CURL
chmod +x "$FAKE_BIN/curl"

run_worker() {
  PATH="$FAKE_BIN:$PATH" \
    UPDATE_COMMUNITY_APPS_LOG_DIR="$LOG_DIR" \
    UPDATE_COMMUNITY_APPS_STATUS_FILE="$STATUS_FILE" \
    UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR="$UPSTREAM_LOG_DIR" \
    UPDATE_COMMUNITY_APPS_CACHE_DIR="$CACHE_DIR" \
    UPDATE_COMMUNITY_APPS_LOCK_FILE="$LOCK_FILE" \
    UPDATE_COMMUNITY_APPS_CONFIG_FILE="$CONFIG_FILE" \
    bash "$ROOT/update-community-apps.sh" "$@"
}

# ── Test 1: first successful download caches upstream ───────────────────────
cat >"$CONFIG_FILE" <<CFG
CONTAINERS=101
BACKUP=no
BACKUP_STORAGE=
NOTIFY=no
CFG
run_worker >"$TMPDIR/o1" 2>&1
[ -f "$CACHE_DIR/update-apps.sh" ] || { echo "FAIL: cache file not created"; exit 1; }
[ -f "$CACHE_DIR/update-apps.meta" ] || { echo "FAIL: cache meta not created"; exit 1; }
grep -q '^upstream_used=fresh$' "$STATUS_FILE" || { echo "FAIL: status not fresh"; cat "$STATUS_FILE"; exit 1; }
grep -q '^upstream_refresh_status=success$' "$STATUS_FILE" || { echo "FAIL: refresh status not success"; exit 1; }
echo "ok - first successful download caches upstream"

# ── Test 2: HTTP failure with valid cache falls back to cache ───────────────
CURL_MODE=fail run_worker >"$TMPDIR/o2" 2>&1
grep -q '^upstream_used=cached$' "$STATUS_FILE" || { echo "FAIL: expected cached fallback"; cat "$STATUS_FILE"; exit 1; }
grep -q '^upstream_refresh_status=failed$' "$STATUS_FILE" || { echo "FAIL: expected failed refresh"; exit 1; }
worker_log=$(find "$LOG_DIR" -name 'update-community-apps-*.log' | head -1)
grep -q 'Using last-known-good cached' "$worker_log" || { echo "FAIL: no cache fallback warning in log"; cat "$worker_log"; exit 1; }
echo "ok - HTTP failure with valid cache falls back to cached copy"

# ── Test 3: HTTP failure without cache is fatal ──────────────────────────────
rm -f "$CACHE_DIR/update-apps.sh" "$CACHE_DIR/update-apps.meta"
set +e
CURL_MODE=fail run_worker >"$TMPDIR/o3" 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || { echo "FAIL: expected exit 1 without cache, got $code"; exit 1; }
grep -q '^exit_code=1$' "$STATUS_FILE" || { echo "FAIL: status not failure"; exit 1; }
echo "ok - HTTP failure without cache is fatal"

# ── Test 4: empty download never replaces a good cache ───────────────────────
# Re-seed a valid cache first.
CURL_MODE=ok run_worker >/dev/null 2>&1
good_hash=$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')
CURL_MODE=empty run_worker >"$TMPDIR/o4" 2>&1
[ "$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')" = "$good_hash" ] || { echo "FAIL: cache was replaced by empty download"; exit 1; }
echo "ok - empty download does not replace known-good cache"

# ── Test 5: invalid candidate never replaces a good cache ────────────────────
CURL_MODE=html run_worker >"$TMPDIR/o5" 2>&1
[ "$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')" = "$good_hash" ] || { echo "FAIL: cache replaced by invalid candidate"; exit 1; }
echo "ok - invalid candidate does not replace known-good cache"

# ── Test 6: malformed config fails cleanly ───────────────────────────────────
printf 'CONTAINERS=abc,def\nBACKUP=no\n' >"$CONFIG_FILE"
set +e
run_worker >"$TMPDIR/o6" 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || { echo "FAIL: expected exit 2 for bad containers, got $code"; cat "$TMPDIR/o6"; exit 1; }
echo "ok - malformed container list fails cleanly"

# ── Test 7: invalid boolean fails cleanly ────────────────────────────────────
printf 'CONTAINERS=101\nBACKUP=maybe\n' >"$CONFIG_FILE"
set +e
run_worker >"$TMPDIR/o7" 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || { echo "FAIL: expected exit 2 for bad boolean, got $code"; cat "$TMPDIR/o7"; exit 1; }
echo "ok - invalid boolean fails cleanly"

# ── Test 8: backup enabled without storage fails ─────────────────────────────
printf 'CONTAINERS=101\nBACKUP=yes\nBACKUP_STORAGE=\n' >"$CONFIG_FILE"
set +e
run_worker >"$TMPDIR/o8" 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || { echo "FAIL: expected exit 2 for backup w/o storage, got $code"; cat "$TMPDIR/o8"; exit 1; }
echo "ok - backup enabled without storage fails"

# ── Test 9: concurrency lock prevents overlap ────────────────────────────────
printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\n' >"$CONFIG_FILE"
exec 7>"$LOCK_FILE"
flock -n 7 || { echo "setup: could not acquire lock"; exit 1; }
set +e
run_worker >"$TMPDIR/o9" 2>&1
code=$?
set -e
[ "$code" -eq 0 ] || { echo "FAIL: expected clean exit 0 on lock contention, got $code"; exit 1; }
grep -q 'already active' "$TMPDIR/o9" || { echo "FAIL: no lock contention message"; exit 1; }
flock -u 7
echo "ok - concurrency lock prevents overlapping runs"

# ── Test 10: Healthchecks ping is best-effort ────────────────────────────────
HC_LOG="$TMPDIR/hc.log"
printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\nHEALTHCHECK_URL=https://hc.invalid/x\n' >"$CONFIG_FILE"
HC_LOG="$HC_LOG" run_worker >"$TMPDIR/o10" 2>&1
grep -q 'healthcheck=enabled' "$STATUS_FILE" || { echo "FAIL: healthcheck not recorded"; exit 1; }
echo "ok - healthcheck ping recorded as enabled"

# ── Test 11: status mode works with no previous run ──────────────────────────
rm -f "$STATUS_FILE"
printf 'CONTAINERS=101\nBACKUP=no\n' >"$CONFIG_FILE"
run_worker --status >"$TMPDIR/o11" 2>&1
grep -q 'Worker installed: yes' "$TMPDIR/o11" || { echo "FAIL: status missing worker line"; exit 1; }
grep -q 'Last run:' "$TMPDIR/o11" || { echo "FAIL: status missing last run"; exit 1; }
echo "ok - status mode reports operational overview"

echo "ALL CACHE/CONFIG/LOCK TESTS PASSED"
