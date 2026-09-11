# Notifications

Set `NOTIFY="yes"` to send Proxmox notifications after completed runs. Set `NOTIFY="no"` to disable.

The worker uses Proxmox VE's default notification pipeline through `PVE::Notify` and creates `simple` templates under `/etc/pve/notification-templates/default/` if missing.

Severity: successful fresh run `info`; successful cached-upstream run `warning`; non-zero result `error`. Dry runs include `[DRY-RUN]`; cached runs include `[CACHED UPSTREAM]`.

Healthchecks is independent dead-man monitoring. Proxmox notifications are human-facing summaries.

Troubleshoot:

```bash
grep '^NOTIFY=' /etc/update-community-apps.conf
ls -l /etc/pve/notification-templates/default/
tail -n 100 /var/log/update-community-apps-cron.log
/usr/local/bin/update-community-apps.sh --status
```

Also verify Proxmox notification targets and matchers in the Proxmox UI.
