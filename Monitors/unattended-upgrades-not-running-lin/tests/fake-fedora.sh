#!/bin/bash
# Makes the runner look like a non-Debian system: its /etc/os-release (a symlink
# on Ubuntu) is set aside for tests/restore.sh and a Fedora one written instead.
set -eu
state=/var/tmp/tc-uu-test
mkdir -p "$state"
mv /etc/os-release "$state/os-release"
printf '%s\n' 'NAME="Fedora Linux"' 'ID=fedora' 'PRETTY_NAME="Fedora Linux 41"' > /etc/os-release
echo "now: $(. /etc/os-release && echo "$PRETTY_NAME")"
