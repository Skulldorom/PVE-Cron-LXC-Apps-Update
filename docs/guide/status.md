# Status

```bash
/usr/local/bin/update-community-apps.sh --status
```

Fields: worker installation and SHA256, configured containers, backup/storage settings, notification setting, configuration warnings, upstream cache presence/source/SHA256/refresh age, last skipped invocation, and last completed run timestamp/exit code/upstream source/log.

Raw status file:

```bash
cat /var/log/update-community-apps-last-status
```

`Used upstream: fresh` means a validated download was used. `Used upstream: cached` means the last-known-good cache was used. `last_invocation_result=skipped` with `already_running` means `flock` prevented overlap.
