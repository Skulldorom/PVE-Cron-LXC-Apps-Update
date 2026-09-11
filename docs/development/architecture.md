# Architecture

```text
cron or operator
  ↓
update-community-apps.sh
  ↓
configuration
  ↓
lock
  ↓
upstream refresh/cache selection
  ↓
backup
  ↓
community-scripts update-apps.sh
  ↓
logging/status
  ↓
notifications/healthcheck
```

Reliability choices actually present: constrained config parsing instead of `source`, selected-container allow-list, last-known-good cache, validation before cache replacement, atomic replacement, bounded network operations, `flock`, status persistence, and secret-safe Healthchecks logging.

The wrapper owns scheduling/config/cache/status/logging/notifications. Application update behavior inside containers comes from upstream `update-apps.sh`.
