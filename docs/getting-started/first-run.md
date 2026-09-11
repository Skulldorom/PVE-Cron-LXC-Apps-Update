# First run

Use a dry run first. It verifies configuration, locking, upstream cache refresh, logging, status writing, and notifications without applying application updates.

```bash
/usr/local/bin/update-community-apps.sh --dry-run
/usr/local/bin/update-community-apps.sh --status
ls -lt /var/log/update-community-apps-*.log | head
cat /var/log/update-community-apps-last-status
```

If the dry run succeeds and selected containers are correct, run a real update:

```bash
/usr/local/bin/update-community-apps.sh
```

Scheduled runs use the same worker and configuration. If `DRY_RUN="yes"` is set in config, scheduled runs stay dry-run until changed.
