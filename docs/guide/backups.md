# Backups

When `BACKUP="yes"`, the worker passes `var_backup=yes` and `var_backup_storage=<BACKUP_STORAGE>` to upstream `update-apps.sh`. Upstream performs `vzdump` backups before application updates.

The installer lists backup-capable storages from `/etc/pve/storage.cfg` and honors node restrictions.

`BACKUP="yes"` requires valid `BACKUP_STORAGE`; otherwise validation fails before upstream updates. Disable backups with:

```text
BACKUP="no"
BACKUP_STORAGE=""
```

The worker runs upstream with `var_continue_on_error=yes`. Overall success/failure comes from upstream. If upstream reports backup or update failures, the wrapper records a non-zero result, writes status/logs, and sends failure notification/Healthchecks `/fail` when configured. Updating the local worker is separate from application updates.
