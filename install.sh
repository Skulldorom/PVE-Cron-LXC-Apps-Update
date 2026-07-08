#!/usr/bin/env bash
# Community Apps Update — Installer
# Installs update-community-apps.sh and provides interactive cron configuration.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main"
SCRIPT_URL="${REPO_URL}/update-community-apps.sh"
LOCAL_SCRIPT="/usr/local/bin/update-community-apps.sh"
LOG_FILE="/var/log/update-community-apps-cron.log"
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

   ___  __  ___  ____  _  _  __    ___  ____  ____  _  _
  / __)/  \/ __)(  __)/ )( \(  )  / __)(_  _)(  _ \/ )( \
 ( (__(  O ) _ \ ) _) ) \/ (/ (_/\\__ \  )(   )   /) \/ (
  \___)\__/\___/(____)\____/\____/(____/ (__) (__\_)\____/

   Community Apps Update — Cron Installer
   https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update

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
    msg_error "whiptail is required. Install it with: apt install whiptail"
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in jq curl pct vzdump; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    msg_error "Missing required commands: ${missing[*]}"
    msg_info "Install with: apt install jq curl"
    exit 1
  fi
}

# ── Discover containers with community-script tags ───────────────────────────
discover_containers() {
  local containers cid cname cstatus formatted
  containers=$(pct list | tail -n +2)
  if [ -z "$containers" ]; then
    return 1
  fi

  MENU_ITEMS=()
  while read -r container; do
    cid=$(echo "$container" | awk '{print $1}')
    cname=$(echo "$container" | awk '{print $NF}')
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
  local storages
  storages=$(awk '
    /^[a-z]+:/ {
      if (name != "") {
        if (has_backup || (!has_content && type == "dir")) print name
      }
      split($0, a, ":")
      type = a[1]
      name = a[2]
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      has_content = 0
      has_backup = 0
    }
    /^[ \t]*content/ {
      has_content = 1
      if ($0 ~ /backup/) has_backup = 1
    }
    END {
      if (name != "") {
        if (has_backup || (!has_content && type == "dir")) print name
      }
    }
  ' /etc/pve/storage.cfg)

  while read -r storage; do
    [ -n "$storage" ] && STORAGE_ITEMS+=("$storage" "")
  done <<<"$storages"
}

# ── Remove current cron entry ────────────────────────────────────────────────
remove_cron() {
  if crontab -l -u root 2>/dev/null | grep -q "${LOCAL_SCRIPT}"; then
    (crontab -l -u root 2>/dev/null | grep -v "${LOCAL_SCRIPT}") | crontab -u root -
    return 0
  fi
  return 1
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

  if crontab -l -u root 2>/dev/null | grep -q "${LOCAL_SCRIPT}"; then
    local entry schedule
    entry=$(crontab -l -u root 2>/dev/null | grep "${LOCAL_SCRIPT}")
    schedule=$(echo "$entry" | awk '{print $1,$2,$3,$4,$5}')
    msg_ok "Cron active: ${schedule}"
    echo -e "      Full entry: ${entry}"
  else
    msg_error "Cron not configured"
  fi

  if [ -f "$LOG_FILE" ]; then
    local log_size last_run
    log_size=$(du -h "$LOG_FILE" | awk '{print $1}')
    last_run=$(grep 'Community Apps Update' "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/===== //' | sed 's/ =====//')
    echo -e "  ${BLUE}[Info]${NC}  Log: ${LOG_FILE} (${log_size})"
    [ -n "${last_run:-}" ] && echo -e "      Last run: ${last_run}"
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
  echo -e "  ${YELLOW}─── Cron Configuration ────────────────────────────────────────${NC}"
  if crontab -l -u root 2>/dev/null | grep -q "${LOCAL_SCRIPT}"; then
    crontab -l -u root 2>/dev/null | grep "${LOCAL_SCRIPT}"
  else
    msg_error "No cron entry configured."
  fi
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Run now ──────────────────────────────────────────────────────────────────
run_now() {
  if [ ! -f "$LOCAL_SCRIPT" ]; then
    msg_error "No script installed. Use 'Install & Configure' first."
    read -rp "Press Enter to continue..."
    return
  fi
  clear
  msg_info "Running update script now..."
  echo ""
  bash "$LOCAL_SCRIPT" | tee -a "$LOG_FILE" 2>&1
  echo ""
  msg_ok "Run completed. Log appended to ${LOG_FILE}"
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Remove ───────────────────────────────────────────────────────────────────
remove_all() {
  if ! whiptail --backtitle "Community Apps Update" --title "Remove" \
    --yesno "Remove the cron schedule and local script?\n\nThis will delete:\n  • Cron entry\n  • ${LOCAL_SCRIPT}\n\nLog file (${LOG_FILE}) will be kept." 12 65; then
    return
  fi

  if crontab -l -u root 2>/dev/null | grep -q "${LOCAL_SCRIPT}"; then
    (crontab -l -u root 2>/dev/null | grep -v "${LOCAL_SCRIPT}") | crontab -u root -
    msg_ok "Removed cron schedule"
  fi
  if [ -f "$LOCAL_SCRIPT" ]; then
    rm -f "$LOCAL_SCRIPT"
    msg_ok "Removed ${LOCAL_SCRIPT}"
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

  msg_info "Downloading latest version..."
  local tmp
  tmp=$(mktemp)
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
    msg_ok "Already up-to-date (no changes)."
    rm -f "$tmp"
    read -rp "Press Enter to continue..."
    return
  fi

  if command -v diff &>/dev/null; then
    diff --color=always "$LOCAL_SCRIPT" "$tmp" 2>/dev/null || true
  fi

  echo ""
  echo -e "  ${BLUE}Current SHA256:${NC} ${old_hash}"
  echo -e "  ${BLUE}New SHA256:${NC}     ${new_hash}"
  echo ""

  if ! whiptail --backtitle "Community Apps Update" --title "Update" \
    --yesno "Apply update?\n\nCurrent: ${old_hash}\nNew:      ${new_hash}" 10 60; then
    rm -f "$tmp"
    msg_info "Update cancelled."
    return
  fi

  install -m 0755 "$tmp" "$LOCAL_SCRIPT"
  rm -f "$tmp"
  msg_ok "Updated ${LOCAL_SCRIPT}"
  echo ""
  read -rp "Press Enter to continue..."
}

# ── Install & Configure ──────────────────────────────────────────────────────
install_and_configure() {
  # ── Step 1: Discover containers ──────────────────────────────────────────
  msg_info "Scanning for community-script containers..."
  if ! discover_containers || [ ${#MENU_ITEMS[@]} -eq 0 ]; then
    whiptail --backtitle "Community Apps Update" --title "No Containers Found" \
      --msgbox "No LXC containers with community-script tags found.\n\nTags checked: ${TAGS//\|/, }\n\nMake sure your containers are tagged with 'community-script'\nor 'proxmox-helper-scripts' in their Proxmox config." 12 65
    return
  fi

  CHOICE=$(whiptail --backtitle "Community Apps Update" --title "Select Containers" \
    --checklist "Select LXC containers to update:\n(Use SPACE to select, TAB to switch, ENTER to confirm)" \
    20 75 12 \
    "${MENU_ITEMS[@]}" \
    3>&1 1>&2 2>&3 | tr -d '"')

  if [ -z "$CHOICE" ]; then
    msg_info "No containers selected. Aborting."
    return
  fi
  CONTAINER_IDS=$(echo "$CHOICE" | tr '\n' ',' | sed 's/,$//')

  # ── Step 2: Discover storage ─────────────────────────────────────────────
  discover_storages

  if [ ${#STORAGE_ITEMS[@]} -eq 0 ]; then
    whiptail --backtitle "Community Apps Update" --title "No Storage Found" \
      --msgbox "No backup-capable storage found in /etc/pve/storage.cfg.\n\nMake sure you have a storage configured with 'backup' content type." 10 65
    return
  fi

  BACKUP_STORAGE=$(whiptail --backtitle "Community Apps Update" --title "Backup Storage" \
    --menu "Select storage for pre-update backups:" 15 60 8 \
    "${STORAGE_ITEMS[@]}" \
    3>&1 1>&2 2>&3)

  if [ -z "$BACKUP_STORAGE" ]; then
    msg_info "No storage selected. Aborting."
    return
  fi

  # ── Step 3: Schedule — Day of week ───────────────────────────────────────
  DOW=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Day" \
    --menu "Select day of week:" 15 50 8 \
    "0" "Sunday" \
    "1" "Monday" \
    "2" "Tuesday" \
    "3" "Wednesday" \
    "4" "Thursday" \
    "5" "Friday" \
    "6" "Saturday" \
    "*" "Daily" \
    3>&1 1>&2 2>&3)

  [ -z "$DOW" ] && { msg_info "Aborted."; return; }

  # ── Step 4: Schedule — Hour ──────────────────────────────────────────────
  HOUR=$(whiptail --backtitle "Community Apps Update" --title "Schedule — Hour" \
    --menu "Select hour (24h format):" 15 50 8 \
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

  # ── Step 5: Notifications ────────────────────────────────────────────────
  if whiptail --backtitle "Community Apps Update" --title "Notifications" \
    --yesno "Enable Discord notifications?\n\nSends summary table to proxmox-discord-notifier.\n(Requires https://github.com/Skulldorom/proxmox-discord-notifier)" 10 65; then
    NOTIFY="yes"
  else
    NOTIFY="no"
  fi

  # ── Step 6: Dry-run mode ─────────────────────────────────────────────────
  if whiptail --backtitle "Community Apps Update" --title "Mode" \
    --yesno --defaultno "Enable dry-run mode?\n\nChecks for updates without applying them.\n(Recommended: 'No' for normal operation)" 10 65; then
    DRY_RUN="yes"
    DRY_RUN_ARG="dry-run"
  else
    DRY_RUN="no"
    DRY_RUN_ARG=""
  fi

  # ── Step 7: Review & Confirm ─────────────────────────────────────────────
  local dow_label
  case "$DOW" in
    0) dow_label="Sunday" ;;  1) dow_label="Monday" ;;   2) dow_label="Tuesday" ;;
    3) dow_label="Wednesday" ;; 4) dow_label="Thursday" ;; 5) dow_label="Friday" ;;
    6) dow_label="Saturday" ;; *) dow_label="Every day" ;;
  esac

  local schedule_desc
  if [ "$DOW" = "*" ]; then
    schedule_desc="Daily at $(printf '%02d' "$HOUR"):00"
    DOW="*"
  else
    schedule_desc="Every ${dow_label} at $(printf '%02d' "$HOUR"):00"
  fi

  whiptail --backtitle "Community Apps Update" --title "Review Configuration" \
    --yesno "Please review your configuration:\n\n\
  Containers:     ${CONTAINER_IDS}\n\
  Backup Storage:  ${BACKUP_STORAGE}\n\
  Schedule:        ${schedule_desc}\n\
  Notifications:   ${NOTIFY}\n\
  Dry-run:         ${DRY_RUN}\n\
\n\
  Install to:      ${LOCAL_SCRIPT}\n\
  Log file:        ${LOG_FILE}\n\
\nProceed with installation?" 18 65 || {
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

  # ── Step 9: Add crontab ──────────────────────────────────────────────────
  remove_cron  # remove any existing entry first

  local cron_entry cron_env
  cron_env="NOTIFY=${NOTIFY}"
  cron_entry="${cron_env} ${LOCAL_SCRIPT} \"${CONTAINER_IDS}\" \"${BACKUP_STORAGE}\""

  [ "$DRY_RUN" = "yes" ] && cron_entry="${cron_entry} dry-run"

  cron_entry="${cron_entry} >>${LOG_FILE} 2>&1"
  cron_entry="0 ${HOUR} * * ${DOW} ${cron_entry}"

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
  [ "$DRY_RUN" = "yes" ] && echo -e "  ${YELLOW}Mode:    DRY-RUN (no updates applied)${NC}"
  echo ""
  echo -e "  Run manually: ${LOCAL_SCRIPT} \"${CONTAINER_IDS}\" \"${BACKUP_STORAGE}\""
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
    if crontab -l -u root 2>/dev/null | grep -q "${LOCAL_SCRIPT}"; then
      local active_schedule
      active_schedule=$(crontab -l -u root 2>/dev/null | grep "${LOCAL_SCRIPT}" | head -1 | awk '{print $1,$2,$3,$4,$5}')
      echo -e "  ${GREEN}Status: Active — ${active_schedule}${NC}"
    else
      echo -e "  ${YELLOW}Status: Not configured${NC}"
    fi
    echo ""

    local choice
    choice=$(whiptail --backtitle "Community Apps Update" --title "Main Menu" \
      --menu "Select an option:" 18 60 7 \
      "Install" "Install script & configure cron schedule" \
      "Update"  "Update local script from GitHub" \
      "Remove"  "Remove cron schedule & local script" \
      "Status"  "Show installation status & last run" \
      "Run Now" "Run update script now (manual trigger)" \
      "View"    "View installed script & cron config" \
      "Exit"    "Exit" \
      3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
      "Install") install_and_configure ;;
      "Update")  update_script ;;
      "Remove")  remove_all ;;
      "Status")  show_status ;;
      "Run Now") run_now ;;
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
