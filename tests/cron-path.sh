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
mkdir -p "$FAKE_BIN" "$LOG_DIR" "$UPSTREAM_LOG_DIR"

cat >"$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$out" ] || exit 2
cat >"$out" <<'UPSTREAM'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR"
log="$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR/$(date '+%Y%m%d_%H%M%S').log"
echo "Update started: $(date '+%Y-%m-%d %H:%M:%S')" >"$log"
case ":$PATH:" in
  *:/usr/sbin:*) echo "cron-safe PATH includes /usr/sbin" >>"$log" ;;
  *) echo "missing /usr/sbin in PATH: $PATH" >>"$log"; exit 127 ;;
esac
echo "Full log: $log"
UPSTREAM
chmod +x "$out"
CURL
chmod +x "$FAKE_BIN/curl"

# Simulate cron's tiny PATH. The worker should prepend/export a Proxmox-safe PATH
# before running upstream, so upstream sees /usr/sbin even though cron did not
# provide it.
set +e
PATH="$FAKE_BIN" \
UPDATE_COMMUNITY_APPS_LOG_DIR="$LOG_DIR" \
UPDATE_COMMUNITY_APPS_STATUS_FILE="$STATUS_FILE" \
UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR="$UPSTREAM_LOG_DIR" \
UPDATE_COMMUNITY_APPS_UPSTREAM_SCRIPT_URL="https://example.invalid/update-apps.sh" \
NOTIFY=no \
BACKUP=no \
/bin/bash "$ROOT/update-community-apps.sh" "101" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
exit_code=$?
set -e

if [ "$exit_code" -ne 0 ]; then
  echo "Expected worker to succeed with Proxmox-safe PATH, got $exit_code" >&2
  cat "$TMPDIR/stdout" >&2
  cat "$TMPDIR/stderr" >&2
  exit 1
fi

worker_log=$(find "$LOG_DIR" -maxdepth 1 -name 'update-community-apps-[0-9]*_[0-9]*.log' -type f | head -1)
[ -n "$worker_log" ] || { echo "No worker log created" >&2; exit 1; }

grep -q 'cron-safe PATH includes /usr/sbin' "$worker_log" || {
  echo "Worker log did not include cron-safe PATH marker" >&2
  cat "$worker_log" >&2
  exit 1
}

echo "ok - worker exports a cron-safe PATH for Proxmox commands"
