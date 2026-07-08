# PVE-Cron-LXC-Apps-Update
Automates weekly updates of community-scripts-managed LXC containers on a Proxmox VE node. Runs the official `update-apps.sh` with all env vars preset, strips the per-container verbose logging, and sends only the final summary table (with exit info) via **proxmox-discord-notifier**.
