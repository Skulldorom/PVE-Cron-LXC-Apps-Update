#!/bin/bash
# update-community-apps.sh — Unattended community-scripts app update + optional notifier
#
# Usage:
#   /usr/local/bin/update-community-apps.sh <container_ids> [backup_storage] [dry-run]
#
# Environment variables:
#   NOTIFY=yes|no    Enable/disable Proxmox notification (default: yes)
#   BACKUP=yes|no    Enable/disable pre-update vzdump backups (default: yes)
#
# backup_storage is required when BACKUP=yes and ignored when BACKUP=no.

# No 'set -e' — we handle exit codes explicitly so downstream processing
# (summary parsing, notification, status file) always runs even when the
# upstream script fails on individual containers.
set -uo pipefail

CONTAINERS="${1:?Usage: $0 <container_ids> [backup_storage] [dry-run]}"
BACKUP_STORAGE="${2:-}"
DRY_RUN=no
NOTIFY="${NOTIFY:-yes}"
BACKUP="${BACKUP:-yes}"

if [ "${2:-}" = "dry-run" ]; then
  DRY_RUN=yes
  BACKUP_STORAGE=""
elif [ "${3:-}" = "dry-run" ]; then
  DRY_RUN=yes
fi

if [ "$BACKUP" = "yes" ] && [ -z "$BACKUP_STORAGE" ]; then
  echo "[ERROR] Backup storage is required when BACKUP=yes" >&2
  exit 2
fi

NODE_NAME="$(hostname -s)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
TIMESTAMP_FILE="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="/var/log/update-community-apps-${TIMESTAMP_FILE}.log"
STATUS_FILE="/var/log/update-community-apps-last-status"
MAX_WORKER_LOG_BYTES="${MAX_WORKER_LOG_BYTES:-10485760}"
MAX_UPSTREAM_CAPTURE_BYTES="${MAX_UPSTREAM_CAPTURE_BYTES:-1048576}"

case "$MAX_WORKER_LOG_BYTES" in
  ''|*[!0-9]*) MAX_WORKER_LOG_BYTES=10485760 ;;
esac
case "$MAX_UPSTREAM_CAPTURE_BYTES" in
  ''|*[!0-9]*) MAX_UPSTREAM_CAPTURE_BYTES=1048576 ;;
esac
[ "$MAX_WORKER_LOG_BYTES" -lt 4096 ] && MAX_WORKER_LOG_BYTES=4096
[ "$MAX_UPSTREAM_CAPTURE_BYTES" -lt 4096 ] && MAX_UPSTREAM_CAPTURE_BYTES=4096

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
  var_unattended=yes
  var_skip_confirm=yes
  var_continue_on_error=yes
  var_auto_reboot=yes
)

[ "$BACKUP" = "yes" ] && env_args+=(var_backup_storage="$BACKUP_STORAGE")
[ "$DRY_RUN" = "yes" ] && env_args+=(var_dry_run=yes)

# ── Run upstream update script ────────────────────────────────────────────────
# Capture the exit code explicitly rather than relying on set -e, so downstream
# processing always runs (summary parsing, notification, status file) even when
# the upstream script fails on individual containers.
EXIT_CODE=0
tmp="$(mktemp)"
UPSTREAM_OUTPUT="$(mktemp)"
if ! curl -fsSL -o "$tmp" https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh; then
  echo "[ERROR] Failed to download upstream update script" | tee -a "$LOG_FILE" >&2
  EXIT_CODE=1
  rm -f "$tmp" "$UPSTREAM_OUTPUT"
else
  # Capture only the tail of upstream's noisy TTY-style stream. The useful
  # upstream "Full log:" pointer is printed at the end, and tail -c keeps the
  # temporary capture bounded even if spinner output goes feral mid-run.
  env "${env_args[@]}" bash "$tmp" 2>&1 | tail -c "$MAX_UPSTREAM_CAPTURE_BYTES" >"$UPSTREAM_OUTPUT"
  EXIT_CODE=${PIPESTATUS[0]}
  rm -f "$tmp"
fi

# ── Produce a clean readable log (I2 fix) ─────────────────────────────────────
# The upstream script writes terminal escape codes, ANSI sequences, redraws,
# and banners to stdout. Keep only a clean persisted log that is safe to
# cat / view / grep.
dedupe_log_redraws() {
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function normalize(value) {
      value = trim(value)
      gsub(/[[:space:]]+/, " ", value)
      return value
    }
    {
      normalized = normalize($0)
      if (normalized != "" && normalized == last_normalized) next
      last_normalized = normalized
      print
    }
  '
}

sanitize_log_for_file() {
  LC_ALL=C.UTF-8 perl -CSDA -0pe '
    s/\e\][^\a]*(?:\a|\e\\)//g;
    s/\e[PX^_].*?\e\\//gs;
    s/\e\[[0-?]*[ -\/]*[@-~]//g;
    s/\e[()][0-2A-Z]//g;
    s/\r\n/\n/g;
    s/\r/\n/g;
    s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
    # Canonicalize Braille spinner frames before awk dedupe so rotating
    # progress redraws compare as the same normalized line.
    s/^([ \t]*)[\x{280B}\x{2819}\x{2839}\x{2838}\x{283C}\x{2834}\x{2826}\x{2827}\x{2807}\x{280F}]([ \t]+)/${1}⠋${2}/gm;
  ' | dedupe_log_redraws
}

write_capped_clean_log() {
  local source="$1" dest="$2" size head_bytes tail_bytes tmp_dest
  tmp_dest="$(mktemp)"
  size=$(wc -c < "$source" 2>/dev/null || echo 0)

  if [ "$size" -le "$MAX_WORKER_LOG_BYTES" ]; then
    sanitize_log_for_file < "$source" > "$tmp_dest" 2>/dev/null || true
  else
    head_bytes=$(((MAX_WORKER_LOG_BYTES - 2048) / 2))
    tail_bytes=$head_bytes
    [ "$head_bytes" -lt 1024 ] && head_bytes=1024
    [ "$tail_bytes" -lt 1024 ] && tail_bytes=1024
    {
      echo "[WARN] Log truncated by update-community-apps.sh to stay within ${MAX_WORKER_LOG_BYTES} bytes."
      echo "[WARN] Original source log size: ${size} bytes. Showing first ${head_bytes} bytes and last ${tail_bytes} bytes."
      echo ""
      head -c "$head_bytes" "$source" | sanitize_log_for_file
      echo ""
      echo "[WARN] ... middle of log omitted due to size cap ..."
      echo ""
      tail -c "$tail_bytes" "$source" | sanitize_log_for_file
    } > "$tmp_dest" 2>/dev/null || true
  fi

  # Final hard cap after sanitization and warning text. If a pathological input
  # still expands past the limit, keep the tail containing the final summary.
  if [ -s "$tmp_dest" ] && [ "$(wc -c < "$tmp_dest")" -gt "$MAX_WORKER_LOG_BYTES" ]; then
    tail -c "$MAX_WORKER_LOG_BYTES" "$tmp_dest" > "$dest" 2>/dev/null || true
    rm -f "$tmp_dest"
  else
    mv "$tmp_dest" "$dest" 2>/dev/null || rm -f "$tmp_dest"
  fi
}

if [ -f "$UPSTREAM_OUTPUT" ] && [ -s "$UPSTREAM_OUTPUT" ]; then
  UPSTREAM_FULL_LOG=$(awk -F'Full log: ' '/Full log: / { value=$2 } END { print value }' "$UPSTREAM_OUTPUT" 2>/dev/null | tr -d '\r' || true)
  if [ -n "$UPSTREAM_FULL_LOG" ] && [ -r "$UPSTREAM_FULL_LOG" ]; then
    write_capped_clean_log "$UPSTREAM_FULL_LOG" "$LOG_FILE"
  else
    # Fallback for upstream format changes or missing files: keep a readable log
    # rather than no log at all.
    write_capped_clean_log "$UPSTREAM_OUTPUT" "$LOG_FILE"
  fi
fi
rm -f "$UPSTREAM_OUTPUT"

# ── Extract summary table (I1 fix: guarded) ───────────────────────────────────
# Use the clean log for extraction to avoid escape-sequence interference.
LOG_FOR_PARSE="${LOG_FILE}"

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
  echo "max_worker_log_bytes=${MAX_WORKER_LOG_BYTES}"
  echo "max_upstream_capture_bytes=${MAX_UPSTREAM_CAPTURE_BYTES}"
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
    s/\r\n/\n/g;
    s/\r/\n/g;
    s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
    # Canonicalize Braille spinner frames before awk dedupe so rotating
    # progress redraws compare as the same normalized line.
    s/^([ \t]*)[\x{280B}\x{2819}\x{2839}\x{2838}\x{283C}\x{2834}\x{2826}\x{2827}\x{2807}\x{280F}]([ \t]+)/${1}⠋${2}/gm;
  ' | awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function normalize(value) {
      value = trim(value)
      gsub(/[[:space:]]+/, " ", value)
      return value
    }
    function flush_blank() {
      if (started && pending_blank) { print ""; pending_blank=0 }
    }
    /^ *(__|\/ \/|\/_____)/ { next }
    /\/____/ { next }
    /^ *\/_\/ *$/ { next }
    /^ *[_\/]/ && /(__|___|\\|`)/ { next }
    /Loading all possible LXC containers from Proxmox VE/ { next }
    /^Loaded [0-9]+ containers$/ { next }
    /^$/ {
      if (started) pending_blank=1
      next
    }
    {
      normalized = normalize($0)

      # Upstream helper scripts redraw spinner/progress lines in-place. Once
      # carriage returns are converted for notifications, those redraws become
      # hundreds of identical lines. Keep the first copy and drop consecutive
      # duplicates so the notification stays readable instead of weaponized.
      if (normalized == last_normalized) next
      last_normalized = normalized

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
if [ "$BACKUP" = "yes" ]; then
  echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE | Backup enabled: yes"
else
  echo "Containers: $CONTAINERS | Backup: disabled"
fi
[ "$DRY_RUN" = "yes" ] && echo "Mode: DRY-RUN"
echo ""
[ -n "$TABLE" ] && echo "$TABLE"
[ -n "$EXIT_INFO" ] && echo "$EXIT_INFO"
echo ""
echo "Log: $LOG_FILE"

# Notification (if enabled)
if [ "$NOTIFY" = "yes" ]; then
  TITLE="Community Apps Update - $NODE_NAME - $TIMESTAMP"
  [ "$DRY_RUN" = "yes" ] && TITLE="[DRY-RUN] $TITLE"

  NOTIFICATION_BODY=$(mktemp)
  {
    echo "===== Community Apps Update - $NODE_NAME - $TIMESTAMP ====="
    if [ "$BACKUP" = "yes" ]; then
      echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE"
    else
      echo "Containers: $CONTAINERS | Backup: disabled"
    fi
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
