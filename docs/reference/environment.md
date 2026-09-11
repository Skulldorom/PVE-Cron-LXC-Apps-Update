# Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `NOTIFY` | `yes` | Default before config |
| `BACKUP` | `yes` | Default before config |
| `AUTO_REBOOT` | `yes` | Default before config |
| `UPSTREAM_REFRESH` | `yes` | Default before config |
| `ALLOW_CACHED_UPSTREAM` | `yes` | Default before config |
| `HEALTHCHECK_URL` | empty | Default before config |
| `UPDATE_COMMUNITY_APPS_CONFIG_FILE` | `/etc/update-community-apps.conf` | Config path |
| `UPDATE_COMMUNITY_APPS_LOG_DIR` | `/var/log` | Worker log directory |
| `UPDATE_COMMUNITY_APPS_STATUS_FILE` | `$UPDATE_COMMUNITY_APPS_LOG_DIR/update-community-apps-last-status` | Status file |
| `UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR` | `/usr/local/community-scripts/update_apps` | Upstream full-log directory |
| `UPDATE_COMMUNITY_APPS_UPSTREAM_SCRIPT_URL` | community-scripts raw URL | Upstream source |
| `UPDATE_COMMUNITY_APPS_CACHE_DIR` | `/usr/local/lib/update-community-apps` | Cache directory |
| `UPDATE_COMMUNITY_APPS_CACHE_FILE` | `$UPDATE_COMMUNITY_APPS_CACHE_DIR/update-apps.sh` | Cached script |
| `UPDATE_COMMUNITY_APPS_CACHE_META` | `$UPDATE_COMMUNITY_APPS_CACHE_DIR/update-apps.meta` | Cache metadata |
| `UPDATE_COMMUNITY_APPS_LOCK_FILE` | `/run/update-community-apps.lock` | Lock file |
| `MAX_WORKER_LOG_BYTES` | `10485760` | Persisted worker log byte cap; minimum 4096 |
| `MAX_UPSTREAM_CAPTURE_BYTES` | `1048576` | Upstream terminal capture byte cap; minimum 4096 |

Installer/test override: `UPDATE_COMMUNITY_APPS_CRON_LOG` controls cron log path.
