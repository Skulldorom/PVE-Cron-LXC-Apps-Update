# Troubleshooting

## `raw.githubusercontent.com` / GitHub unavailable

Expected behavior: refresh fails, valid cache is used with a warning. Check `--status` and `/var/log/update-community-apps-cron.log`.

## No valid cached upstream script

The worker fails safely before updating containers. Fix network/DNS, then run `--refresh-upstream-cache`.

## Backup storage error

```bash
grep -E '^(BACKUP|BACKUP_STORAGE)=' /etc/update-community-apps.conf
/usr/local/bin/update-community-apps.sh --status
```

`BACKUP="yes"` requires valid backup-capable Proxmox storage.

## Wrong containers updating

```bash
grep '^CONTAINERS=' /etc/update-community-apps.conf
nano /etc/update-community-apps.conf
```

Set `CONTAINERS="101,102"`.

## Schedule did not run

```bash
crontab -l
tail -n 100 /var/log/update-community-apps-cron.log
/usr/local/bin/update-community-apps.sh --status
```

## Notifications not arriving

```bash
grep '^NOTIFY=' /etc/update-community-apps.conf
ls -l /etc/pve/notification-templates/default/
tail -n 100 /var/log/update-community-apps-cron.log
```

If logs show delivery failure, verify Proxmox notification targets and matchers.

## Healthcheck not arriving

Do not paste the secret URL into tickets or logs. Check if configured without printing it:

```bash
awk -F= '/^HEALTHCHECK_URL=/{print $1"=<configured>"}' /etc/update-community-apps.conf
/usr/local/bin/update-community-apps.sh --dry-run
```

## Another updater is already running

The worker uses `flock` on `/run/update-community-apps.lock`. A second invocation exits cleanly and records `already_running`. Check processes before acting:

```bash
ps aux | grep '[u]pdate-community-apps.sh'
/usr/local/bin/update-community-apps.sh --status
```

Do not casually delete the lock file while a process may be running.

## Config validation failure

Common causes: non-numeric container ID, invalid boolean, `BACKUP="yes"` without storage, invalid `HEALTHCHECK_URL`, malformed line. Inspect with `less -N /etc/update-community-apps.conf` and `--status`.

## Migration appears incomplete

```bash
ls -l /etc/update-community-apps.conf /etc/update-community-apps/config 2>/dev/null || true
/usr/local/bin/update-community-apps.sh --status
crontab -l | grep update-community-apps
```

Cron should invoke `/usr/local/bin/update-community-apps.sh`, not the legacy wrapper.
