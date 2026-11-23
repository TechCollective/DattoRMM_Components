#!/bin/bash
# publish.sh VERSION: build tctest-apt-pkg at VERSION into /opt/tctest-repo and
# rewrite the repository index (by hand: the runner has no apt-utils).
set -e
mkdir -p /opt/tctest-repo
d=$(mktemp -d); mkdir -p "$d/DEBIAN"
printf 'Package: tctest-apt-pkg\nVersion: %s\nArchitecture: all\nMaintainer: TC Test <test@example.com>\nDescription: Tier 1 test package\n' "$1" > "$d/DEBIAN/control"
dpkg-deb -b "$d" "/opt/tctest-repo/tctest-apt-pkg_$1_all.deb" >/dev/null
cd /opt/tctest-repo
for f in *.deb; do dpkg-deb -f "$f"; echo "Filename: ./$f"; echo "Size: $(stat -c %s "$f")"; echo "SHA256: $(sha256sum "$f" | cut -d ' ' -f 1)"; echo; done > Packages
# apt compares whole-second mtimes, so a republish in the same second as the last update would read as unchanged
rm -f /var/lib/apt/lists/_opt_tctest-repo_*
grep -q "^Version: $1$" Packages
