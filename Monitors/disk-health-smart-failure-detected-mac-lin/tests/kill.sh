#!/bin/bash
# Run the monitor as the harness does, with the smartctl/diskutil shim hanging,
# and send it TERM after 2 seconds. The harness checks result blocks only on
# runComponent steps, so this counts them itself.
m="$PWD/Monitors/disk-health-smart-failure-detected-mac-lin/disk-health-smart-failure-detected-mac-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
out=$(mktemp)
# smartctlTimeout=3 caps the hung smartctl or diskutil: macOS's /bin/bash 3.2
# holds a TERM until the command it is running returns, so there the result
# comes when the cap stops it. TERM goes to bash alone on both, the hard case.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	tcTestHealth=hang smartctlTimeout=3 /bin/bash "$m" >"$out" 2>&1 &
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
