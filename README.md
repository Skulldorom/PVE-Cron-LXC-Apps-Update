# PVE-Cron-LXC-Apps-Update

> **Disclaimer:** This project is NOT affiliated with, endorsed by, or connected to [community-scripts](https://community-scripts.org) / Proxmox VE Helper Scripts. It is an independent wrapper around their `update-apps.sh` tool.

PVE-Cron-LXC-Apps-Update automates scheduled **application-level** updates for supported community-scripts-managed LXC containers on Proxmox VE.

## Features

- Explicit selected-container allow-list
- Optional `vzdump` backup before application updates
- Daily, weekly, or monthly cron scheduling
- Manual run and dry-run modes
- Proxmox notification summaries
- Optional Healthchecks.io-compatible monitoring
- Last-known-good upstream `update-apps.sh` cache for transient GitHub/raw CDN failures
- Status file and timestamped logs
- Migration from the legacy wrapper/config layout

## Requirements

- Proxmox VE node with `pct` and `vzdump`
- `curl` and `whiptail`
- community-scripts-managed LXC containers tagged `community-script` or `proxmox-helper-scripts`
- backup-capable Proxmox storage if backups are enabled

Node/npm is not required on Proxmox hosts. It is only used to build the documentation site.

## Quick install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

The installer scans eligible containers, writes `/etc/update-community-apps.conf`, installs `/usr/local/bin/update-community-apps.sh`, and configures root cron.

## Basic usage

```bash
/usr/local/bin/update-community-apps.sh --status
/usr/local/bin/update-community-apps.sh --dry-run
/usr/local/bin/update-community-apps.sh
/usr/local/bin/update-community-apps.sh --refresh-upstream-cache
```

Authoritative config: `/etc/update-community-apps.conf`. Cron log: `/var/log/update-community-apps-cron.log`.

## Documentation

Full operator documentation is available in [`docs/`](docs/) and published at [skulldorom.github.io/PVE-Cron-LXC-Apps-Update](https://skulldorom.github.io/PVE-Cron-LXC-Apps-Update/).

One-time Pages setup after merge: in repository settings, set **Pages → Build and deployment → Source** to **GitHub Actions**.

## Development

```bash
bash -n update-community-apps.sh install.sh tests/*.sh
bash tests/run.sh
bash tests/cache-config-lock.sh
bash tests/cron-path.sh
bash tests/migration.sh
bash tests/notification-noise.sh
npm ci
npm run docs:build
```

## License

MIT. See [LICENSE](LICENSE).
