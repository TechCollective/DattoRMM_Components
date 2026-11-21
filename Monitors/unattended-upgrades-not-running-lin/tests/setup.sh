# shellcheck shell=bash
# Runs as root before the first run. Puts the runner in a known state and
# records what it changed, for tests/restore.sh to undo.
set -eu
state=/var/tmp/tc-uu-test
log_dir=/var/log/unattended-upgrades
rm -rf "$state"; mkdir -p "$state"
if ! command -v unattended-upgrade >/dev/null; then
    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
    touch "$state/installed-by-test"
fi
if [ -e "$log_dir" ]; then mv "$log_dir" "$state/log-dir"; fi
mkdir -m 750 "$log_dir"
# A real run, so the healthy case reads the log unattended-upgrades itself writes.
timeout 240 unattended-upgrade --dry-run || echo "dry run exited $?"
grep -m1 -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$log_dir/unattended-upgrades.log"
