#!/bin/bash
# Run the monitor as the harness does, with the smartctl/diskutil shim hanging,
# and send it TERM after 2 seconds. The harness checks result blocks only on
# runComponent steps, so this counts them itself.
m="$PWD/Monitors/disk-health-smart-failure-detected-mac-lin/disk-health-smart-failure-detected-mac-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
out=$(mktemp)
# macOS's /bin/bash 3.2 holds a TERM until the command it is running returns,
# and the shim never does, so there the hung command is stopped too, as when a
# job's process group is killed (not with `set -m` and a group kill: with it,
# the macOS CI job hung). Linux (bash 5) gets TERM on bash alone, the harder case.
mac=0; [ "$(uname -s)" = Darwin ] && mac=1
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	tcTestHealth=hang /bin/bash "$m" >"$out" 2>&1 &
pid=$!
sleep 2
kill -TERM "$pid"
[ "$mac" -eq 1 ] && pkill -TERM -f '^sleep 600$'
t0=$SECONDS; wait "$pid"
rc=$?; s=$((SECONDS - t0))
echo "exit status: $rc. Result $s seconds after TERM."
[ "$s" -le 5 ] && echo "result within 5 seconds of TERM"
cat "$out"
echo "start markers: $(grep -c '^<-Start Result->$' "$out"), end markers: $(grep -c '^<-End Result->$' "$out"), STATUS lines: $(grep -c '^STATUS=' "$out")"
rm -f "$out"
pkill -f '^sleep 600$' || true
