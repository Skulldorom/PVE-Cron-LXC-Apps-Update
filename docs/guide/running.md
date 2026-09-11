# Running the updater

```bash
/usr/local/bin/update-community-apps.sh
/usr/local/bin/update-community-apps.sh --dry-run
/usr/local/bin/update-community-apps.sh --status
/usr/local/bin/update-community-apps.sh --refresh-upstream-cache
/usr/local/bin/update-community-apps.sh --help
```

- **Run Now** in the installer runs the worker with current config.
- **Dry Run** runs `--dry-run`.
- **Status** prints diagnostics and reads the last status file.
- **Refresh Cache** downloads, validates, and atomically stores upstream without updating containers.
- **Scheduled execution** is root cron appending stdout/stderr to `/var/log/update-community-apps-cron.log`.

Legacy positional form remains supported:

```bash
/usr/local/bin/update-community-apps.sh "101,102" "local" dry-run
```

Arguments are `container_ids [backup_storage] [dry-run]`. Prefer config and named options for new automation.
