---
layout: home

hero:
  name: PVE Cron LXC Apps Update
  text: Scheduled community-scripts LXC app updates for Proxmox VE
  tagline: Select containers, run safe unattended application updates, keep logs and status, and monitor the result without replacing normal Proxmox maintenance.
  actions:
    - theme: brand
      text: Install
      link: /getting-started/installation
    - theme: alt
      text: Configure
      link: /guide/configuration
    - theme: alt
      text: GitHub
      link: https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update

features:
  - title: Container app updates
    details: Wraps the community-scripts update-apps.sh flow for selected LXC containers managed on a Proxmox VE node.
  - title: Operator-safe automation
    details: Adds cron scheduling, dry runs, backup-before-update support, Proxmox notifications, status files, and timestamped logs.
  - title: Monitoring and recovery
    details: Supports optional Healthchecks-compatible pings and a last-known-good upstream cache for GitHub/raw CDN outages.
---

## What is this?

PVE Cron LXC Apps Update is an independent Proxmox VE helper for scheduled **application-level updates inside community-scripts-managed LXC containers**. It is a local wrapper around the community-scripts `update-apps.sh` tool. It does not replace Proxmox package updates, container OS updates, or backups.

## Install

Run the installer on the Proxmox VE node as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

Node/npm is only needed to build this documentation site. It is not needed to install or run the updater on Proxmox.

## Configure

The current configuration file is:

```text
/etc/update-community-apps.conf
```

Open it with:

```bash
nano /etc/update-community-apps.conf
```

Start with [Configuration](./guide/configuration.md), then review [Scheduling](./guide/scheduling.md), [Backups](./guide/backups.md), [Notifications](./guide/notifications.md), and [Healthchecks](./guide/healthchecks.md).

## Run and check

Use the installed worker directly:

```bash
/usr/local/bin/update-community-apps.sh --status
/usr/local/bin/update-community-apps.sh --dry-run
/usr/local/bin/update-community-apps.sh --refresh-upstream-cache
```

Manual run details live in [Running](./guide/running.md). Status output is explained in [Status](./guide/status.md). Logs are covered in [Logging](./guide/logging.md).

## Troubleshoot

If installation, validation, cache refresh, backups, or container updates fail, start with [Troubleshooting](./troubleshooting/) and the [CLI reference](./reference/cli.md).
