#!/bin/bash
# update-community-apps.sh — Unattended community-scripts app update + optional notifier
#
# Usage:
#   /usr/local/bin/update-community-apps.sh <container_ids> <backup_storage> [dry-run]
#
# Environment variables:
#   NOTIFY=yes|no    Enable/disable Proxmox notification (default: yes)
#   BACKUP=yes|no    Enable/disable pre-update vzdump backups (default: yes)

# No 'set -e' — we handle exit codes explicitly so downstream processing
# (summary parsing, notification, status file) always runs even when the
# upstream script fails on individual containers.
set -uo pipefail

CONTAINERS="${1:?Usage: $0 <container_ids> <backup_storage> [dry-run]}"
BACKUP_STORAGE="${2:?Usage: $0 <container_ids> <backup_storage> [dry-run]}"
DRY_RUN=no
NOTIFY="${NOTIFY:-yes}"
BACKUP="${BACKUP:-yes}"

[ "${3:-}" = "dry-run" ] && DRY_RUN=yes

NODE_NAME="$(hostname -s)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
TIMESTAMP_FILE="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="/var/log/update-community-apps-${TIMESTAMP_FILE}.log"
LOG_FILE_CLEAN="/var/log/update-community-apps-${TIMESTAMP_FILE}-clean.log"
STATUS_FILE="/var/log/update-community-apps-last-status"

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
  var_backup="$BACKUP"
  var_backup_storage="$BACKUP_STORAGE"
  var_unattended=yes
  var_skip_confirm=yes
  var_continue_on_error=yes
  var_auto_reboot=yes
)

[ "$DRY_RUN" = "yes" ] && env_args+=(var_dry_run=yes)

# ── Run upstream update script ────────────────────────────────────────────────
# Capture the exit code explicitly rather than relying on set -e, so downstream
# processing always runs (summary parsing, notification, status file) even when
# the upstream script fails on individual containers.
EXIT_CODE=0
tmp="$(mktemp)"
if ! curl -fsSL -o "$tmp" https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh; then
  echo "[ERROR] Failed to download upstream update script" | tee -a "$LOG_FILE" >&2
  EXIT_CODE=1
  rm -f "$tmp"
else
  env "${env_args[@]}" bash "$tmp" 2>&1 | tee "$LOG_FILE" || true
  EXIT_CODE=${PIPESTATUS[0]}
  rm -f "$tmp"
fi

# ── Produce a clean readable log (I2 fix) ─────────────────────────────────────
# The upstream script writes terminal escape codes, ANSI sequences, redraws,
# and banners to stdout. The raw log is preserved for debugging, but we also
# produce a clean version that is safe to cat / view / grep.
sanitize_log_for_file() {
  LC_ALL=C.UTF-8 perl -CSDA -0pe '
    s/\e\][^\a]*(?:\a|\e\\)//g;
    s/\e[PX^_].*?\e\\//gs;
    s/\e\[[0-?]*[ -\/]*[@-~]//g;
    s/\e[()][0-2A-Z]//g;
    s/\r\n/\n/g;
    s/\r/\n/g;
    s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
  '
}

if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
  sanitize_log_for_file < "$LOG_FILE" > "$LOG_FILE_CLEAN" 2>/dev/null || true
fi

# ── Extract summary table (I1 fix: guarded) ───────────────────────────────────
# Use the clean log for extraction to avoid escape-sequence interference.
LOG_FOR_PARSE="${LOG_FILE_CLEAN}"
[ -s "$LOG_FOR_PARSE" ] || LOG_FOR_PARSE="$LOG_FILE"

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
' "$LOG_FOR_PARSE" 2>/dev/null || true)

# Fallback: if separator parsing fails (e.g. upstream format change),
# send the last 40 lines so you always get something useful
if [ -z "$TABLE" ]; then
  TABLE=$(tail -40 "$LOG_FOR_PARSE" 2>/dev/null || true)
fi

EXIT_INFO=$(grep -E '^(Exit code:|Completed:)' "$LOG_FOR_PARSE" 2>/dev/null || true)

# Build a copy of the run log without the ending summary table. The summary is
# already included at the top of the notification, so excluding the final table
# keeps notification payloads concise while preserving the actionable run output.
LOG_WITHOUT_SUMMARY=$(awk '
  /━━━━/{
    if(!first) first=NR
    last=NR
  }
  {lines[NR]=$0}
  END{
    for(i=1;i<=NR;i++){
      if(first && last && i>=first && i<=last) continue
      print lines[i]
    }
  }
' "$LOG_FOR_PARSE" 2>/dev/null || true)

# ── Write last-run status file (I3 fix) ───────────────────────────────────────
# Provides a machine-readable status that the installer's Status menu reads.
# Also useful for monitoring scripts and debugging.
CONTAINER_COUNT=$(echo "$CONTAINERS" | tr ',' '\n' | wc -l)
ERROR_COUNT=$(grep -c 'exit code [1-9]' "$LOG_FOR_PARSE" 2>/dev/null || echo 0)

{
  echo "exit_code=${EXIT_CODE}"
  echo "timestamp=${TIMESTAMP}"
  echo "node=${NODE_NAME}"
  echo "containers=${CONTAINERS}"
  echo "container_count=${CONTAINER_COUNT}"
  echo "backup_storage=${BACKUP_STORAGE}"
  echo "backup_enabled=${BACKUP}"
  echo "dry_run=${DRY_RUN}"
  echo "notify=${NOTIFY}"
  echo "errors_count=${ERROR_COUNT}"
  echo "log_file=${LOG_FILE}"
  echo "log_file_clean=${LOG_FILE_CLEAN}"
} > "$STATUS_FILE" 2>/dev/null || true

# Proxmox webhook notification templates can be rendered or consumed by targets
# that do not preserve UTF-8 correctly. Keep notification title/body ASCII-only
# so em dashes and box-drawing table borders do not arrive as mojibake.
ascii_for_notification() {
  LC_ALL=C.UTF-8 perl -CSDA -0pe '
    s/\x{2014}|\x{2013}/-/g;
    s/[\x{2500}-\x{257F}]/-/g;
    s/[^\x09\x0A\x0D\x20-\x7E]/?/g;
  '
}

# Convert the raw upstream TTY-style log into notification-friendly text. The
# upstream script redraws status lines and clears the terminal while scanning,
# which is useful interactively but produces noisy escape sequences and repeated
# banners in notifications. Keep the actionable progress lines and final log path.
sanitize_log_for_notification() {
  LC_ALL=C.UTF-8 perl -CSDA -0pe '
    s/\e\][^\a]*(?:\a|\e\\)//g;
    s/\e[PX^_].*?\e\\//gs;
    s/\e\[[0-?]*[ -\/]*[@-~]//g;
    s/\e[()][0-2A-Z]//g;
    s/\r/\n/g;
    s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
  ' | awk '
    function flush_blank() {
      if (started && pending_blank) { print ""; pending_blank=0 }
    }
    /^ *(__|\/ \/|\/_____)/ { next }
    /\/____/ { next }
    /^ *\/_\/ *$/ { next }
    /Loading all possible LXC containers from Proxmox VE/ { next }
    /^Loaded [0-9]+ containers$/ { next }
    /^$/ {
      if (started) pending_blank=1
      next
    }
    {
      if (last_selected && /^\[INFO\]/) pending_blank=1
      flush_blank()
      print
      last_selected = /^Selected containers:/
      started=1
    }
  '
}

# Always print summary to stdout (for cron mail / log capture)
echo "===== Community Apps Update - $NODE_NAME - $TIMESTAMP ====="
echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE | Backup enabled: $BACKUP"
[ "$DRY_RUN" = "yes" ] && echo "Mode: DRY-RUN"
echo ""
[ -n "$TABLE" ] && echo "$TABLE"
[ -n "$EXIT_INFO" ] && echo "$EXIT_INFO"
echo ""
echo "Log: $LOG_FILE"
echo "Clean log: $LOG_FILE_CLEAN"

# Notification (if enabled)
if [ "$NOTIFY" = "yes" ]; then
  TITLE="Community Apps Update - $NODE_NAME - $TIMESTAMP"
  [ "$DRY_RUN" = "yes" ] && TITLE="[DRY-RUN] $TITLE"

  NOTIFICATION_BODY=$(mktemp)
  {
    echo "===== Community Apps Update - $NODE_NAME - $TIMESTAMP ====="
    echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE"
    [ "$DRY_RUN" = "yes" ] && echo "Mode: DRY-RUN"
    echo ""
    echo "===== Summary ====="
    [ -n "$TABLE" ] && echo "$TABLE"
    [ -n "$EXIT_INFO" ] && echo "$EXIT_INFO"
    echo ""
    echo "===== Log Output ====="
    echo ""
    if [ -n "$LOG_WITHOUT_SUMMARY" ]; then
      echo "$LOG_WITHOUT_SUMMARY"
    else
      cat "$LOG_FILE" 2>/dev/null || true
    fi | sanitize_log_for_notification
  } | ascii_for_notification > "$NOTIFICATION_BODY" 2>/dev/null || true

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

  if ! TITLE="$TITLE" MESSAGE_FILE="$NOTIFICATION_BODY" SEVERITY="$SEVERITY" perl -MPVE::Notify -e '
    my $message = "";
    if (defined $ENV{MESSAGE_FILE} && open(my $fh, "<", $ENV{MESSAGE_FILE})) {
      local $/;
      $message = <$fh> // "";
      close($fh);
    }
    my $common = PVE::Notify::common_template_data();
    my $data = {
      %$common,
      title => $ENV{TITLE} // "",
      message => $message,
    };
    my $fields = { origin => "update-community-apps" };
    PVE::Notify::notify($ENV{SEVERITY} // "info", "simple", $data, $fields);
  ' 2>/dev/null; then
    echo "[WARN]  Proxmox notification delivery failed" >&2
  fi
  rm -f "$NOTIFICATION_BODY"
fi

exit $EXIT_CODE
