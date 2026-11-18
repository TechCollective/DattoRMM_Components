#!/usr/bin/env bash
# Docker - Containers Differ From Expected [Lin]
#
# Datto RMM custom monitor. Runs as root. Compares the containers on a Docker
# host with its expected-containers list, /etc/tc-docker/expected-containers
# (created by "Docker - Configure Host Maintenance [Lin]", changed with
# "Docker - Update Expected Containers [Lin]"), and reports what the host's
# weekly prune is about to remove and whether that prune is out of date.
#
# Changes on the host: one file, /var/lib/tc-docker/monitor-first-seen (when it
# first saw each running container that is not on the list; the directory is
# created root-only when missing). It never starts a stopped Docker, and every
# docker command of a run is stopped DOCKER_TIMEOUT seconds after the start.
#
# Result: exit 0 healthy, exit 1 alert; one result block on every way out.
#   1  with the matching action set to Alert: an expected container stopped
#      or gone on a reviewed list (usrMissingAction), an unlisted container or
#      one with unreadable Compose labels (usrUnlistedAction), a stopped
#      container the prune has recorded for removal (usrPendingRemovalAction),
#      a stale prune (usrStalePruneAction), an unreviewed list
#      (usrUnreviewedAction; under Warn once it is usrUnreviewedAfterDays old).
#      Always: Docker stopped while the list has entries; Docker not answering
#      or not returning its container list; a docker client missing where
#      Docker's socket or unit is present; an invalid input variable or a
#      missing tool; the script stopped unexpectedly.
#   0  everything else, each finding named in the status.
#
# Every condition, input variable and exit, the order of the checks and the
# first-seen file:
# https://github.com/TechCollective/DattoRMM_Components/tree/main/Monitors/docker-containers-differ-from-expected-lin

set -u

# >>> tc-docker result: identical in the Containers, Health and Images monitors; change them together.
# The one result a run prints, as Datto reads it: <-Start Result->, one STATUS=
# line, <-End Result->, on every way out. With an exit code that is not 0, and
# only then, the lines diag collected follow as the diagnostic block.
#   diag LINE         adds a line to the diagnostic
#   emit CODE STATUS  prints the result (and the diagnostic), then exits CODE
# The status is made one line (a CR, newline or tab becomes a space, a run of
# spaces one space) and is cut at STATUS_MAX characters, so what matters most
# goes first. A run that ends any other way (an unset variable under set -u, a
# signal) leaves through the EXIT trap, which prints the result itself and
# makes the exit non-zero: a monitor that exits non-zero with nothing printed
# is an alert with no text. Before it does, it calls tc_cleanup when the
# monitor has defined one (something to remove on every way out). Once the
# result is being printed, HUP, INT and TERM are ignored, so it is printed
# once and whole.
STATUS_MAX=900
EMITTED=0
DIAG=""
diag() { DIAG="${DIAG}${1}"$'\n'; }
emit() {  # exit code, status
    local msg="$2"
    trap '' HUP INT TERM
    msg="${msg//$'\r'/ }"; msg="${msg//$'\n'/ }"; msg="${msg//$'\t'/ }"
    while [ "$msg" != "${msg//  / }" ]; do msg="${msg//  / }"; done
    msg="${msg# }"; msg="${msg% }"
    [ -n "$msg" ] || msg="Check produced no status text"
    [ "${#msg}" -gt "$STATUS_MAX" ] && msg="${msg:0:$((STATUS_MAX - 3))}..."
    printf '<-Start Result->\nSTATUS=%s\n<-End Result->\n' "$msg"
    EMITTED=1
    if [ "$1" -ne 0 ] && [ -n "$DIAG" ]; then
        printf '<-Start Diagnostic->\n%s<-End Diagnostic->\n' "$DIAG"
    fi
    exit "$1"
}
on_exit() {
    local rc=$?
    trap '' HUP INT TERM
    if declare -F tc_cleanup >/dev/null; then tc_cleanup; fi
    if [ "$EMITTED" -eq 0 ]; then
        printf '<-Start Result->\nSTATUS=Check could not run: the monitor stopped unexpectedly (exit %s)\n<-End Result->\n' "$rc"
        exit 1
    fi
}
trap on_exit EXIT
# <<< tc-docker result

# One PATH rule, whatever PATH the agent gives the script: the usual system
# directories are appended (never prepended, so what the agent's PATH finds
# first still wins), so whether docker is found does not depend on the agent.
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

# The oldest prune this monitor accepts: the version of "Docker - Configure Host
# Maintenance [Lin]" that installed /usr/local/sbin/tc-docker-prune (it stamps
# TC_PRUNE_VERSION=<its own version> at the top of the script). Raise this when a
# safety fix to the prune ships, and every host still on an older prune is
# flagged on its next run.
# 11 is the first prune that never starts a stopped Docker: its service has
# Requisite=docker.service, and it asks systemd before any docker command. The
# prunes of versions 9 and 10 start a Docker that was stopped on purpose, and
# every restart: always container with it. Version 12 only changes how the
# prune reads its own settings file, which matters after a hand edit of that
# file, version 13 only moves code, and version 14 only refuses a
# /var/lib/tc-docker that is not root's, so 11 is still accepted.
PRUNE_MIN_VERSION=11
PRUNE_BIN="/usr/local/sbin/tc-docker-prune"
PRUNE_UNIT="/etc/systemd/system/tc-docker-prune.service"
PRUNE_CONF="/etc/default/tc-docker-prune"
FIRST_SEEN_KEEP_DAYS=7
DOCKER_SOCK="/var/run/docker.sock"
# Every docker command of one run must have finished this many seconds after the
# monitor started; whatever is still running then is stopped, and the check
# says Docker did not answer. With the 5 seconds timeout(1) allows after TERM
# before KILL, the result block is out well within 60 seconds.
DOCKER_TIMEOUT=40

usrUnlistedAfterHours="${usrUnlistedAfterHours:-24}"
usrUnreviewedAfterDays="$(printf '%s' "${usrUnreviewedAfterDays-14}" | tr -d '[:space:]')"
usrUnlistedAction="$(printf '%s' "${usrUnlistedAction:-warn}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrMissingAction="$(printf '%s' "${usrMissingAction:-alert}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrUnreviewedAction="$(printf '%s' "${usrUnreviewedAction:-warn}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrStalePruneAction="$(printf '%s' "${usrStalePruneAction:-alert}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrPendingRemovalAction="$(printf '%s' "${usrPendingRemovalAction:-alert}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$usrUnlistedAfterHours" =~ ^[0-9]+$ ]] && [ "$usrUnlistedAfterHours" -le 8760 ] \
    || emit 1 "Check could not run: usrUnlistedAfterHours must be 0-8760 (got '$usrUnlistedAfterHours')"
[[ "$usrUnreviewedAfterDays" =~ ^[0-9]{1,3}$ ]] && [ $((10#$usrUnreviewedAfterDays)) -le 365 ] \
    || emit 1 "Check could not run: usrUnreviewedAfterDays must be 0-365 (got '$usrUnreviewedAfterDays')"
usrUnreviewedAfterDays=$((10#$usrUnreviewedAfterDays))
case "$usrUnlistedAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrUnlistedAction must be alert, warn or ignore (got '$usrUnlistedAction')" ;; esac
case "$usrMissingAction"  in alert|warn) ;;        *) emit 1 "Check could not run: usrMissingAction must be alert or warn (got '$usrMissingAction')" ;; esac
case "$usrUnreviewedAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrUnreviewedAction must be alert, warn or ignore (got '$usrUnreviewedAction')" ;; esac
case "$usrStalePruneAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrStalePruneAction must be alert, warn or ignore (got '$usrStalePruneAction')" ;; esac
case "$usrPendingRemovalAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrPendingRemovalAction must be alert, warn or ignore (got '$usrPendingRemovalAction')" ;; esac
for t in awk grep sed date xargs sort timeout; do
    command -v "$t" >/dev/null 2>&1 || emit 1 "Check could not run: required tool '$t' is missing"
done
timeout -k 1 10 true >/dev/null 2>&1 \
    || emit 1 "Check could not run: this host's timeout command does not take -k (GNU coreutils timeout is needed)"
START="$(date +%s)"
[[ "$START" =~ ^[0-9]+$ ]] || emit 1 "Check could not run: date +%s does not give the time in seconds"
DOCKER_DEADLINE=$(( START + DOCKER_TIMEOUT ))

# >>> tc-docker bounded: identical in the Containers, Health and Images monitors; change them together.
# Runs $1 (shell code) in a new bash under timeout(1), with the rest of the
# arguments as $1..., and returns its exit status: 124 or 137 when it was still
# running DOCKER_TIMEOUT seconds after the monitor started. timeout(1) puts the
# command in a process group of its own, whose id is timeout's own pid, and
# signals that group only (TERM; KILL 5 seconds later if its child is still
# there). Once it has timed out, whatever is left in that group (a docker client
# that ignored TERM after the bash above it died) is sent KILL here. Nothing
# else is ever signalled: not the monitor's own process group, not its parent.
# The caller sets DOCKER_DEADLINE (seconds since 1970) before the first call.
bounded() {
    local code=$1 left pid rc
    shift
    left=$(( DOCKER_DEADLINE - $(date +%s) ))
    [ "$left" -ge 1 ] || left=1
    timeout -k 5 "$left" "${BASH:-bash}" -c "$code" tc-docker-monitor "$@" &
    pid=$!
    wait "$pid"; rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        kill -KILL -- "-$pid" 2>/dev/null
    fi
    return "$rc"
}
systemd_up() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
# docker.service is a unit systemd knows (a unit file, or generated from /etc/init.d/docker).
docker_unit_loaded() {
    systemd_up || return 1
    [ "$(timeout -k 2 10 systemctl show docker.service -p LoadState 2>/dev/null)" = "LoadState=loaded" ]
}
# <<< tc-docker bounded

DOCKER="$(command -v docker 2>/dev/null || true)"
if [ -z "$DOCKER" ]; then
    seen=""
    [ -S "$DOCKER_SOCK" ] && seen="$DOCKER_SOCK is a socket"
    docker_unit_loaded && seen="${seen:+$seen and }docker.service is loaded"
    if [ -n "$seen" ]; then
        diag "No docker command was found in $PATH, but $seen, so Docker looks installed here. Find where its client went (a package removed only the CLI, a snap or a custom path) and put docker on one of those directories."
        emit 1 "Docker appears to be installed but no docker command was found"
    fi
    emit 0 "Docker is not installed on this host; nothing to check"
fi

# >>> tc-docker shared: identical in every tc-docker component; change them together.
TC_DIR="/etc/tc-docker"
EXPECTED_FILE="$TC_DIR/expected-containers"
IGNORE_FILE="$TC_DIR/ignore"
# Written by "Docker - Update Expected Containers [Lin]" (Confirm reviewed). Until it
# exists, the prune removes no containers and no images on this host.
REVIEWED_FILE="$TC_DIR/reviewed"
# shellcheck disable=SC2034  # not every component uses every name
KEY_RE='^(name:[a-zA-Z0-9][a-zA-Z0-9_.-]*|compose:[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*)$'

# One line per container, tab separated, every field non-empty:
#   id  key  name  running  restart-policy  created  started  tc.keep(y/n)  transient(y/n)
# key is compose:<project>/<service> for a Compose service, otherwise name:<name>.
# Labels are untrusted (a container inherits them from its image), so they are
# read JSON-encoded, one line each: a tab or newline in a label cannot add a
# field or a row. A container whose Compose labels are set but are not plain
# names gets the key unreadable:<first 12 characters of its id>, which matches
# no list entry and never carries the label. A row with the wrong field count,
# or an id that is not 64 hex characters, is dropped.
# transient is y for Compose one-offs (compose run) and --rm containers.
# Returns 1, printing nothing, when docker ps or docker inspect fails three
# times (a container removed between the two is normal; the whole listing is
# retried). Capture the output, rows="$(tc_containers)", and check the status:
# a pipe or < <(...) hides it, and "Docker did not answer" is not "no containers".
tc_containers() {
    local try ids out
    for try in 1 2 3; do
        [ "$try" -gt 1 ] && sleep 1
        ids="$("$DOCKER" ps -aq --no-trunc 2>/dev/null)" || continue
        [ -n "$ids" ] || return 0
        out="$(printf '%s\n' "$ids" | xargs "$DOCKER" inspect -f \
'{{.Id}}{{"\t"}}{{.Name}}{{"\t"}}{{json (index .Config.Labels "com.docker.compose.project")}}{{"\t"}}{{json (index .Config.Labels "com.docker.compose.service")}}{{"\t"}}{{json (index .Config.Labels "com.docker.compose.oneoff")}}{{"\t"}}{{.HostConfig.AutoRemove}}{{"\t"}}{{.State.Running}}{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{.Created}}{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{range $k, $v := .Config.Labels}}{{if eq $k "tc.keep"}}y{{end}}{{end}}' 2>/dev/null)" || continue
        printf '%s\n' "$out" | awk -F'\t' -v OFS='\t' '
            function absent(v) { return v == "null" || v == "\"\"" }
            function plain(v)  { return v ~ /^"[a-zA-Z0-9][a-zA-Z0-9_.-]*"$/ }
            function unq(v)    { return substr(v, 2, length(v) - 2) }
            NF != 11 || length($1) != 64 || $1 ~ /[^0-9a-f]/ { next }
            $7 != "true" && $7 != "false" || $9 == "" || $10 == "" { next }
            {
                name = $2; sub(/^\//, "", name)
                if (name !~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/) next
                if (!(absent($3) || plain($3)) || !(absent($4) || plain($4))) key = "unreadable:" substr($1, 1, 12)
                else if (plain($3) && plain($4)) key = "compose:" unq($3) "/" unq($4)
                else key = "name:" name
                print $1, key, name, $7, ($8 == "" ? "no" : $8), $9, $10, ($11 == "y" ? "y" : "n"), (($5 == "\"True\"" || $6 == "true") ? "y" : "n")
            }'
        return 0
    done
    return 1
}

# The entries of a list file: comments and blank lines dropped.
tc_list() {
    [ -r "$1" ] || return 0
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'
    return 0
}

# Succeeds if key $1 matches any pattern in the ignore file.
tc_ignored() {
    local p
    while IFS= read -r p; do
        printf '%s\n' "$1" | grep -qE -- "$p" 2>/dev/null && return 0
    done < <(tc_list "$IGNORE_FILE")
    return 1
}
# Succeeds once a person has confirmed this host's expected list.
tc_reviewed() { [ -s "$REVIEWED_FILE" ]; }

# The well-formed lines of pending-removal file $1 (the stopped containers
# tc-docker-prune has recorded and will remove), tab separated:
#   id  key  name  first-recorded
# first-recorded is seconds since 1970, printed without leading zeros. Then,
# when the file has any other line, one last line:
#   BAD  n  line-numbers
# n is how many lines are not well formed, line-numbers which ones (", "
# between them). Comment lines (#) and blank lines are neither. The file is
# untrusted: a line is well formed only when it is exactly four fields, a 64
# hex character id, a key, a plain name and a number of at most 10 digits; an
# id may appear on more than one line, and the caller decides which one counts.
# Prints nothing when $1 is missing or is not a regular file (a symlink is not
# one) that can be read.
tc_pending_lines() {
    { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; } || return 0
    awk -F'\t' -v OFS='\t' -v keyre="$KEY_RE" '
        /^#/ || /^[ \t]*$/ { next }
        NF == 4 && length($1) == 64 && $1 !~ /[^0-9a-f]/ && $2 ~ keyre && $3 ~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && $4 ~ /^[0-9]+$/ && length($4) <= 10 {
            sub(/^0+/, "", $4); if ($4 == "") $4 = "0"
            print; next
        }
        { bad++; where = where (bad > 1 ? ", " : "") NR }
        END { if (bad) print "BAD", bad, where }' "$1"
}
# <<< tc-docker shared

# >>> tc-docker running: identical in every tc-docker component; change them together.
# Whether the Docker daemon is running, found out without starting it. Where
# systemd manages docker.service, systemd is asked, and no docker command is run
# unless the service is active: on most installs docker.socket stays listening
# while the service is stopped, and any docker command (docker info, docker ps)
# would start Docker again, with every restart: always container. Elsewhere
# docker info is asked. Returns 0 running and answering; 1 stopped (systemd says
# docker.service is not active); 2 not answering (docker info failed). Sets
# DOCKER_STATE to a short reason when it returns 1 or 2. Plain systemctl
# options only, so systemd 219 understands them.
DOCKER_STATE=""
# shellcheck disable=SC2034  # the monitors read DOCKER_STATE in the bash that bounded starts, as text shellcheck cannot follow
tc_docker_running() {
    local load state
    DOCKER_STATE=""
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        load="$(systemctl show docker.service -p LoadState 2>/dev/null)"
        if [ "$load" = "LoadState=loaded" ] && ! systemctl is-active --quiet docker.service 2>/dev/null; then
            state="$(systemctl is-active docker.service 2>/dev/null)"
            DOCKER_STATE="docker.service is ${state:-not active}"
            return 1
        fi
    fi
    if ! "$DOCKER" info >/dev/null 2>&1; then
        DOCKER_STATE="docker info did not answer"
        return 2
    fi
    return 0
}
# <<< tc-docker running

# >>> tc-docker state: identical in the prune and in the Containers, Health and Images monitors; change them together.
# The one directory the tc-docker components keep state in, and the one way a
# file in it is written. tc_state_write NAME CONTENT replaces
# $TC_STATE_DIR/NAME with CONTENT, exactly as given. The new file is made in
# the same directory (mode 0600), read back and compared (a full disk can
# leave a short file), then renamed over the old one, so a reader sees the old
# file or the new one and never part of one. The directory is created when it
# is missing, and made root:root 0700 when it is root's but is not that.
# Nothing is written, and it returns 1 with the reason in TC_STATE_WHY (and
# the failing command's own words, when it had any, in TC_STATE_ERR), when:
#   - the directory is a symlink, or is there and is not a directory;
#   - NAME is there as a symlink, or as anything but a regular file (a symlink
#     is never followed, written through or replaced);
#   - the directory cannot be created, is not owned by root, or cannot be made
#     root:root 0700;
#   - no file can be created in it, what was written does not read back the
#     same, or the rename fails.
# What a failure means is the caller's to say: the prune removes no container
# it could not record first. Needs GNU stat (-c), mktemp and mv (-T).
TC_STATE_DIR=/var/lib/tc-docker
TC_STATE_WHY=""
TC_STATE_ERR=""
# shellcheck disable=SC2034  # only the prune prints TC_STATE_ERR
tc_state_write() {  # name, content
    local d="$TC_STATE_DIR" f="$TC_STATE_DIR/$1" tmp="" err=""
    TC_STATE_WHY=""; TC_STATE_ERR=""
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
        TC_STATE_WHY="$d is not a directory"
    elif [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
        TC_STATE_WHY="$f is not a regular file"
    elif ! err="$(mkdir -p -- "$d" 2>&1)"; then
        TC_STATE_WHY="$d cannot be created"
    elif [ "$(stat -c %u -- "$d" 2>/dev/null)" != "0" ]; then
        TC_STATE_WHY="$d is not owned by root"
    elif [ "$(stat -c '%u:%g:%a' -- "$d" 2>/dev/null)" != "0:0:700" ] \
         && ! err="$( { chown 0:0 -- "$d" && chmod 700 -- "$d"; } 2>&1)"; then
        TC_STATE_WHY="$d cannot be made root-only"
    elif ! tmp="$(mktemp -- "$d/.$1.XXXXXX" 2>&1)"; then
        err="$tmp"; tmp=""
        TC_STATE_WHY="no file can be created in $d"
    elif ! err="$( { printf '%s' "$2" >"$tmp"; } 2>&1)" || [ "$(cat -- "$tmp" 2>/dev/null; echo x)" != "${2}x" ] \
         || ! err="$(chmod 600 -- "$tmp" 2>&1)"; then
        TC_STATE_WHY="writing it failed"
    elif ! err="$(mv -fT -- "$tmp" "$f" 2>&1)"; then
        TC_STATE_WHY="the new file could not be renamed into place"
    else
        return 0
    fi
    [ -z "$tmp" ] || rm -f -- "$tmp"
    TC_STATE_ERR="$(printf '%s' "$err" | tr -cd '[:print:]' | cut -c1-200)"
    return 1
}
# <<< tc-docker state
# The two files this monitor has in that directory: the prune's record of the
# stopped containers it will remove (read only), and its own first-seen file.
PENDING_FILE="$TC_STATE_DIR/pending-removal"
FIRST_SEEN_FILE="$TC_STATE_DIR/monitor-first-seen"

# A prune installed by an older Host Maintenance. Reads two files and nothing
# else. STALE_STATUS is the status text ("" when nothing is stale or the action
# is ignore); STALE_DIAG the diagnostic lines for an alert.
STALE_STATUS=""
STALE_DIAG=()
stale_prune_check() {
    local found=() v n line bad="" val
    # The version 1 layout: the service runs docker itself, not the script.
    if [ -e "$PRUNE_UNIT" ] || [ -L "$PRUNE_UNIT" ]; then
        local seen=0
        while IFS= read -r line; do
            seen=1
            val="${line#"${line%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
            [ "$val" = "$PRUNE_BIN" ] || bad="${bad:-${val:-(empty)}}"
        done < <(sed -n 's/^[[:space:]]*ExecStart=//p' "$PRUNE_UNIT" 2>/dev/null)
        [ "$seen" -eq 1 ] || bad="(no ExecStart line)"
        if [ -n "$bad" ]; then
            found+=("prune service on this host does not run $PRUNE_BIN (version 1 layout)")
            STALE_DIAG+=("STALE PRUNE  $PRUNE_UNIT has ExecStart: $(printf '%s' "$bad" | tr -cd '[:print:]' | cut -c1-200)")
        fi
    fi
    # The script: a readable TC_PRUNE_VERSION whole number, at least PRUNE_MIN_VERSION.
    # The stamp was introduced in version 7, so a script without one is older than 7
    # whatever PRUNE_MIN_VERSION is by now.
    if [ -e "$PRUNE_BIN" ] || [ -L "$PRUNE_BIN" ]; then
        line="$(grep -a -m 1 '^TC_PRUNE_VERSION=' "$PRUNE_BIN" 2>/dev/null)" || line=""
        if [ -z "$line" ]; then
            found+=("prune on this host has no version (installed before version 7)")
            STALE_DIAG+=("STALE PRUNE  $PRUNE_BIN has no TC_PRUNE_VERSION line, so it was installed before version 7 of Docker - Configure Host Maintenance [Lin]")
        else
            v="${line#TC_PRUNE_VERSION=}"; v="${v%"${v##*[![:space:]]}"}"
            if [[ ! "$v" =~ ^[0-9]+$ ]]; then
                found+=("prune on this host has an unreadable version (not a whole number)")
                STALE_DIAG+=("STALE PRUNE  $PRUNE_BIN has a TC_PRUNE_VERSION line that is not a whole number")
            else
                n="${v#"${v%%[!0]*}"}"; n="${n:-0}"      # no leading zeros: never octal
                # More than 9 digits is a number far above any minimum; skip the arithmetic.
                if [ "${#n}" -le 9 ] && [ "$n" -lt "$PRUNE_MIN_VERSION" ]; then
                    found+=("prune on this host is version $n, older than $PRUNE_MIN_VERSION")
                    STALE_DIAG+=("STALE PRUNE  $PRUNE_BIN is version $n; this monitor wants $PRUNE_MIN_VERSION or newer")
                fi
            fi
        fi
    fi
    [ "${#found[@]}" -gt 0 ] || return 0
    local f
    for f in ${found[@]+"${found[@]}"}; do STALE_STATUS="${STALE_STATUS:+$STALE_STATUS; }$f"; done
    STALE_DIAG+=("             Run Docker - Configure Host Maintenance [Lin] on this host to install the current prune. Until then the old prune's rules apply.")
}
# Before any docker command and before the "no list" exit: it reads two files and
# needs no daemon, so a host with an old prune is reported while Docker is stopped,
# and hosts on versions 1 and 2 have no list and are the ones it exists to find.
[ "$usrStalePruneAction" = "ignore" ] || stale_prune_check

# The exits before the container list. emit_early puts a stale prune first and
# alerts for it under Alert; emit_failed is for "Check could not run", which
# stays first, with a stale prune after it.
stale_diag() {
    local line
    [ "$usrStalePruneAction" = "alert" ] || return 0
    for line in ${STALE_DIAG[@]+"${STALE_DIAG[@]}"}; do diag "$line"; done
}
emit_early() {  # exit code, status
    local rc=$1 msg=$2
    if [ -n "$STALE_STATUS" ]; then
        msg="$STALE_STATUS; $msg"
        if [ "$usrStalePruneAction" = "alert" ]; then stale_diag; rc=1; fi
    fi
    emit "$rc" "$msg"
}
emit_failed() {  # status
    stale_diag
    emit 1 "$1${STALE_STATUS:+; $STALE_STATUS}"
}
docker_hung() {  # what was running
    diag "$1 had not finished $DOCKER_TIMEOUT seconds after this monitor started, so it was stopped: timeout(1) sent TERM to the process group of the docker commands this run started, then anything left in that group was sent KILL; nothing else was signalled."
    diag "A Docker daemon that accepts connections but does not answer is the usual cause. Look at dockerd: systemctl status docker; journalctl -u docker."
    emit_failed "Check could not run: Docker did not answer within $DOCKER_TIMEOUT seconds"
}
LIST_ENTRIES=0
[ -e "$EXPECTED_FILE" ] && LIST_ENTRIES="$(tc_list "$EXPECTED_FILE" | grep -c .)"

# Is Docker running? Asked without starting it: tc_docker_running asks systemd
# first and runs docker info only when docker.service is active (or not
# managed by systemd). Run under the time limit, in a bash of its own.
STATE="$(bounded "$(declare -f tc_docker_running)"$'\n''DOCKER=$1; tc_docker_running; rc=$?; printf "%s" "$DOCKER_STATE"; exit "$rc"' "$DOCKER")"
case $? in
    0) ;;
    1)  # systemd says docker.service is not active; no docker command was run.
        if [ "$LIST_ENTRIES" -gt 0 ]; then
            diag "Docker is stopped: systemd says ${STATE:-docker.service is not active}. This monitor ran no docker command, so it did not start it (any docker command would, through docker.socket)."
            diag "The $LIST_ENTRIES container(s) on $EXPECTED_FILE are not running. If Docker was stopped on purpose, this alert is expected until it is started again; otherwise: systemctl start docker."
            emit_early 1 "Docker is stopped (${STATE:-docker.service is not active}); its expected containers are not running"
        fi
        if [ -e "$EXPECTED_FILE" ]; then
            emit_early 0 "Docker is stopped (${STATE:-docker.service is not active}); its expected-containers list is empty, so nothing is expected to run"
        fi
        emit_early 0 "Docker is stopped (${STATE:-docker.service is not active}); no expected-containers list on this host yet, so nothing is expected to run"
        ;;
    2)  # docker info failed.
        if [ ! -e "$EXPECTED_FILE" ] && [ ! -S "$DOCKER_SOCK" ] && ! docker_unit_loaded; then
            emit_early 0 "Docker client installed ($DOCKER) but no Docker daemon on this host (no docker.service, no $DOCKER_SOCK); nothing to check"
        fi
        # Asked once more for Docker's own words. Safe: systemd does not say
        # docker.service is stopped, so this cannot be what starts it.
        err="$(bounded '"$1" info 2>&1 >/dev/null' "$DOCKER")"
        case $? in 124|137) docker_hung "docker info" ;; esac
        diag "docker info said: $(printf '%s' "$err" | tail -n 2 | tr -cd '[:print:]\n' | cut -c1-300)"
        if systemd_up; then
            diag "systemd: docker.service is $(timeout -k 2 10 systemctl is-active docker.service 2>/dev/null || true), docker.socket is $(timeout -k 2 10 systemctl is-active docker.socket 2>/dev/null || true)."
        else
            diag "systemd does not manage this host."
        fi
        [ -S "$DOCKER_SOCK" ] && diag "$DOCKER_SOCK is a socket." || diag "$DOCKER_SOCK is not a socket."
        emit_failed "Check could not run: cannot talk to the Docker daemon"
        ;;
    124|137) docker_hung "docker info" ;;
    *) emit_failed "Check could not run: asking whether Docker is running failed unexpectedly" ;;
esac

if [ ! -e "$EXPECTED_FILE" ]; then
    NO_LIST="No expected-containers list on this host yet; Docker - Configure Host Maintenance [Lin] creates it"
    if [ -n "$STALE_STATUS" ]; then
        emit_early 0 "${NO_LIST,}"
    fi
    emit 0 "$NO_LIST"
fi

mapfile -t EXPECTED < <(tc_list "$EXPECTED_FILE")
BAD=()
declare -A LISTED=()
for k in ${EXPECTED[@]+"${EXPECTED[@]}"}; do
    if [[ "$k" =~ $KEY_RE ]]; then LISTED[$k]=1; else BAD+=("$k"); fi
done

ROWS="$(bounded "$(declare -f tc_containers)"$'\n''DOCKER=$1; tc_containers' "$DOCKER")"
case $? in
    0) ;;
    124|137) docker_hung "Listing the containers (docker ps, docker inspect)" ;;
    *)  diag "docker ps or docker inspect failed 3 times in a row, so the containers on this host are unknown."
        emit_failed "Check could not run: Docker did not return its container list" ;;
esac
NOW="$(date +%s)"
MIN_AGE=$(( usrUnlistedAfterHours * 3600 ))

RUNNING=(); STOPPED=(); MISSING=()
for k in ${EXPECTED[@]+"${EXPECTED[@]}"}; do
    [[ "$k" =~ $KEY_RE ]] || continue
    if   printf '%s\n' "$ROWS" | awk -F'\t' -v k="$k" '$2 == k && $4 == "true" {f=1} END {exit !f}'; then RUNNING+=("$k")
    elif printf '%s\n' "$ROWS" | awk -F'\t' -v k="$k" '$2 == k {f=1} END {exit !f}'; then STOPPED+=("$k")
    else MISSING+=("$k"); fi
done

# The running, non-transient, unlisted, not-ignored keys, each with its
# container's start time (the first container of a key, as before).
UNREADABLE=(); IGNORED=0; CAND=()
declare -A SEEN=() STARTED=()
while IFS=$'\t' read -r id key name running _policy _created started _keep transient; do
    [ -n "$id" ] || continue
    # Compose labels that are not plain names: counted whatever the state, age
    # or ignore list, and named by container name and short id only.
    case "$key" in unreadable:*) UNREADABLE+=("$name (${id:0:12})"); continue ;; esac
    [ "$running" = "true" ] && [ "$transient" = "n" ] || continue
    [ -n "${SEEN[$key]:-}" ] && continue
    SEEN[$key]=1
    [ -n "${LISTED[$key]:-}" ] && continue
    if tc_ignored "$key"; then IGNORED=$((IGNORED + 1)); continue; fi
    s="$(date -d "$started" +%s 2>/dev/null)" || s=""
    [[ "$s" =~ ^[0-9]{1,10}$ ]] || s="$NOW"
    CAND+=("$key"); STARTED[$key]="$s"
done <<<"$ROWS"

# ---- first seen: /var/lib/tc-docker/monitor-first-seen
# The well-formed lines of the file, key<TAB>first<TAB>last, first <= last, last
# no more than an hour ahead of now, each key once. Nothing else is trusted.
first_seen_lines() {
    { [ -f "$FIRST_SEEN_FILE" ] && [ ! -L "$FIRST_SEEN_FILE" ] && [ -r "$FIRST_SEEN_FILE" ]; } || return 0
    awk -F'\t' -v OFS='\t' -v keyre="$KEY_RE" -v now="$NOW" '
        /^#/ { next }
        NF == 3 && $1 ~ keyre && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && length($2) <= 10 && length($3) <= 10 \
            && $2 + 0 <= $3 + 0 && $3 + 0 <= now + 3600 && !seen[$1]++ { print $1, $2 + 0, $3 + 0 }' "$FIRST_SEEN_FILE"
}
# Replaces the file with a header and $1 (lines ending in newlines), through
# tc_state_write (the tc-docker state block): a new root-only file in the same
# root-only directory, read back, then renamed over the old one; a symlink is
# never followed or written through. Returns 1, with FIRST_SEEN_WHY set, when
# it cannot.
FIRST_SEEN_WHY=""
first_seen_text() {
    printf '%s\n' "# Running containers not on the expected list, as Docker - Containers Differ From" \
        "# Expected [Lin] has seen them, so that a restart or a redeploy does not reset how" \
        "# long one has been there. Written by that monitor; do not edit." \
        "# key<TAB>first seen<TAB>last seen (seconds since 1970). A key is dropped once it is" \
        "# on the list, or has not been seen running for $FIRST_SEEN_KEEP_DAYS days."
    printf '%s' "$1"
}
first_seen_write() {
    local body
    body="$(first_seen_text "$1"; echo x)"
    tc_state_write monitor-first-seen "${body%x}" && return 0
    FIRST_SEEN_WHY="$TC_STATE_WHY"
    return 1
}
declare -A FS_FIRST=() FS_LAST=() FROM=()
while IFS=$'\t' read -r k f l; do
    [ -n "$k" ] || continue
    FS_FIRST[$k]="$f"; FS_LAST[$k]="$l"
done <<<"$(first_seen_lines)"
FS_BODY=""
for k in ${CAND[@]+"${CAND[@]}"}; do
    f="${STARTED[$k]}"
    if [ -n "${FS_FIRST[$k]:-}" ] && [ "${FS_FIRST[$k]}" -lt "$f" ]; then f="${FS_FIRST[$k]}"; fi
    FROM[$k]="$f"
    FS_BODY="${FS_BODY}${k}"$'\t'"${f}"$'\t'"${NOW}"$'\n'
done
for k in ${FS_FIRST[@]+"${!FS_FIRST[@]}"}; do
    [ -n "${FROM[$k]:-}" ] && continue                      # seen this run
    [ -n "${LISTED[$k]:-}" ] && continue                    # on the list now
    l="${FS_LAST[$k]}"
    [ $(( NOW - l )) -ge $(( FIRST_SEEN_KEEP_DAYS * 86400 )) ] && continue   # not seen for the keep period
    FS_BODY="${FS_BODY}${k}"$'\t'"${FS_FIRST[$k]}"$'\t'"${l}"$'\n'
done
[ -z "$FS_BODY" ] || FS_BODY="$(printf '%s' "$FS_BODY" | LC_ALL=C sort)"$'\n'
# Written when there is something to keep or an old file to replace, and only
# when that changes it.
if { [ -n "$FS_BODY" ] || [ -e "$FIRST_SEEN_FILE" ] || [ -L "$FIRST_SEEN_FILE" ]; } \
   && ! { [ -f "$FIRST_SEEN_FILE" ] && [ ! -L "$FIRST_SEEN_FILE" ] \
          && [ "$(cat -- "$FIRST_SEEN_FILE" 2>/dev/null)" = "$(first_seen_text "$FS_BODY")" ]; }; then
    if ! first_seen_write "$FS_BODY"; then
        # Not saved, so not trusted either: every age counts from its container's start.
        for k in ${CAND[@]+"${CAND[@]}"}; do FROM[$k]="${STARTED[$k]}"; done
    fi
fi

UNLISTED=(); YOUNG=0
for k in ${CAND[@]+"${CAND[@]}"}; do
    f="${FROM[$k]}"
    if [ $(( NOW - f )) -lt "$MIN_AGE" ]; then YOUNG=$((YOUNG + 1)); continue; fi
    UNLISTED+=("$k")
done

join() { local IFS=','; printf '%s' "$*" | sed 's/,/, /g'; }

SUMMARY="$(( ${#EXPECTED[@]} - ${#BAD[@]} )) expected: ${#RUNNING[@]} running"
[ "${#STOPPED[@]}" -gt 0 ] && SUMMARY="$SUMMARY, ${#STOPPED[@]} stopped ($(join ${STOPPED[@]+"${STOPPED[@]}"}))"
[ "${#MISSING[@]}" -gt 0 ] && SUMMARY="$SUMMARY, ${#MISSING[@]} missing ($(join ${MISSING[@]+"${MISSING[@]}"}))"
if [ "${#UNLISTED[@]}" -gt 0 ] && [ "$usrUnlistedAction" != "ignore" ]; then
    SUMMARY="$SUMMARY; ${#UNLISTED[@]} unlisted ($(join ${UNLISTED[@]+"${UNLISTED[@]}"}))"
fi
[ "${#UNREADABLE[@]}" -gt 0 ] && SUMMARY="$SUMMARY; ${#UNREADABLE[@]} with unreadable Compose labels"
[ "$YOUNG" -gt 0 ] && SUMMARY="$SUMMARY; $YOUNG new, under ${usrUnlistedAfterHours}h"
[ -n "$FIRST_SEEN_WHY" ] && SUMMARY="$SUMMARY; first-seen times not saved ($FIRST_SEEN_WHY), so unlisted ages count from each container's start"
[ "$IGNORED" -gt 0 ] && SUMMARY="$SUMMARY; $IGNORED ignored"
[ "${#BAD[@]}" -gt 0 ] && SUMMARY="$SUMMARY; ${#BAD[@]} unreadable list line(s)"
UNREVIEWED=0; tc_reviewed || UNREVIEWED=1
# How long the list has gone unreviewed: the age of the list file (it is
# created unreviewed, and Update Expected Containers rewrites it on Add, Remove
# and Accept current). -1 when it cannot be read; that never escalates.
UNREVIEWED_DAYS=-1; UNREVIEWED_ESCALATE=0
if [ "$UNREVIEWED" -eq 1 ] && [ "$usrUnreviewedAction" != "ignore" ]; then
    mtime="$(stat -c %Y -- "$EXPECTED_FILE" 2>/dev/null)" || mtime=""
    if [[ "$mtime" =~ ^[0-9]{1,12}$ ]] && [ "$mtime" -le "$NOW" ]; then
        UNREVIEWED_DAYS=$(( (NOW - mtime) / 86400 ))
    fi
    if [ "$UNREVIEWED_DAYS" -lt 0 ]; then FOR=""
    elif [ "$UNREVIEWED_DAYS" -eq 0 ]; then FOR=" for less than a day"
    elif [ "$UNREVIEWED_DAYS" -eq 1 ]; then FOR=" for 1 day"
    else FOR=" for $UNREVIEWED_DAYS days"; fi
    SUMMARY="$SUMMARY; list NOT REVIEWED$FOR, so no containers or images are pruned"
    if [ "$usrUnreviewedAction" = "warn" ] && [ "$usrUnreviewedAfterDays" -gt 0 ] \
       && [ "$UNREVIEWED_DAYS" -ge "$usrUnreviewedAfterDays" ]; then
        UNREVIEWED_ESCALATE=1
    fi
fi

# Stopped containers the prune has recorded and will remove. Read only while
# the list is reviewed (before that the prune removes nothing and clears the
# file), and only those still stopped and unprotected: the prune drops the
# others on its next run. A line that is not well formed is counted, not shown.
PENDING=(); PENDING_DIAG=(); PENDING_ALERTABLE=0; PENDING_BAD=0; PENDING_BAD_LINES=""
if [ "$usrPendingRemovalAction" != "ignore" ] && [ "$UNREVIEWED" -eq 0 ] \
   && { [ -e "$PENDING_FILE" ] || [ -L "$PENDING_FILE" ]; }; then
    if [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] && [ -r "$PENDING_FILE" ]; then
        PLINES="$(tc_pending_lines "$PENDING_FILE")"
    else
        PLINES=""; PENDING_BAD=1; PENDING_BAD_LINES="it is not a regular file this monitor can read"
    fi
    GRACE="$(sed -n 's/^GRACE_HOURS=\([0-9]\{1,5\}\)$/\1/p' "$PRUNE_CONF" 2>/dev/null | tail -n 1)"
    GRACE=$(( 10#${GRACE:-144} ))
    declare -A PSEEN=()
    while IFS=$'\t' read -r pid pkey pname pat; do
        [ -n "$pid" ] || continue
        if [ "$pid" = "BAD" ]; then     # one such line at most: how many lines, and which
            PENDING_BAD="$pkey"; PENDING_BAD_LINES="line(s) $pname"; continue
        fi
        [ -z "${PSEEN[$pid]:-}" ] || continue
        PSEEN[$pid]=1
        # Still there, stopped, with the same key and name, and not protected.
        row="$(printf '%s\n' "$ROWS" | awk -F'\t' -v id="$pid" '$1 == id {print; exit}')"
        IFS=$'\t' read -r _id rkey rname rrunning rpolicy _c _s rkeep _t <<<"$row"
        [ -n "$row" ] && [ "$rrunning" = "false" ] && [ "$rkey" = "$pkey" ] && [ "$rname" = "$pname" ] || continue
        printf '%s\n' ${EXPECTED[@]+"${EXPECTED[@]}"} | grep -qxF -- "$pkey" && continue
        case "$rpolicy" in always|unless-stopped) continue ;; esac
        [ "$rkeep" = "y" ] && continue
        from=$(( pat + GRACE * 3600 ))
        if tc_ignored "$pkey"; then
            PENDING+=("$pkey from $(date -d "@$from" '+%Y-%m-%d') (ignored)")
            PENDING_DIAG+=("PENDING   $pkey  - stopped container $pname, recorded $(date -d "@$pat" '+%Y-%m-%d %H:%M'); the prune removes it from $(date -d "@$from" '+%Y-%m-%d %H:%M'). It matches an ignore pattern, so it does not alert.")
        else
            PENDING+=("$pkey from $(date -d "@$from" '+%Y-%m-%d')")
            PENDING_ALERTABLE=$((PENDING_ALERTABLE + 1))
            PENDING_DIAG+=("PENDING   $pkey  - stopped container $pname, recorded $(date -d "@$pat" '+%Y-%m-%d %H:%M'); the prune removes it from $(date -d "@$from" '+%Y-%m-%d %H:%M'). To keep it: Docker - Update Expected Containers [Lin], usrAction Add, usrItems $pkey. To let it go: do nothing.")
        fi
    done <<<"$PLINES"
fi
PENDING_STATUS=""
if [ "${#PENDING[@]}" -gt 0 ]; then
    if [ "${#PENDING[@]}" -eq 1 ]; then PENDING_STATUS="1 stopped container will be removed by the prune"
    else PENDING_STATUS="${#PENDING[@]} stopped containers will be removed by the prune"; fi
    shown=(${PENDING[@]+"${PENDING[@]:0:5}"})
    PENDING_STATUS="$PENDING_STATUS ($(join ${shown[@]+"${shown[@]}"})$([ "${#PENDING[@]}" -gt 5 ] && echo " and $(( ${#PENDING[@]} - 5 )) more"))"
fi
if [ "$PENDING_BAD" -gt 0 ]; then
    PENDING_STATUS="${PENDING_STATUS:+$PENDING_STATUS; }pending-removal file has $PENDING_BAD unreadable line(s)"
fi
[ -n "$PENDING_STATUS" ] && SUMMARY="$PENDING_STATUS; $SUMMARY"
# A stale prune goes first: it is what the old prune may delete that matters
# most here, and emit cuts the status at STATUS_MAX characters.
[ -n "$STALE_STATUS" ] && SUMMARY="$STALE_STATUS; $SUMMARY"

ALERT=0
# Before review, stopped or missing containers are part of the review, not
# separate alerts: onboarding raises one "not reviewed" item, not one per container.
if [ $(( ${#STOPPED[@]} + ${#MISSING[@]} )) -gt 0 ] && [ "$usrMissingAction" = "alert" ] && [ "$UNREVIEWED" -eq 0 ]; then ALERT=1; fi
if [ "${#UNLISTED[@]}" -gt 0 ] && [ "$usrUnlistedAction" = "alert" ]; then ALERT=1; fi
if [ "${#UNREADABLE[@]}" -gt 0 ] && [ "$usrUnlistedAction" = "alert" ]; then ALERT=1; fi
if [ "$UNREVIEWED" -eq 1 ] && [ "$usrUnreviewedAction" = "alert" ]; then ALERT=1; fi
if [ "$UNREVIEWED_ESCALATE" -eq 1 ]; then ALERT=1; fi
if [ -n "$STALE_STATUS" ] && [ "$usrStalePruneAction" = "alert" ]; then ALERT=1; fi
if [ $(( PENDING_ALERTABLE + PENDING_BAD )) -gt 0 ] && [ "$usrPendingRemovalAction" = "alert" ]; then ALERT=1; fi

if [ "$ALERT" -eq 1 ]; then
    if [ -n "$STALE_STATUS" ] && [ "$usrStalePruneAction" = "alert" ]; then
        for k in ${STALE_DIAG[@]+"${STALE_DIAG[@]}"}; do diag "$k"; done
    fi
    if [ "$usrPendingRemovalAction" = "alert" ]; then
        for k in ${PENDING_DIAG[@]+"${PENDING_DIAG[@]}"}; do diag "$k"; done
        [ "$PENDING_BAD" -eq 0 ] || diag "BAD PENDING  $PENDING_FILE: $PENDING_BAD_LINES not id<TAB>key<TAB>name<TAB>time, so not shown or trusted. The prune drops such lines on its next run."
    fi
    for k in ${STOPPED[@]+"${STOPPED[@]}"}; do diag "STOPPED   $k  - start it, or remove it from the list if it was retired"; done
    for k in ${MISSING[@]+"${MISSING[@]}"}; do diag "MISSING   $k  - no container with this key exists; redeploy it, or remove it from the list"; done
    for k in ${UNLISTED[@]+"${UNLISTED[@]}"}; do diag "UNLISTED  $k  - add it to the list, add an ignore pattern, or remove the container"; done
    for k in ${UNREADABLE[@]+"${UNREADABLE[@]}"}; do diag "UNREADABLE  $k  - its Compose labels are not plain names, so it cannot be listed and is never pruned; find out where it came from"; done
    for k in ${BAD[@]+"${BAD[@]}"}; do diag "BAD LINE  $k  - not name:<name> or compose:<project>/<service>"; done
    if [ "$UNREVIEWED_ESCALATE" -eq 1 ]; then
        diag "NOT REVIEWED for $UNREVIEWED_DAYS days  - this alerts because the list has gone unreviewed for $usrUnreviewedAfterDays days or more (usrUnreviewedAfterDays). Until it is reviewed, the prune removes no containers or images on this host, and stopped or missing containers do not alert. Review it with Docker - Update Expected Containers [Lin]: run Show, fix the list (Add, Remove, Accept current), then Confirm reviewed."
    elif [ "$UNREVIEWED" -eq 1 ]; then
        diag "NOT REVIEWED  - run Show, fix the list, then Confirm reviewed. Until then the prune removes no containers or images."
    fi
    diag ""
    diag "Change the list with Docker - Update Expected Containers [Lin] (usrAction add, remove, accept-current, add-ignore)."
    diag "List: $EXPECTED_FILE   Ignore patterns: $IGNORE_FILE"
    emit 1 "$SUMMARY"
fi
emit 0 "$SUMMARY"
