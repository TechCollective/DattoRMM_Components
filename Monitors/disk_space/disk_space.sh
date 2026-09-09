#!/bin/bash
# Disk Space - Free Space Below Threshold [Lin]
# TechCollective custom monitor. Replaces the Linux branch of the ComStore
# "Unified Disk Space Monitor" (build 55 / seagull). Linux only by design.
#
# Input variables:
#   usrThreshold      percent used that counts as full            (default 90)
#   usrMinFreeGB      also require free space below this, in GB   (default 0 = percent only)
#   usrDisks          ALL, or a space-separated list of devices/mountpoints
#   usrExclude        space-separated glob patterns to skip (devices or mountpoints)
#   usrUnknownFs      warn | alert | ignore                       (default warn)
#   usrPoolThreshold  percent for btrfs metadata and LVM thin pools (default 85)
#
# Read-only: runs df, and where present btrfs(8), dmsetup(8) and a depth-1 du.
# Changes nothing on the endpoint.

set -u
export LC_ALL=C

# Diagnostic work must finish inside Datto's 60s post-alert window. Every
# expensive step is individually capped AND gated on this overall budget.
readonly DIAG_BUDGET=30
readonly STATUS_MAX=900

#--------------------------------------------------------------------- helpers

blnResultEmitted=0

# The result block is a hard contract: exactly one line, "STATUS=" with no space
# after the equals sign. Mount points and input variables can carry newlines
# (/proc/mounts octal-escapes them, and an input variable is free text), so the
# payload is flattened here rather than trusted at each call site.
emit_result() {
	local msg="$1"
	# Pure parameter expansion on purpose: the one thing that must never depend
	# on an external binary is the code that reports a missing external binary.
	msg="${msg//$'\n'/ }"
	msg="${msg//$'\r'/ }"
	msg="${msg//$'\t'/ }"
	msg="${msg#"${msg%%[![:space:]]*}"}"
	[ "${#msg}" -gt "$STATUS_MAX" ] && msg="${msg:0:$((STATUS_MAX - 3))}..."
	[ -n "$msg" ] || msg="Check produced no status text"
	printf '%s\n' '<-Start Result->'
	printf 'STATUS=%s\n' "$msg"
	printf '%s\n' '<-End Result->'
	blnResultEmitted=1
}

# A monitor that dies without a result block raises an alert with no text in it,
# which is the defect the contract calls out first. This guarantees one.
on_exit() {
	local code=$?
	if [ "$blnResultEmitted" -eq 0 ]; then
		# Reaching here means the script died before deciding anything -- a shell
		# error, or a signal. Never report success: exit 0 with no result block
		# would leave the monitor's last-known text stale and the job green.
		printf '%s\n' '<-Start Result->'
		printf 'STATUS=%s\n' "Check failed before it could measure anything (shell exit ${code}); see the component's raw job output for the error"
		printf '%s\n' '<-End Result->'
		exit 1
	fi
	exit "$code"
}
trap on_exit EXIT

# Bail out in a way a technician can read. Not knowing whether a disk is full is
# dangerous, so an unrunnable check alerts rather than going green.
die_unrunnable() {
	emit_result "Check could not run: $1"
	exit 1
}

human_gb() {
	awk -v k="${1:-0}" 'BEGIN { g = k / 1048576; if (g < 10) printf "%.1f", g; else printf "%.0f", g }'
}

# "${arr[*]}" with a multi-character IFS joins on the first character only,
# which is a quiet way to produce unreadable alert text.
join_by() {
	local sep="$1" out="" item
	shift
	for item in "$@"; do
		[ -n "$out" ] && out="${out}${sep}"
		out="${out}${item}"
	done
	printf '%s' "$out"
}

# /proc/mounts octal-escapes spaces, tabs and backslashes
unescape() { printf '%b' "$1"; }

# glob match a value against a pattern list (for usrDisks / usrExclude)
matches_any() {
	local value="$1" pattern
	shift
	for pattern in "$@"; do
		[ -z "$pattern" ] && continue
		# shellcheck disable=SC2254
		case "$value" in $pattern) return 0 ;; esac
	done
	return 1
}

# exact string membership -- de-duplication must not treat a device name as a glob
contains_exact() {
	local value="$1" item
	shift
	for item in "$@"; do
		[ "$item" = "$value" ] && return 0
	done
	return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# run a command with a wall-clock guard when timeout(1) exists
guard() {
	local secs="$1"
	shift
	if have timeout; then timeout "$secs" "$@"; else "$@"; fi
}

#------------------------------------------------------------ input validation

usrThreshold="${usrThreshold:-90}"
usrMinFreeGB="${usrMinFreeGB:-0}"
usrDisks="${usrDisks:-ALL}"
usrExclude="${usrExclude:-}"
usrUnknownFs="${usrUnknownFs:-warn}"
usrPoolThreshold="${usrPoolThreshold:-85}"

# Dependencies first: the normalisation below already needs tr and the checks
# need awk, so testing them afterwards would report a validation error for what
# is really a missing binary.
[ -r /proc/mounts ] || die_unrunnable "/proc/mounts is not readable; is this a Linux host?"
for dep in df awk tr; do
	have "$dep" || die_unrunnable "${dep} not found in PATH; this component needs df, awk and tr"
done

# tolerate whitespace and a trailing % if someone typed "90%"
usrThreshold="$(printf '%s' "$usrThreshold" | tr -d '[:space:]%')"
usrMinFreeGB="$(printf '%s' "$usrMinFreeGB" | tr -d '[:space:]')"
usrPoolThreshold="$(printf '%s' "$usrPoolThreshold" | tr -d '[:space:]%')"
usrUnknownFs="$(printf '%s' "$usrUnknownFs" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

# A bad threshold is never silently coerced to a default. Monitoring against a
# value nobody chose is worse than a loud refusal to run.
case "$usrThreshold" in
	'' | *[!0-9]*) die_unrunnable "usrThreshold must be a whole number 1-99 (given: '${usrThreshold}')" ;;
esac
if [ "$usrThreshold" -lt 1 ] || [ "$usrThreshold" -gt 99 ]; then
	die_unrunnable "usrThreshold must be between 1 and 99 (given: ${usrThreshold})"
fi

case "$usrMinFreeGB" in
	'' | *[!0-9]*) die_unrunnable "usrMinFreeGB must be a whole number of GB, 0 to disable (given: '${usrMinFreeGB}')" ;;
esac

case "$usrPoolThreshold" in
	'' | *[!0-9]*) die_unrunnable "usrPoolThreshold must be a whole number 1-99 (given: '${usrPoolThreshold}')" ;;
esac
if [ "$usrPoolThreshold" -lt 1 ] || [ "$usrPoolThreshold" -gt 99 ]; then
	die_unrunnable "usrPoolThreshold must be between 1 and 99 (given: ${usrPoolThreshold})"
fi

case "$usrUnknownFs" in
	warn | alert | ignore) : ;;
	*) die_unrunnable "usrUnknownFs must be warn, alert or ignore (given: '${usrUnknownFs}')" ;;
esac

read -r -a arrExclude <<<"$usrExclude"
declare -a arrWanted=()
blnAllDisks=1
if [ "$usrDisks" != "ALL" ] && [ -n "$(printf '%s' "$usrDisks" | tr -d '[:space:]')" ]; then
	# the original quoted the whole string into one array element, so a list of
	# more than one disk became a single bogus path. read -r -a splits properly.
	read -r -a arrWanted <<<"$usrDisks"
	blnAllDisks=0
fi

#-------------------------------------------------- filesystem classification

# Checked: df's numbers mean "can I write here" on these.
FS_LOCAL=" ext2 ext3 ext4 xfs btrfs zfs f2fs jfs reiserfs nilfs2 bcachefs ufs vfat msdos exfat ntfs ntfs3 fuseblk "
# Skipped without comment: no admin action is possible when one of these is full.
FS_PSEUDO=" tmpfs devtmpfs ramfs proc sysfs cgroup cgroup2 devpts securityfs pstore efivarfs bpf debugfs tracefs configfs fusectl hugetlbfs mqueue autofs binfmt_misc nsfs selinuxfs rpc_pipefs squashfs overlay iso9660 udf erofs "
# Reported under the usrUnknownFs policy: capacity here belongs to another host.
FS_NETWORK=" nfs nfs4 cifs smb3 smbfs afs ceph fuse.glusterfs glusterfs 9p fuse.sshfs fuse.s3fs davfs fuse.davfs "

classify() {
	case "$FS_PSEUDO" in *" $1 "*) echo pseudo; return ;; esac
	case "$FS_LOCAL" in *" $1 "*) echo local; return ;; esac
	case "$FS_NETWORK" in *" $1 "*) echo network; return ;; esac
	echo unknown
}

#----------------------------------------------------------- btrfs deep checks

# Btrfs df numbers are an estimate. The filesystem can refuse writes with space
# still showing when metadata chunks are exhausted and nothing is left
# unallocated to make new ones from. Returns "unalloc_bytes meta_pct" or fails.
btrfs_pool_state() {
	local mp="$1" out unalloc meta_total meta_used meta_pct
	have btrfs || return 1

	out="$(guard 10 btrfs filesystem usage -b "$mp" 2>/dev/null)" || return 1
	[ -n "$out" ] || return 1

	unalloc="$(printf '%s\n' "$out" | awk -F: '/Device unallocated/ { gsub(/[^0-9]/, "", $2); print $2; exit }')"

	# "Metadata,DUP: Size:1073741824, Used:415236096" -- profile and spacing vary
	# by btrfs-progs version, so pull the two numbers rather than fixed fields.
	meta_total="$(printf '%s\n' "$out" | awk '/^Metadata,/ { if (match($0, /Size:[0-9]+/)) { print substr($0, RSTART + 5, RLENGTH - 5); exit } }')"
	meta_used="$(printf '%s\n' "$out" | awk '/^Metadata,/ { if (match($0, /Used:[0-9]+/)) { print substr($0, RSTART + 5, RLENGTH - 5); exit } }')"

	case "${unalloc:-x}${meta_total:-x}${meta_used:-x}" in *x*) return 1 ;; esac
	[ "$meta_total" -gt 0 ] 2>/dev/null || return 1

	meta_pct="$(awk -v u="$meta_used" -v t="$meta_total" 'BEGIN { printf "%.0f", (u / t) * 100 }')"
	printf '%s %s' "$unalloc" "$meta_pct"
}

#-------------------------------------------------------- LVM thin pool checks

# df reports the thin volume's virtual size. The pool underneath can be full
# while the volume looks half empty, and pool exhaustion means a read-only
# filesystem or worse. Different layer, so it is checked separately.
declare -a arrPoolAlerts=()
blnPoolBlind=0
scan_thin_pools() {
	local out rc line name data_used data_total meta_used meta_total dpct mpct field seen
	have dmsetup || return 0

	out="$(guard 5 dmsetup status --target thin-pool 2>/dev/null)"
	rc=$?
	# dmsetup needs root. During script-mode testing it will fail, and a silent
	# failure here is indistinguishable from "this host has no thin pools".
	if [ "$rc" -ne 0 ]; then
		blnPoolBlind=1
		return 0
	fi

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in *"thin-pool"*) : ;; *) continue ;; esac
		name="${line%%:*}"
		# <name>: <start> <len> thin-pool <txn> <meta_used>/<meta_total> <data_used>/<data_total> ...
		meta_used=""
		meta_total=""
		data_used=""
		data_total=""
		seen=0
		for field in $line; do
			case "$field" in
				*/*)
					if [ "$seen" -eq 0 ]; then
						meta_used="${field%%/*}"
						meta_total="${field##*/}"
						seen=1
					elif [ "$seen" -eq 1 ]; then
						data_used="${field%%/*}"
						data_total="${field##*/}"
						seen=2
					fi
					;;
			esac
		done
		case "${data_total:-x}${data_used:-x}" in *x* | *[!0-9]*) continue ;; esac
		[ "$data_total" -gt 0 ] 2>/dev/null || continue

		dpct="$(awk -v u="$data_used" -v t="$data_total" 'BEGIN { printf "%.0f", (u / t) * 100 }')"
		mpct=0
		case "${meta_total:-x}${meta_used:-x}" in
			*x* | *[!0-9]*) : ;;
			*)
				if [ "$meta_total" -gt 0 ]; then
					mpct="$(awk -v u="$meta_used" -v t="$meta_total" 'BEGIN { printf "%.0f", (u / t) * 100 }')"
				fi
				;;
		esac

		if [ "$dpct" -ge "$usrPoolThreshold" ]; then
			arrPoolAlerts+=("LVM thin pool ${name} data ${dpct}% full")
		fi
		if [ "$mpct" -ge "$usrPoolThreshold" ]; then
			arrPoolAlerts+=("LVM thin pool ${name} metadata ${mpct}% full")
		fi
	done <<<"$out"
	return 0
}

#--------------------------------------------------------------- gather mounts

declare -a arrBreach=() arrChecked=() arrSkippedUnknown=() arrNoRead=()
declare -a arrBtrfsNote=() arrBtrfsBlind=() arrReadOnly=() arrSeenSources=()
declare -a arrBtrfsMounts=()
intChecked=0
intMaxPct=-1
strMaxDesc=""

while read -r rawSource rawMount rawType rawOpts _rest; do
	[ -n "${rawType:-}" ] || continue

	fsType="$rawType"
	[ "$fsType" = "fuse" ] && fsType="fuse.unknown"

	kind="$(classify "$fsType")"
	[ "$kind" = "pseudo" ] && continue

	mountPoint="$(unescape "$rawMount")"
	source="$(unescape "$rawSource")"

	if [ "$blnAllDisks" -eq 1 ]; then
		if matches_any "$mountPoint" "${arrExclude[@]+"${arrExclude[@]}"}" ||
			matches_any "$source" "${arrExclude[@]+"${arrExclude[@]}"}"; then
			continue
		fi
	else
		if ! matches_any "$mountPoint" "${arrWanted[@]+"${arrWanted[@]}"}" &&
			! matches_any "$source" "${arrWanted[@]+"${arrWanted[@]}"}"; then
			continue
		fi
	fi

	if [ "$kind" != "local" ]; then
		[ "$usrUnknownFs" = "ignore" ] && continue
		arrSkippedUnknown+=("${fsType} at ${mountPoint}")
		continue
	fi

	# A read-only mount cannot be freed up, so it is not a space alert. But a
	# LOCAL filesystem mounted ro is usually ext4/xfs that hit errors and
	# remounted itself, and dropping it silently would mute the monitor at
	# exactly the wrong moment -- so it is named in the status instead. This is
	# checked AFTER usrDisks/usrExclude so a deliberately read-only mount can be
	# silenced with the exclude list rather than needing its own variable.
	case ",$rawOpts," in
		*,ro,*)
			arrReadOnly+=("${fsType} at ${mountPoint}")
			continue
			;;
	esac

	# One filesystem, one check. Btrfs subvolumes and bind mounts share a source
	# and share the space, so counting them once is correct; ZFS datasets have
	# distinct sources and are counted separately, which is also correct.
	if contains_exact "$source" "${arrSeenSources[@]+"${arrSeenSources[@]}"}"; then
		continue
	fi
	arrSeenSources+=("$source")

	# POSIX output: one line per filesystem, never wrapped, no --output needed
	# (the original used GNU --output, absent on older coreutils and busybox).
	dfLine="$(guard 20 df -Pk "$mountPoint" 2>/dev/null | awk 'NR==2')"
	if [ -z "$dfLine" ]; then
		arrNoRead+=("$mountPoint")
		continue
	fi

	set -- $dfLine
	if [ "$#" -lt 5 ]; then
		arrNoRead+=("$mountPoint")
		continue
	fi
	availKb="$4"
	pctUsed="$(printf '%s' "$5" | tr -d '%')"
	case "${pctUsed}${availKb}" in '' | *[!0-9]*)
		arrNoRead+=("$mountPoint")
		continue
		;;
	esac

	intChecked=$((intChecked + 1))
	freeGb="$(human_gb "$availKb")"
	freeGbInt=$((availKb / 1048576))
	arrChecked+=("${mountPoint} (${source}, ${fsType}) ${pctUsed}% used, ${freeGb} GB free")
	if [ "$pctUsed" -gt "$intMaxPct" ]; then
		intMaxPct="$pctUsed"
		strMaxDesc="${mountPoint} at ${pctUsed}% (${freeGb} GB free)"
	fi

	# ---- the percent + floor decision -------------------------------------
	# The original compared a percentage only, and computed it as
	# 1 - (avail/size) rather than used/(used+avail). Anywhere available space
	# is decoupled from raw size -- ext4 root reserve, quotas, btrfs profiles --
	# that overstates usage badly. df's own Use% is field 5 and is used as-is.
	blnOver=0
	if [ "$pctUsed" -ge "$usrThreshold" ]; then blnOver=1; fi

	blnLowFree=1
	if [ "$usrMinFreeGB" -gt 0 ] && [ "$freeGbInt" -ge "$usrMinFreeGB" ]; then
		blnLowFree=0
	fi

	if [ "$blnOver" -eq 1 ] && [ "$blnLowFree" -eq 1 ]; then
		if [ "$usrMinFreeGB" -gt 0 ]; then
			arrBreach+=("${mountPoint} (${source}) at ${pctUsed}% used with only ${freeGb} GB free (alerts at >=${usrThreshold}% and <${usrMinFreeGB} GB)")
		else
			arrBreach+=("${mountPoint} (${source}) at ${pctUsed}% used, ${freeGb} GB free (alerts at >=${usrThreshold}%)")
		fi
	fi

	# ---- btrfs: the failure df cannot see ----------------------------------
	if [ "$fsType" = "btrfs" ]; then
		arrBtrfsMounts+=("$mountPoint")
		if btrfsState="$(btrfs_pool_state "$mountPoint")"; then
			set -- $btrfsState
			btrUnalloc="$1"
			btrMetaPct="$2"
			btrUnallocGb="$(awk -v b="$btrUnalloc" 'BEGIN { printf "%.1f", b / 1073741824 }')"
			arrBtrfsNote+=("${mountPoint}: metadata ${btrMetaPct}%, ${btrUnallocGb} GB unallocated")
			# Metadata nearly full AND nothing unallocated left to carve a new
			# chunk from is the ENOSPC corner. Either alone is survivable.
			if [ "$btrMetaPct" -ge "$usrPoolThreshold" ] &&
				[ "$btrUnalloc" -lt 1073741824 ]; then
				arrBreach+=("${mountPoint} (btrfs) metadata ${btrMetaPct}% full with only ${btrUnallocGb} GB unallocated -- writes may fail while df still shows free space")
			fi
		else
			# Without btrfs-progs we are back to trusting df on the one
			# filesystem where df is least trustworthy. Say so out loud
			# rather than reporting a clean bill of health.
			arrBtrfsNote+=("${mountPoint}: btrfs detected but 'btrfs filesystem usage' could not be read; df figures are an estimate only")
			arrBtrfsBlind+=("$mountPoint")
		fi
	fi
done </proc/mounts

scan_thin_pools
for poolAlert in "${arrPoolAlerts[@]+"${arrPoolAlerts[@]}"}"; do
	arrBreach+=("$poolAlert (threshold ${usrPoolThreshold}%)")
done

#-------------------------------------------------------------------- verdict

if [ "$intChecked" -eq 0 ] && [ "${#arrBreach[@]}" -eq 0 ]; then
	msg="No local filesystems could be measured"
	if [ "${#arrReadOnly[@]}" -gt 0 ]; then
		msg="${msg} -- ${#arrReadOnly[@]} local filesystem(s) are mounted READ-ONLY: $(join_by ', ' "${arrReadOnly[@]}")"
	fi
	if [ "${#arrSkippedUnknown[@]}" -gt 0 ]; then
		msg="${msg} -- ${#arrSkippedUnknown[@]} mount(s) are a filesystem type this monitor does not measure: $(join_by ', ' "${arrSkippedUnknown[@]}")"
	fi
	if [ "$blnAllDisks" -eq 0 ]; then
		msg="${msg} -- usrDisks was set to '${usrDisks}' and matched nothing"
	fi
	die_unrunnable "$msg"
fi

# The alert condition, spelled out once so the status text and the diagnostic
# cannot drift apart.
if [ "$usrMinFreeGB" -gt 0 ]; then
	strCond="at or above ${usrThreshold}% used with under ${usrMinFreeGB} GB free"
else
	strCond="at or above ${usrThreshold}% used (no free-space floor set)"
fi

# Everything the monitor saw but did not measure is named on BOTH paths. A gap
# a technician cannot see is the same as no monitoring at all.
strNotes=""
[ "${#arrReadOnly[@]}" -gt 0 ] &&
	strNotes="${strNotes}; ${#arrReadOnly[@]} local fs mounted READ-ONLY ($(join_by ', ' "${arrReadOnly[@]}"))"
[ "${#arrSkippedUnknown[@]}" -gt 0 ] &&
	strNotes="${strNotes}; ${#arrSkippedUnknown[@]} not measured ($(join_by ', ' "${arrSkippedUnknown[@]}"))"
[ "${#arrNoRead[@]}" -gt 0 ] &&
	strNotes="${strNotes}; ${#arrNoRead[@]} unreadable ($(join_by ', ' "${arrNoRead[@]}"))"
[ "${#arrBtrfsBlind[@]}" -gt 0 ] &&
	strNotes="${strNotes}; ${#arrBtrfsBlind[@]} btrfs fs not verified, btrfs-progs unavailable ($(join_by ', ' "${arrBtrfsBlind[@]}"))"
[ "$blnPoolBlind" -eq 1 ] &&
	strNotes="${strNotes}; LVM thin pools not verified (dmsetup failed, needs root)"

# One line is all a technician gets in the alert, so cap the list and send the
# rest to the diagnostic.
strBreachList=""
if [ "${#arrBreach[@]}" -gt 3 ]; then
	strBreachList="$(join_by '; ' "${arrBreach[0]}" "${arrBreach[1]}" "${arrBreach[2]}") (+$((${#arrBreach[@]} - 3)) more, see diagnostic)"
elif [ "${#arrBreach[@]}" -gt 0 ]; then
	strBreachList="$(join_by '; ' "${arrBreach[@]}")"
fi

if [ "${#arrBreach[@]}" -gt 0 ] ||
	{ [ "$usrUnknownFs" = "alert" ] && [ "${#arrSkippedUnknown[@]}" -gt 0 ]; }; then

	if [ "${#arrBreach[@]}" -gt 0 ]; then
		emit_result "ALERT - ${strBreachList}; ${intChecked} filesystem(s) checked${strNotes}"
	else
		emit_result "ALERT - ${#arrSkippedUnknown[@]} mount(s) are a filesystem type this monitor cannot measure; ${intChecked} filesystem(s) checked${strNotes}"
	fi

	# --- diagnostic, failure path only, on a wall-clock budget --------------
	diagStart=$SECONDS
	diag_ok() { [ $((SECONDS - diagStart)) -lt "$DIAG_BUDGET" ]; }

	echo '<-Start Diagnostic->'
	echo "== thresholds =="
	echo "usrThreshold=${usrThreshold}% usrMinFreeGB=${usrMinFreeGB} usrPoolThreshold=${usrPoolThreshold}% usrUnknownFs=${usrUnknownFs}"
	echo "usrDisks=${usrDisks}"
	echo "usrExclude=${usrExclude:-(none)}"
	echo ""
	echo "== filesystems checked =="
	for entry in "${arrChecked[@]+"${arrChecked[@]}"}"; do echo "  $entry"; done

	if [ "${#arrReadOnly[@]}" -gt 0 ]; then
		echo ""
		echo "== local filesystems mounted READ-ONLY (not space-checked) =="
		for entry in "${arrReadOnly[@]}"; do echo "  $entry"; done
		echo "  A local fs mounted ro has usually remounted itself after errors."
		echo "  Check dmesg; this monitor reports it but does not alert on it."
	fi

	if [ "${#arrSkippedUnknown[@]}" -gt 0 ]; then
		echo ""
		echo "== present but NOT measured by this monitor =="
		for entry in "${arrSkippedUnknown[@]}"; do echo "  $entry"; done
		echo "  (network and unrecognised filesystems are reported, not measured;"
		echo "   set usrUnknownFs=alert to make these raise, or ignore to hide them)"
	fi

	if [ "${#arrBtrfsNote[@]}" -gt 0 ]; then
		echo ""
		echo "== btrfs detail =="
		for entry in "${arrBtrfsNote[@]}"; do echo "  $entry"; done
	fi

	echo ""
	echo "== df -PhT =="
	guard 10 df -PhT 2>/dev/null || guard 10 df -Ph 2>/dev/null || echo "  (df exceeded its cap)"

	# Capped at three filesystems so a host with many btrfs mounts cannot blow
	# the 60 second window.
	if [ "${#arrBtrfsMounts[@]}" -gt 0 ] && have btrfs; then
		intBtr=0
		for bmp in "${arrBtrfsMounts[@]}"; do
			diag_ok || break
			[ "$intBtr" -ge 3 ] && break
			intBtr=$((intBtr + 1))
			echo ""
			echo "== btrfs filesystem usage ${bmp} =="
			guard 5 btrfs filesystem usage "$bmp" 2>/dev/null | sed 's/^/  /' ||
				echo "  (btrfs exceeded its cap)"
		done
	fi

	if have dmsetup && diag_ok; then
		poolStatus="$(guard 5 dmsetup status --target thin-pool 2>/dev/null)"
		if [ -n "$poolStatus" ]; then
			echo ""
			echo "== LVM thin pools (meta_used/meta_total data_used/data_total) =="
			echo "$poolStatus" | sed 's/^/  /'
		fi
	fi

	# Top-level usage of at most two offending mounts, so the whole diagnostic
	# still posts inside the 60 second window on a slow or busy volume.
	if [ "${#arrBreach[@]}" -gt 0 ] && have du; then
		intDu=0
		for entry in "${arrBreach[@]}"; do
			diag_ok || break
			[ "$intDu" -ge 2 ] && break
			bmp="${entry%% *}"
			[ -d "$bmp" ] || continue
			intDu=$((intDu + 1))
			echo ""
			echo "== top-level usage of ${bmp} (5s cap, may be partial) =="
			guard 5 du -xh --max-depth=1 "$bmp" 2>/dev/null | sort -rh | head -12 | sed 's/^/  /' ||
				echo "  (du exceeded its 5s cap)"
		done
	fi

	if ! diag_ok; then
		echo ""
		echo "(diagnostic budget of ${DIAG_BUDGET}s reached; some sections were omitted)"
	fi
	echo '<-End Diagnostic->'
	exit 1
fi

emit_result "OK - ${intChecked} filesystem(s) checked, none ${strCond}; fullest is ${strMaxDesc:-n/a}${strNotes}"
exit 0
