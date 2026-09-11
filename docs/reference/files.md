# Files reference

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/update-community-apps.sh` | Stable local worker |
| `/etc/update-community-apps.conf` | Current authoritative configuration |
| `/usr/local/lib/update-community-apps/update-apps.sh` | Validated cached upstream `update-apps.sh` |
| `/usr/local/lib/update-community-apps/update-apps.meta` | Cache source URL, SHA256, refresh timestamp |
| `/var/log/update-community-apps-*.log` | Timestamped per-run worker logs |
| `/var/log/update-community-apps-cron.log` | Cron stdout/stderr log |
| `/var/log/update-community-apps-last-status` | Last invocation and completed run status |
| `/run/update-community-apps.lock` | `flock` lock file |
| `/etc/logrotate.d/update-community-apps` | Log rotation policy |
| `/usr/local/community-scripts/update_apps/*.log` | Upstream full logs |

Legacy-only: `/etc/update-community-apps/config` old inactive config after migration; `/usr/local/bin/update-community-apps-wrapper.sh` compatibility shim.
