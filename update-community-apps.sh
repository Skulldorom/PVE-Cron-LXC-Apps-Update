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

# Cron often runs with a tiny PATH that omits /usr/sbin, where Proxmox
# commands such as pct and vzdump live. Export a Proxmox-safe PATH before
# downloading/running the upstream updater so scheduled runs behave like
# root's interactive shell.
PATH="${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

CONFIG_FILE="${UPDATE_COMMUNITY_APPS_CONFIG_FILE:-/etc/update-community-apps.conf}"
CONTAINERS=""
BACKUP_STORAGE=""
DRY_RUN=no
NOTIFY="${NOTIFY:-yes}"
BACKUP="${BACKUP:-yes}"
AUTO_REBOOT="${AUTO_REBOOT:-yes}"
UPSTREAM_REFRESH="${UPSTREAM_REFRESH:-yes}"
ALLOW_CACHED_UPSTREAM="${ALLOW_CACHED_UPSTREAM:-yes}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
REFRESH_ONLY=no
STATUS_ONLY=no
CLI_DRY_RUN=no
CLI_HAS_CONTAINERS=no
CLI_CONTAINERS=""
CLI_BACKUP_STORAGE=""
CLI_BACKUP_STORAGE_SET=no
CONFIG_LOAD_ERROR=""
CONFIG_WARNINGS=()

normalize_bool() {
  case "${1:-}" in
    yes|YES|true|TRUE|1|on|ON) echo yes ;;
    no|NO|false|FALSE|0|off|OFF) echo no ;;
    *) return 1 ;;
  esac
}

normalize_container_list() {
  echo "$1" | tr '[:space:]' ',' | sed -E 's/,+/,/g; s/^,//; s/,$//'
}

valid_storage() { [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]]; }
valid_url_or_empty() { [[ -z "$1" || "$1" =~ ^https?://[^[:space:]]+$ ]]; }

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local line key value bool
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line=$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { CONFIG_LOAD_ERROR="Malformed config line: $line"; echo "[ERROR] $CONFIG_LOAD_ERROR" >&2; return 2; }
    key="${line%%=*}"
    value="${line#*=}"
    value=$(echo "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//')
    case "$key" in
      CONTAINERS|CONTAINER_IDS) CONTAINERS=$(normalize_container_list "$value") ;;
      BACKUP|NOTIFY|AUTO_REBOOT|UPSTREAM_REFRESH|ALLOW_CACHED_UPSTREAM|DRY_RUN)
        printf -v "$key" '%s' "$value"
        ;;
      BACKUP_STORAGE) BACKUP_STORAGE="$value" ;;
      HEALTHCHECK_URL) HEALTHCHECK_URL="$value" ;;
    esac
  done <"$CONFIG_FILE"
}

case "${1:-}" in
  --refresh-upstream-cache) REFRESH_ONLY=yes ;;
  --status) STATUS_ONLY=yes ;;
  --dry-run) CLI_DRY_RUN=yes ;;
  --help|-h) echo "Usage: $0 [--dry-run|--status|--refresh-upstream-cache] [container_ids] [backup_storage] [dry-run]"; exit 0 ;;
  *)
    if [ "$#" -gt 0 ]; then
      CLI_HAS_CONTAINERS=yes
      CLI_CONTAINERS="$1"
      CLI_BACKUP_STORAGE="${2:-}"
      CLI_BACKUP_STORAGE_SET=yes
      [ "${2:-}" = "dry-run" ] && { CLI_DRY_RUN=yes; CLI_BACKUP_STORAGE=""; CLI_BACKUP_STORAGE_SET=no; }
      [ "${3:-}" = "dry-run" ] && CLI_DRY_RUN=yes
    fi
    ;;
esac

load_config_status=0
load_config || load_config_status=$?
if [ "$load_config_status" -ne 0 ] && [ "$STATUS_ONLY" != yes ]; then
  exit "$load_config_status"
fi
# Effective precedence: built-in defaults < environment/default variables < config < explicit CLI arguments.
if [ "$CLI_HAS_CONTAINERS" = yes ]; then
  CONTAINERS="$CLI_CONTAINERS"
fi
if [ "$CLI_BACKUP_STORAGE_SET" = yes ]; then
  BACKUP_STORAGE="$CLI_BACKUP_STORAGE"
fi
if [ "$CLI_DRY_RUN" = yes ]; then
  DRY_RUN=yes
fi

NODE_NAME="$(hostname -s)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
TIMESTAMP_FILE="$(date '+%Y%m%d_%H%M%S')"
LOG_DIR="${UPDATE_COMMUNITY_APPS_LOG_DIR:-/var/log}"
STATUS_FILE="${UPDATE_COMMUNITY_APPS_STATUS_FILE:-${LOG_DIR}/update-community-apps-last-status}"
UPSTREAM_LOG_DIR="${UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR:-/usr/local/community-scripts/update_apps}"
UPSTREAM_SCRIPT_URL="${UPDATE_COMMUNITY_APPS_UPSTREAM_SCRIPT_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh}"
CACHE_DIR="${UPDATE_COMMUNITY_APPS_CACHE_DIR:-/usr/local/lib/update-community-apps}"
CACHE_FILE="${UPDATE_COMMUNITY_APPS_CACHE_FILE:-${CACHE_DIR}/update-apps.sh}"
CACHE_META="${UPDATE_COMMUNITY_APPS_CACHE_META:-${CACHE_DIR}/update-apps.meta}"
LOCK_FILE="${UPDATE_COMMUNITY_APPS_LOCK_FILE:-/run/update-community-apps.lock}"
UPSTREAM_USED=none
UPSTREAM_SHA256=""
UPSTREAM_REFRESH_STATUS=not_attempted
UPSTREAM_CACHE_AGE=""
LOG_FILE="${LOG_DIR}/update-community-apps-${TIMESTAMP_FILE}.log"
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
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Accept IDs separated by commas and/or whitespace. Whiptail checklists return
# multiple selections as a space-separated list, while cron entries are stored as
# comma-separated lists. Normalize both forms before passing them upstream.
CONTAINERS=$(echo "$CONTAINERS" | tr '[:space:]' ',' | sed -E 's/,+/,/g; s/^,//; s/,$//')

add_config_warning() { CONFIG_WARNINGS+=("$1"); }

# Validate according to execution mode. Status is diagnostic: broken config is
# reported in its output instead of aborting the command. Cache refresh only
# checks what it actually needs. Normal and dry-run updates stay strict.
if [ "$STATUS_ONLY" = yes ]; then
  [ "$load_config_status" -eq 0 ] || add_config_warning "$CONFIG_LOAD_ERROR"
  if [ -n "$CONTAINERS" ] && [[ ! "$CONTAINERS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    add_config_warning "Container IDs must be a comma-separated list of numeric IDs: $CONTAINERS"
  fi
  backup_status=$(normalize_bool "$BACKUP") || backup_status=invalid
  notify_status=$(normalize_bool "$NOTIFY") || notify_status=invalid
  auto_reboot_status=$(normalize_bool "$AUTO_REBOOT") || auto_reboot_status=invalid
  upstream_refresh_status_config=$(normalize_bool "$UPSTREAM_REFRESH") || upstream_refresh_status_config=invalid
  allow_cached_status=$(normalize_bool "$ALLOW_CACHED_UPSTREAM") || allow_cached_status=invalid
  dry_run_status=$(normalize_bool "$DRY_RUN") || dry_run_status=invalid
  [ "$backup_status" != invalid ] || add_config_warning "Invalid BACKUP value"
  [ "$notify_status" != invalid ] || add_config_warning "Invalid NOTIFY value"
  [ "$auto_reboot_status" != invalid ] || add_config_warning "Invalid AUTO_REBOOT value"
  [ "$upstream_refresh_status_config" != invalid ] || add_config_warning "Invalid UPSTREAM_REFRESH value"
  [ "$allow_cached_status" != invalid ] || add_config_warning "Invalid ALLOW_CACHED_UPSTREAM value"
  [ "$dry_run_status" != invalid ] || add_config_warning "Invalid DRY_RUN value"
  if [ "$backup_status" = yes ] && { [ -z "$BACKUP_STORAGE" ] || ! valid_storage "$BACKUP_STORAGE"; }; then
    add_config_warning "Backup storage is required when BACKUP=yes"
  fi
  valid_url_or_empty "$HEALTHCHECK_URL" || add_config_warning "Invalid HEALTHCHECK_URL"
elif [ "$REFRESH_ONLY" = yes ]; then
  # Only the settings used to download/validate the upstream script matter here.
  [[ "$UPSTREAM_SCRIPT_URL" =~ ^https?://[^[:space:]]+$ ]] || { echo "[ERROR] Invalid upstream script URL" >&2; exit 2; }
else
  if [[ ! "$CONTAINERS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    echo "[ERROR] Container IDs must be a comma-separated list of numeric IDs: $CONTAINERS" >&2
    exit 2
  fi
  BACKUP=$(normalize_bool "$BACKUP") || { echo "[ERROR] Invalid BACKUP value" >&2; exit 2; }
  NOTIFY=$(normalize_bool "$NOTIFY") || { echo "[ERROR] Invalid NOTIFY value" >&2; exit 2; }
  AUTO_REBOOT=$(normalize_bool "$AUTO_REBOOT") || { echo "[ERROR] Invalid AUTO_REBOOT value" >&2; exit 2; }
  UPSTREAM_REFRESH=$(normalize_bool "$UPSTREAM_REFRESH") || { echo "[ERROR] Invalid UPSTREAM_REFRESH value" >&2; exit 2; }
  ALLOW_CACHED_UPSTREAM=$(normalize_bool "$ALLOW_CACHED_UPSTREAM") || { echo "[ERROR] Invalid ALLOW_CACHED_UPSTREAM value" >&2; exit 2; }
  DRY_RUN=$(normalize_bool "$DRY_RUN") || { echo "[ERROR] Invalid DRY_RUN value" >&2; exit 2; }
  if [ "$BACKUP" = "yes" ] && { [ -z "$BACKUP_STORAGE" ] || ! valid_storage "$BACKUP_STORAGE"; }; then
    echo "[ERROR] Backup storage is required when BACKUP=yes" >&2
    exit 2
  fi
  valid_url_or_empty "$HEALTHCHECK_URL" || { echo "[ERROR] Invalid HEALTHCHECK_URL" >&2; exit 2; }
fi

env_args=(
  var_container="$CONTAINERS"
  var_backup="$BACKUP"
  var_unattended=yes
  var_skip_confirm=yes
  var_continue_on_error=yes
  var_auto_reboot="$AUTO_REBOOT"
)

[ "$BACKUP" = "yes" ] && env_args+=(var_backup_storage="$BACKUP_STORAGE")
[ "$DRY_RUN" = "yes" ] && env_args+=(var_dry_run=yes)

# ── Upstream cache (last-known-good update-apps.sh) ─────────────────────────
sha_file() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
script_sanity_valid() {
  [ -s "$1" ] || return 1
  head -n 5 "$1" | grep -Eq '^#!.*(bash|sh)' || return 1
  grep -Eq '^[[:space:]]*<html' "$1" && return 1
  bash -n "$1" >/dev/null 2>&1
}
cache_age_seconds() { [ -f "$CACHE_FILE" ] || return 1; echo $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))); }
write_cache_meta() {
  local tmp
  mkdir -p "$CACHE_DIR" || return 1
  tmp=$(mktemp "${CACHE_META}.tmp.XXXXXX") || return 1
  {
    echo "source_url=$UPSTREAM_SCRIPT_URL"
    echo "sha256=$1"
    echo "refreshed_at=$(date '+%Y-%m-%d %H:%M:%S')"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$CACHE_META"
}
refresh_upstream_cache() {
  local tmp old new
  mkdir -p "$CACHE_DIR" || return 1
  tmp=$(mktemp "${CACHE_DIR}/update-apps.tmp.XXXXXX") || return 1
  if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 3 -o "$tmp" "$UPSTREAM_SCRIPT_URL"; then
    rm -f "$tmp"; return 1
  fi
  script_sanity_valid "$tmp" || { rm -f "$tmp"; return 1; }
  new=$(sha_file "$tmp")
  old=""; [ -f "$CACHE_FILE" ] && old=$(sha_file "$CACHE_FILE")
  chmod 0755 "$tmp"
  if [ "$new" = "$old" ]; then rm -f "$tmp"; else mv -f "$tmp" "$CACHE_FILE" || { rm -f "$tmp"; return 1; }; fi
  write_cache_meta "$new" || true
  UPSTREAM_SHA256="$new"
}
select_upstream_script() {
  if [ "$UPSTREAM_REFRESH" = yes ]; then
    append_worker_log_note "Refreshing upstream cache"
    if refresh_upstream_cache; then
      UPSTREAM_USED=fresh; UPSTREAM_REFRESH_STATUS=success
      append_worker_log_note "Upstream refresh successful"
      append_worker_log_note "Upstream SHA256: $UPSTREAM_SHA256"
      append_worker_log_note "Using freshly downloaded upstream"
      return 0
    fi
    UPSTREAM_REFRESH_STATUS=failed
    append_worker_log_note "WARNING: upstream refresh failed"
  else
    UPSTREAM_REFRESH_STATUS=disabled
    append_worker_log_note "Upstream refresh disabled by configuration"
  fi

  if [ "$ALLOW_CACHED_UPSTREAM" != yes ]; then
    echo "[ERROR] Cached upstream fallback is disabled and no fresh upstream is available" | tee -a "$LOG_FILE" >&2
    return 1
  fi

  if script_sanity_valid "$CACHE_FILE"; then
    UPSTREAM_USED=cached
    UPSTREAM_SHA256=$(sha_file "$CACHE_FILE")
    UPSTREAM_CACHE_AGE=$(cache_age_seconds || echo unknown)
    if [ "$UPSTREAM_REFRESH_STATUS" = disabled ]; then
      append_worker_log_note "Using cached update-apps.sh because upstream refresh is disabled"
    else
      append_worker_log_note "WARNING: Using last-known-good cached update-apps.sh"
    fi
    append_worker_log_note "Cached SHA256: $UPSTREAM_SHA256"
    append_worker_log_note "Cached age: $UPSTREAM_CACHE_AGE seconds"
    return 0
  fi

  if [ "$UPSTREAM_REFRESH_STATUS" = disabled ]; then
    echo "[ERROR] Upstream refresh is disabled and no valid cached update-apps.sh is available" | tee -a "$LOG_FILE" >&2
  else
    echo "[ERROR] Upstream refresh failed and no valid cached update-apps.sh is available" | tee -a "$LOG_FILE" >&2
  fi
  return 1
}
healthcheck_ping() {
  [ -n "$HEALTHCHECK_URL" ] || return 0
  local url="${HEALTHCHECK_URL%/}$1"
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    curl -fsS --connect-timeout 5 --max-time 15 --retry 1 --data-binary @"$2" "$url" -o /dev/null 2>/dev/null || true
  else
    curl -fsS --connect-timeout 5 --max-time 15 --retry 1 "$url" -o /dev/null 2>/dev/null || true
  fi
}

write_skipped_invocation_status() {
  local tmp
  tmp=$(mktemp "${STATUS_FILE}.tmp.XXXXXX") || return 0
  if [ -f "$STATUS_FILE" ]; then
    grep -Ev '^(last_invocation_result|last_invocation_reason|last_invocation_timestamp)=' "$STATUS_FILE" >"$tmp" 2>/dev/null || true
  fi
  {
    echo "last_invocation_result=skipped"
    echo "last_invocation_reason=already_running"
    echo "last_invocation_timestamp=${TIMESTAMP}"
  } >>"$tmp"
  mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$tmp"
}

if [ "$REFRESH_ONLY" = yes ]; then
  if refresh_upstream_cache; then
    echo "Upstream cache refreshed: $CACHE_FILE"
    echo "SHA256: $UPSTREAM_SHA256"
    exit 0
  fi
  echo "Failed to refresh upstream cache; existing cache left untouched." >&2
  exit 1
fi

if [ "${STATUS_ONLY:-no}" = yes ]; then
  echo "Worker installed: yes"
  echo "Worker SHA256: $(sha_file "$0")"
  echo "Configured containers: ${CONTAINERS:-not configured}"
  echo "Backup: ${backup_status:-$BACKUP}"
  echo "Backup storage: ${BACKUP_STORAGE:-not configured}"
  echo "Notifications: ${notify_status:-$NOTIFY}"
  echo "Configuration:"
  if [ "${#CONFIG_WARNINGS[@]}" -eq 0 ]; then
    echo "  Status: ok"
  else
    echo "  Status: incomplete or invalid"
    for warning in "${CONFIG_WARNINGS[@]}"; do
      echo "  Warning: $warning"
    done
  fi
  echo "Upstream cache:"
  echo "  Present: $([ -f "$CACHE_FILE" ] && echo yes || echo no)"
  echo "  Source: $(grep -E '^source_url=' "$CACHE_META" 2>/dev/null | cut -d= -f2- || echo "$UPSTREAM_SCRIPT_URL")"
  echo "  SHA256: $([ -f "$CACHE_FILE" ] && sha_file "$CACHE_FILE" || echo unknown)"
  echo "  Last refreshed: $(grep -E '^refreshed_at=' "$CACHE_META" 2>/dev/null | cut -d= -f2- || echo unknown)"
  echo "  Age: $(cache_age_seconds 2>/dev/null || echo unknown)"
  echo "Last invocation:"
  echo "  Result: $(grep -E '^last_invocation_result=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  echo "  Reason: $(grep -E '^last_invocation_reason=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  echo "  Timestamp: $(grep -E '^last_invocation_timestamp=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  echo "Last completed run:"
  echo "  Timestamp: $(grep -E '^timestamp=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  echo "  Exit code: $(grep -E '^exit_code=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  echo "  Used upstream: $(grep -E '^upstream_used=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  echo "  Log: $(grep -E '^log_file=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || echo none)"
  exit 0
fi

# ── Concurrency protection ────────────────────────────────────────────────────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[WARN] Another update-community-apps run is already active; exiting."
  write_skipped_invocation_status
  exit 0
fi
healthcheck_ping "/start"

# ── Run upstream update script ────────────────────────────────────────────────
# Capture the exit code explicitly rather than relying on set -e, so downstream
# processing always runs (summary parsing, notification, status file) even when
# the upstream script fails on individual containers.
EXIT_CODE=0
UPSTREAM_OUTPUT="$(mktemp)"
UPSTREAM_LOG_SCAN_MARKER="$(mktemp)"
if ! select_upstream_script; then
  EXIT_CODE=1
else
  # Capture only the tail of upstream's noisy TTY-style stream. The useful
  # upstream "Full log:" pointer is printed at the end, and tail -c keeps the
  # temporary capture bounded even if spinner output goes feral mid-run.
  env "${env_args[@]}" bash "$CACHE_FILE" 2>&1 | tail -c "$MAX_UPSTREAM_CAPTURE_BYTES" >"$UPSTREAM_OUTPUT"
  EXIT_CODE=${PIPESTATUS[0]}
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

filter_non_actionable_log_lines() {
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    {
      line = trim($0)
      if (line == "") next
      if (line ~ /^Update started:/) next
      if (line ~ /Loading all possible LXC containers from Proxmox VE/) next
      if (line ~ /^Loaded [0-9]+ containers$/) next
      if (line ~ /Proxmox VE with tags: .*This may take a few seconds/) next
      if (line ~ /with tags: community-script, proxmox-helper-scripts\. This may take a few seconds/) next
      print
    }
  '
}

actionable_log_tail() {
  tail -40 "$LOG_FOR_PARSE" 2>/dev/null | sanitize_log_for_file | filter_non_actionable_log_lines || true
}

append_worker_log_note() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

find_latest_upstream_log() {
  [ -d "$UPSTREAM_LOG_DIR" ] || return 1
  find "$UPSTREAM_LOG_DIR" -maxdepth 1 -type f -name '[0-9]*_[0-9]*.log' -newer "$UPSTREAM_LOG_SCAN_MARKER" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 { $1=""; sub(/^ /, ""); print; exit }'
}

if [ -f "$UPSTREAM_OUTPUT" ] && [ -s "$UPSTREAM_OUTPUT" ]; then
  UPSTREAM_FULL_LOG=$(awk -F'Full log: ' '/Full log: / { value=$2 } END { print value }' "$UPSTREAM_OUTPUT" 2>/dev/null | tr -d '\r' || true)
  if [ -n "$UPSTREAM_FULL_LOG" ] && [ -r "$UPSTREAM_FULL_LOG" ]; then
    write_capped_clean_log "$UPSTREAM_FULL_LOG" "$LOG_FILE"
    append_worker_log_note "Copied upstream log from Full log pointer: $UPSTREAM_FULL_LOG"
  elif UPSTREAM_FULL_LOG=$(find_latest_upstream_log) && [ -n "$UPSTREAM_FULL_LOG" ] && [ -r "$UPSTREAM_FULL_LOG" ]; then
    write_capped_clean_log "$UPSTREAM_FULL_LOG" "$LOG_FILE"
    append_worker_log_note "Copied latest upstream log because no Full log pointer was printed: $UPSTREAM_FULL_LOG"
  else
    # Fallback for upstream format changes or missing files: keep a readable log
    # rather than no log at all.
    write_capped_clean_log "$UPSTREAM_OUTPUT" "$LOG_FILE"
    append_worker_log_note "Fell back to captured upstream terminal output; no readable upstream log file was found."
  fi
elif UPSTREAM_FULL_LOG=$(find_latest_upstream_log) && [ -n "$UPSTREAM_FULL_LOG" ] && [ -r "$UPSTREAM_FULL_LOG" ]; then
  write_capped_clean_log "$UPSTREAM_FULL_LOG" "$LOG_FILE"
  append_worker_log_note "Copied latest upstream log after empty terminal capture: $UPSTREAM_FULL_LOG"
else
  : > "$LOG_FILE" 2>/dev/null || true
  append_worker_log_note "No upstream output or upstream log file was available."
fi
rm -f "$UPSTREAM_OUTPUT" "$UPSTREAM_LOG_SCAN_MARKER"

# The upstream-cache summary is appended AFTER the clean log is written, since
# write_capped_clean_log overwrites LOG_FILE with the sanitized upstream output.
{
  echo "[$(date '+%H:%M:%S')] Updater started: $TIMESTAMP"
  echo "[$(date '+%H:%M:%S')] Configuration loaded"
  echo "[$(date '+%H:%M:%S')] Lock acquired"
  if [ "$UPSTREAM_USED" = fresh ]; then
    echo "[$(date '+%H:%M:%S')] Upstream refresh successful"
    echo "[$(date '+%H:%M:%S')] Upstream SHA256: $UPSTREAM_SHA256"
    echo "[$(date '+%H:%M:%S')] Using freshly downloaded upstream"
  elif [ "$UPSTREAM_USED" = cached ]; then
    if [ "$UPSTREAM_REFRESH_STATUS" = disabled ]; then
      echo "[$(date '+%H:%M:%S')] Upstream refresh disabled by configuration"
      echo "[$(date '+%H:%M:%S')] Using cached update-apps.sh because upstream refresh is disabled"
    else
      echo "[$(date '+%H:%M:%S')] WARNING: upstream refresh failed"
      echo "[$(date '+%H:%M:%S')] Using last-known-good cached update-apps.sh"
    fi
    echo "[$(date '+%H:%M:%S')] Cached SHA256: $UPSTREAM_SHA256"
    echo "[$(date '+%H:%M:%S')] Cached age: $UPSTREAM_CACHE_AGE seconds"
  fi
} >>"$LOG_FILE" 2>/dev/null || true

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

# Fallback: if separator parsing fails (e.g. upstream format change), include
# actionable tail lines but do not promote spinner/progress redraws into the
# notification summary.
if [ -z "$TABLE" ]; then
  TABLE=$(actionable_log_tail)
fi
if [ -z "$TABLE" ]; then
  TABLE="No summary table was produced. Check the run log for details: ${LOG_FILE}"
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
ERROR_COUNT=$(grep -c 'exit code [1-9]' "$LOG_FOR_PARSE" 2>/dev/null || true)
ERROR_COUNT=${ERROR_COUNT:-0}

{
  echo "last_invocation_result=completed"
  echo "last_invocation_reason=none"
  echo "last_invocation_timestamp=${TIMESTAMP}"
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
  echo "upstream_used=${UPSTREAM_USED}"
  echo "upstream_sha256=${UPSTREAM_SHA256}"
  echo "upstream_refresh_status=${UPSTREAM_REFRESH_STATUS}"
  echo "upstream_cache_age=${UPSTREAM_CACHE_AGE}"
  echo "healthcheck=$([ -n "$HEALTHCHECK_URL" ] && echo enabled || echo disabled)"
} > "${STATUS_FILE}.tmp" 2>/dev/null || true
mv -f "${STATUS_FILE}.tmp" "$STATUS_FILE" 2>/dev/null || true

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
    /^Update started:/ { next }
    /Loading all possible LXC containers from Proxmox VE/ { next }
    /Proxmox VE with tags: .*This may take a few seconds/ { next }
    /with tags: community-script, proxmox-helper-scripts\. This may take a few seconds/ { next }
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
[ "$UPSTREAM_USED" = "cached" ] && echo "WARNING: Used cached upstream update-apps.sh"
echo ""
[ -n "$TABLE" ] && echo "$TABLE"
[ -n "$EXIT_INFO" ] && echo "$EXIT_INFO"
echo ""
echo "Log: $LOG_FILE"

# Notification (if enabled)
if [ "$NOTIFY" = "yes" ]; then
  TITLE="Community Apps Update - $NODE_NAME - $TIMESTAMP"
  [ "$DRY_RUN" = "yes" ] && TITLE="[DRY-RUN] $TITLE"
  [ "$UPSTREAM_USED" = "cached" ] && TITLE="[CACHED UPSTREAM] $TITLE"

  NOTIFICATION_BODY=$(mktemp)
  {
    echo "===== Community Apps Update - $NODE_NAME - $TIMESTAMP ====="
    if [ "$BACKUP" = "yes" ]; then
      echo "Containers: $CONTAINERS | Backup: $BACKUP_STORAGE"
    else
      echo "Containers: $CONTAINERS | Backup: disabled"
    fi
    [ "$DRY_RUN" = "yes" ] && echo "Mode: DRY-RUN"
    [ "$UPSTREAM_USED" = "cached" ] && echo "WARNING: Used cached upstream update-apps.sh (${UPSTREAM_SHA256})"
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
  [ "$UPSTREAM_USED" = "cached" ] && [ "$SEVERITY" = "info" ] && SEVERITY="warning"

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

  NOTIFICATION_ERROR="$(mktemp)"
  if TITLE="$TITLE" MESSAGE_FILE="$NOTIFICATION_BODY" SEVERITY="$SEVERITY" perl -MPVE::Notify -e '
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
  ' 2>"$NOTIFICATION_ERROR"; then
    append_worker_log_note "Proxmox notification queued with severity=${SEVERITY}."
  else
    echo "[WARN]  Proxmox notification delivery failed" >&2
    append_worker_log_note "Proxmox notification delivery failed. Check Proxmox notification targets/matchers and /var/log/update-community-apps-cron.log."
    if [ -s "$NOTIFICATION_ERROR" ]; then
      sanitize_log_for_file < "$NOTIFICATION_ERROR" | sed 's/^/[notify] /' >> "$LOG_FILE" 2>/dev/null || true
    fi
  fi
  rm -f "$NOTIFICATION_BODY" "$NOTIFICATION_ERROR"
fi

# Healthchecks final ping is best-effort and never changes the updater result.
if [ "$EXIT_CODE" -eq 0 ]; then
  healthcheck_ping "" "$LOG_FILE"
else
  healthcheck_ping "/fail" "$LOG_FILE"
fi

exit "$EXIT_CODE"
