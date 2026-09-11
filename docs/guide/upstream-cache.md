# Upstream cache

Cache files:

```text
/usr/local/lib/update-community-apps/update-apps.sh
/usr/local/lib/update-community-apps/update-apps.meta
```

```text
Attempt upstream refresh
        |
        +-- success --> validate --> atomic cache replacement --> execute
        |
        +-- failure --> valid cache?
                           |
                           +-- yes --> warn + use cache
                           |
                           +-- no --> fail safely
```

This protects scheduled maintenance from transient GitHub, `raw.githubusercontent.com`, CDN, or DNS failures. Downloads are accepted only if non-empty, shell shebang near the top, not HTML, and `bash -n` succeeds. Failed or partial downloads do not replace a known-good cache.

Metadata records source URL, SHA256, and refresh timestamp. SHA256 is for change detection and observability, not independent cryptographic authentication.

Refresh manually:

```bash
/usr/local/bin/update-community-apps.sh --refresh-upstream-cache
```

Check whether the last run used fresh or cached code:

```bash
/usr/local/bin/update-community-apps.sh --status
```
