#!/bin/bash
# Time Sync - Clock Offset Exceeds Threshold [Lin]
# TechCollective custom monitor. Alerts when the clock is not synchronised, or
# its offset from NTP time is above usrThreshold seconds.
#
# Asks whichever time service is running, in this order: chronyd (chronyc),
# ntpd or ntpsec (ntpq), systemd-timesyncd (timedatectl timesync-status).
# Those report their own measured offset, so the monitor makes no network call.
#
# Input variables:
#   usrThreshold  whole seconds of offset that alert, 1-86400 (default 60)
#
# Read-only. Exit 0 healthy, 1 alert.

set -u
export LC_ALL=C   # timedatectl prints "us", not "µs", and . as the decimal point

blnResultEmitted=0

emit_result() {
	local msg="${1//$'\n'/ }"
	printf '%s\n' '<-Start Result->' "STATUS=${msg}" '<-End Result->'
	blnResultEmitted=1
}

alert() {
	emit_result "ALERT - $1"
	printf '%s\n' '<-Start Diagnostic->' "$2" '<-End Diagnostic->'
	exit 1
}

# One result block on every path, and never OK, if the script dies first.
on_exit() {
	local code=$?
	if [ "$blnResultEmitted" -eq 0 ]; then
		# On a signal $? is 0 and bash exits with the signal's code whatever this says.
		local why="shell exit ${code}"
		[ "$code" -eq 0 ] && why="stopped by a signal"
		printf '%s\n' '<-Start Result->' "STATUS=Check failed before it could decide (${why}); see the component's raw job output for the error" '<-End Result->'
		exit 1
	fi
	exit "$code"
}
trap on_exit EXIT

have() { command -v "$1" >/dev/null 2>&1; }
guard() { if have timeout; then timeout 10 "$@"; else "$@"; fi; }

#------------------------------------------------------------ input validation

usrThreshold="${usrThreshold:-60}"
usrThreshold="${usrThreshold//[[:space:]]/}"
case "$usrThreshold" in
	'' | *[!0-9]*) emit_result "Check could not run: usrThreshold must be whole seconds 1-86400 (given: '${usrThreshold}')"; exit 1 ;;
esac
if [ "${#usrThreshold}" -gt 5 ] || [ "$usrThreshold" -lt 1 ] || [ "$usrThreshold" -gt 86400 ]; then
	emit_result "Check could not run: usrThreshold must be between 1 and 86400 seconds (given: ${usrThreshold})"
	exit 1
fi
have awk || { emit_result "Check could not run: awk not found in PATH"; exit 1; }

#------------------------------------------------------------ read the offset

strSource="" strOffset="" strUnsynced="" strRaw=""

# chronyc -c tracking: CSV, field 5 is System time (seconds), field 14 Leap status.
# Fails with "506 Cannot talk to daemon" when chronyd is not running.
if [ -z "$strSource" ] && have chronyc && strRaw="$(guard chronyc -c tracking 2>&1)"; then
	strSource="chronyd"
	strOffset="$(printf '%s\n' "$strRaw" | awk -F, 'NR==1 && NF>=14 {print $5}')"
	case "$strRaw" in *"Not synchronised"*) strUnsynced="chronyd reports Leap status: Not synchronised" ;; esac
fi

# ntpq rv 0: offset in milliseconds; leap=11 means not synchronised.
if [ -z "$strSource" ] && have ntpq && strRaw="$(guard ntpq -c 'rv 0 offset,leap' 2>&1)" \
	&& printf '%s' "$strRaw" | grep -q 'offset='; then
	strSource="ntpd"
	strOffset="$(printf '%s' "$strRaw" | tr ',' '\n' | awk -F= '$1 ~ /offset$/ {print $2 / 1000; exit}')"
	case "$strRaw" in *leap=11*) strUnsynced="ntpd reports leap=11 (not synchronised)" ;; esac
fi

# timedatectl timesync-status: "Offset: -49.131ms", or e.g. "+1min 3.2s".
# Fails unless systemd-timesyncd is running; needs systemd 239 or later.
if [ -z "$strSource" ] && have timedatectl && strRaw="$(guard timedatectl timesync-status 2>&1)"; then
	strSource="systemd-timesyncd"
	strOffset="$(printf '%s\n' "$strRaw" | awk '
		$1 == "Offset:" {
			total = 0; found = 0
			for (i = 2; i <= NF; i++) {
				v = $i; sub(/^[+-]/, "", v)
				n = v; sub(/[a-z]+$/, "", n); u = substr(v, length(n) + 1)
				m = (u == "us") ? 1e-6 : (u == "ms") ? 1e-3 : (u == "s") ? 1 : (u == "min") ? 60 : (u == "h") ? 3600 : (u == "d") ? 86400 : -1
				if (n == "" || m < 0) { found = 0; break }
				total += n * m; found = 1
			}
			if (found) print total
		}')"
fi

# The kernel sync flag, whatever service sets it. Not every host has timedatectl.
strKernelSync="$(have timedatectl && guard timedatectl show -p NTPSynchronized --value 2>/dev/null)"
if [ "$strKernelSync" = "no" ]; then
	strUnsynced="${strUnsynced:-timedatectl reports NTPSynchronized=no}"
fi

#------------------------------------------------------------ decide

# e.g. timesyncd on systemd older than 239, or openntpd: synced, offset unreadable.
if [ -z "$strSource" ] && [ "$strKernelSync" = "yes" ]; then
	emit_result "OK - clock synchronised (timedatectl NTPSynchronized=yes); no chronyd, ntpd or timesyncd offset to read"
	exit 0
fi

if [ -z "$strSource" ]; then
	alert "no running time sync service found (looked for chronyd, ntpd and systemd-timesyncd); the clock is not being kept in sync" \
		"chronyc: $(have chronyc && echo present || echo absent), ntpq: $(have ntpq && echo present || echo absent), timedatectl: $(have timedatectl && echo present || echo absent). Last error: ${strRaw:-none}"
fi

if [ -n "$strUnsynced" ]; then
	alert "clock is not synchronised (${strSource}): ${strUnsynced}" "$strRaw"
fi

case "$strOffset" in
	'' | *[!0-9.eE+-]*)
		emit_result "OK - clock synchronised by ${strSource}; offset not reported yet"
		exit 0 ;;
esac

strAbs="$(awk -v o="$strOffset" 'BEGIN { o += 0; if (o < 0) o = -o; printf "%.3f", o }')"
if awk -v a="$strAbs" -v t="$usrThreshold" 'BEGIN { exit !(a > t) }'; then
	alert "clock is ${strAbs}s off NTP time (${strSource}), over the ${usrThreshold}s threshold" "$strRaw"
fi
emit_result "OK - clock is ${strAbs}s off NTP time (${strSource}), within ${usrThreshold}s"
exit 0
