# PVE-Cron-LXC-Apps-Update

> **Disclaimer:** This project is NOT affiliated with, endorsed by, or connected to [community-scripts](https://community-scripts.org) / Proxmox VE Helper Scripts. It is an independent wrapper that automates their `update-apps.sh` tool.

PVE-Cron-LXC-Apps-Update automates unattended **application-level** updates for community-scripts-managed LXC containers on Proxmox VE. It runs upstream `update-apps.sh`, backs up containers first, and posts a clean summary notification.

<p align="center">
  <a href="https://ko-fi.com/skulldorom"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Support me on Ko-fi" /></a>
</p>

## What this project does

Runs [community-scripts `update-apps.sh`](https://community-scripts.org/docs/tools/pve/update-apps) against an explicitly selected allow-list of LXC containers, optionally backing them up first, then produces useful logging, status and notifications.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

This launches an interactive whiptail menu that:
1. Scans your Proxmox node for community-script LXC containers
2. Walks you through frequency (daily/weekly/monthly), hour, notifications, backups, and dry-run options
3. If backups are enabled, detects backup-capable storage targets using the upstream `update-apps.sh` selection logic
4. Installs `update-community-apps.sh`, writes the config, and configures the crontab to invoke the worker directly

## How it runs

The scheduled command is simply the worker:

```text
0 4 * * 0 /usr/local/bin/update-community-apps.sh >>/var/log/update-community-apps-cron.log 2>&1
```

Runtime configuration comes from `/etc/update-community-apps.conf`, not from the cron line. Changing configuration (containers, backups, storage, notifications, schedule) never requires reinstalling the worker.

## Configuration

The config file is `/etc/update-community-apps.conf`:

```
CONTAINERS="101,102,105"
BACKUP_STORAGE="local"
BACKUP="yes"
NOTIFY="yes"
AUTO_REBOOT="yes"
UPSTREAM_REFRESH="yes"
ALLOW_CACHED_UPSTREAM="yes"
DRY_RUN="no"
HEALTHCHECK_URL=""
```

| Key | Default | Description |
|-----|---------|-------------|
| `CONTAINERS` | — | Comma- or whitespace-separated allow-list of CT IDs |
| `BACKUP_STORAGE` | — | Proxmox storage for pre-update `vzdump` backups (required when `BACKUP=yes`) |
| `BACKUP` | `yes` | Snapshot/backup before updating |
| `NOTIFY` | `yes` | Send Proxmox notification after the run |
| `AUTO_REBOOT` | `yes` | Reboot CT if the app requires it |
| `UPSTREAM_REFRESH` | `yes` | Attempt to refresh the upstream cache at run start |
| `ALLOW_CACHED_UPSTREAM` | `yes` | Fall back to the cached upstream script when refresh fails |
| `DRY_RUN` | `no` | Check-only mode |
| `HEALTHCHECK_URL` | — | Optional Healthchecks.io/dead-man ping URL (disabled when empty) |

The config is parsed with a **constrained key/value reader**, never shell `source`, so a config file cannot execute arbitrary commands. Validation rejects invalid container IDs, malformed booleans, and `BACKUP=yes` without a storage target.

Effective worker precedence is:

```text
built-in defaults < environment/default variables < config < explicit CLI arguments
```

Most importantly, an explicit `--dry-run` always remains a dry run even if the config contains `DRY_RUN="no"`.

## Upstream cache & fallback

The worker downloads upstream `update-apps.sh` to a **last-known-good** cache so a transient GitHub / `raw.githubusercontent.com` / CDN / DNS outage does not prevent scheduled maintenance.

Cache location: `/usr/local/lib/update-community-apps/update-apps.sh` (plus `update-apps.meta` with source URL, SHA256, refresh timestamp).

```text
Attempt upstream refresh
        |
        +-- success --> validate --> atomically replace cache --> execute cache
        |
        +-- failure --> valid cached copy exists?
                            |
                            +-- yes --> warn + execute cached copy
                            |
                            +-- no --> fail safely + notify
```

- Downloads go to a temporary file first, then are validated (non-empty, shebang, `bash -n`, not HTML) before atomic replacement.
- A failed/empty/partial download **never** replaces a known-good cache.
- SHA256, source URL and refresh timestamp are recorded in the cache metadata for observability, change detection, and debugging. The SHA256 does **not** independently authenticate the upstream source.
- The log clearly states whether the run used fresh or cached upstream code, and warns on fallback.
- If neither a fresh download nor a valid cache is available, the run aborts safely and notifies.

### Manual cache refresh

```bash
/usr/local/bin/update-community-apps.sh --refresh-upstream-cache
```

Prints the cache path and SHA256 on success, leaves the existing cache untouched on failure.

## Manual Usage

```bash
# Normal update — reads config
/usr/local/bin/update-community-apps.sh

# Dry-run — check what's available without applying
/usr/local/bin/update-community-apps.sh --dry-run

# Status overview
/usr/local/bin/update-community-apps.sh --status

# Override containers/storage inline (legacy positional form)
/usr/local/bin/update-community-apps.sh "101,102,105" "HDD-Storage" dry-run
```

The legacy positional arguments (`container_ids`, `backup_storage`, `dry-run`) remain supported. Without arguments the worker reads the config file.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFY` | `yes` | Set to `no` to skip Proxmox notification delivery |
| `BACKUP` | `yes` | Set to `no` to skip pre-update vzdump backups |
| `MAX_WORKER_LOG_BYTES` | `10485760` | Maximum bytes for each persisted timestamped worker log |
| `MAX_UPSTREAM_CAPTURE_BYTES` | `1048576` | Maximum bytes retained from upstream terminal output while looking for the `Full log:` pointer |
| `UPDATE_COMMUNITY_APPS_CONFIG_FILE` | `/etc/update-community-apps.conf` | Config file path |
| `UPDATE_COMMUNITY_APPS_LOG_DIR` | `/var/log` | Directory for timestamped worker logs |
| `UPDATE_COMMUNITY_APPS_STATUS_FILE` | `$UPDATE_COMMUNITY_APPS_LOG_DIR/update-community-apps-last-status` | Last-run status file |
| `UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR` | `/usr/local/community-scripts/update_apps` | Upstream `update-apps.sh` full-log directory |
| `UPDATE_COMMUNITY_APPS_UPSTREAM_SCRIPT_URL` | community-scripts raw GitHub URL | Upstream script URL |
| `UPDATE_COMMUNITY_APPS_CACHE_DIR` | `/usr/local/lib/update-community-apps` | Upstream cache directory |
| `UPDATE_COMMUNITY_APPS_LOCK_FILE` | `/run/update-community-apps.lock` | Concurrency lock file |

## Status

`--status` (and the installer's Status menu) reports an operational overview:

```text
Worker installed: yes
Worker SHA256: ...
Configured containers: ...
Backup: enabled
Backup storage: ...
Notifications: enabled

Upstream cache:
  Present: yes
  Source: ...
  SHA256: ...
  Last refreshed: ...
  Age: ...

Last run:
  Timestamp: ...
  Exit code: ...
  Used upstream: fresh/cached
  Log: ...
```

## Backups

When `BACKUP=yes`, each selected container is snapshotted with `vzdump` before `update-apps.sh` runs. `BACKUP=yes` without a `BACKUP_STORAGE` is rejected at config-validation time. Backup semantics are unchanged from upstream application-update behaviour.

## Notifications

When `NOTIFY=yes`, the worker sends the sanitized summary followed by the clean run log (ending summary removed) through Proxmox VE's default notification pipeline. The worker creates the required `simple` notification templates in `/etc/pve/notification-templates/default/` if missing.

## Healthchecks (optional)

Set `HEALTHCHECK_URL` to your Healthchecks.io (or compatible) ping URL to enable dead-man monitoring. When configured, the worker sends `/start` at run begin, then reports success or `/fail` at the end (with the log attached on failure). Healthchecks is supplementary to native Proxmox notifications — a Healthchecks network failure never breaks the updater, retries are bounded, and the URL is never echoed into logs.

## Logging

Each run produces one timestamped `.log`, capped at `MAX_WORKER_LOG_BYTES` (10 MiB default). Key lifecycle events are recorded explicitly:

```text
Updater started
Configuration loaded
Lock acquired
Refreshing upstream cache
Upstream refresh successful
Upstream SHA256: ...
Using freshly downloaded upstream
```

or, on fallback:

```text
WARNING: upstream refresh failed
Using last-known-good cached update-apps.sh
Cached SHA256: ...
Cached age: ...
```

and finally:

```text
Updater completed
Result: success / partial failure / failure
```

## Concurrency

A `flock` on `/run/update-community-apps.lock` prevents overlapping runs. A second invocation while one is running detects the existing run, logs the reason, and exits cleanly without running simultaneous backups/updates or corrupting cache/status/log state.

## Updating the worker

The installer's **Update** menu checks the latest `update-community-apps.sh` from GitHub, computes current and candidate SHA256, shows a diff when running interactively, requires confirmation before replacing local code, and installs atomically. The working config and cron schedule are preserved. Worker updates and application updates are separate concepts — the scheduled run does **not** silently self-update the worker.

## Uninstall

The **Remove** menu removes only project-owned artifacts: the local worker, the legacy wrapper shim, the cron entry, the upstream cache, and the last-run status file. Configuration is preserved by default (you are asked before deleting it). Log files are kept. Community Scripts files and LXC software are never touched.

## Requirements

- Proxmox VE node with `pct` and `vzdump` available
- `curl` and `whiptail` installed on the host
- Community-scripts-managed LXC containers (tagged `community-script` or `proxmox-helper-scripts`)
- Storage target(s) configured in Proxmox with `backup` content type enabled
- The installer lists storage targets using the same backup-capable storage detection as the upstream `update-apps.sh` tool

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/update-community-apps.sh` | Stable local worker |
| `/etc/update-community-apps.conf` | Persistent configuration |
| `/usr/local/lib/update-community-apps/update-apps.sh` | Cached/validated upstream worker |
| `/usr/local/lib/update-community-apps/update-apps.meta` | Cache metadata (SHA256, source, timestamp) |
| `/var/log/update-community-apps-YYYYMMDD_HHMMSS.log` | Per-run worker log |
| `/var/log/update-community-apps-cron.log` | Stable cron stdout/stderr log |
| `/var/log/update-community-apps-last-status` | Last-run status |
| `/run/update-community-apps.lock` | Concurrency lock |
| `/etc/logrotate.d/update-community-apps` | Log rotation config |

A legacy wrapper at `/usr/local/bin/update-community-apps-wrapper.sh` is retained only as a compatibility shim for pre-existing cron entries; new installs point cron directly at the worker.

### Log Rotation

The included logrotate config removes timestamped worker logs older than 28 days and rotates the cron log daily (3 compressed rotations, 10 MB max).

## Migration

Existing installations are migrated automatically. The old `/etc/update-community-apps/config` (wrapper + `source` model) is converted to `/etc/update-community-apps.conf`, preserving selected containers, backup settings, backup storage, notification preference and schedule. The cron entry is updated to invoke the worker directly while keeping the existing schedule.

After migration, `/etc/update-community-apps.conf` is authoritative. The old `/etc/update-community-apps/config` may remain as a rollback/compatibility artifact, but it is **not** an active configuration source while the new config exists. Editing the legacy file after migration does not change updater behavior. Re-running migration is idempotent and does not duplicate cron entries or rewrite operator settings from the legacy artifact.

## Testing

```bash
bash -n update-community-apps.sh install.sh tests/*.sh
bash tests/run.sh
bash tests/cron-path.sh
bash tests/notification-noise.sh
bash tests/cache-config-lock.sh
bash tests/migration.sh
```

The tests fake the upstream updater, Proxmox notification module, and network boundaries, so they run without a live Proxmox VE node, GitHub, or Healthchecks service.

## Installer Menu Options

| Option | Description |
|--------|-------------|
| **Install** | Discover containers & storage, configure schedule, install cron |
| **Edit Config** | Change containers, backups/storage, schedule, notifications, dry-run without reinstalling |
| **Dry Run** | Check for updates without applying |
| **Update** | Diff and pull latest worker from GitHub (atomic, confirmed) |
| **Remove** | Remove cron, worker, cache, status (config preserved by default) |
| **Status** | Installed state, schedule, last-run outcome, upstream cache |
| **Run Now** | Manual trigger |
| **Logs** | Manage retention, view/delete logs |
| **View** | Display worker, config, cache, cron |

## Schedule Options

| Frequency | Cron Expression | Example Display |
|-----------|----------------|-----------------|
| **Daily** | `0 H * * *` | "Daily at 05:00" |
| **Weekly** | `0 H * * DOW` | "Weekly: Sunday at 05:00" |
| **Monthly** | `0 H DAY * *` | "Monthly: day 15 at 05:00" |

## License

MIT — see [LICENSE](LICENSE)
