#!/bin/bash
# Run the monitor as the harness does, with df hanging, and send it TERM after
# 2 seconds. The harness checks result blocks only on runComponent steps, so
# this counts them itself.
m="$PWD/Monitors/disk-space-free-space-below-threshold-lin/disk-space-free-space-below-threshold-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
out=/var/tmp/tc-disk/kill.out
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	usrDisks=/mnt/tc-ext4 tcTestDfHang=1 /bin/bash "$m" >"$out" 2>&1 &
pid=$!
sleep 2
kill -TERM "$pid"
t0=$SECONDS; wait "$pid"
rc=$?; s=$((SECONDS - t0))
echo "exit status: $rc. Result $s seconds after TERM."
[ "$s" -le 5 ] && echo "result within 5 seconds of TERM"
cat "$out"
echo "start markers: $(grep -c '^<-Start Result->$' "$out"), end markers: $(grep -c '^<-End Result->$' "$out"), STATUS lines: $(grep -c '^STATUS=' "$out")"
pkill -f '^sleep 600$' || true
