#!/bin/bash
# Run the monitor as the harness does, with chronyc hanging, and send it TERM
# after 2 seconds. The harness checks result blocks only on runComponent steps,
# so this counts them itself.
m="$PWD/Monitors/time-sync-clock-offset-exceeds-threshold-lin/time-sync-clock-offset-exceeds-threshold-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
out=$(mktemp)
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	tcTestHang=1 /bin/bash "$m" >"$out" 2>&1 &
pid=$!
sleep 2
kill -TERM "$pid"
t0=$SECONDS; wait "$pid"
rc=$?; s=$((SECONDS - t0))
echo "exit status: $rc. Result $s seconds after TERM."
[ "$s" -le 5 ] && echo "result within 5 seconds of TERM"
cat "$out"
echo "start markers: $(grep -c '^<-Start Result->$' "$out"), end markers: $(grep -c '^<-End Result->$' "$out"), STATUS lines: $(grep -c '^STATUS=' "$out")"
rm -f "$out"
pkill -f '^sleep 600$' || true
