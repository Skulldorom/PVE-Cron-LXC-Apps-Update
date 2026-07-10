#!/bin/bash
# update-community-apps.sh — Unattended community-scripts app update + optional notifier
#
# Usage:
#   /usr/local/bin/update-community-apps.sh <container_ids> <backup_storage> [dry-run]
#
# Environment variables:
#   NOTIFY=yes|no    Enable/disable Discord notification (default: yes)
#   NOTIFIER_URL     Override notifier endpoint (default: http://192.168.0.11:6068/api/notify)

set -euo pipefail

CONTAINERS="${1:?Usage: $0 <container_ids> <backup_storage> [dry-run]}"
BACKUP_STORAGE="${2:?Usage: $0 <container_ids> <backup_storage> [dry-run]}"
DRY_RUN=no
NOTIFY="${NOTIFY:-yes}"
NOTIFIER_URL="${NOTIFIER_URL:-http://192.168.0.11:6068/api/notify}"

[ "${3:-}" = "dry-run" ] && DRY_RUN=yes

NODE_NAME="$(hostname -s)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
LOG_FILE="/var/log/update-community-apps-$(date '+%Y%m%d_%H%M%S').log"

if [[ ! "$CONTAINERS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  echo "[ERROR] Container IDs must be a comma-separated list of numeric IDs: $CONTAINERS" >&2
  exit 2
fi

env_args=(
  var_container="$CONTAINERS"
  var_backup=yes
  var_backup_storage="$BACKUP_STORAGE"
  var_unattended=yes
  var_skip_confirm=yes
  var_continue_on_error=yes
  var_auto_reboot=yes
)

[ "$DRY_RUN" = "yes" ] && env_args+=(var_dry_run=yes)

set +e
env "${env_args[@]}" bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh)" 2>&1 | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

# Extract summary table (everything between first and last ━━ separator)
TABLE=$(awk '
  /━━━━/{
    if(!first) first=NR
    last=NR
  }
  {lines[NR]=$0}
  END{
    if(first && last){
      for(i=first;i<=last;i++) print lines[i]
    }
  }
' "$LOG_FILE")

# Fallback: if separator parsing fails (e.g. upstream format change),
# send the last 40 lines so you always get something useful
if [ -z "$TABLE" ]; then
  TABLE=$(tail -40 "$LOG_FILE")
fi

EXIT_INFO=$(grep -E '^(Exit code:|Completed:)' "$LOG_FILE" || true)

# Always print summary to stdout (for cron mail / log capture)
echo "===== Community Apps Update — $NODE_NAME ====="
echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE"
[ "$DRY_RUN" = "yes" ] && echo "Mode: DRY-RUN"
echo ""
[ -n "$TABLE" ] && echo "$TABLE"
[ -n "$EXIT_INFO" ] && echo "$EXIT_INFO"

# Notification (if enabled)
if [ "$NOTIFY" = "yes" ]; then
  TITLE="Community Apps Update — $NODE_NAME"
  [ "$DRY_RUN" = "yes" ] && TITLE="[DRY-RUN] $TITLE"

  MESSAGE="$TABLE"
  [ -n "$EXIT_INFO" ] && MESSAGE="$MESSAGE"$'\n\n'"$EXIT_INFO"

  SEVERITY="info"
  [ $EXIT_CODE -eq 0 ] && SEVERITY="notice"
  [ $EXIT_CODE -gt 0 ] && SEVERITY="error"

  # Post to notifier — log HTTP status on failure so silent drops are visible
  HTTP_CODE=$(jq -n \
    --arg title "$TITLE" \
    --arg msg "$MESSAGE" \
    --arg severity "$SEVERITY" \
    '{title: $title, message: $msg, severity: $severity}' \
    | curl -s -o /dev/null -w '%{http_code}' \
      -X POST -H "Content-Type: application/json" -d @- "$NOTIFIER_URL" 2>/dev/null) || true

  if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "202" ]; then
    echo "[WARN]  Notifier returned HTTP ${HTTP_CODE:-000} — notification may not have been delivered" >&2
  fi
fi

exit $EXIT_CODE
