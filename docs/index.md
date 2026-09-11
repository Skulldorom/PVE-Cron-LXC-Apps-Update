# PVE Cron LXC Apps Update

Independent Proxmox VE helper for scheduled **application-level updates inside community-scripts-managed LXC containers**.

It is a local wrapper around the community-scripts `update-apps.sh` tool. It does not replace Proxmox package updates, container OS updates, or backups. It is not affiliated with community-scripts.

## Quick install

Run on the Proxmox VE node as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

Node/npm is only for building this documentation site. It is not needed to install or run the updater on Proxmox.

## What problem it solves

community-scripts provides `update-apps.sh` for supported application containers. This project adds operator-friendly automation around it:

- explicit selected-container allow-list
- scheduled cron execution
- backup-before-update support through `vzdump`
- Proxmox notification summaries
- manual dry runs
- status persistence and clean timestamped logs
- upstream last-known-good cache for GitHub/raw CDN outages
- migration from older wrapper/config layouts
- optional Healthchecks.io-compatible monitoring

## Common tasks

| Question | Start here |
| --- | --- |
| Where is my config? | [Configuration](./guide/configuration.md) |
| How do I run it manually? | [Running](./guide/running.md) |
| How do I see whether it worked? | [Status](./guide/status.md) |
| Where are logs? | [Logging](./guide/logging.md) |
| How do backups work? | [Backups](./guide/backups.md) |
| What happens if GitHub is unavailable? | [Upstream cache](./guide/upstream-cache.md) |
| How do I migrate from the old layout? | [Migration](./maintenance/migration.md) |
| What files belong to this project? | [Files reference](./reference/files.md) |

## Safe first verification

```bash
/usr/local/bin/update-community-apps.sh --status
```

Successful output shows the worker is installed, configuration status is `ok`, selected containers are listed, and last-run information appears after the first real or dry run.
