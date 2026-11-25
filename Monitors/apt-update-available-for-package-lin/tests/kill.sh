#!/bin/bash
# Run the monitor as the harness does, with apt-get hanging, and send it TERM
# after 2 seconds. The harness checks result blocks only on runComponent steps,
# so this counts them itself. The monitor calls `sudo apt-get`, and sudo drops
# the environment and searches its secure_path, so the hang is a shim in
# /usr/local/sbin (first on Ubuntu's secure_path), removed again at the end.
m="$PWD/Monitors/apt-update-available-for-package-lin/apt-update-available-for-package-lin.sh"
test -f "$m" || { echo "cannot find $m"; exit 1; }
shim=/usr/local/sbin/apt-get
out=$(mktemp)
# A shim left behind would hang every later apt step on this runner.
trap 'rm -f "$shim" "$out"; pkill -f "^sleep 600$" || true' EXIT
printf '#!/bin/sh\nexec sleep 600\n' >"$shim" && chmod 755 "$shim" || exit 1
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	PACKAGE=tctest-apt-pkg /bin/bash "$m" >"$out" 2>&1 &
pid=$!
sleep 2
kill -TERM "$pid"
t0=$SECONDS; wait "$pid"
rc=$?; s=$((SECONDS - t0))
echo "exit status: $rc. Result $s seconds after TERM."
[ "$s" -le 5 ] && echo "result within 5 seconds of TERM"
cat "$out"
echo "start markers: $(grep -c '^<-Start Result->$' "$out"), end markers: $(grep -c '^<-End Result->$' "$out"), Alert lines: $(grep -c '^Alert=' "$out")"
