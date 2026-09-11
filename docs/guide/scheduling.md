# Scheduling

The schedule lives in root's crontab and is managed by the installer.

```bash
crontab -l | grep update-community-apps
```

Example:

```text
0 4 * * 0 /usr/local/bin/update-community-apps.sh >>/var/log/update-community-apps-cron.log 2>&1
```

Use the installer **Edit** menu to change schedule safely. Daily selects an hour, weekly selects day of week plus hour, monthly selects day of month plus hour. Manual crontab edits are possible for advanced operators, but the installer avoids duplicate project entries and preserves the supported worker/log format.
