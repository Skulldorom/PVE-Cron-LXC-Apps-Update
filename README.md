# PVE-Cron-LXC-Apps-Update

> **Disclaimer:** This project is NOT affiliated with, endorsed by, or connected to [community-scripts](https://community-scripts.org) / Proxmox VE Helper Scripts. It is an independent wrapper that automates their `update-apps.sh` tool.

PVE-Cron-LXC-Apps-Update automates unattended updates for community-scripts-managed LXC containers on Proxmox VE. It runs update-apps.sh, backs up containers first, and posts a clean summary notification.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

This launches an interactive whiptail menu that:
1. Scans your Proxmox node for community-script LXC containers
2. Detects backup-capable storage targets using the upstream `update-apps.sh` selection logic
3. Walks you through schedule, notifications, and dry-run options
4. Installs `update-community-apps.sh` and configures the crontab

## What It Does

- Runs [community-scripts `update-apps.sh`](https://community-scripts.org/docs/tools/pve/update-apps) unattended with:
  - `var_backup=yes` — snapshot with `vzdump` before updating
  - `var_unattended=yes` — no interactive prompts inside containers
  - `var_skip_confirm=yes` — skip initial confirmation
  - `var_continue_on_error=yes` — continue to next CT if one fails
  - `var_auto_reboot=yes` — reboot CT if app requires it
- Captures the summary table for quick review
- Optionally sends the summary followed by a sanitized run log with terminal redraws, banners, scan progress spam, and the ending summary removed through Proxmox VE's default notification pipeline
- Full output logged to `/var/log/update-community-apps-YYYYMMDD_HHMMSS.log`

## Manual Usage

```bash
# Normal update — backup then update
/usr/local/bin/update-community-apps.sh "101,102,105,109,111" "HDD-Storage"

# Dry-run — check what's available without applying
/usr/local/bin/update-community-apps.sh "101,102,105,109,111" "HDD-Storage" dry-run
```

| Arg | Required | Description |
|-----|----------|-------------|
| `container_ids` | ✅ | Comma-separated list of CT IDs to update |
| `backup_storage` | ✅ | Proxmox storage name for pre-update backups |
| `dry-run` | ❌ | Pass `dry-run` as 3rd arg to check only |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFY` | `yes` | Set to `no` to skip Proxmox notification delivery |

## Requirements

- Proxmox VE node with `pct` and `vzdump` available
- `curl` and `whiptail` installed on the host
- Community-scripts-managed LXC containers (tagged `community-script` or `proxmox-helper-scripts`)
- Storage target(s) configured in Proxmox with `backup` content type enabled
- The installer lists storage targets using the same backup-capable storage detection as the upstream `update-apps.sh` tool

## Recommendations

- **Proxmox notifications** — configure notification targets and matchers in Proxmox VE (`Datacenter` → `Notifications`). When enabled, this updater sends the summary at the top of the notification, followed by a sanitized run log with terminal redraws, banners, scan progress spam, and the ending summary removed, through the default Proxmox notification pipeline instead of posting to a custom webhook URL. The updater creates the required `simple` notification templates in `/etc/pve/notification-templates/default/` if they are missing, so webhook targets can render the summary payload.
- **[proxmox-discord-notifier](https://github.com/Skulldorom/proxmox-discord-notifier)** — companion service that receives the JSON webhook payload and delivers it to Discord. Provides rich embed formatting for update summaries. Install it on your homelab and point `NOTIFIER_URL` at its `/api/notify` endpoint.
- **Log monitoring** — check `/var/log/update-community-apps-*.log` periodically. Notification delivery failures are logged as `[WARN]` lines so you can catch Proxmox notification issues even when notifications are enabled.

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/update-community-apps.sh` | The worker script (installed by `install.sh`) |
| `/var/log/update-community-apps-YYYYMMDD_HHMMSS.log` | Per-run full worker output logs |
| `/var/log/update-community-apps-cron.log` | Stable cron stdout/stderr log |

### Log Rotation

Each run creates a timestamped worker log file. Timestamped logs accumulate because every run uses a unique path, so the included logrotate config uses a `maxage 28` cleanup policy to delete worker logs older than 28 days. The cron stdout/stderr log is handled separately as `/var/log/update-community-apps-cron.log` and keeps 4 weekly rotations.

To prevent unbounded accumulation, install the included logrotate config:

```bash
cp logrotate.conf /etc/logrotate.d/update-community-apps
```

Or download directly:

```bash
curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/logrotate.conf \
  -o /etc/logrotate.d/update-community-apps
```

This removes timestamped worker logs older than 28 days, and keeps 4 weekly rotations of the stable cron log, with compression enabled for both. The installer also includes a **Logs** menu where you can change the timestamped worker log retention period, browse all current updater logs, or delete current updater logs.

## Installer Menu Options

| Option | Description |
|--------|-------------|
| **Install** | Discover containers & storage, configure schedule, install cron |
| **Dry Run** | Check for updates without applying (reads args from cron or prompts) |
| **Update** | Diff and pull latest `update-community-apps.sh` from GitHub |
| **Remove** | Remove cron schedule and local script |
| **Status** | Show installed state, cron entry, and last run |
| **Run Now** | Manual trigger — runs script immediately |
| **Logs** | Manage log retention, view update logs, and delete current update logs |
| **View** | Display installed script content and cron config |

## License

MIT — see [LICENSE](LICENSE)
