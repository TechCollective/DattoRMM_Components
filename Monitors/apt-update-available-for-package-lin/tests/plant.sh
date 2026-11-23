#!/bin/bash
# Plant tctest-apt-pkg 1.0, installed, in a local file repository apt reads.
# Runs from the checkout as root, so it can call publish.sh beside it.
set -e
publish="$PWD/Monitors/apt-update-available-for-package-lin/tests/publish.sh"
bash "$publish" 1.0
dpkg -i /opt/tctest-repo/tctest-apt-pkg_1.0_all.deb >/dev/null
echo 'deb [trusted=yes] file:/opt/tctest-repo ./' > /etc/apt/sources.list.d/tctest.list
echo planted 1.0
