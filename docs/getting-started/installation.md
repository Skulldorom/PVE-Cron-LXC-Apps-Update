# Installation

Run as root on the Proxmox VE node:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

The installer asks for containers, schedule frequency, hour/day, notifications, backups, backup storage when backups are enabled, and scheduled dry-run behavior.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/update-community-apps.sh` | Local worker run by cron and manual commands |
| `/etc/update-community-apps.conf` | Authoritative configuration |
| `/usr/local/bin/update-community-apps-wrapper.sh` | Legacy compatibility shim |
| `/etc/logrotate.d/update-community-apps` | Log rotation policy |
| root crontab entry | Schedule invoking the worker |
| `/usr/local/lib/update-community-apps/` | Cached upstream `update-apps.sh` after refresh |

The scheduled cron command invokes the worker directly. Runtime settings are read from `/etc/update-community-apps.conf`, not embedded in cron.

## Verify installation

```bash
/usr/local/bin/update-community-apps.sh --status
crontab -l | grep update-community-apps
```

Expected cron shape:

```text
0 4 * * 0 /usr/local/bin/update-community-apps.sh >>/var/log/update-community-apps-cron.log 2>&1
```
