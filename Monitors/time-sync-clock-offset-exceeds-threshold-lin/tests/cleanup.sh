#!/bin/bash
# Undo setup.sh.
rm -f /usr/local/sbin/chronyc /usr/local/sbin/ntpq /usr/local/sbin/timedatectl
echo "shims left: $(grep -l tc-test-shim /usr/local/sbin/* 2>/dev/null | wc -l)"
