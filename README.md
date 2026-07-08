# PVE-Cron-LXC-Apps-Update

Automates weekly updates of community-scripts-managed LXC containers on a Proxmox VE node. Runs the official `update-apps.sh` with all env vars preset, strips the per-container verbose logging, and optionally sends the final summary table via **[proxmox-discord-notifier](https://github.com/Skulldorom/proxmox-discord-notifier)**.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

This launches an interactive whiptail menu that:
1. Scans your Proxmox node for community-script LXC containers
2. Detects backup-capable storage targets
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
- Optionally POSTs the summary to [proxmox-discord-notifier](https://github.com/Skulldorom/proxmox-discord-notifier)
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
| `NOTIFY` | `yes` | Set to `no` to skip Discord notification |
| `NOTIFIER_URL` | `http://192.168.0.11:6068/api/notify` | Override notifier endpoint |

## Requirements

- Proxmox VE node with `pct` and `vzdump` available
- `jq`, `curl`, and `whiptail` installed on the host
- Community-scripts-managed LXC containers (tagged `community-script` or `proxmox-helper-scripts`)
- Storage target(s) configured in Proxmox with `backup` content type enabled
- [proxmox-discord-notifier](https://github.com/Skulldorom/proxmox-discord-notifier) (optional — only needed if `NOTIFY=yes`)

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/update-community-apps.sh` | The worker script (installed by `install.sh`) |
| `/var/log/update-community-apps-*.log` | Per-run full output logs |
| `/var/log/update-community-apps-cron.log` | Cron output log |

## Installer Menu Options

| Option | Description |
|--------|-------------|
| **Install** | Discover containers & storage, configure schedule, install cron |
| **Update** | Diff and pull latest `update-community-apps.sh` from GitHub |
| **Remove** | Remove cron schedule and local script |
| **Status** | Show installed state, cron entry, and last run |
| **Run Now** | Manual trigger — runs script immediately |
| **View** | Display installed script content and cron config |

## License

MIT — see [LICENSE](LICENSE)
