# Updating

## Updating applications inside LXCs

Scheduled runs and manual worker runs update applications inside selected containers:

```bash
/usr/local/bin/update-community-apps.sh
```

## Updating PVE-Cron-LXC-Apps-Update itself

Scheduled application updates do not silently self-update the local worker. The supported way to check for and apply an updater update is to launch the installer and choose the **Update** menu:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

The **Update** flow downloads the candidate worker from GitHub, compares it with the installed worker, shows the relevant SHA256 values, shows a diff when available, and asks for confirmation before replacement. It also checks the logrotate config and preserves supported logrotate retention settings.

Preserved during worker updates:

- `/etc/update-community-apps.conf`
- selected containers
- schedule
- dry-run setting
- backup setting and storage
- notification setting
- supported logrotate retention settings

These commands identify the installed local worker:

```bash
/usr/local/bin/update-community-apps.sh --status
sha256sum /usr/local/bin/update-community-apps.sh
```

They are useful for support and comparison, but by themselves they do not prove the worker matches the current GitHub `main`. Use the installer **Update** menu when you need to know whether a newer updater is available.
