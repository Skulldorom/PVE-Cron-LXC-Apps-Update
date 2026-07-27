#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

FAKE_BIN="$TMPDIR/bin"
LOG_DIR="$TMPDIR/log"
UPSTREAM_LOG_DIR="$TMPDIR/upstream-logs"
STATUS_FILE="$TMPDIR/status"
PERL_LIB="$TMPDIR/perl5"
NOTIFY_RECORD="$TMPDIR/notify-record"
mkdir -p "$FAKE_BIN" "$LOG_DIR" "$UPSTREAM_LOG_DIR" "$PERL_LIB/PVE"

cat >"$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$out" ] || exit 2
cat >"$out" <<'UPSTREAM'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR"
log="$UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR/$(date '+%Y%m%d_%H%M%S').log"
{
  echo "Update started: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Container 101: starting"
  echo "Container 101 (demo): ERROR — no matching ct/demo.sh script found"
  echo "Exit code: 234"
} >"$log"
echo "⠋ Loading all possible LXC containers from Proxmox VE with tags: community-script, proxmox-helper-scripts. This may take a few seconds..."
exit 234
UPSTREAM
chmod +x "$out"
CURL
chmod +x "$FAKE_BIN/curl"

cat >"$PERL_LIB/PVE/Notify.pm" <<'PERL'
package PVE::Notify;
use strict;
use warnings;
sub common_template_data { return {}; }
sub notify {
  my ($severity, $template, $data, $fields) = @_;
  my $record = $ENV{PVE_NOTIFY_RECORD} || die "PVE_NOTIFY_RECORD missing";
  open(my $fh, '>', $record) or die "open notify record: $!";
  print {$fh} "severity=$severity\n";
  print {$fh} "template=$template\n";
  print {$fh} "origin=" . (($fields && $fields->{origin}) || '') . "\n";
  print {$fh} "title=" . (($data && $data->{title}) || '') . "\n";
  print {$fh} "message=" . (($data && $data->{message}) || '') . "\n";
  close($fh);
  return 1;
}
1;
PERL

set +e
PATH="$FAKE_BIN:$PATH" \
PERL5LIB="$PERL_LIB" \
PVE_NOTIFY_RECORD="$NOTIFY_RECORD" \
UPDATE_COMMUNITY_APPS_LOG_DIR="$LOG_DIR" \
UPDATE_COMMUNITY_APPS_STATUS_FILE="$STATUS_FILE" \
UPDATE_COMMUNITY_APPS_UPSTREAM_LOG_DIR="$UPSTREAM_LOG_DIR" \
NOTIFY=yes \
BACKUP=no \
bash "$ROOT/update-community-apps.sh" "101" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
exit_code=$?
set -e

if [ "$exit_code" -ne 234 ]; then
  echo "Expected worker to propagate upstream exit 234, got $exit_code" >&2
  cat "$TMPDIR/stdout" >&2
  cat "$TMPDIR/stderr" >&2
  exit 1
fi

worker_log=$(find "$LOG_DIR" -maxdepth 1 -name 'update-community-apps-[0-9]*_[0-9]*.log' -type f | head -1)
[ -n "$worker_log" ] || { echo "No worker log created" >&2; exit 1; }

grep -q 'Container 101 (demo): ERROR' "$worker_log" || {
  echo "Worker log did not copy upstream log content" >&2
  cat "$worker_log" >&2
  exit 1
}
grep -q 'Copied latest upstream log because no Full log pointer was printed' "$worker_log" || {
  echo "Worker log did not record fallback reason" >&2
  cat "$worker_log" >&2
  exit 1
}
grep -q 'Proxmox notification queued with severity=error' "$worker_log" || {
  echo "Worker log did not record notification success" >&2
  cat "$worker_log" >&2
  exit 1
}

grep -q '^exit_code=234$' "$STATUS_FILE" || {
  echo "Status file did not record exit code" >&2
  cat "$STATUS_FILE" >&2
  exit 1
}
grep -q '^severity=error$' "$NOTIFY_RECORD" || {
  echo "Notification was not sent with error severity" >&2
  cat "$NOTIFY_RECORD" >&2
  exit 1
}
grep -q '^origin=update-community-apps$' "$NOTIFY_RECORD" || {
  echo "Notification origin not recorded" >&2
  cat "$NOTIFY_RECORD" >&2
  exit 1
}

echo "ok - early upstream exit copies upstream log and records notification status"
