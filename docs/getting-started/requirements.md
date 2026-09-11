# Requirements

Run the installer on a Proxmox VE node as root.

Required host tools: `bash`, `curl`, `whiptail`, `pct`, `vzdump`, `crontab`, `sha256sum`, `flock`, and Perl with Proxmox `PVE::Notify` for notifications.

Required environment:

- LXC containers managed by community-scripts.
- Containers tagged `community-script` or `proxmox-helper-scripts`.
- Proxmox storage with backup content enabled if `BACKUP=yes`.
- Network access to `raw.githubusercontent.com` for initial upstream cache refresh, unless a valid cache already exists.

Node/npm is not a runtime requirement. It is only used by contributors building the documentation site.

## Container discovery

The installer lists `pct list`, then checks each container config with `pct config <CTID>`. Containers are offered for selection when their tags include `community-script` or `proxmox-helper-scripts`. Selected IDs are saved as `CONTAINERS` in `/etc/update-community-apps.conf`.
