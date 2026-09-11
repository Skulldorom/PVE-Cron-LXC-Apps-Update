# Logging

Important locations:

```text
/var/log/update-community-apps-YYYYMMDD_HHMMSS.log
/var/log/update-community-apps-cron.log
/var/log/update-community-apps-last-status
/usr/local/community-scripts/update_apps/*.log
```

Useful commands:

```bash
tail -f /var/log/update-community-apps-cron.log
ls -lt /var/log/update-community-apps-*.log | head
latest=$(ls -t /var/log/update-community-apps-*.log | head -1)
less "$latest"
cat /var/log/update-community-apps-last-status
```

The wrapper copies upstream full logs into its timestamped worker log when upstream prints a `Full log:` pointer. Upstream logs usually live in `/usr/local/community-scripts/update_apps`.

Logrotate config: `/etc/logrotate.d/update-community-apps`. Timestamped worker logs use `maxage 28`, weekly stanza, 10 MB max size, compression. Cron log rotates daily, keeps 3 compressed rotations, uses 10 MB max size and `copytruncate`.
