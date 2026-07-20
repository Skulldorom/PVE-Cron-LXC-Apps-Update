# PVE-Cron-LXC-Apps-Update

> **Disclaimer:** This project is NOT affiliated with, endorsed by, or connected to [community-scripts](https://community-scripts.org) / Proxmox VE Helper Scripts. It is an independent wrapper that automates their `update-apps.sh` tool.

PVE-Cron-LXC-Apps-Update automates unattended updates for community-scripts-managed LXC containers on Proxmox VE. It runs update-apps.sh, backs up containers first, and posts a clean summary notification.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

This launches an interactive whiptail menu that:
1. Scans your Proxmox node for community-script LXC containers
2. Walks you through frequency (daily/weekly/monthly), hour, notifications, backups, and dry-run options
3. If backups are enabled, detects backup-capable storage targets using the upstream `update-apps.sh` selection logic
4. Installs `update-community-apps.sh`, a cron wrapper script, and configures the crontab

## What It Does

- Runs [community-scripts `update-apps.sh`](https://community-scripts.org/docs/tools/pve/update-apps) unattended with:
  - `var_backup=yes|no` — snapshot with `vzdump` before updating (toggleable)
  - `var_unattended=yes` — no interactive prompts inside containers
  - `var_skip_confirm=yes` — skip initial confirmation
  - `var_continue_on_error=yes` — continue to next CT if one fails
  - `var_auto_reboot=yes` — reboot CT if app requires it
- **Per-container error resilience** — one container failing does not abort the run; downstream processing (summary, notification, status file) always executes
- **Clean readable logs only** — produces a single `-clean.log` per run from upstream's own `Full log:` file; raw terminal-noise output is only held temporarily as a fallback
- **Last-run status file** — writes `/var/log/update-community-apps-last-status` with exit code, timestamp, containers, and error count; the installer Status menu reads it for ✅/❌ display
- Captures the summary table for quick review
- Optionally sends the summary followed by the clean run log, with the ending summary removed, through Proxmox VE's default notification pipeline
- Upstream's generated full log is copied into `/var/log/update-community-apps-YYYYMMDD_HHMMSS-clean.log` without duplicating noisy spinner output into the stable cron log

## Manual Usage

```bash
# Normal update — backup then update
/usr/local/bin/update-community-apps.sh "101,102,105,109,111" "HDD-Storage"

# Dry-run — check what's available without applying
/usr/local/bin/update-community-apps.sh "101,102,105,109,111" "HDD-Storage" dry-run

# Run without backups — no storage selection needed
BACKUP=no /usr/local/bin/update-community-apps.sh "101,102,105,109,111"
```

| Arg | Required | Description |
|-----|----------|-------------|
| `container_ids` | ✅ | Comma-separated list of CT IDs to update |
| `backup_storage` | Required when `BACKUP=yes` | Proxmox storage name for pre-update backups |
| `dry-run` | ❌ | Pass `dry-run` as 3rd arg to check only |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFY` | `yes` | Set to `no` to skip Proxmox notification delivery |
| `BACKUP` | `yes` | Set to `no` to skip pre-update vzdump backups |

## Configuration

The installer creates a config file at `/etc/update-community-apps/config` with all settings:

```
CONTAINER_IDS="101,102,105"
BACKUP_STORAGE="local"
BACKUP="yes"
SCHEDULE="0 5 * * 0"
NOTIFY="yes"
DRY_RUN="no"
```

A thin wrapper script at `/usr/local/bin/update-community-apps-wrapper.sh` sources this config and calls the worker. The crontab entry invokes the wrapper, keeping the cron line compact and editable via the **Edit Config** menu.

### Edit Config

The installer's **Edit Config** menu shows each current value and lets you keep it or change only that setting — no reinstall, no remembering your old LXC IDs, no ritual sacrifice to the cron gods. When backups are enabled, storage is selected immediately after the backup prompt; when backups are disabled, storage is skipped. It rewrites the config file, wrapper script, and crontab entry atomically.

## Requirements

- Proxmox VE node with `pct` and `vzdump` available
- `curl` and `whiptail` installed on the host
- Community-scripts-managed LXC containers (tagged `community-script` or `proxmox-helper-scripts`)
- Storage target(s) configured in Proxmox with `backup` content type enabled
- The installer lists storage targets using the same backup-capable storage detection as the upstream `update-apps.sh` tool

## Recommendations

- **Proxmox notifications** — configure notification targets and matchers in Proxmox VE (`Datacenter` → `Notifications`). When enabled, this updater sends the summary at the top of the notification, followed by a sanitized run log with terminal redraws, banners, scan progress spam, and the ending summary removed, through the default Proxmox notification pipeline instead of posting to a custom webhook URL. The updater creates the required `simple` notification templates in `/etc/pve/notification-templates/default/` if they are missing, so webhook targets can render the summary payload.
- **[proxmox-discord-notifier](https://github.com/Skulldorom/proxmox-discord-notifier)** — companion service that receives the JSON webhook payload and delivers it to Discord. Provides rich embed formatting for update summaries. Install it on your homelab and point `NOTIFIER_URL` at its `/api/notify` endpoint.
- **Log monitoring** — check `/var/log/update-community-apps-*-clean.log` for readable run output based on upstream's own `Full log:` file. Raw terminal-noise output is not kept as a separate timestamped log and is not duplicated into `/var/log/update-community-apps-cron.log`. Notification delivery failures are logged as `[WARN]` lines in the clean log.

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/update-community-apps.sh` | The worker script (installed by `install.sh`) |
| `/usr/local/bin/update-community-apps-wrapper.sh` | Cron wrapper — sources config, calls worker |
| `/etc/update-community-apps/config` | Configuration file (source-able key=value pairs) |
| `/var/log/update-community-apps-YYYYMMDD_HHMMSS-clean.log` | Per-run clean worker log copied from upstream's `Full log:` output |
| `/var/log/update-community-apps-cron.log` | Stable cron stdout/stderr log |
| `/var/log/update-community-apps-last-status` | Last-run status (exit code, timestamp, errors) |

### Log Rotation

Each run creates one timestamped clean worker log file. Timestamped logs accumulate because every run uses a unique path, so the included logrotate config uses a `maxage 28` cleanup policy to delete clean worker logs older than 28 days. The cron stdout/stderr log is handled separately as `/var/log/update-community-apps-cron.log`, rotates daily, keeps 3 compressed rotations, and rotates early at 10 MB.

To prevent unbounded accumulation, install the included logrotate config:

```bash
cp logrotate.conf /etc/logrotate.d/update-community-apps
```

Or download directly:

```bash
curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/logrotate.conf \
  -o /etc/logrotate.d/update-community-apps
```

This removes timestamped worker logs older than 28 days, and keeps 3 compressed daily rotations of the stable cron log with a 10 MB max size. The installer also includes a **Logs** menu where you can change the timestamped worker log retention period, browse all current updater logs, or delete current updater logs.

## Installer Menu Options

| Option | Description |
|--------|-------------|
| **Install** | Discover containers & storage, configure schedule, install cron |
| **Edit Config** | Keep current settings or change only containers, backups/storage, schedule, notifications, and dry-run without reinstalling |
| **Dry Run** | Check for updates without applying (reads args from config or prompts) |
| **Update** | Diff and pull latest `update-community-apps.sh` from GitHub |
| **Remove** | Remove cron schedule, wrapper, config file, and local script |
| **Status** | Show installed state, human-readable schedule, ✅/❌ last-run outcome |
| **Run Now** | Manual trigger — runs script immediately |
| **Logs** | Manage log retention, view update logs, and delete current update logs |
| **View** | Display installed script, config file, and cron config |

## Schedule Options

The installer supports three schedule frequencies:

| Frequency | Cron Expression | Example Display |
|-----------|----------------|-----------------|
| **Daily** | `0 H * * *` | "Daily at 05:00" |
| **Weekly** | `0 H * * DOW` | "Weekly: Sunday at 05:00" |
| **Monthly** | `0 H DAY * *` | "Monthly: day 15 at 05:00" |

The Status menu parses the cron entry and displays a human-readable schedule description. The Edit Config menu lets you change the schedule at any time.

## License

MIT — see [LICENSE](LICENSE)
