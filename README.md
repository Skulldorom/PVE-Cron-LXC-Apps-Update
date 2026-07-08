# PVE-Cron-LXC-Apps-Update

> **Disclaimer:** This project is NOT affiliated with, endorsed by, or connected to [community-scripts](https://community-scripts.org) / Proxmox VE Helper Scripts. It is an independent wrapper that automates their `update-apps.sh` tool.

Automates weekly updates of community-scripts-managed LXC containers on a Proxmox VE node. Runs the official `update-apps.sh` with all env vars preset, strips the per-container verbose logging, and optionally sends the final summary table to any JSON webhook endpoint (e.g., Discord, Slack, Gotify).

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

This launches an interactive whiptail menu that:
1. Scans your Proxmox node for community-script LXC containers
2. Detects backup-capable storage targets available to this node
3. Walks you through schedule, notifications, and dry-run options
4. Installs `update-community-apps.sh` and configures the crontab

## What It Does

- Runs [community-scripts `update-apps.sh`](https://community-scripts.org/docs/tools/pve/update-apps) unattended with:
  - `var_backup=yes` — snapshot with `vzdump` before updating
  - `var_unattended=yes` — no interactive prompts inside containers
  - `var_skip_confirm=yes` — skip initial confirmation
  - `var_continue_on_error=yes` — continue to next CT if one fails
  - `var_auto_reboot=yes` — reboot CT if app requires it
- Captures the summary table (strips verbose per-container logs)
- Optionally POSTs the summary to a configurable JSON webhook endpoint (see [Recommendations](#recommendations))
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
| `NOTIFY` | `yes` | Set to `no` to skip webhook notification |
| `NOTIFIER_URL` | `http://192.168.0.11:6068/api/notify` | JSON webhook URL (compatible with Discord, Slack, Gotify, etc.) |

## Requirements

- Proxmox VE node with `pct` and `vzdump` available
- `jq`, `curl`, and `whiptail` installed on the host
- Community-scripts-managed LXC containers (tagged `community-script` or `proxmox-helper-scripts`)
- Storage target(s) configured in Proxmox with `backup` content type enabled
- The installer automatically filters storages by node — only targets available to the current node are shown

## Recommendations

- **[proxmox-discord-notifier](https://github.com/Skulldorom/proxmox-discord-notifier)** — companion service that receives the JSON webhook payload and delivers it to Discord. Provides rich embed formatting for update summaries. Install it on your homelab and point `NOTIFIER_URL` at its `/api/notify` endpoint.
- **Log monitoring** — check `/var/log/update-community-apps-*.log` periodically. Notification delivery failures are logged as `[WARN]` lines so you can catch misconfigured webhooks even when notifications are enabled.

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/update-community-apps.sh` | The worker script (installed by `install.sh`) |
| `/var/log/update-community-apps-*.log` | Per-run full output logs |
| `/var/log/update-community-apps-cron.log` | Cron output log |

### Log Rotation

Each run creates a timestamped log file. To prevent unbounded accumulation, install the included logrotate config:

```bash
cp logrotate.conf /etc/logrotate.d/update-community-apps
```

Or download directly:

```bash
curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/logrotate.conf \
  -o /etc/logrotate.d/update-community-apps
```

This keeps 4 weekly rotations with compression.

## Installer Menu Options

| Option | Description |
|--------|-------------|
| **Install** | Discover containers & storage, configure schedule, install cron |
| **Dry Run** | Check for updates without applying (reads args from cron or prompts) |
| **Update** | Diff and pull latest `update-community-apps.sh` from GitHub |
| **Remove** | Remove cron schedule and local script |
| **Status** | Show installed state, cron entry, and last run |
| **Run Now** | Manual trigger — runs script immediately |
| **View** | Display installed script content and cron config |

## License

MIT — see [LICENSE](LICENSE)
