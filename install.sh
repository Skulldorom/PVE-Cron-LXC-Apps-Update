#!/usr/bin/env bash
# Community Apps Update — Installer
# Installs update-community-apps.sh and provides interactive cron configuration.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main"
SCRIPT_URL="${REPO_URL}/update-community-apps.sh"
LOGROTATE_URL="${REPO_URL}/logrotate.conf"
LOCAL_SCRIPT="/usr/local/bin/update-community-apps.sh"
LOG_FILE="/var/log/update-community-apps-cron.log"
LOGROTATE_FILE="/etc/logrotate.d/update-community-apps"
CONFIG_FILE="/etc/update-community-apps/config"
WRAPPER_SCRIPT="/usr/local/bin/update-community-apps-wrapper.sh"
TAGS="community-script|proxmox-helper-scripts"

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[36m'; NC='\e[0m'
msg_info()  { echo -e "  ${BLUE}[Info]${NC}  $*"; }
msg_ok()    { echo -e "  ${GREEN}[OK]${NC}    $*"; }
msg_error() { echo -e "  ${RED}[Error]${NC} $*" >&2; }

# ── Banner ───────────────────────────────────────────────────────────────────
banner() {
  clear
  cat <<'BANNER'

  Community Apps Update — Cron Installer
  https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update

  DISCLAIMER: This project is NOT affiliated with, endorsed by, or
  connected to community-scripts / Proxmox VE Helper Scripts in any way.
  It is an independent wrapper that automates their update-apps.sh tool.

BANNER
}

# ── Prerequisite checks ──────────────────────────────────────────────────────
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    msg_error "This script must be run as root."
    exit 1
  fi
}

check_whiptail() {
  if ! command -v whiptail &>/dev/null; then
    msg_error "whiptail is required. Install the Debian package with: apt install whiptail"
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in curl pct vzdump; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    msg_error "Missing required commands: ${missing[*]}"

    local apt_packages=()
    local needs_proxmox_tools=0
    local cmd
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        curl) apt_packages+=("$cmd") ;;
        pct|vzdump) needs_proxmox_tools=1 ;;
      esac
    done

    if [ ${#apt_packages[@]} -gt 0 ]; then
      msg_info "Install missing Debian packages with: apt install ${apt_packages[*]}"
    fi
    if [ "$needs_proxmox_tools" -eq 1 ]; then
      msg_info "This installer must run on a Proxmox VE host with Proxmox tools (pct, vzdump) available."
    fi
    exit 1
  fi
}

# ── Discover containers with community-script tags ───────────────────────────
discover_containers() {
  local containers container cid cname cstatus formatted
  containers=$(pct list | tail -n +2 | awk '{print $0 " " $4}')
  if [ -z "$containers" ]; then
    return 1
  fi

  MENU_ITEMS=()
  while read -r container; do
    cid=$(echo "$container" | awk '{print $1}')
    cname=$(echo "$container" | awk '{print $2}')
    cstatus=$(echo "$container" | awk '{print $3}')
    formatted=$(printf "%-20s %-10s" "$cname" "$cstatus")
    if pct config "$cid" 2>/dev/null | grep -qE "[^-][; ](${TAGS}).*"; then
      MENU_ITEMS+=("$cid" "$formatted" "OFF")
    fi
  done <<<"$containers"
}

# ── Discover backup-capable storages ─────────────────────────────────────────
discover_storages() {
  STORAGE_ITEMS=()
  local node_name storages
  node_name=$(hostname -s)

  storages=$(awk -v node="$node_name" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }
    function node_allowed(nodes, item_count, node_items, i) {
      nodes = trim(nodes)
      if (nodes == "") return 1
      item_count = split(nodes, node_items, /[,[:space:]]+/)
      for (i = 1; i <= item_count; i++) {
        if (node_items[i] == node) return 1
      }
      return 0
    }
    function print_if_allowed() {
      if (name == "") return
      if ((has_backup || (!has_content && type == "dir")) && node_allowed(nodes)) print name
    }
    /^[a-z]+:/ {
      print_if_allowed()
      split($0, a, ":")
      type = a[1]
      name = trim(a[2])
      has_content = 0
      has_backup = 0
      nodes = ""
    }
    /^[ \t]*content[ \t]/ {
      has_content = 1
      if ($0 ~ /(^|[ ,])backup([, ]|$)/) has_backup = 1
    }
    /^[ \t]*nodes[ \t]/ {
      sub(/^[ \t]*nodes[ \t]+/, "", $0)
      nodes = $0
    }
    END {
      print_if_allowed()
    }
  ' /etc/pve/storage.cfg)

  while read -r storage; do
    [ -n "$storage" ] && STORAGE_ITEMS+=("$storage" "")
  done <<<"$storages"
}

select_backup_storage() {
  local title="${1:-Backup Storage}"
  discover_storages

  if [ ${#STORAGE_ITEMS[@]} -eq 0 ]; then
    whiptail --backtitle "Community Apps Update" --title "No Storage Found" \
      --msgbox "No backup-capable storage accessible from node '$(hostname -s)' was found in /etc/pve/storage.cfg.\n\nMake sure a storage has backup content enabled and either no nodes restriction or includes this node." 12 70
    return 1
  fi

  whiptail --backtitle "Community Apps Update" --title "$title" \
    --menu "Select storage for pre-update backups:" 15 60 8 \
    "${STORAGE_ITEMS[@]}" \
    3>&1 1>&2 2>&3
}


# ── Log management ───────────────────────────────────────────────────────────
write_logrotate_config() {
  local retention_days="${1:-28}"
  local cron_rotations="${2:-4}"

  cat >"$LOGROTATE_FILE" <<EOF
# Timestamped worker logs created by update-community-apps.sh.
# These files do not receive additional writes after each run finishes, so
# maxage is the retention mechanism that removes old timestamped logs.
# Both raw (terminal noise) and clean (sanitized) logs are covered.
/var/log/update-community-apps-[0-9]*_[0-9]*.log
/var/log/update-community-apps-[0-9]*_[0-9]*-clean.log {
    weekly
    maxage ${retention_days}
    missingok
    notifempty
    compress
    delaycompress
}

# Stable cron wrapper log that receives stdout/stderr from scheduled runs.
/var/log/update-community-apps-cron.log {
    weekly
    rotate ${cron_rotations}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

current_log_retention() {
  if [ -f "$LOGROTATE_FILE" ]; then
    awk '/update-community-apps-\[0-9\]/ { in_worker=1; next } in_worker && /^[[:space:]]*maxage[[:space:]]+/ { print $2; exit } /^}/ { in_worker=0 }' "$LOGROTATE_FILE"
  fi
}

change_log_retention() {
  local current retention
  current=$(current_log_retention)
  current=${current:-28}

  retention=$(whiptail --backtitle "Community Apps Update" --title "Log Retention" \
    --inputbox "Keep timestamped worker logs for how many days?\n\nCurrent: ${current} days" 10 60 "$current" \
    3>&1 1>&2 2>&3) || return

  if ! [[ "$retention" =~ ^[0-9]+$ ]] || [ "$retention" -lt 1 ]; then
    whiptail --backtitle "Community Apps Update" --title "Invalid Retention" \
      --msgbox "Retention must be a positive whole number of days." 8 60
    return
  fi

  write_logrotate_config "$retention" 4
  msg_ok "Log retention set to ${retention} days in ${LOGROTATE_FILE}"
  echo ""
  read -rp "Press Enter to continue..."
}

view_logs() {
  local logs=() log size modified selected
  while IFS= read -r log; do
    [ -e "$log" ] || continue
    size=$(du -h "$log" 2>/dev/null | awk '{print $1}')
    modified=$(stat -c '%y' "$log" 2>/dev/null | cut -d. -f1)
    logs+=("$log" "${size:-?}  ${modified:-unknown}")
  done < <(find /var/log -maxdepth 1 \( -name 'update-community-apps-[0-9]*_[0-9]*.log' -o -name 'update-community-apps-[0-9]*_[0-9]*-clean.log' -o -name 'update-community-apps-cron.log*' \) -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')

  if [ ${#logs[@]} -eq 0 ]; then
    whiptail --backtitle "Community Apps Update" --title "Logs" \
      --msgbox "No update-community-apps logs were found in /var/log." 8 65
    return
  fi

  selected=$(whiptail --backtitle "Community Apps Update" --title "Logs" \
    --menu "Select a log to view:" 20 90 12 \
    "${logs[@]}" \
    3>&1 1>&2 2>&3) || return

  whiptail --backtitle "Community Apps Update" --title "$selected" \
    --textbox "$selected" 30 110
}

delete_logs() {
  local count=0
  count=$(find /var/log -maxdepth 1 \( -name 'update-community-apps-[0-9]*_[0-9]*.log' -o -name 'update-community-apps-[0-9]*_[0-9]*-clean.log' -o -name 'update-community-apps-cron.log*' \) -type f 2>/dev/null | wc -l)

  if [ "$count" -eq 0 ]; then
    whiptail --backtitle "Community Apps Update" --title "Delete Logs" \
      --msgbox "No update-community-apps logs were found in /var/log." 8 65
    return
  fi

  if ! whiptail --backtitle "Community Apps Update" --title "Delete Logs" \
    --yesno "Delete ${count} update-community-apps log file(s) from /var/log?\n\nThis includes timestamped worker logs, clean logs, and cron logs/rotations." 10 70; then
    return
  fi

  find /var/log -maxdepth 1 \( -name 'update-community-apps-[0-9]*_[0-9]*.log' -o -name 'update-community-apps-[0-9]*_[0-9]*-clean.log' -o -name 'update-community-apps-cron.log*' \) -type f -delete 2>/dev/null || true
  msg_ok "Deleted update-community-apps logs."
  echo ""
  read -rp "Press Enter to continue..."
}

logs_menu() {
  while true; do
    local current choice
    current=$(current_log_retention)
    current=${current:-not configured}

    choice=$(whiptail --backtitle "Community Apps Update" --title "Logs" \
      --menu "Log retention: ${current} day(s)\n\nSelect an option:" 16 70 6 \
      "Retention" "Change timestamped worker log retention" \
      "View"      "See all update-community-apps logs" \
      "Delete"    "Delete current update-community-apps logs" \
      "Back"      "Return to main menu" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      "Retention") change_log_retention ;;
      "View")      view_logs ;;
      "Delete")    delete_logs ;;
      "Back")      return ;;
    esac
  done
}

# ── Remove current cron entry ────────────────────────────────────────────────
remove_cron() {
  if crontab -l -u root 2>/dev/null | grep -qE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}"; then
    (crontab -l -u root 2>/dev/null | grep -vE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}") | crontab -u root -
    return 0
  fi
  return 1
}

# ── Config file management ──────────────────────────────────────────────────
write_config() {
  # Write current settings to the config file. Writes a wrapper script that
  # sources the config and calls the worker with the stored values.
  local min hour day month dow
  min="${1:-0}" hour="${2:-0}" day="${3:-*}" month="${4:-*}" dow="${5:-0}"
  local ct_ids="${6}" storage="${7}" notify="${8:-yes}" backup="${9:-yes}" dry="${10:-no}"

  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true

  cat > "$CONFIG_FILE" <<CFGEOF
# Community Apps Update — configuration
# Generated by install.sh on $(date)
CONTAINER_IDS="${ct_ids}"
BACKUP_STORAGE="${storage}"
BACKUP="${backup}"
SCHEDULE="${min} ${hour} ${day} ${month} ${dow}"
NOTIFY="${notify}"
DRY_RUN="${dry}"
CFGEOF

  # Write the cron wrapper script
  cat > "$WRAPPER_SCRIPT" <<WREOF
#!/bin/bash
# Community Apps Update — cron wrapper
# Sources the config file and calls the worker script.
# Generated by install.sh on $(date)
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE}"
WORKER_SCRIPT="${LOCAL_SCRIPT}"

if [ -f "\$CONFIG_FILE" ]; then
  source "\$CONFIG_FILE"
else
  echo "[ERROR] Config file not found: \$CONFIG_FILE" >&2
  exit 1
fi

args=("\$CONTAINER_IDS")
if [ "\${BACKUP:-yes}" = "yes" ]; then
  args+=("\$BACKUP_STORAGE")
fi
if [ "\${DRY_RUN:-no}" = "yes" ]; then
  args+=(dry-run)
fi

NOTIFY="\${NOTIFY:-yes}" BACKUP="\${BACKUP:-yes}" \
  "\$WORKER_SCRIPT" "\${args[@]}"

exit \$?
WREOF
  chmod 0755 "$WRAPPER_SCRIPT"
}

read_config() {
  # Source the config file if it exists. Sets CONTAINER_IDS, BACKUP_STORAGE,
  # BACKUP, SCHEDULE, NOTIFY, DRY_RUN in the caller's scope.
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    return 0
  fi
  return 1
}


container_is_selected() {
  local cid="$1" selected_ids=",${2:-},"
  [[ "$selected_ids" == *",${cid},"* ]]
}

apply_container_defaults() {
  local current_ids="${1:-}" index cid
  [ -n "$current_ids" ] || return 0

  for ((index=0; index<${#MENU_ITEMS[@]}; index+=3)); do
    cid="${MENU_ITEMS[$index]}"
    if container_is_selected "$cid" "$current_ids"; then
      MENU_ITEMS[$((index + 2))]="ON"
    fi
  done
}

select_containers() {
  local title="$1" prompt="$2" current_ids="${3:-}" choice

  if ! discover_containers || [ ${#MENU_ITEMS[@]} -eq 0 ]; then
    whiptail --backtitle "Community Apps Update" --title "No Containers Found" \
      --msgbox "No LXC containers with community-script tags found.\n\nTags checked: ${TAGS//\|/, }\n\nMake sure your containers are tagged with 'community-script'\nor 'proxmox-helper-scripts' in their Proxmox config." 12 65
    return 1
  fi

  apply_container_defaults "$current_ids"

  choice=$(whiptail --backtitle "Community Apps Update" --title "$title" \
    --checklist "$prompt\n(Use SPACE to select, TAB to switch, ENTER to confirm)" \
    20 75 12 \
    "${MENU_ITEMS[@]}" \
    3>&1 1>&2 2>&3 | tr -d '"') || return 1

  if [ -z "$choice" ]; then
    msg_info "No containers selected. Aborting."
    return 1
  fi

  echo "$choice" | tr '[:space:]' ',' | sed -E 's/,+/,/g; s/^,//; s/,$//'
}

ask_change_setting() {
  local title="$1" setting="$2" current="$3" choice
  choice=$(whiptail --backtitle "Community Apps Update" --title "$title" \
    --menu "${setting}\n\nCurrent: ${current}\n\nKeep the current value or change it?" 13 72 2 \
    "keep"   "Keep current value" \
    "change" "Change this setting" \
    3>&1 1>&2 2>&3) || return 1

  [ "$choice" = "change" ]
}

prompt_yes_no_value() {
  local title="$1" message="$2" current="${3:-yes}"

  if [ "$current" = "yes" ]; then
    if whiptail --backtitle "Community Apps Update" --title "$title" \
      --yesno "$message" 10 65; then
      echo "yes"
    else
      echo "no"
    fi
  else
    if whiptail --backtitle "Community Apps Update" --title "$title" \
      --defaultno --yesno "$message" 10 65; then
      echo "yes"
    else
      echo "no"
    fi
  fi
}

configure_backup_flow() {
  local title_prefix="$1" current_backup="${2:-yes}" backup storage

  backup=$(prompt_yes_no_value "${title_prefix} — Backups" \
    "Allow pre-update backups?\n\nIf enabled, the next screen will ask which storage to use for vzdump backups." \
    "$current_backup") || return 1

  if [ "$backup" = "yes" ]; then
    storage=$(select_backup_storage "${title_prefix} — Backup Storage") || return 1
    if [ -z "$storage" ]; then
      msg_info "No storage selected. Aborting."
      return 1
    fi
  else
    storage=""
  fi

  printf '%s\t%s\n' "$backup" "$storage"
}

edit_config() {
  # Edit the installed configuration without reinstalling.
  # Each setting can be kept as-is or changed, so users only touch the pieces
  # that actually need changing.
  if [ ! -f "$CONFIG_FILE" ]; then
    whiptail --backtitle "Community Apps Update" --title "Edit Config" \
      --msgbox "No config file found.\n\nRun 'Install' first to create one." 8 60
    return
  fi

  read_config || {
    whiptail --backtitle "Community Apps Update" --title "Edit Config" \
      --msgbox "Failed to read config file: ${CONFIG_FILE}" 8 70
    return
  }

  local ct_ids="${CONTAINER_IDS:-}"
  local storage="${BACKUP_STORAGE:-}"
  local backup="${BACKUP:-yes}"
  local notify="${NOTIFY:-yes}"
  local dry="${DRY_RUN:-no}"

  # Parse current schedule
  local cur_min cur_hour cur_day cur_month cur_dow
  read -r cur_min cur_hour cur_day cur_month cur_dow <<< "${SCHEDULE:-0 0 * * 0}"

  # ── Edit: Containers ──────────────────────────────────────────────────────
  if ask_change_setting "Edit Config — Containers" "LXC containers to update" "$ct_ids"; then
    local new_ct_ids
    msg_info "Scanning for community-script containers..."
    new_ct_ids=$(select_containers "Edit Config — Containers" \
      "Current: ${ct_ids}\n\nSelect LXC containers to update:" "$ct_ids") || return
    ct_ids="$new_ct_ids"
  fi

  # ── Edit: Backups + Storage ───────────────────────────────────────────────
  local storage_display="${storage:-not selected}"
  if ask_change_setting "Edit Config — Backups" "Backups and backup storage" "backups=${backup}, storage=${storage_display}"; then
    local backup_result
    backup_result=$(configure_backup_flow "Edit Config" "$backup") || return
    backup=$(printf '%s' "$backup_result" | cut -f1)
    storage=$(printf '%s' "$backup_result" | cut -f2-)
  fi

  # ── Edit: Schedule ────────────────────────────────────────────────────────
  local current_schedule_desc
  current_schedule_desc=$(cron_to_human "$cur_min" "$cur_hour" "$cur_day" "$cur_month" "$cur_dow" 2>/dev/null || echo "${cur_min} ${cur_hour} ${cur_day} ${cur_month} ${cur_dow}")

  if ask_change_setting "Edit Config — Schedule" "Cron schedule" "$current_schedule_desc"; then
    local new_freq new_hour new_dow new_day
    new_freq=$(whiptail --backtitle "Community Apps Update" --title "Edit Config — Frequency" \
      --menu "Current schedule: ${current_schedule_desc}\n\nHow often should updates run?" 14 60 3 \
      "daily"   "Every day" \
      "weekly"  "Once a week" \
      "monthly" "Once a month" \
      3>&1 1>&2 2>&3) || return

    new_hour=""
    case "$new_freq" in
      daily)
        new_hour=$(whiptail --backtitle "Community Apps Update" --title "Edit Config — Hour" \
          --menu "Select hour for daily updates:" 15 50 8 \
          "0" "00:00" "1" "01:00" "2" "02:00" "3" "03:00" "4" "04:00" \
          "5" "05:00" "6" "06:00" "7" "07:00" "8" "08:00" "9" "09:00" \
          "10" "10:00" "11" "11:00" "12" "12:00" "13" "13:00" "14" "14:00" \
          "15" "15:00" "16" "16:00" "17" "17:00" "18" "18:00" "19" "19:00" \
          "20" "20:00" "21" "21:00" "22" "22:00" "23" "23:00" \
          3>&1 1>&2 2>&3) || return
        cur_min=0; cur_hour="$new_hour"; cur_day="*"; cur_month="*"; cur_dow="*"
        ;;
      weekly)
        new_dow=$(whiptail --backtitle "Community Apps Update" --title "Edit Config — Day" \
          --menu "Select day of week:" 15 50 8 \
          "0" "Sunday" "1" "Monday" "2" "Tuesday" "3" "Wednesday" \
          "4" "Thursday" "5" "Friday" "6" "Saturday" \
          3>&1 1>&2 2>&3) || return
        new_hour=$(whiptail --backtitle "Community Apps Update" --title "Edit Config — Hour" \
          --menu "Select hour:" 15 50 8 \
          "0" "00:00" "1" "01:00" "2" "02:00" "3" "03:00" "4" "04:00" \
          "5" "05:00" "6" "06:00" "7" "07:00" "8" "08:00" "9" "09:00" \
          "10" "10:00" "11" "11:00" "12" "12:00" "13" "13:00" "14" "14:00" \
          "15" "15:00" "16" "16:00" "17" "17:00" "18" "18:00" "19" "19:00" \
          "20" "20:00" "21" "21:00" "22" "22:00" "23" "23:00" \
          3>&1 1>&2 2>&3) || return
        cur_min=0; cur_hour="$new_hour"; cur_day="*"; cur_month="*"; cur_dow="$new_dow"
        ;;
      monthly)
        new_day=$(whiptail --backtitle "Community Apps Update" --title "Edit Config — Day" \
          --menu "Select day of month:" 15 50 8 \
          "1" "1st" "2" "2nd" "3" "3rd" "4" "4th" "5" "5th" \
          "6" "6th" "7" "7th" "8" "8th" "9" "9th" "10" "10th" \
          "11" "11th" "12" "12th" "13" "13th" "14" "14th" "15" "15th" \
          "16" "16th" "17" "17th" "18" "18th" "19" "19th" "20" "20th" \
          "21" "21st" "22" "22nd" "23" "23rd" "24" "24th" \
          "25" "25th" "26" "26th" "27" "27th" "28" "28th" \
          3>&1 1>&2 2>&3) || return
        new_hour=$(whiptail --backtitle "Community Apps Update" --title "Edit Config — Hour" \
          --menu "Select hour:" 15 50 8 \
          "0" "00:00" "1" "01:00" "2" "02:00" "3" "03:00" "4" "04:00" \
          "5" "05:00" "6" "06:00" "7" "07:00" "8" "08:00" "9" "09:00" \
          "10" "10:00" "11" "11:00" "12" "12:00" "13" "13:00" "14" "14:00" \
          "15" "15:00" "16" "16:00" "17" "17:00" "18" "18:00" "19" "19:00" \
          "20" "20:00" "21" "21:00" "22" "22:00" "23" "23:00" \
          3>&1 1>&2 2>&3) || return
        cur_min=0; cur_hour="$new_hour"; cur_day="$new_day"; cur_month="*"; cur_dow="*"
        ;;
    esac
  fi

  # ── Edit: Notifications ──────────────────────────────────────────────────
  if ask_change_setting "Edit Config — Notifications" "Notifications" "$notify"; then
    notify=$(prompt_yes_no_value "Edit Config — Notifications" "Enable notifications?" "$notify") || return
  fi

  # ── Edit: Dry-run ─────────────────────────────────────────────────────────
  if ask_change_setting "Edit Config — Mode" "Dry-run mode" "$dry"; then
    dry=$(prompt_yes_no_value "Edit Config — Mode" "Enable dry-run mode?\n\nChecks for updates without applying them." "$dry") || return
  fi

  # ── Review ───────────────────────────────────────────────────────────────
  local schedule_desc review_storage
  schedule_desc=$(cron_to_human "$cur_min" "$cur_hour" "$cur_day" "$cur_month" "$cur_dow" 2>/dev/null || echo "${cur_min} ${cur_hour} ${cur_day} ${cur_month} ${cur_dow}")
  review_storage="${storage:-not used}"

  if ! whiptail --backtitle "Community Apps Update" --title "Edit Config — Review" \
    --yesno "Review your changes:

  Containers:      ${ct_ids}
  Backups:         ${backup}
  Backup Storage:  ${review_storage}
  Schedule:        ${schedule_desc}
  Notifications:   ${notify}
  Dry-run:         ${dry}

Apply changes?" 16 65; then
    msg_info "Edit cancelled."
    return
  fi

  # ── Write config + wrapper + update crontab ──────────────────────────────
  write_config "$cur_min" "$cur_hour" "$cur_day" "$cur_month" "$cur_dow" \
    "$ct_ids" "$storage" "$notify" "$backup" "$dry"

  remove_cron || true
  local cron_entry
  cron_entry="${cur_min} ${cur_hour} ${cur_day} ${cur_month} ${cur_dow} ${WRAPPER_SCRIPT} >>${LOG_FILE} 2>&1"
  (crontab -l -u root 2>/dev/null || true; echo "$cron_entry") | crontab -u root -

  msg_ok "Configuration updated."
  msg_ok "Schedule: ${schedule_desc}"
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Human-readable cron description ───────────────────────────────────────────
cron_to_human() {
  # Parse cron fields (min hour day month dow) into a human-readable description.
  # Supports daily, weekly, and monthly schedules.
  local min hour day month dow dow_label
  min="$1" hour="$2" day="$3" month="$4" dow="$5"

  if [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$dow" = "*" ]; then
    # Daily
    printf 'Daily at %02d:%02d' "$hour" "$min"
  elif [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$dow" != "*" ]; then
    # Weekly
    case "$dow" in
      0) dow_label="Sunday" ;; 1) dow_label="Monday" ;;   2) dow_label="Tuesday" ;;
      3) dow_label="Wednesday" ;; 4) dow_label="Thursday" ;; 5) dow_label="Friday" ;;
      6) dow_label="Saturday" ;; *) dow_label="day $dow" ;;
    esac
    printf 'Weekly: %s at %02d:%02d' "$dow_label" "$hour" "$min"
  elif [ "$day" != "*" ] && [ "$month" = "*" ] && [ "$dow" = "*" ]; then
    # Monthly
    printf 'Monthly: day %s at %02d:%02d' "$day" "$hour" "$min"
  else
    # Generic
    printf '%s %s %s %s %s' "$min" "$hour" "$day" "$month" "$dow"
  fi
}

# ── Status ───────────────────────────────────────────────────────────────────
show_status() {
  echo ""
  if [ -f "$LOCAL_SCRIPT" ]; then
    local hash installed
    hash=$(sha256sum "$LOCAL_SCRIPT" | awk '{print $1}')
    installed=$(stat -c '%y' "$LOCAL_SCRIPT" 2>/dev/null | cut -d. -f1)
    msg_ok "Script installed: ${LOCAL_SCRIPT}"
    echo -e "      SHA256:  ${hash}"
    echo -e "      Installed: ${installed}"
  else
    msg_error "Script not installed"
  fi

  if crontab -l -u root 2>/dev/null | grep -qE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}"; then
    local entry cron_fields schedule_desc
    entry=$(crontab -l -u root 2>/dev/null | grep -E "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}" | head -1)
    cron_fields=$(echo "$entry" | awk '{print $1,$2,$3,$4,$5}')
    schedule_desc=$(cron_to_human $cron_fields 2>/dev/null || echo "$cron_fields")
    msg_ok "Cron active: ${schedule_desc}"
    echo -e "      Full entry: ${entry}"
  else
    msg_error "Cron not configured"
  fi

  # ── Last run status (I3 integration) ─────────────────────────────────────
  local status_file="/var/log/update-community-apps-last-status"
  if [ -f "$status_file" ]; then
    local exit_code timestamp containers errors
    exit_code=$(grep '^exit_code=' "$status_file" 2>/dev/null | cut -d= -f2)
    timestamp=$(grep '^timestamp=' "$status_file" 2>/dev/null | cut -d= -f2-)
    containers=$(grep '^containers=' "$status_file" 2>/dev/null | cut -d= -f2)
    errors=$(grep '^errors_count=' "$status_file" 2>/dev/null | cut -d= -f2)

    if [ -n "$exit_code" ]; then
      if [ "$exit_code" = "0" ]; then
        echo -e "  ${GREEN}Last run: ✅ SUCCESS${NC}"
      else
        echo -e "  ${RED}Last run: ❌ FAILED (exit ${exit_code})${NC}"
      fi
      [ -n "$timestamp" ] && echo -e "      When: ${timestamp}"
      [ -n "$containers" ] && echo -e "      Containers: ${containers}"
      [ -n "${errors:-}" ] && [ "$errors" -gt 0 ] && echo -e "      ${YELLOW}Errors: ${errors} container(s)${NC}"
    fi
  fi

  if [ -f "$LOG_FILE" ]; then
    local log_size
    log_size=$(du -h "$LOG_FILE" | awk '{print $1}')
    echo -e "  ${BLUE}[Info]${NC}  Log: ${LOG_FILE} (${log_size})"
  else
    echo -e "  ${BLUE}[Info]${NC}  Log: (no runs yet)"
  fi
  echo ""
  read -rp "Press Enter to continue..."
}

# ── View script / cron ───────────────────────────────────────────────────────
view_config() {
  echo ""
  echo -e "  ${YELLOW}─── Installed Script ─────────────────────────────────────────${NC}"
  if [ -f "$LOCAL_SCRIPT" ]; then
    cat "$LOCAL_SCRIPT"
    echo ""
    echo -e "  ${BLUE}SHA256:${NC} $(sha256sum "$LOCAL_SCRIPT" | awk '{print $1}')"
  else
    msg_error "No script installed."
  fi
  echo ""
  echo -e "  ${YELLOW}─── Config File ──────────────────────────────────────────────${NC}"
  if [ -f "$CONFIG_FILE" ]; then
    cat "$CONFIG_FILE"
  else
    msg_error "No config file found."
  fi
  echo ""
  echo -e "  ${YELLOW}─── Cron Configuration ────────────────────────────────────────${NC}"
  if crontab -l -u root 2>/dev/null | grep -qE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}"; then
    crontab -l -u root 2>/dev/null | grep -E "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}"
  elif crontab -l -u root 2>/dev/null | grep -q "${WRAPPER_SCRIPT}"; then
    crontab -l -u root 2>/dev/null | grep "${WRAPPER_SCRIPT}"
  else
    msg_error "No cron entry configured."
  fi
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Extract args from crontab entry ───────────────────────────────────────────
get_cron_args() {
  # Returns container IDs and backup storage from the cron entry.
  # Splits on double quotes: cron line has "...script.sh" "101,102" "storage" ...
  local entry
  entry=$(crontab -l -u root 2>/dev/null | grep -E "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}" | head -1)
  if [ -z "$entry" ]; then
    return 1
  fi
  CRON_CT_IDS=$(echo "$entry" | cut -d'"' -f2)
  CRON_STORAGE=$(echo "$entry" | cut -d'"' -f4)
  [ -n "$CRON_CT_IDS" ] && [ -n "$CRON_STORAGE" ]
}

# ── Run now ──────────────────────────────────────────────────────────────────
run_now() {
  if [ ! -f "$LOCAL_SCRIPT" ]; then
    msg_error "No script installed. Use 'Install & Configure' first."
    read -rp "Press Enter to continue..."
    return
  fi

  local ct_ids storage notify_val backup_val
  if read_config 2>/dev/null; then
    ct_ids="$CONTAINER_IDS"
    storage="$BACKUP_STORAGE"
    notify_val="${NOTIFY:-yes}"
    backup_val="${BACKUP:-yes}"
  elif get_cron_args; then
    ct_ids="$CRON_CT_IDS"
    storage="$CRON_STORAGE"
    notify_val="${NOTIFY:-yes}"
    backup_val="${BACKUP:-yes}"
  else
    ct_ids=$(whiptail --backtitle "Community Apps Update" --title "Run Now" \
      --inputbox "Enter container IDs (comma-separated):" 10 50 "101,102" \
      3>&1 1>&2 2>&3) || return
    storage=$(select_backup_storage "Run Now") || return
    notify_val="yes"
    backup_val="yes"
  fi

  clear
  msg_info "Running update script now..."
  echo ""
  NOTIFY="$notify_val" BACKUP="$backup_val" bash "$LOCAL_SCRIPT" "$ct_ids" "$storage" 2>&1 | tee -a "$LOG_FILE"
  echo ""
  msg_ok "Run completed. Log appended to ${LOG_FILE}"
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Dry run ──────────────────────────────────────────────────────────────────
dry_run() {
  if [ ! -f "$LOCAL_SCRIPT" ]; then
    msg_error "No script installed. Use 'Install & Configure' first."
    read -rp "Press Enter to continue..."
    return
  fi

  local ct_ids storage notify_val backup_val
  if read_config 2>/dev/null; then
    ct_ids="$CONTAINER_IDS"
    storage="$BACKUP_STORAGE"
    notify_val="${NOTIFY:-yes}"
    backup_val="${BACKUP:-yes}"
  elif get_cron_args; then
    ct_ids="$CRON_CT_IDS"
    storage="$CRON_STORAGE"
    notify_val="${NOTIFY:-yes}"
    backup_val="${BACKUP:-yes}"
  else
    ct_ids=$(whiptail --backtitle "Community Apps Update" --title "Dry Run" \
      --inputbox "Enter container IDs (comma-separated):" 10 50 "101,102" \
      3>&1 1>&2 2>&3) || return
    storage=$(select_backup_storage "Dry Run") || return
    notify_val="yes"
    backup_val="yes"
  fi

  clear
  msg_info "Running dry-run (check only — no changes)..."
  echo ""
  NOTIFY="$notify_val" BACKUP="$backup_val" bash "$LOCAL_SCRIPT" "$ct_ids" "$storage" dry-run 2>&1 | tee -a "$LOG_FILE"
  echo ""
  msg_ok "Dry-run completed. Log appended to ${LOG_FILE}"
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Remove ───────────────────────────────────────────────────────────────────
remove_all() {
  if ! whiptail --backtitle "Community Apps Update" --title "Remove" \
    --yesno "Remove the cron schedule and local script?\n\nThis will delete:\n  • Cron entry\n  • ${LOCAL_SCRIPT}\n\nLog file (${LOG_FILE}) will be kept." 12 65; then
    return
  fi

  if crontab -l -u root 2>/dev/null | grep -qE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}"; then
    (crontab -l -u root 2>/dev/null | grep -vE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}") | crontab -u root -
    msg_ok "Removed cron schedule"
  fi
  if [ -f "$LOCAL_SCRIPT" ]; then
    rm -f "$LOCAL_SCRIPT"
    msg_ok "Removed ${LOCAL_SCRIPT}"
  fi
  if [ -f "$WRAPPER_SCRIPT" ]; then
    rm -f "$WRAPPER_SCRIPT"
    msg_ok "Removed ${WRAPPER_SCRIPT}"
  fi
  if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    msg_ok "Removed ${CONFIG_FILE}"
  fi
  msg_info "Log file kept at ${LOG_FILE} (remove manually if desired)."
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Update ───────────────────────────────────────────────────────────────────
update_script() {
  if [ ! -f "$LOCAL_SCRIPT" ]; then
    msg_error "No local script found. Use 'Install & Configure' first."
    read -rp "Press Enter to continue..."
    return
  fi

  local tmp
  tmp=$(mktemp)

  # ── Update: Worker script ───────────────────────────────────────────────
  msg_info "Downloading latest worker script..."
  if ! curl -fsSL -o "$tmp" "$SCRIPT_URL"; then
    msg_error "Failed to download: ${SCRIPT_URL}"
    rm -f "$tmp"
    read -rp "Press Enter to continue..."
    return
  fi

  local new_hash old_hash
  new_hash=$(sha256sum "$tmp" | awk '{print $1}')
  old_hash=$(sha256sum "$LOCAL_SCRIPT" | awk '{print $1}')

  if [ "$new_hash" = "$old_hash" ]; then
    msg_ok "Worker script already up-to-date (no changes)."
    rm -f "$tmp"
  else
    if command -v diff &>/dev/null; then
      diff --color=always "$LOCAL_SCRIPT" "$tmp" 2>/dev/null || true
    fi

    echo ""
    echo -e "  ${BLUE}Current SHA256:${NC} ${old_hash}"
    echo -e "  ${BLUE}New SHA256:${NC}     ${new_hash}"
    echo ""

    if whiptail --backtitle "Community Apps Update" --title "Update" \
      --yesno "Update worker script?\n\nCurrent: ${old_hash}\nNew:      ${new_hash}" 10 60; then
      install -m 0755 "$tmp" "$LOCAL_SCRIPT"
      rm -f "$tmp"
      msg_ok "Updated ${LOCAL_SCRIPT}"
    else
      rm -f "$tmp"
      msg_info "Worker script update skipped."
    fi
  fi

  # ── Update: Logrotate config ────────────────────────────────────────────
  local logrotate_tmp
  logrotate_tmp=$(mktemp)
  msg_info "Checking logrotate config..."
  if curl -fsSL -o "$logrotate_tmp" "$LOGROTATE_URL"; then
    if [ -f "$LOGROTATE_FILE" ]; then
      # Carry forward the user's custom retention settings from the installed
      # logrotate config so updates don't silently reset them to defaults.
      local user_maxage user_rotate
      user_maxage=$(awk '/^[[:space:]]*maxage[[:space:]]/ { print $2; exit }' "$LOGROTATE_FILE")
      user_rotate=$(awk '/^[[:space:]]*rotate[[:space:]]/ { print $2; exit }' "$LOGROTATE_FILE")
      if [ -n "$user_maxage" ]; then
        sed -i "s/^\([[:space:]]*maxage[[:space:]]\+\).*/\1${user_maxage}/" "$logrotate_tmp"
      fi
      if [ -n "$user_rotate" ]; then
        sed -i "s/^\([[:space:]]*rotate[[:space:]]\+\).*/\1${user_rotate}/" "$logrotate_tmp"
      fi

      local logrotate_new logrotate_old
      logrotate_new=$(sha256sum "$logrotate_tmp" | awk '{print $1}')
      logrotate_old=$(sha256sum "$LOGROTATE_FILE" | awk '{print $1}')

      if [ "$logrotate_new" = "$logrotate_old" ]; then
        msg_ok "Logrotate config already up-to-date."
      else
        if command -v diff &>/dev/null; then
          diff --color=always "$LOGROTATE_FILE" "$logrotate_tmp" 2>/dev/null || true
        fi

        echo ""
        if whiptail --backtitle "Community Apps Update" --title "Update Logrotate Config" \
          --yesno "Update logrotate config?\n\nCurrent: ${logrotate_old}\nNew:      ${logrotate_new}" 10 60; then
          cp "$logrotate_tmp" "$LOGROTATE_FILE"
          msg_ok "Updated ${LOGROTATE_FILE}"
        else
          msg_info "Logrotate config update skipped."
        fi
      fi
    else
      # No existing logrotate config; install it fresh
      cp "$logrotate_tmp" "$LOGROTATE_FILE"
      msg_ok "Installed logrotate config to ${LOGROTATE_FILE}"
    fi
  else
    msg_info "Skipping logrotate update (could not download ${LOGROTATE_URL})"
  fi
  rm -f "$logrotate_tmp"

  # ── Regenerate: Wrapper script ──────────────────────────────────────────
  # The wrapper template lives inside install.sh's write_config() function.
  # Re-running write_config with values from the existing config file picks
  # up any template changes without altering user settings.
  if [ -f "$CONFIG_FILE" ]; then
    msg_info "Regenerating wrapper script..."
    source "$CONFIG_FILE"
    write_config \
      "$(echo "${SCHEDULE:-0 0 * * 0}" | awk '{print $1}')" \
      "$(echo "${SCHEDULE:-0 0 * * 0}" | awk '{print $2}')" \
      "$(echo "${SCHEDULE:-0 0 * * 0}" | awk '{print $3}')" \
      "$(echo "${SCHEDULE:-0 0 * * 0}" | awk '{print $4}')" \
      "$(echo "${SCHEDULE:-0 0 * * 0}" | awk '{print $5}')" \
      "${CONTAINER_IDS:-}" \
      "${BACKUP_STORAGE:-}" \
      "${NOTIFY:-yes}" \
      "${BACKUP:-yes}" \
      "${DRY_RUN:-no}"
    msg_ok "Regenerated ${WRAPPER_SCRIPT}"
  fi

  echo ""
  read -rp "Press Enter to continue..."
}

# ── Install & Configure ──────────────────────────────────────────────────────
install_and_configure() {
  # ── Step 1: Discover containers ──────────────────────────────────────────
  msg_info "Scanning for community-script containers..."
  CONTAINER_IDS=$(select_containers "Select Containers" "Select LXC containers to update:" "") || return

  # ── Step 2: Schedule — Frequency ─────────────────────────────────────────
  FREQ=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Frequency" \
    --menu "How often should updates run?" 14 50 3 \
    "daily"   "Every day" \
    "weekly"  "Once a week" \
    "monthly" "Once a month" \
    3>&1 1>&2 2>&3)

  [ -z "$FREQ" ] && { msg_info "Aborted."; return; }

  HOUR=""
  DOW=""
  DAY=""

  case "$FREQ" in
    daily)
      HOUR=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Daily Hour" \
        --menu "Select hour for daily updates (24h format):" 15 50 8 \
        "0"  "00:00 (midnight)" \
        "1"  "01:00" \
        "2"  "02:00" \
        "3"  "03:00" \
        "4"  "04:00" \
        "5"  "05:00" \
        "6"  "06:00" \
        "7"  "07:00" \
        "8"  "08:00" \
        "9"  "09:00" \
        "10" "10:00" \
        "11" "11:00" \
        "12" "12:00 (noon)" \
        "13" "13:00" \
        "14" "14:00" \
        "15" "15:00" \
        "16" "16:00" \
        "17" "17:00" \
        "18" "18:00" \
        "19" "19:00" \
        "20" "20:00" \
        "21" "21:00" \
        "22" "22:00" \
        "23" "23:00" \
        3>&1 1>&2 2>&3)
      [ -z "$HOUR" ] && { msg_info "Aborted."; return; }
      ;;

    weekly)
      DOW=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Day of Week" \
        --menu "Select day of week:" 15 50 8 \
        "0" "Sunday" \
        "1" "Monday" \
        "2" "Tuesday" \
        "3" "Wednesday" \
        "4" "Thursday" \
        "5" "Friday" \
        "6" "Saturday" \
        3>&1 1>&2 2>&3)
      [ -z "$DOW" ] && { msg_info "Aborted."; return; }

      HOUR=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Hour" \
        --menu "Select hour for weekly updates (24h format):" 15 50 8 \
        "0"  "00:00 (midnight)" \
        "1"  "01:00" \
        "2"  "02:00" \
        "3"  "03:00" \
        "4"  "04:00" \
        "5"  "05:00" \
        "6"  "06:00" \
        "7"  "07:00" \
        "8"  "08:00" \
        "9"  "09:00" \
        "10" "10:00" \
        "11" "11:00" \
        "12" "12:00 (noon)" \
        "13" "13:00" \
        "14" "14:00" \
        "15" "15:00" \
        "16" "16:00" \
        "17" "17:00" \
        "18" "18:00" \
        "19" "19:00" \
        "20" "20:00" \
        "21" "21:00" \
        "22" "22:00" \
        "23" "23:00" \
        3>&1 1>&2 2>&3)
      [ -z "$HOUR" ] && { msg_info "Aborted."; return; }
      ;;

    monthly)
      DAY=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Day of Month" \
        --menu "Select day of month:" 15 50 8 \
        "1"  "1st" \
        "2"  "2nd" \
        "3"  "3rd" \
        "4"  "4th" \
        "5"  "5th" \
        "6"  "6th" \
        "7"  "7th" \
        "8"  "8th" \
        "9"  "9th" \
        "10" "10th" \
        "11" "11th" \
        "12" "12th" \
        "13" "13th" \
        "14" "14th" \
        "15" "15th" \
        "16" "16th" \
        "17" "17th" \
        "18" "18th" \
        "19" "19th" \
        "20" "20th" \
        "21" "21st" \
        "22" "22nd" \
        "23" "23rd" \
        "24" "24th" \
        "25" "25th" \
        "26" "26th" \
        "27" "27th" \
        "28" "28th" \
        3>&1 1>&2 2>&3)
      [ -z "$DAY" ] && { msg_info "Aborted."; return; }

      HOUR=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Hour" \
        --menu "Select hour for monthly updates (24h format):" 15 50 8 \
        "0"  "00:00 (midnight)" \
        "1"  "01:00" \
        "2"  "02:00" \
        "3"  "03:00" \
        "4"  "04:00" \
        "5"  "05:00" \
        "6"  "06:00" \
        "7"  "07:00" \
        "8"  "08:00" \
        "9"  "09:00" \
        "10" "10:00" \
        "11" "11:00" \
        "12" "12:00 (noon)" \
        "13" "13:00" \
        "14" "14:00" \
        "15" "15:00" \
        "16" "16:00" \
        "17" "17:00" \
        "18" "18:00" \
        "19" "19:00" \
        "20" "20:00" \
        "21" "21:00" \
        "22" "22:00" \
        "23" "23:00" \
        3>&1 1>&2 2>&3)
      [ -z "$HOUR" ] && { msg_info "Aborted."; return; }
      ;;
  esac

# ── Step 5: Notifications ────────────────────────────────────────────────
  if whiptail --backtitle "Community Apps Update" --title "Notifications" \
    --yesno "Enable notifications?\n\nSends the summary table to your configured\nnotification endpoint on completion." 10 60; then
    NOTIFY="yes"
  else
    NOTIFY="no"
  fi

  # ── Step 5b: Backups + Storage ────────────────────────────────────────────
  local backup_result
  backup_result=$(configure_backup_flow "Install" "yes") || return
  BACKUP=$(printf '%s' "$backup_result" | cut -f1)
  BACKUP_STORAGE=$(printf '%s' "$backup_result" | cut -f2-)

  # ── Step 6: Dry-run mode ─────────────────────────────────────────────────
  if whiptail --backtitle "Community Apps Update" --title "Mode" \
    --yesno --defaultno "Enable dry-run mode?\n\nChecks for updates without applying them.\n(Recommended: 'No' for normal operation)" 10 65; then
    DRY_RUN="yes"
  else
    DRY_RUN="no"
  fi

  # ── Step 7: Review & Confirm ─────────────────────────────────────────────
  local schedule_desc
  case "$FREQ" in
    daily)
      schedule_desc="Daily at $(printf '%02d' "$HOUR"):00"
      ;;
    weekly)
      local dow_label
      case "$DOW" in
        0) dow_label="Sunday" ;; 1) dow_label="Monday" ;;   2) dow_label="Tuesday" ;;
        3) dow_label="Wednesday" ;; 4) dow_label="Thursday" ;; 5) dow_label="Friday" ;;
        6) dow_label="Saturday" ;;
      esac
      schedule_desc="Weekly: ${dow_label} at $(printf '%02d' "$HOUR"):00"
      ;;
    monthly)
      schedule_desc="Monthly: day ${DAY} at $(printf '%02d' "$HOUR"):00"
      ;;
  esac

  whiptail --backtitle "Community Apps Update" --title "Review Configuration" \
    --yesno "Please review your configuration:\n\n\
  Containers:     ${CONTAINER_IDS}\n\
  Backups:         ${BACKUP}\n\
  Backup Storage:  ${BACKUP_STORAGE:-not used}\n\
  Schedule:        ${schedule_desc}\n\
  Notifications:   ${NOTIFY}\n\
  Dry-run:         ${DRY_RUN}\n\
\n\
  Install to:      ${LOCAL_SCRIPT}\n\
  Log file:        ${LOG_FILE}\n\
\nProceed with installation?" 19 65 || {
    msg_info "Installation cancelled."
    return
  }

  # ── Step 8: Install script ───────────────────────────────────────────────
  msg_info "Downloading update-community-apps.sh..."
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL -o "$tmp" "$SCRIPT_URL"; then
    msg_error "Failed to download: ${SCRIPT_URL}"
    rm -f "$tmp"
    return
  fi

  install -m 0755 "$tmp" "$LOCAL_SCRIPT"
  rm -f "$tmp"
  msg_ok "Installed to ${LOCAL_SCRIPT}"

  # Write config file and wrapper script for Edit Config support
  local cron_min cron_hour cron_day cron_month cron_dow
  cron_min="0"
  cron_hour="$HOUR"
  case "$FREQ" in
    daily)   cron_day="*";   cron_month="*"; cron_dow="*" ;;
    weekly)  cron_day="*";   cron_month="*"; cron_dow="$DOW" ;;
    monthly) cron_day="$DAY"; cron_month="*"; cron_dow="*" ;;
  esac
  write_config "$cron_min" "$cron_hour" "$cron_day" "$cron_month" "$cron_dow"     "$CONTAINER_IDS" "$BACKUP_STORAGE" "$NOTIFY" "$BACKUP" "$DRY_RUN"
  msg_ok "Wrote config to ${CONFIG_FILE}"

  write_logrotate_config 28 4
  msg_ok "Installed logrotate config to ${LOGROTATE_FILE}"

  # ── Step 9: Add crontab ──────────────────────────────────────────────────
  remove_cron || true  # remove any existing entry first (ok if none)

  # Map frequency to cron fields
  local cron_min cron_hour cron_day cron_month cron_dow
  case "$FREQ" in
    daily)   cron_min="0"; cron_hour="$HOUR"; cron_day="*";   cron_month="*"; cron_dow="*" ;;
    weekly)  cron_min="0"; cron_hour="$HOUR"; cron_day="*";   cron_month="*"; cron_dow="$DOW" ;;
    monthly) cron_min="0"; cron_hour="$HOUR"; cron_day="$DAY"; cron_month="*"; cron_dow="*" ;;
  esac

  # Cron entry calls the wrapper script (which sources the config file),
  # keeping the crontab line compact and editable via Edit Config.
  local cron_entry
  cron_entry="${cron_min} ${cron_hour} ${cron_day} ${cron_month} ${cron_dow} ${WRAPPER_SCRIPT} >>${LOG_FILE} 2>&1"

  (crontab -l -u root 2>/dev/null || true; echo "$cron_entry") | crontab -u root -
  msg_ok "Cron schedule added: ${schedule_desc}"

  echo ""
  echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${GREEN}║               Installation Complete!                         ║${NC}"
  echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BLUE}Script:${NC}  ${LOCAL_SCRIPT}"
  echo -e "  ${BLUE}Log:${NC}     ${LOG_FILE}"
  echo -e "  ${BLUE}Cron:${NC}    ${schedule_desc}"
  echo -e "  ${BLUE}Notify:${NC}  ${NOTIFY}"
  echo -e "  ${BLUE}Backups:${NC} ${BACKUP}"
  [ "$DRY_RUN" = "yes" ] && echo -e "  ${YELLOW}Mode:    DRY-RUN (no updates applied)${NC}"
  echo ""
  echo -e "  Run manually: BACKUP=\"${BACKUP}\" ${LOCAL_SCRIPT} \"${CONTAINER_IDS}\" \"${BACKUP_STORAGE}\""
  echo ""
  read -rp "Press Enter to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    banner

    # Show quick status line
    if crontab -l -u root 2>/dev/null | grep -qE "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}"; then
      local active_schedule
      active_schedule=$(crontab -l -u root 2>/dev/null | grep -E "${LOCAL_SCRIPT}|${WRAPPER_SCRIPT}" | head -1 | awk '{print $1,$2,$3,$4,$5}')
      echo -e "  ${GREEN}Status: Active — ${active_schedule}${NC}"
    else
      echo -e "  ${YELLOW}Status: Not configured${NC}"
    fi
    echo ""

    local choice
    choice=$(whiptail --backtitle "Community Apps Update" --title "Main Menu" \
      --menu "Select an option:" 20 65 10 \
      "Install"    "Install script & configure cron schedule" \
      "Update"     "Update local script from GitHub" \
      "Status"     "Show installation status & last run" \
      "Edit"       "Edit containers, schedule & settings" \
      "Remove"     "Remove cron schedule & local script" \
      "Dry Run"    "Check for updates without applying (dry-run)" \
      "Run Now"    "Run update script now (manual trigger)" \
      "Logs"       "Manage retention, view logs, delete logs" \
      "View"       "View installed script & cron config" \
      "Exit"       "Exit" \
      3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
      "Install")     install_and_configure ;;
      "Update")  update_script ;; 
      "Status")  show_status ;;
      "Edit") edit_config ;;
      "Remove")  remove_all ;;
      "Dry Run") dry_run ;;
      "Run Now") run_now ;;
      "Logs")    logs_menu ;;
      "View")    view_config ;;
      "Exit")    clear; exit 0 ;;
    esac
  done
}

# ── Entry point ──────────────────────────────────────────────────────────────
check_root
check_whiptail
check_deps
main_menu
