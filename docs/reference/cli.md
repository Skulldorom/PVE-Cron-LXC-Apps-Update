# CLI reference

```bash
/usr/local/bin/update-community-apps.sh [--dry-run|--status|--refresh-upstream-cache] [container_ids] [backup_storage] [dry-run]
```

| Option | Behavior |
| --- | --- |
| `--dry-run` | Force dry-run for this invocation. Overrides `DRY_RUN="no"`. |
| `--status` | Print installation/config/cache/last-run status. Does not run updates. |
| `--refresh-upstream-cache` | Download, validate, and atomically replace cached upstream script. Does not run updates. |
| `--help`, `-h` | Print usage. |

No option runs with `/etc/update-community-apps.conf`. Legacy positional arguments are `container_ids [backup_storage] [dry-run]`.
