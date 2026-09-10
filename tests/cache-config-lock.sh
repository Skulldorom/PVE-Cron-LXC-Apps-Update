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
EVENTS="$TMPDIR/events.log"
CURL_LOG="$TMPDIR/curl.log"
HC_LOG="$TMPDIR/hc.log"
mkdir -p "$FAKE_BIN" "$LOG_DIR" "$UPSTREAM_LOG_DIR" "$CACHE_DIR"
: >"$EVENTS"; : >"$CURL_LOG"; : >"$HC_LOG"

cat >"$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
MODE="${CURL_MODE:-ok}"
out=""
url=""
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) data="${2:-}"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://hc.test*)
    if [[ "$url" == */start ]]; then echo "healthcheck:start" >>"${EVENTS_LOG:?}"; echo "/start" >>"${HC_LOG:?}";
    elif [[ "$url" == */fail ]]; then echo "healthcheck:fail" >>"${EVENTS_LOG:?}"; echo "/fail" >>"${HC_LOG:?}";
    else echo "healthcheck:success" >>"${EVENTS_LOG:?}"; echo "success" >>"${HC_LOG:?}"; fi
    [ -n "$data" ] && echo "$data" >>"${HC_LOG:?}"
    exit 0
    ;;
esac
echo "$url" >>"${CURL_LOG:?}"
case "$MODE" in
  fail) exit 22 ;;
  empty) : >"$out"; exit 0 ;;
  html) printf '<html><body>error</body></html>\n' >"$out"; exit 0 ;;
  failrun) suffix='FAILRUN'; exit_code='7' ;;
  b) suffix='B'; exit_code='0' ;;
  *) suffix='A'; exit_code='0' ;;
esac
cat >"$out" <<UPSTREAM
#!/usr/bin/env bash
set -uo pipefail
echo "update:${suffix}:dry=\${var_dry_run:-no}:backup=\${var_backup:-unset}" >>"\${EVENTS_LOG:?}"
mkdir -p "\$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR"
log="\$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR/\$(date '+%Y%m%d_%H%M%S')-${suffix}.log"
echo "Update ${suffix} started" >"\$log"
echo "Container \${var_container:-none}: updated"
echo "Full log: \$log"
exit ${exit_code}
UPSTREAM
exit 0
CURL
chmod +x "$FAKE_BIN/curl"

run_worker() {
  PATH="$FAKE_BIN:$PATH" \
    EVENTS_LOG="$EVENTS" CURL_LOG="$CURL_LOG" HC_LOG="$HC_LOG" \
    UPDATE_COMMUNITY_APPS_LOG_DIR="$LOG_DIR" \
    UPDATE_COMMUNITY_APPS_STATUS_FILE="$STATUS_FILE" \
    UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR="$UPSTREAM_LOG_DIR" \
    UPDATE_COMMUNITY_APPS_CACHE_DIR="$CACHE_DIR" \
    UPDATE_COMMUNITY_APPS_LOCK_FILE="$LOCK_FILE" \
    UPDATE_COMMUNITY_APPS_CONFIG_FILE="$CONFIG_FILE" \
    bash "$ROOT/update-community-apps.sh" "$@"
}

latest_worker_log() { find "$LOG_DIR" -name 'update-community-apps-*.log' -printf '%T@ %p\n' | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}'; }
reset_logs() { : >"$EVENTS"; : >"$CURL_LOG"; : >"$HC_LOG"; }

cat >"$CONFIG_FILE" <<CFG
CONTAINERS=101
BACKUP=no
BACKUP_STORAGE=
NOTIFY=no
DRY_RUN=no
CFG
run_worker >"$TMPDIR/o1" 2>&1
[ -f "$CACHE_DIR/update-apps.sh" ] || { echo "FAIL: cache file not created"; exit 1; }
grep -q '^upstream_used=fresh$' "$STATUS_FILE" || { echo "FAIL: status not fresh"; cat "$STATUS_FILE"; exit 1; }
grep -q 'update:A:dry=no' "$EVENTS" || { echo "FAIL: normal run unexpectedly dry"; cat "$EVENTS"; exit 1; }
echo "ok - first successful download caches upstream and normal run is live"

reset_logs
run_worker --dry-run >"$TMPDIR/o2" 2>&1
grep -q 'update:A:dry=yes' "$EVENTS" || { echo "FAIL: --dry-run overridden by config"; cat "$EVENTS"; exit 1; }
echo "ok - explicit --dry-run overrides DRY_RUN=no config"

old_hash=$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')
CURL_MODE=b run_worker --refresh-upstream-cache >"$TMPDIR/o3" 2>&1
new_hash=$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')
[ "$new_hash" != "$old_hash" ] || { echo "FAIL: changed upstream did not replace cache"; exit 1; }
grep -q '^sha256=' "$CACHE_DIR/update-apps.meta" || { echo "FAIL: cache meta missing sha"; exit 1; }
grep -q 'Update B started' "$CACHE_DIR/update-apps.sh" || { echo "FAIL: cache does not contain B"; exit 1; }
echo "ok - changed valid upstream replaces cache and metadata"

CURL_MODE=html run_worker >"$TMPDIR/o4" 2>&1
[ "$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')" = "$new_hash" ] || { echo "FAIL: invalid candidate replaced cache"; exit 1; }
echo "ok - invalid candidate does not replace known-good cache"

reset_logs
CURL_MODE=fail run_worker >"$TMPDIR/o5" 2>&1
grep -q '^upstream_used=cached$' "$STATUS_FILE" || { echo "FAIL: expected cached fallback"; cat "$STATUS_FILE"; exit 1; }
grep -q '^upstream_refresh_status=failed$' "$STATUS_FILE" || { echo "FAIL: expected failed refresh"; exit 1; }
grep -q 'Using last-known-good cached' "$(latest_worker_log)" || { echo "FAIL: no fallback warning"; exit 1; }
echo "ok - HTTP failure with valid cache falls back when allowed"

rm -f "$CACHE_DIR/update-apps.sh" "$CACHE_DIR/update-apps.meta"
set +e
CURL_MODE=fail run_worker >"$TMPDIR/o6" 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || { echo "FAIL: expected exit 1 without cache, got $code"; exit 1; }
grep -q '^exit_code=1$' "$STATUS_FILE" || { echo "FAIL: status not failure"; exit 1; }
echo "ok - HTTP failure without cache is fatal"

CURL_MODE=ok run_worker >/dev/null 2>&1
good_hash=$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')
CURL_MODE=empty run_worker >"$TMPDIR/o7" 2>&1
[ "$(sha256sum "$CACHE_DIR/update-apps.sh" | awk '{print $1}')" = "$good_hash" ] || { echo "FAIL: empty download replaced cache"; exit 1; }
echo "ok - empty download does not replace known-good cache"

printf 'CONTAINERS=abc,def\nBACKUP=no\n' >"$CONFIG_FILE"
set +e; run_worker >"$TMPDIR/o8" 2>&1; code=$?; set -e
[ "$code" -eq 2 ] || { echo "FAIL: expected exit 2 for bad containers, got $code"; cat "$TMPDIR/o8"; exit 1; }
echo "ok - malformed container list fails cleanly"

printf 'CONTAINERS=101\nBACKUP=maybe\n' >"$CONFIG_FILE"
set +e; run_worker >"$TMPDIR/o9" 2>&1; code=$?; set -e
[ "$code" -eq 2 ] || { echo "FAIL: expected exit 2 for bad boolean, got $code"; cat "$TMPDIR/o9"; exit 1; }
echo "ok - invalid boolean fails cleanly"

printf 'CONTAINERS=101\nBACKUP=yes\nBACKUP_STORAGE=\n' >"$CONFIG_FILE"
set +e; run_worker >"$TMPDIR/o10" 2>&1; code=$?; set -e
[ "$code" -eq 2 ] || { echo "FAIL: expected exit 2 for backup w/o storage, got $code"; cat "$TMPDIR/o10"; exit 1; }
echo "ok - backup enabled without storage fails"

printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\nHEALTHCHECK_URL=https://hc.test/x\n' >"$CONFIG_FILE"
exec 7>"$LOCK_FILE"; flock -n 7 || { echo "setup: could not acquire lock"; exit 1; }
reset_logs
set +e; run_worker >"$TMPDIR/o11" 2>&1; code=$?; set -e
[ "$code" -eq 0 ] || { echo "FAIL: expected clean exit 0 on lock contention, got $code"; exit 1; }
grep -q 'already active' "$TMPDIR/o11" || { echo "FAIL: no lock contention message"; exit 1; }
[ ! -s "$HC_LOG" ] || { echo "FAIL: lock contention emitted healthcheck"; cat "$HC_LOG"; exit 1; }
flock -u 7
echo "ok - concurrency lock prevents overlap and no healthcheck run is emitted"

reset_logs
CURL_MODE=ok run_worker >"$TMPDIR/o12" 2>&1
start_line=$(grep -n 'healthcheck:start' "$EVENTS" | cut -d: -f1)
update_line=$(grep -n 'update:A' "$EVENTS" | head -1 | cut -d: -f1)
success_line=$(grep -n 'healthcheck:success' "$EVENTS" | cut -d: -f1)
if ! { [ "$start_line" -lt "$update_line" ] && [ "$update_line" -lt "$success_line" ]; }; then
  echo "FAIL: healthcheck success ordering"; cat "$EVENTS"; exit 1
fi
echo "ok - healthcheck /start precedes successful update and success follows"

reset_logs
set +e; CURL_MODE=failrun run_worker >"$TMPDIR/o13" 2>&1; code=$?; set -e
[ "$code" -eq 7 ] || { echo "FAIL: expected upstream failure 7, got $code"; exit 1; }
start_line=$(grep -n 'healthcheck:start' "$EVENTS" | cut -d: -f1)
update_line=$(grep -n 'update:FAILRUN' "$EVENTS" | cut -d: -f1)
fail_line=$(grep -n 'healthcheck:fail' "$EVENTS" | cut -d: -f1)
if ! { [ "$start_line" -lt "$update_line" ] && [ "$update_line" -lt "$fail_line" ]; }; then
  echo "FAIL: healthcheck failure ordering"; cat "$EVENTS"; exit 1
fi
echo "ok - healthcheck /fail follows failed update"

printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\nUPSTREAM_REFRESH=yes\nALLOW_CACHED_UPSTREAM=yes\n' >"$CONFIG_FILE"
CURL_MODE=ok run_worker >/dev/null 2>&1

printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\nUPSTREAM_REFRESH=no\nALLOW_CACHED_UPSTREAM=yes\n' >"$CONFIG_FILE"
reset_logs
CURL_MODE=fail run_worker >"$TMPDIR/o14" 2>&1
grep -q '^upstream_used=cached$' "$STATUS_FILE" || { echo "FAIL: refresh-disabled did not use cache"; cat "$STATUS_FILE"; exit 1; }
grep -q '^upstream_refresh_status=disabled$' "$STATUS_FILE" || { echo "FAIL: refresh status not disabled"; exit 1; }
[ ! -s "$CURL_LOG" ] || { echo "FAIL: refresh-disabled made network request"; cat "$CURL_LOG"; exit 1; }
grep -q 'refresh is disabled' "$(latest_worker_log)" || { echo "FAIL: refresh-disabled log missing"; exit 1; }
echo "ok - UPSTREAM_REFRESH=no uses valid cache without network"

rm -f "$CACHE_DIR/update-apps.sh"
reset_logs
set +e; CURL_MODE=fail run_worker >"$TMPDIR/o15" 2>&1; code=$?; set -e
[ "$code" -eq 1 ] || { echo "FAIL: refresh-disabled/no-cache expected failure, got $code"; exit 1; }
[ ! -s "$CURL_LOG" ] || { echo "FAIL: refresh-disabled/no-cache made network request"; exit 1; }
grep -q '^upstream_refresh_status=disabled$' "$STATUS_FILE" || { echo "FAIL: status not disabled"; cat "$STATUS_FILE"; exit 1; }
echo "ok - UPSTREAM_REFRESH=no without cache fails safely without refresh attempt"

printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\nUPSTREAM_REFRESH=yes\nALLOW_CACHED_UPSTREAM=yes\n' >"$CONFIG_FILE"
CURL_MODE=ok run_worker >/dev/null 2>&1
printf 'CONTAINERS=101\nBACKUP=no\nNOTIFY=no\nUPSTREAM_REFRESH=yes\nALLOW_CACHED_UPSTREAM=no\n' >"$CONFIG_FILE"
reset_logs
set +e; CURL_MODE=fail run_worker >"$TMPDIR/o16" 2>&1; code=$?; set -e
[ "$code" -eq 1 ] || { echo "FAIL: fallback-disabled expected failure, got $code"; exit 1; }
! grep -q 'update:' "$EVENTS" || { echo "FAIL: cache executed though fallback disabled"; cat "$EVENTS"; exit 1; }
grep -q '^upstream_refresh_status=failed$' "$STATUS_FILE" || { echo "FAIL: refresh failure not recorded"; cat "$STATUS_FILE"; exit 1; }
grep -q 'fallback is disabled' "$TMPDIR/o16" "$(latest_worker_log)" || { echo "FAIL: fallback-disabled reason missing"; exit 1; }
echo "ok - ALLOW_CACHED_UPSTREAM=no blocks cached fallback after refresh failure"

rm -f "$STATUS_FILE"
printf 'CONTAINERS=101\nBACKUP=no\n' >"$CONFIG_FILE"
run_worker --status >"$TMPDIR/o17" 2>&1
grep -q 'Worker installed: yes' "$TMPDIR/o17" || { echo "FAIL: status missing worker line"; exit 1; }
grep -q 'Last run:' "$TMPDIR/o17" || { echo "FAIL: status missing last run"; exit 1; }
echo "ok - status mode reports operational overview"

echo "ALL CACHE/CONFIG/LOCK TESTS PASSED"
