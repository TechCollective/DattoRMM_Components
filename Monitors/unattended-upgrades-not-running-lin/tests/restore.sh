# shellcheck shell=bash
# Undoes tests/setup.sh: the runner's own log directory back, and the package
# removed again if the test installed it.
set -eu
state=/var/tmp/tc-uu-test
log_dir=/var/log/unattended-upgrades
rm -rf "$log_dir"
if [ -e "$state/log-dir" ]; then mv "$state/log-dir" "$log_dir"; fi
if [ -e "$state/installed-by-test" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq unattended-upgrades >/dev/null
fi
rm -rf "$state"
echo restored
