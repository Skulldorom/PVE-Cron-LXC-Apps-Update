# Updating

## Updating applications inside LXCs

Scheduled runs and manual worker runs update applications inside selected containers:

```bash
/usr/local/bin/update-community-apps.sh
```

## Updating PVE-Cron-LXC-Apps-Update itself

Scheduled application updates do not silently self-update the local worker. Use the installer **Update** menu:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

The menu downloads candidate worker/logrotate files, calculates current and candidate SHA256 values, shows a diff when available, and asks for confirmation before replacement. Configuration, selected containers, schedule, dry-run, backup, notification, and supported logrotate retention settings are preserved.

Check installed worker hash with `--status` or `sha256sum /usr/local/bin/update-community-apps.sh`.
