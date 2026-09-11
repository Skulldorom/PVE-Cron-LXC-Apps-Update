#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN" "$TMPDIR/etc/update-community-apps" "$TMPDIR/usr/local/bin" "$TMPDIR/logrotate"
CRONTAB_FILE="$TMPDIR/root.cron"
LOCAL_SCRIPT="$TMPDIR/usr/local/bin/update-community-apps.sh"
WRAPPER_SCRIPT="$TMPDIR/usr/local/bin/update-community-apps-wrapper.sh"
CONFIG_FILE="$TMPDIR/new-config-dir/update-community-apps.conf"
OLD_CONFIG_FILE="$TMPDIR/etc/update-community-apps/config"
LOG_FILE="$TMPDIR/update-community-apps-cron.log"
LOGROTATE_FILE="$TMPDIR/logrotate/update-community-apps"

touch "$LOCAL_SCRIPT"
cat >"$FAKE_BIN/crontab" <<'CRON'
#!/usr/bin/env bash
set -euo pipefail
file="${FAKE_CRONTAB_FILE:?}"
if [ "${1:-}" = "-l" ]; then
  cat "$file" 2>/dev/null || true
  exit 0
fi
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "root" ] && [ "$#" -eq 2 ]; then
  cat >"$file"
  exit 0
fi
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "root" ] && [ "${3:-}" = "-" ]; then
  cat >"$file"
  exit 0
fi
echo "unsupported crontab invocation: $*" >&2
exit 1
CRON
chmod +x "$FAKE_BIN/crontab"

cat >"$OLD_CONFIG_FILE" <<CFG
CONTAINER_IDS="101,102,105"
BACKUP_STORAGE="pbs-backup"
BACKUP="no"
NOTIFY="no"
DRY_RUN="yes"
AUTO_REBOOT="no"
UPSTREAM_REFRESH="no"
ALLOW_CACHED_UPSTREAM="no"
HEALTHCHECK_URL="https://hc-ping.example.invalid/legacy-check"
CFG
cat >"$CRONTAB_FILE" <<CRON
17 3 * * 2 $WRAPPER_SCRIPT >>$LOG_FILE 2>&1
CRON

run_migrate() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CRONTAB_FILE="$CRONTAB_FILE" \
    UPDATE_COMMUNITY_APPS_LOCAL_SCRIPT="$LOCAL_SCRIPT" \
    UPDATE_COMMUNITY_APPS_WRAPPER_SCRIPT="$WRAPPER_SCRIPT" \
    UPDATE_COMMUNITY_APPS_CONFIG_FILE="$CONFIG_FILE" \
    UPDATE_COMMUNITY_APPS_OLD_CONFIG_FILE="$OLD_CONFIG_FILE" \
    UPDATE_COMMUNITY_APPS_CRON_LOG="$LOG_FILE" \
    UPDATE_COMMUNITY_APPS_LOGROTATE_FILE="$LOGROTATE_FILE" \
    bash "$ROOT/install.sh" --migrate-only >"$TMPDIR/migrate.out" 2>&1
}

run_migrate
[ -f "$CONFIG_FILE" ] || { echo "FAIL: migrated config missing"; exit 1; }
[ -f "$OLD_CONFIG_FILE" ] || { echo "FAIL: legacy config was destructively removed"; exit 1; }
grep -q '^CONTAINERS="101,102,105"$' "$CONFIG_FILE" || { echo "FAIL: containers not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^BACKUP="no"$' "$CONFIG_FILE" || { echo "FAIL: backup not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^BACKUP_STORAGE="pbs-backup"$' "$CONFIG_FILE" || { echo "FAIL: storage not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^NOTIFY="no"$' "$CONFIG_FILE" || { echo "FAIL: notify not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^DRY_RUN="yes"$' "$CONFIG_FILE" || { echo "FAIL: dry-run not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^AUTO_REBOOT="no"$' "$CONFIG_FILE" || { echo "FAIL: auto-reboot not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^UPSTREAM_REFRESH="no"$' "$CONFIG_FILE" || { echo "FAIL: upstream refresh not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^ALLOW_CACHED_UPSTREAM="no"$' "$CONFIG_FILE" || { echo "FAIL: cache policy not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q '^HEALTHCHECK_URL="https://hc-ping.example.invalid/legacy-check"$' "$CONFIG_FILE" || { echo "FAIL: healthcheck URL not preserved"; cat "$CONFIG_FILE"; exit 1; }
grep -q "^17 3 \* \* 2 $LOCAL_SCRIPT >>$LOG_FILE 2>&1$" "$CRONTAB_FILE" || { echo "FAIL: cron not rewritten with exact schedule"; cat "$CRONTAB_FILE"; exit 1; }
! grep -q "$WRAPPER_SCRIPT" "$CRONTAB_FILE" || { echo "FAIL: old wrapper still in cron"; cat "$CRONTAB_FILE"; exit 1; }
first_config_hash=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
first_cron_hash=$(sha256sum "$CRONTAB_FILE" | awk '{print $1}')
cat >"$OLD_CONFIG_FILE" <<CFG
CONTAINER_IDS="999"
BACKUP_STORAGE="changed-storage"
BACKUP="yes"
NOTIFY="yes"
DRY_RUN="no"
AUTO_REBOOT="yes"
UPSTREAM_REFRESH="yes"
ALLOW_CACHED_UPSTREAM="yes"
HEALTHCHECK_URL="https://hc-ping.example.invalid/changed-check"
CFG


run_migrate
second_config_hash=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
second_cron_hash=$(sha256sum "$CRONTAB_FILE" | awk '{print $1}')
[ "$first_config_hash" = "$second_config_hash" ] || { echo "FAIL: migration not config-idempotent"; exit 1; }
[ "$first_cron_hash" = "$second_cron_hash" ] || { echo "FAIL: migration not cron-idempotent"; cat "$CRONTAB_FILE"; exit 1; }
[ "$(grep -c "$LOCAL_SCRIPT" "$CRONTAB_FILE")" -eq 1 ] || { echo "FAIL: duplicate cron entries"; cat "$CRONTAB_FILE"; exit 1; }
[ "$(grep -c '^CONTAINERS=' "$CONFIG_FILE")" -eq 1 ] || { echo "FAIL: duplicate config values"; cat "$CONFIG_FILE"; exit 1; }

echo "ok - legacy migration preserves settings, rewrites cron directly, and is idempotent"
