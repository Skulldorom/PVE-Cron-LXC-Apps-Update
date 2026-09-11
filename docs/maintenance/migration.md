# Migration

Old config:

```text
/etc/update-community-apps/config
```

New authoritative config:

```text
/etc/update-community-apps.conf
```

After successful migration, editing the old config does not affect the updater. Migration preserves these legacy values when they exist:

- selected containers from `CONTAINER_IDS`
- backup storage from `BACKUP_STORAGE`
- backup enablement from `BACKUP`
- notification preference from `NOTIFY`
- dry-run preference from `DRY_RUN`
- cron schedule
- `AUTO_REBOOT`
- `UPSTREAM_REFRESH`
- `ALLOW_CACHED_UPSTREAM`
- `HEALTHCHECK_URL`

If `AUTO_REBOOT`, `UPSTREAM_REFRESH`, `ALLOW_CACHED_UPSTREAM`, or `HEALTHCHECK_URL` are absent from the legacy config, the generated config uses the same defaults as a new install. Cron is updated to invoke `/usr/local/bin/update-community-apps.sh` directly.

## Verify migration

```bash
/usr/local/bin/update-community-apps.sh --status
cat /etc/update-community-apps.conf
crontab -l | grep update-community-apps
/usr/local/bin/update-community-apps.sh --dry-run
```

Expected results:

- `/etc/update-community-apps.conf` exists and contains the migrated settings.
- `--status` reports the new config.
- Cron points to `/usr/local/bin/update-community-apps.sh`.
- The dry run completes with the migrated container allow-list.

## Cleaning up legacy files

Legacy-only artifacts:

```text
/etc/update-community-apps/config
/usr/local/bin/update-community-apps-wrapper.sh
```

Only remove after confirming new config exists, status works, cron points directly to the worker, and updater operates correctly. Guarded cleanup:

```bash
if [ ! -f /etc/update-community-apps.conf ]; then
  echo "Refusing cleanup: /etc/update-community-apps.conf is missing" >&2
  exit 1
fi
if crontab -l 2>/dev/null | grep -q '/usr/local/bin/update-community-apps-wrapper.sh'; then
  echo "Refusing cleanup: cron still references the legacy wrapper" >&2
  exit 1
fi
/usr/local/bin/update-community-apps.sh --status >/dev/null || {
  echo "Refusing cleanup: status command failed" >&2
  exit 1
}
rm -i /etc/update-community-apps/config /usr/local/bin/update-community-apps-wrapper.sh
```
