# Testing

Syntax checks:

```bash
bash -n update-community-apps.sh install.sh tests/*.sh
```

Shell tests:

```bash
bash tests/run.sh
bash tests/cache-config-lock.sh
bash tests/cron-path.sh
bash tests/migration.sh
bash tests/notification-noise.sh
```

The tests use fake commands and temporary directories where applicable and do not require a live Proxmox host.

Docs build:

```bash
npm ci
npm run docs:build
```
