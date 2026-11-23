#!/bin/bash
# Run the monitor as the harness does, pinging an address that never replies,
# and send it TERM 2 seconds into a 10-ping run. The harness checks result
# blocks only on runComponent steps, so this counts them itself.
m="$PWD/Monitors/connection-health-ping-targets-not-responding-lin/connection-health-ping-targets-not-responding-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
o=$(mktemp)
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	usrTargets=192.0.2.1 usrPingCount=10 usrReplyTimeoutSec=5 /bin/bash "$m" >"$o" 2>&1 &
p=$!
sleep 2
kill -TERM "$p"
wait "$p"
rc=$?
cat "$o"
echo "exit $rc"
echo "result blocks: $(grep -c '^<-Start Result->$' "$o") start, $(grep -c '^<-End Result->$' "$o") end"
rm -f "$o"
