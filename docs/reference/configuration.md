# Configuration reference

Current authoritative config: `/etc/update-community-apps.conf`.

| Key | Default | Valid values |
| --- | --- | --- |
| `CONTAINERS` | empty | numeric IDs separated by comma/space |
| `CONTAINER_IDS` | alias | legacy alias accepted by parser |
| `BACKUP_STORAGE` | empty | `[A-Za-z0-9_.:-]+` |
| `BACKUP` | `yes` | yes/no/true/false/1/0/on/off variants |
| `NOTIFY` | `yes` | boolean variants |
| `AUTO_REBOOT` | `yes` | boolean variants |
| `UPSTREAM_REFRESH` | `yes` | boolean variants |
| `ALLOW_CACHED_UPSTREAM` | `yes` | boolean variants |
| `DRY_RUN` | `no` | boolean variants |
| `HEALTHCHECK_URL` | empty | empty or `http(s)://` URL without spaces |

Unknown keys are ignored. Malformed non-empty lines cause load failure for normal runs. `--status` reports warnings instead of aborting.

```text
built-in defaults < environment/default variables < config < explicit CLI arguments
```
