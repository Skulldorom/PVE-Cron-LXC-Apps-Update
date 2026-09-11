# Uninstalling

Use the installer **Remove** menu:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Skulldorom/PVE-Cron-LXC-Apps-Update/main/install.sh)"
```

The menu removes cron entry, worker, legacy wrapper shim, upstream cache directory, and last status file. It asks before deleting configuration. Logs are kept. It does not remove community-scripts files or change software inside LXCs.

Verify scheduled updates are disabled:

```bash
crontab -l | grep update-community-apps || echo "No update-community-apps cron entry"
```
