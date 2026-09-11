# Configuration

The authoritative configuration file for current installations is:

```text
/etc/update-community-apps.conf
```

View it:

```bash
cat /etc/update-community-apps.conf
less -N /etc/update-community-apps.conf
```

Edit it:

```bash
nano /etc/update-community-apps.conf
```

You can also use the installer **Edit** menu for common settings.

## Complete example

```bash
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

The worker parses simple key/value lines with a constrained parser. It does not `source` this file.

## Precedence

```text
built-in defaults < environment/default variables < config < explicit CLI arguments
```

An explicit CLI `--dry-run` always remains a dry run even when config contains `DRY_RUN="no"`.

## Options

### `CONTAINERS`
Purpose: selected LXC container IDs passed to upstream `update-apps.sh`. Valid values: comma-separated or whitespace-separated numeric IDs. Default: empty; normal updates fail validation. Example: `CONTAINERS="101,102,105"`.

### `BACKUP_STORAGE`
Purpose: Proxmox storage ID used for `vzdump` backups. Valid values: letters, numbers, `_`, `.`, `:`, `-`. Default: empty. Required when `BACKUP="yes"`. Example: `BACKUP_STORAGE="pbs-backup"`.

### `BACKUP`
Purpose: enable pre-update backups. Valid values: `yes`, `no`, `true`, `false`, `1`, `0`, `on`, `off` in supported case variants. Default: `yes`. If `yes` without valid storage, validation fails before updates run.

### `NOTIFY`
Purpose: enable Proxmox notification delivery. Valid values: boolean forms. Default: `yes`.

### `AUTO_REBOOT`
Purpose: passes `var_auto_reboot` to upstream `update-apps.sh`. Valid values: boolean forms. Default: `yes`.

### `UPSTREAM_REFRESH`
Purpose: attempt to download and validate fresh upstream `update-apps.sh` at run start. Valid values: boolean forms. Default: `yes`.

### `ALLOW_CACHED_UPSTREAM`
Purpose: allow fallback to last-known-good cached upstream script. Valid values: boolean forms. Default: `yes`. If `no`, failed refresh causes safe failure instead of cache fallback.

### `DRY_RUN`
Purpose: make normal and scheduled runs check-only. Valid values: boolean forms. Default: `no`. CLI `--dry-run` overrides to `yes` for that invocation.

### `HEALTHCHECK_URL`
Purpose: optional Healthchecks.io-compatible ping URL. Valid values: empty or `http://` / `https://` URL without spaces. Default: empty. Example: `HEALTHCHECK_URL="https://hc-ping.example.invalid/uuid"`. Treat the URL as secret.
