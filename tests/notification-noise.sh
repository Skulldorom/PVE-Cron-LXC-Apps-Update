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
echo "Update started: $(date '+%Y-%m-%d %H:%M:%S')" >"$log"
echo "roxmox VE with tags: community-script, proxmox-helper-scripts. This may take a few seconds..."
echo "??? Loading all possible LXC containers from Proxmox VE with tags: community-script, proxmox-helper-scripts. This may take a few seconds..."
exit 127
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

if [ "$exit_code" -ne 127 ]; then
  echo "Expected worker to propagate upstream exit 127, got $exit_code" >&2
  cat "$TMPDIR/stdout" >&2
  cat "$TMPDIR/stderr" >&2
  exit 1
fi

[ -s "$NOTIFY_RECORD" ] || { echo "No notification was captured" >&2; exit 1; }

grep -q '^severity=error$' "$NOTIFY_RECORD" || {
  echo "Notification was not sent with error severity" >&2
  cat "$NOTIFY_RECORD" >&2
  exit 1
}
if grep -Eq 'Loading all possible LXC containers|roxmox VE with tags|Update started:' "$NOTIFY_RECORD"; then
  echo "Notification still contains non-actionable spinner/setup noise" >&2
  cat "$NOTIFY_RECORD" >&2
  exit 1
fi
grep -q 'No summary table was produced\|Copied latest upstream log' "$NOTIFY_RECORD" || {
  echo "Notification did not include a useful fallback message" >&2
  cat "$NOTIFY_RECORD" >&2
  exit 1
}

echo "ok - notification fallback omits spinner-only startup noise"
