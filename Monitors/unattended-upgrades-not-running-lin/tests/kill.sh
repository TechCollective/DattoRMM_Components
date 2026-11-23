#!/bin/bash
# Run the monitor as the harness does, with its log a FIFO nobody writes to (so
# tac blocks reading it), and send it TERM after 2 seconds. The harness checks
# result blocks only on runComponent steps, so this counts them itself.
m="$PWD/Monitors/unattended-upgrades-not-running-lin/unattended-upgrades-not-running-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
log=/var/log/unattended-upgrades/unattended-upgrades.log
out=/var/tmp/tc-uu-test/kill.out
rm -f "$log" && mkfifo "$log" || exit 1
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	/bin/bash "$m" >"$out" 2>&1 &
pid=$!
sleep 2
kill -TERM "$pid"
t0=$SECONDS; wait "$pid"
rc=$?; s=$((SECONDS - t0))
echo "exit status: $rc. Result $s seconds after TERM."
[ "$s" -le 5 ] && echo "result within 5 seconds of TERM"
cat "$out"
echo "start markers: $(grep -c '^<-Start Result->$' "$out"), end markers: $(grep -c '^<-End Result->$' "$out"), Status lines: $(grep -c '^Status=' "$out")"
pkill -x tac || true
rm -f "$log"
