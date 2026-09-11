# Healthchecks

Healthchecks support is optional and complements Proxmox notifications.

Edit config:

```bash
nano /etc/update-community-apps.conf
```

Set a compatible ping URL. This example is not a real token:

```text
HEALTHCHECK_URL="https://hc-ping.example.invalid/your-check-id"
```

Leaving `HEALTHCHECK_URL=""` disables it. Treat the URL as secret.

## Lifecycle

Actual worker behavior:

```text
run begins
    ↓
/start ping
    ↓
updater runs
    ↓
success → base ping URL with log body

failure → /fail ping with log body
```

The final success ping is the configured base URL, not `/success`. Healthchecks request failures never change updater result. Curl uses 5 second connect timeout, 15 second max time, and one retry. The worker does not echo the URL into logs.

## Practical setup

1. Create a check in Healthchecks.io or a compatible service.
2. Copy its ping URL.
3. Edit `/etc/update-community-apps.conf`.
4. Set `HEALTHCHECK_URL`.
5. Save.
6. Run a safe dry run: `/usr/local/bin/update-community-apps.sh --dry-run`.
7. Confirm `/start` and final success ping were received.
