#!/bin/bash
# update-community-apps.sh — Unattended community-scripts app update + optional notifier
#
# Usage:
#   /usr/local/bin/update-community-apps.sh <container_ids> <backup_storage> [dry-run]
#
# Environment variables:
#   NOTIFY=yes|no    Enable/disable Proxmox notification (default: yes)

set -euo pipefail

CONTAINERS="${1:?Usage: $0 <container_ids> <backup_storage> [dry-run]}"
BACKUP_STORAGE="${2:?Usage: $0 <container_ids> <backup_storage> [dry-run]}"
DRY_RUN=no
NOTIFY="${NOTIFY:-yes}"

[ "${3:-}" = "dry-run" ] && DRY_RUN=yes

NODE_NAME="$(hostname -s)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
LOG_FILE="/var/log/update-community-apps-$(date '+%Y%m%d_%H%M%S').log"

# Accept IDs separated by commas and/or whitespace. Whiptail checklists return
# multiple selections as a space-separated list, while cron entries are stored as
# comma-separated lists. Normalize both forms before passing them upstream.
CONTAINERS=$(echo "$CONTAINERS" | tr '[:space:]' ',' | sed -E 's/,+/,/g; s/^,//; s/,$//')

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
tmp="$(mktemp)"
if ! curl -fsSL -o "$tmp" https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh; then
  echo "[ERROR] Failed to download upstream update script"
  echo "[ERROR] Failed to download upstream update script" >&2
  echo "[ERROR] Failed to download upstream update script" >> "$LOG_FILE"
  EXIT_CODE=1
  rm -f "$tmp"
else
  env "${env_args[@]}" bash "$tmp" 2>&1 | tee "$LOG_FILE"
  EXIT_CODE=${PIPESTATUS[0]}
  rm -f "$tmp"
fi
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
echo "===== Community Apps Update — $NODE_NAME — $TIMESTAMP ====="
echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE"
[ "$DRY_RUN" = "yes" ] && echo "Mode: DRY-RUN"
echo ""
[ -n "$TABLE" ] && echo "$TABLE"
[ -n "$EXIT_INFO" ] && echo "$EXIT_INFO"

# Notification (if enabled)
if [ "$NOTIFY" = "yes" ]; then
  TITLE="Community Apps Update — $NODE_NAME — $TIMESTAMP"
  [ "$DRY_RUN" = "yes" ] && TITLE="[DRY-RUN] $TITLE"

  MESSAGE="$TABLE"
  [ -n "$EXIT_INFO" ] && MESSAGE="$MESSAGE"$'\n\n'"$EXIT_INFO"

  SEVERITY="info"
  [ "$EXIT_CODE" -gt 0 ] && SEVERITY="error"

  # Send via Proxmox VE's default notification pipeline. This respects the
  # node/datacenter notification targets and matchers instead of posting to a
  # custom webhook URL. The custom "simple" template is installed on demand
  # because PVE::Notify requires a renderable subject/body template for each
  # notification name before any target (including webhook targets) can receive
  # the message.
  TEMPLATE_DIR="/etc/pve/notification-templates/default"
  if mkdir -p "$TEMPLATE_DIR" 2>/dev/null; then
    [ -f "$TEMPLATE_DIR/simple-subject.txt.hbs" ] || printf '%s\n' '{{ title }}' > "$TEMPLATE_DIR/simple-subject.txt.hbs"
    [ -f "$TEMPLATE_DIR/simple-body.txt.hbs" ] || printf '%s\n' '{{ message }}' > "$TEMPLATE_DIR/simple-body.txt.hbs"
    [ -f "$TEMPLATE_DIR/simple-body.html.hbs" ] || printf '%s\n' '<pre>{{ message }}</pre>' > "$TEMPLATE_DIR/simple-body.html.hbs"
  else
    echo "[WARN]  Could not create Proxmox notification template directory: $TEMPLATE_DIR" >&2
  fi

  if ! TITLE="$TITLE" MESSAGE="$MESSAGE" SEVERITY="$SEVERITY" perl -MPVE::Notify -e '
    my $common = PVE::Notify::common_template_data();
    my $data = {
      %$common,
      title => $ENV{TITLE} // "",
      message => $ENV{MESSAGE} // "",
    };
    my $fields = { origin => "update-community-apps" };
    PVE::Notify::notify($ENV{SEVERITY} // "info", "simple", $data, $fields);
  '; then
    echo "[WARN]  Proxmox notification delivery failed" >&2
  fi
fi

exit $EXIT_CODE
