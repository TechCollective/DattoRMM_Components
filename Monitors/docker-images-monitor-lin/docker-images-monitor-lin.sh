#!/bin/bash
# Docker Images monitor [Lin]
# (the name in component.json and in Datto; see "Known issues" in the README)
#
# Datto RMM custom monitor. Runs as root. Safe to assign to every Linux device.
# For every running container it compares the image digest the container runs
# with the digest its tag now points to in the registry. It alerts on the ones
# that have fallen behind, and on an image reference whose registry has not
# answered for usrStaleAfterDays. It never pulls.
#
# Changes on the host: one file, its cache of registry answers,
# /var/lib/tc-docker/image-digests.tsv (the directory is created root-only
# when missing), and a scratch directory from mktemp -d, removed on every way
# out. It changes no container or image and never starts a stopped Docker. Its
# only network calls are registry lookups (docker buildx imagetools inspect,
# with the host's own docker login), cached for usrCacheHours and stopped at
# the first rate-limit answer.
#
# Result: exit 0 healthy, exit 1 alert; one result block on every way out.
#   1  a container behind its registry tag by usrMinAgeDays or more; a
#      reference with no registry answer for usrStaleAfterDays; every lookup
#      failed; Docker unreachable, not answering within DOCKER_TIMEOUT seconds
#      or not returning its container list; docker buildx missing; an invalid
#      input variable or a missing tool; the script stopped unexpectedly
#   0  everything else (Docker not installed or stopped, nothing behind,
#      pinned tags, lookups rate limited or deferred), named in the status
#
# Every outcome, the input variables (and the names they had before version
# 3), the cache file's format and how registry load is kept low:
# https://github.com/TechCollective/DattoRMM_Components/tree/main/Monitors/docker-images-monitor-lin

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

# The scratch directory of a run (one file per registry lookup), made further
# down and removed on every way out. Set here, before anything can exit, and
# under a name of its own: whatever an inherited TMP names is never touched.
SCRATCH=""
tc_cleanup() { [ -z "$SCRATCH" ] || rm -rf -- "$SCRATCH" 2>/dev/null; return 0; }
# A signal ends the run through the EXIT trap, with the usual 128+N status.
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

# One PATH rule, whatever PATH the agent gives the script: the usual system
# directories are appended (never prepended, so what the agent's PATH finds
# first still wins).
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

DOCKER_SOCK="/var/run/docker.sock"
# Every command that talks to the Docker daemon must have finished this many
# seconds after the monitor started; whatever is still running then is stopped.
DOCKER_TIMEOUT=40
# No registry lookup runs past this many seconds after the start (plus the 5
# seconds timeout(1) allows after TERM before KILL), so the result is out
# inside 90 seconds on every path. The component's Datto timeout is 120.
RUN_LIMIT=75
STATE_NAME="image-digests.tsv"
# A cache entry for an image no running container uses is dropped once nothing
# has been recorded for it for this many days.
STATE_KEEP_DAYS=90

# ---------------------------------------------------------------- inputs

trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

# Each value is read from its usr name first. OLD-NAME FALLBACK: when the usr
# name is not set at all, the name used before version 3 is read instead, for
# monitor policies saved before the rename. Remove the inner ${old-...} and
# from_name once no policy in Datto sends the old names.
MIN_AGE="$(trim "${usrMinAgeDays-${minAgeDays-7}}")";           [ -n "$MIN_AGE" ] || MIN_AGE=7
EXCLUDE="$(trim "${usrExcludePattern-${excludePattern-}}")"
TIMEOUT="$(trim "${usrInspectTimeout-${inspectTimeout-20}}")";  [ -n "$TIMEOUT" ] || TIMEOUT=20
MAXPAR="$(trim "${usrMaxParallel-${maxParallel-3}}")";          [ -n "$MAXPAR" ] || MAXPAR=3
CACHE_HOURS="$(trim "${usrCacheHours-${cacheHours-12}}")";      [ -n "$CACHE_HOURS" ] || CACHE_HOURS=12
STALE_DAYS="$(trim "${usrStaleAfterDays-${staleAfterDays-7}}")"; [ -n "$STALE_DAYS" ] || STALE_DAYS=7

# The name a value was read from, for messages: the usr name ($1) unless only
# the old name ($2) is set. OLD-NAME FALLBACK: goes with it.
from_name() {
    if [ -z "${!1+x}" ] && [ -n "${!2+x}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# A whole number from $3 to $4, at most 3 digits; a leading zero is decimal.
check_num() {  # name value min max
    local name="$1" v="$2"
    [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ $((10#$v)) -ge "$3" ] && [ $((10#$v)) -le "$4" ] \
        || emit 1 "Check could not run: $name must be a whole number from $3 to $4 (got '$(printf '%s' "$v" | tr -cd '[:print:]' | cut -c1-40)')"
}
check_num "$(from_name usrMinAgeDays minAgeDays)" "$MIN_AGE" 0 365;              MIN_AGE=$((10#$MIN_AGE))
check_num "$(from_name usrInspectTimeout inspectTimeout)" "$TIMEOUT" 10 60;      TIMEOUT=$((10#$TIMEOUT))
check_num "$(from_name usrMaxParallel maxParallel)" "$MAXPAR" 1 8;               MAXPAR=$((10#$MAXPAR))
check_num "$(from_name usrCacheHours cacheHours)" "$CACHE_HOURS" 0 720;          CACHE_HOURS=$((10#$CACHE_HOURS))
check_num "$(from_name usrStaleAfterDays staleAfterDays)" "$STALE_DAYS" 0 365;   STALE_DAYS=$((10#$STALE_DAYS))

for t in awk grep sed sort cut tr date mktemp stat timeout xargs cksum; do
    command -v "$t" >/dev/null 2>&1 || emit 1 "Check could not run: required tool '$t' is missing"
done
timeout -k 1 10 true >/dev/null 2>&1 \
    || emit 1 "Check could not run: this host's timeout command does not take -k (GNU coreutils timeout is needed)"

if [ -n "$EXCLUDE" ]; then
    printf 'x' | grep -qE -- "$EXCLUDE" 2>/dev/null
    [ $? -le 1 ] || emit 1 "Check could not run: $(from_name usrExcludePattern excludePattern) is not a valid extended regular expression"
fi

START="$(date +%s)"
[[ "$START" =~ ^[0-9]+$ ]] || emit 1 "Check could not run: date +%s does not give the time in seconds"
NOW="$START"
DOCKER_DEADLINE=$(( START + DOCKER_TIMEOUT ))
RUN_DEADLINE=$(( START + RUN_LIMIT ))

# ---------------------------------------------------------------- bounded docker

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
docker_hung() {  # what was running
    diag "$1 had not finished $DOCKER_TIMEOUT seconds after this monitor started, so it was stopped: timeout(1) sent TERM to the process group of the docker commands this run started, then anything left in that group was sent KILL; nothing else was signalled."
    diag "A Docker daemon that accepts connections but does not answer is the usual cause. Look at dockerd: systemctl status docker; journalctl -u docker."
    emit 1 "Check could not run: Docker did not answer within $DOCKER_TIMEOUT seconds"
}

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

# >>> tc-docker monitor state: identical in the Health and Images monitors; change them together.
# tc_state_read NAME prints state file NAME from $TC_STATE_DIR (the tc-docker
# state block), and only when it can be this monitor's own: the directory is a
# real directory (not a symlink) owned by root, and the file a regular file
# (not a symlink) owned by root. Otherwise it prints nothing, and the caller
# starts without saved state. The caller still keeps only the lines it can
# check.
# MOVED STATE. Until Health version 2 and Images version 4 these two monitors
# kept their state in /var/lib/tc-docker-monitor. While NAME is not in
# $TC_STATE_DIR at all, the file of that name in the old directory is printed
# instead, under the same rule. The run's tc_state_write then makes the new
# file, so the old one is read once. Nothing here changes or removes the old
# directory or what is in it. Remove this fallback (TC_STATE_OLD_DIR and the
# line that uses it) once no host has state only in the old directory.
# Needs GNU stat (-c).
TC_STATE_OLD_DIR=/var/lib/tc-docker-monitor
tc_state_read() {  # name
    local d="$TC_STATE_DIR"
    if [ ! -e "$d/$1" ] && [ ! -L "$d/$1" ]; then d="$TC_STATE_OLD_DIR"; fi
    [ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -c %u -- "$d" 2>/dev/null)" = "0" ] \
        && [ -f "$d/$1" ] && [ ! -L "$d/$1" ] && [ "$(stat -c %u -- "$d/$1" 2>/dev/null)" = "0" ] || return 0
    cat -- "$d/$1" 2>/dev/null
    return 0
}
# <<< tc-docker monitor state

# ------------------------------------------------------------------- pre-flight

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

STATE="$(bounded "$(declare -f tc_docker_running)"$'\n''DOCKER=$1; tc_docker_running; rc=$?; printf "%s" "$DOCKER_STATE"; exit "$rc"' "$DOCKER")"
case $? in
    0) ;;
    1) emit 0 "Docker is stopped (${STATE:-docker.service is not active}); nothing to check" ;;
    2)  if [ ! -S "$DOCKER_SOCK" ] && ! docker_unit_loaded; then
            emit 0 "Docker client installed ($DOCKER) but no Docker daemon on this host (no docker.service, no $DOCKER_SOCK); nothing to check"
        fi
        err="$(bounded '"$1" info 2>&1 >/dev/null' "$DOCKER")"
        case $? in 124|137) docker_hung "docker info" ;; esac
        diag "docker info said: $(printf '%s' "$err" | tail -n 2 | tr -cd '[:print:]\n' | cut -c1-300)"
        emit 1 "Check could not run: cannot talk to the Docker daemon" ;;
    124|137) docker_hung "docker info" ;;
    *) emit 1 "Check could not run: asking whether Docker is running failed unexpectedly" ;;
esac

SCRATCH="$(mktemp -d)" || emit 1 "Check could not run: cannot create a temporary directory"
BREAKER="${SCRATCH}/rate-limited"

# ------------------------------------------------------- gather local state

# One line per running container, in docker ps order, tab separated:
#   ok    name  ref  local-digest
#   excl  name
#   skip  name  reason
# Three docker commands, whatever the number of containers: docker ps, one
# docker inspect over every container, and one docker image inspect over the
# distinct images they run. The templates name struct fields only, never a map
# key (on Docker 29 a template that addresses a missing map key can fail the whole
# call). Every value is read JSON-encoded and kept only when it is a plain
# name, reference, digest or id, so nothing in a name, tag or digest can add a
# row or a field: a name that is not plain is shown as the first 12 characters
# of the container id, a reference or tag that is not plain is no image tag,
# and a digest that is not plain is ignored. A container removed between docker
# ps and docker inspect (or its image between the two inspects) fails that
# call, so the whole listing is retried, three tries one second apart. Exits 3
# when no try succeeds: "Docker did not answer" is never "no containers". Run
# under bounded(), in a bash of its own.
gather() {
    local try ids cout iout id jn jr ji extra cname ref imgid repo r loc d k n
    local -a cid cnm cref cimg imgs fl
    local -A seen tag0 digs
    for try in 1 2 3; do
        [ "$try" -gt 1 ] && sleep 1
        ids="$("$DOCKER" ps -q --no-trunc 2>/dev/null)" || continue
        [ -n "$ids" ] || exit 0
        cout="$(printf '%s\n' "$ids" | xargs "$DOCKER" inspect --type container -f \
'{{json .Id}}{{"\t"}}{{json .Name}}{{"\t"}}{{json .Config.Image}}{{"\t"}}{{json .Image}}' 2>/dev/null)" || continue
        cid=(); cnm=(); cref=(); cimg=(); imgs=(); seen=(); tag0=(); digs=()
        while IFS=$'\t' read -r id jn jr ji extra; do
            [[ "$id" =~ ^\"([0-9a-f]{64})\"$ ]] && [ -n "$ji" ] && [ -z "$extra" ] || continue
            id="${BASH_REMATCH[1]}"
            if [[ "$jn" =~ ^\"/?([a-zA-Z0-9][a-zA-Z0-9_.-]*)\"$ ]]; then cname="${BASH_REMATCH[1]}"; else cname="${id:0:12}"; fi
            if [[ "$jr" =~ ^\"([a-zA-Z0-9][a-zA-Z0-9._/:@-]*)\"$ ]]; then ref="${BASH_REMATCH[1]}"
            elif [ "$jr" = '""' ]; then ref=""
            else ref="(unreadable)"; fi
            if [[ "$ji" =~ ^\"(sha256:[0-9a-f]{64})\"$ ]]; then imgid="${BASH_REMATCH[1]}"; else imgid=""; fi
            cid+=("$id"); cnm+=("$cname"); cref+=("$ref"); cimg+=("$imgid")
            if [ -n "$imgid" ] && [ -z "${seen[$imgid]+x}" ]; then seen[$imgid]=1; imgs+=("$imgid"); fi
        done <<< "$cout"
        if [ "${#imgs[@]}" -gt 0 ]; then
            iout="$("$DOCKER" image inspect -f \
'{{json .Id}}{{range .RepoTags}}{{"\t"}}T{{json .}}{{end}}{{range .RepoDigests}}{{"\t"}}D{{json .}}{{end}}' \
                    "${imgs[@]}" 2>/dev/null)" || continue
            while IFS=$'\t' read -r -a fl; do
                [ "${#fl[@]}" -gt 0 ] && [[ "${fl[0]}" =~ ^\"(sha256:[0-9a-f]{64})\"$ ]] || continue
                imgid="${BASH_REMATCH[1]}"
                for ((n = 1; n < ${#fl[@]}; n++)); do
                    d="${fl[$n]}"
                    case "$d" in
                        T*) [ -n "${tag0[$imgid]+x}" ] && continue    # the first tag, as before
                            if [[ "$d" =~ ^T\"([a-zA-Z0-9][a-zA-Z0-9._/:@-]*)\"$ ]]; then tag0[$imgid]="${BASH_REMATCH[1]}"
                            else tag0[$imgid]="(unreadable)"; fi ;;
                        D*) [[ "$d" =~ ^D\"([a-zA-Z0-9][a-zA-Z0-9._/:@-]*)\"$ ]] \
                                && digs[$imgid]="${digs[$imgid]:-}${BASH_REMATCH[1]}"$'\n' ;;
                    esac
                done
            done <<< "$iout"
        fi
        for ((k = 0; k < ${#cid[@]}; k++)); do
            cname="${cnm[$k]}"; ref="${cref[$k]}"; imgid="${cimg[$k]}"
            if [ -n "$EXCLUDE" ] && printf '%s\n' "$cname" | grep -qE -- "$EXCLUDE" 2>/dev/null; then
                printf 'excl\t%s\n' "$cname"; continue
            fi
            if [ -z "$ref" ] || [[ "$ref" =~ ^(sha256:)?[0-9a-f]{12,}$ ]]; then
                ref=""; [ -n "$imgid" ] && ref="${tag0[$imgid]:-}"
            fi
            if [ -z "$ref" ] || [[ ! "$ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]]; then
                printf 'skip\t%s\tno image tag\n' "$cname"; continue
            fi
            r="${ref%%@*}"
            case "${r##*/}" in *:*) repo="${r%:*}" ;; *) repo="$r" ;; esac
            # The first repo digest containing "<repo>@", as before.
            loc=""
            if [ -n "$imgid" ]; then
                while IFS= read -r d; do
                    [[ "$d" == *"${repo}@"* ]] || continue
                    loc="${d#*@}"; loc="${loc%%@*}"; break
                done <<< "${digs[$imgid]:-}"
            fi
            if [[ ! "$loc" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                printf 'skip\t%s\tlocal image, not from a registry\n' "$cname"; continue
            fi
            printf 'ok\t%s\t%s\t%s\n' "$cname" "$ref" "$loc"
        done
        exit 0
    done
    exit 3
}

ROWS="$(bounded "$(declare -f gather)"$'\n''DOCKER=$1; EXCLUDE=$2; gather' "$DOCKER" "$EXCLUDE")"
case $? in
    0) ;;
    3)  diag "docker ps, docker inspect or docker image inspect failed on three tries, one second apart. A container removed between docker ps and docker inspect fails one try; three in a row is Docker not answering properly."
        emit 1 "Check could not run: Docker did not return its container list" ;;
    124|137) docker_hung "Listing the containers (docker ps, docker inspect)" ;;
    *) emit 1 "Check could not run: listing the containers failed unexpectedly" ;;
esac

[ -z "${ROWS//[[:space:]]/}" ] && emit 0 "Docker is installed but no containers are running"

if ! timeout -k 2 10 "$DOCKER" buildx version >/dev/null 2>&1; then
    emit 1 "Check could not run: docker buildx is missing; install the docker-buildx-plugin package on this host"
fi

NAMES=(); REFS=(); LOCALS=(); SKIPPED=(); EXCLUDED=0
while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
        ok)   NAMES+=("$a"); REFS+=("$b"); LOCALS+=("$c") ;;
        excl) EXCLUDED=$((EXCLUDED + 1)) ;;
        skip) SKIPPED+=("$a ($b)") ;;
    esac
done <<< "$ROWS"

TOTAL=$(( ${#NAMES[@]} + ${#SKIPPED[@]} + EXCLUDED ))

join() {
    local sep="$1"; shift
    [ "$#" -eq 0 ] && return 0
    local out="$1" i; shift
    for i in "$@"; do out="${out}${sep}${i}"; done
    printf '%s' "$out"
}
image_tag() {
    local r="${1%%@*}"
    case "${r##*/}" in *:*) printf '%s' "${r##*:}" ;; *) printf 'latest' ;; esac
}
day() { date -u -d "@$1" +%Y-%m-%d 2>/dev/null || printf '%s' "$1"; }

# ---------------------------------------------------------------------- state

declare -A S_DIG=() S_CRE=() S_OK=() S_ERR=() S_SINCE=()
S_ORDER=()
while IFS=$'\t' read -r -a f; do
    n=${#f[@]}
    r="${f[0]:-}"
    [[ "$r" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]] || continue
    [ -z "${S_OK[$r]+x}" ] || continue                       # first line per ref wins
    if [ "$n" -eq 4 ]; then                                  # version 1: ref digest created checked
        f=("$r" "${f[1]}" "${f[2]:--}" "${f[3]}" none 0)
    elif [ "$n" -eq 3 ]; then                                # version 1 with no created date
        f=("$r" "${f[1]}" - "${f[2]}" none 0)
    elif [ "$n" -ne 6 ]; then
        continue
    fi
    [[ "${f[1]}" =~ ^(sha256:[0-9a-f]{64}|-)$ ]] || continue
    [[ "${f[2]}" =~ ^(-|[0-9][0-9TZ:.+-]{0,39})$ ]] || continue
    [[ "${f[3]}" =~ ^[0-9]{1,12}$ ]] && [[ "${f[5]}" =~ ^[0-9]{1,12}$ ]] || continue
    [ "${f[3]}" -le $((NOW + 3600)) ] && [ "${f[5]}" -le $((NOW + 3600)) ] || continue
    case "${f[4]}" in none|ratelimited|refused|notfound|timeout|other) ;; *) continue ;; esac
    [ "${f[4]}" = none ] && f[5]=0
    S_DIG[$r]="${f[1]}"; S_CRE[$r]="${f[2]}"; S_OK[$r]="${f[3]}"; S_ERR[$r]="${f[4]}"; S_SINCE[$r]="${f[5]}"
    S_ORDER+=("$r")
done < <(tc_state_read "$STATE_NAME")

# Never fatal: a run that cannot save its state says so in the status.
STATE_NOTE=""
save_state() {
    local r newest out=""
    declare -A wrote=()
    for r in ${UNIQ[@]+"${UNIQ[@]}"} ${S_ORDER[@]+"${S_ORDER[@]}"}; do
        [ -n "$r" ] && [ -n "${S_OK[$r]+x}" ] && [ -z "${wrote[$r]+x}" ] || continue
        wrote[$r]=1
        if [ -z "${IN_USE[$r]+x}" ]; then
            newest="${S_OK[$r]}"; [ "${S_SINCE[$r]:-0}" -gt "$newest" ] && newest="${S_SINCE[$r]:-0}"
            [ $(( NOW - newest )) -lt $(( STATE_KEEP_DAYS * 86400 )) ] || continue
        fi
        out="${out}${r}"$'\t'"${S_DIG[$r]:--}"$'\t'"${S_CRE[$r]:--}"$'\t'"${S_OK[$r]}"$'\t'"${S_ERR[$r]:-none}"$'\t'"${S_SINCE[$r]:-0}"$'\n'
    done
    tc_state_write "$STATE_NAME" "$out" \
        || STATE_NOTE="; state not saved ($TC_STATE_WHY), so nothing is cached and lookup failures are not tracked over time"
}

if [ "${#NAMES[@]}" -eq 0 ]; then
    emit 0 "$(printf '%d container(s) running, none checkable (%d excluded, %d without a registry image)' \
        "$TOTAL" "$EXCLUDED" "${#SKIPPED[@]}")"
fi

# A long TTL means every host refreshes in one burst. Hosts built from the same
# image would then all refresh together and hammer the site's shared NAT address,
# so shave a stable per-host slice of up to 10% off the TTL. Stable, not random:
# a fresh roll each run would expire entries early at random.
JITTER=0
if [ "$CACHE_HOURS" -ge 24 ]; then
    JITTER=$(( $( (hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo host) \
                  | cksum | cut -d' ' -f1 ) % (CACHE_HOURS * 360) ))
fi
TTL=$(( CACHE_HOURS * 3600 - JITTER ))

mapfile -t UNIQ < <(printf '%s\n' ${REFS[@]+"${REFS[@]}"} | sort -u)
declare -A IN_USE=()
for r in ${UNIQ[@]+"${UNIQ[@]}"}; do IN_USE[$r]=1; done

# --------------------------------------------- phase 1: digests, cheap and cached

# R_DIG: the digest used for this run's comparison; R_SRC: where it came from
# (cached, queried, stale) or why there is none (ratelimit, deferred, err).
declare -A R_DIG=() R_CRE=() R_SRC=() R_MSG=()
CACHED=0; QUERIED=0; TIMED_OUT_RUN=0

TO_QUERY=()
for r in ${UNIQ[@]+"${UNIQ[@]}"}; do
    if [[ "${S_DIG[$r]:-}" == sha256:* ]] && [ "${S_ERR[$r]:-}" = none ] && [ $(( NOW - ${S_OK[$r]:-0} )) -lt "$TTL" ]; then
        R_DIG[$r]="${S_DIG[$r]}"; R_CRE[$r]="${S_CRE[$r]:--}"; R_SRC[$r]=cached
        CACHED=$((CACHED + 1))
    else
        TO_QUERY+=("$r")
    fi
done

# Runs one registry lookup with its own time limit (the smaller of
# usrInspectTimeout and what is left of RUN_LIMIT), in a process group of its
# own that is killed if the lookup times out. Prints its output; returns its
# exit status (124 or 137: timed out).
reg_inspect() {  # seconds, format, ref
    local pid rc
    timeout -k 5 "$1" "$DOCKER" buildx imagetools inspect --format "$2" "$3" </dev/null 2>&1 &
    pid=$!
    wait "$pid"; rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then kill -KILL -- "-$pid" 2>/dev/null; fi
    return "$rc"
}
# Kind of a failed lookup: ratelimited, refused, notfound, timeout or other.
# Only the registry's rate-limit words count as a rate limit, not the digits
# 429 anywhere in the text (a port, an address, a digest).
err_kind() {  # rc, output
    if [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; then echo timeout
    elif printf '%s\n' "$2" | grep -qiF -e '429 Too Many Requests' -e 'toomanyrequests'; then echo ratelimited
    elif printf '%s\n' "$2" | grep -qiE '401 Unauthorized|403 Forbidden|unauthorized|denied|no basic auth credentials|authentication required'; then echo refused
    elif printf '%s\n' "$2" | grep -qiE 'manifest unknown|no such manifest|name unknown|404 Not Found|: not found'; then echo notfound
    else echo other
    fi
}
last_line() { printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -cd '[:print:]' | cut -c1-160; }

# Digest only. This is a single HEAD against the manifest -- asking for the
# image config here is what makes a sweep expensive, so it is deferred.
lookup_digest() {  # ref, out file, seconds
    local ref="$1" out="$2" raw rc digest kind
    [ -e "$BREAKER" ] && { printf '%s\tSKIP\n' "$ref" > "$out"; return; }
    raw="$(reg_inspect "$3" '{{.Manifest.Digest}}' "$ref")"; rc=$?
    digest="$(printf '%s' "$raw" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
    if [ "$rc" -eq 0 ] && [ -n "$digest" ]; then
        printf '%s\t%s\n' "$ref" "$digest" > "$out"; return
    fi
    kind="$(err_kind "$rc" "$raw")"
    [ "$kind" = ratelimited ] && : > "$BREAKER"
    printf '%s\tERR\t%s\t%s\n' "$ref" "$kind" "$(last_line "$raw")" > "$out"
}

# Time left for one more lookup, or nothing when too little is left.
lookup_secs() {
    local left=$(( RUN_DEADLINE - $(date +%s) ))
    [ "$left" -ge 5 ] || return 1
    [ "$left" -gt "$TIMEOUT" ] && left="$TIMEOUT"
    printf '%s' "$left"
}

n=0
for r in ${TO_QUERY[@]+"${TO_QUERY[@]}"}; do
    [ -e "$BREAKER" ] && break
    while [ "$(jobs -rp | wc -l)" -ge "$MAXPAR" ]; do sleep 0.2; done
    [ -e "$BREAKER" ] && break
    secs="$(lookup_secs)" || { TIMED_OUT_RUN=1; break; }
    n=$((n + 1)); QUERIED=$((QUERIED + 1))
    lookup_digest "$r" "${SCRATCH}/d${n}" "$secs" &
done
wait

declare -A ATTEMPT=()
for ((i = 1; i <= n; i++)); do
    IFS=$'\t' read -r r what kind msg < "${SCRATCH}/d${i}" 2>/dev/null || continue
    [ -n "$r" ] || continue
    case "$what" in
        sha256:*)
            ATTEMPT[$r]=ok; R_DIG[$r]="$what"; R_SRC[$r]=queried
            [ "${S_DIG[$r]:-}" = "$what" ] && [ "${S_CRE[$r]:--}" != "-" ] && R_CRE[$r]="${S_CRE[$r]}"
            S_DIG[$r]="$what"; S_OK[$r]="$NOW"; S_ERR[$r]=none; S_SINCE[$r]=0
            [ -n "${R_CRE[$r]:-}" ] || S_CRE[$r]="-"
            ;;
        ERR)
            ATTEMPT[$r]="$kind"; R_MSG[$r]="$msg"
            if [ -z "${S_OK[$r]+x}" ]; then S_DIG[$r]="-"; S_CRE[$r]="-"; S_OK[$r]=0; S_ERR[$r]=none; S_SINCE[$r]=0; fi
            if [ "${S_ERR[$r]:-none}" = none ]; then S_SINCE[$r]="$NOW"; fi
            S_ERR[$r]="$kind"
            ;;
    esac
done

# No answer this run (rate limited, cut short by the breaker or the time limit):
# a stale answer beats no answer, so fall back to whatever we knew before. A
# lookup that failed for another reason is a real failure: unreadable, as before.
STALE=0
for r in ${UNIQ[@]+"${UNIQ[@]}"}; do
    [ -n "${R_SRC[$r]:-}" ] && continue
    a="${ATTEMPT[$r]:-}"
    if [ -n "$a" ] && [ "$a" != ratelimited ]; then R_SRC[$r]=err; continue; fi
    if [[ "${S_DIG[$r]:-}" == sha256:* ]]; then
        R_DIG[$r]="${S_DIG[$r]}"; R_CRE[$r]="${S_CRE[$r]:--}"; R_SRC[$r]=stale
        STALE=$((STALE + 1))
    elif [ "$a" = ratelimited ] || [ -e "$BREAKER" ]; then
        R_SRC[$r]=ratelimit
    else
        R_SRC[$r]=deferred
    fi
done

# --------------------------------- phase 2: build dates, only for images that moved

MOVERS=()
for r in ${UNIQ[@]+"${UNIQ[@]}"}; do
    [ -n "${R_DIG[$r]:-}" ] || continue
    [ "${R_CRE[$r]:--}" = "-" ] || continue          # created date already known
    for ((i = 0; i < ${#REFS[@]}; i++)); do
        if [ "${REFS[$i]}" = "$r" ] && [ "${LOCALS[$i]}" != "${R_DIG[$r]}" ]; then
            MOVERS+=("$r"); break
        fi
    done
done

lookup_created() {  # ref, out file, seconds
    local ref="$1" out="$2" raw rc created
    [ -e "$BREAKER" ] && { : > "$out"; return; }
    raw="$(reg_inspect "$3" '{{json .Image}}' "$ref")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        [ "$(err_kind "$rc" "$raw")" = ratelimited ] && : > "$BREAKER"
        : > "$out"; return
    fi
    # .Image is a map keyed by platform on multi-arch images and a bare config
    # on single-arch ones; the first "created" is right in both shapes.
    created="$(printf '%s' "$raw" | grep -oE '"created"[[:space:]]*:[[:space:]]*"[^"]+"' \
              | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [[ "$created" =~ ^[0-9][0-9TZ:.+-]{0,39}$ ]] || created=""
    printf '%s\t%s\n' "$ref" "$created" > "$out"
}

m=0
for r in ${MOVERS[@]+"${MOVERS[@]}"}; do
    [ -e "$BREAKER" ] && break
    while [ "$(jobs -rp | wc -l)" -ge "$MAXPAR" ]; do sleep 0.2; done
    [ -e "$BREAKER" ] && break
    secs="$(lookup_secs)" || { TIMED_OUT_RUN=1; break; }
    m=$((m + 1))
    lookup_created "$r" "${SCRATCH}/c${m}" "$secs" &
done
wait
for ((i = 1; i <= m; i++)); do
    IFS=$'\t' read -r r c < "${SCRATCH}/c${i}" 2>/dev/null || continue
    [ -n "$r" ] && [ -n "$c" ] || continue
    R_CRE[$r]="$c"
    [ "${S_DIG[$r]:-}" = "${R_DIG[$r]:-}" ] && S_CRE[$r]="$c"
done

save_state

# ------------------------------------------------------------------ classify

BEHIND=(); PENDING=(); CURRENT=(); PINNED=(); UNCHECKED=(); RATELIMITED=(); DEFERRED=()

for ((i = 0; i < ${#NAMES[@]}; i++)); do
    CNAME="${NAMES[$i]}"; REF="${REFS[$i]}"; LOCAL="${LOCALS[$i]}"
    TAG="$(image_tag "$REF")"
    REMOTE="${R_DIG[$REF]:-}"; CREATED="${R_CRE[$REF]:-}"; [ "$CREATED" = "-" ] && CREATED=""

    case "${R_SRC[$REF]:-}" in
        ratelimit) RATELIMITED+=("$CNAME"); continue ;;
        deferred)  DEFERRED+=("$CNAME"); continue ;;
        err)
            UNCHECKED+=("$CNAME")
            diag "${CNAME} (${REF}): registry lookup failed (${ATTEMPT[$REF]:-other})"
            diag "  ${R_MSG[$REF]:-no detail}"
            continue ;;
    esac

    if [ "$REMOTE" = "$LOCAL" ]; then
        if [[ "$TAG" =~ (^|[^a-zA-Z0-9])[vV]?[0-9]+\.[0-9]+ ]]; then
            PINNED+=("${CNAME}:${TAG}")
        else
            CURRENT+=("${CNAME}:${TAG}")
        fi
        continue
    fi

    AGE_DAYS=""
    if [ -n "$CREATED" ]; then
        BUILT="$(date -d "$CREATED" +%s 2>/dev/null)"
        [ -n "$BUILT" ] && [ "$BUILT" -gt 0 ] && AGE_DAYS=$(( (NOW - BUILT) / 86400 ))
    fi

    # Unknown or nonsensical build date fails open: report rather than hide.
    if [ -n "$AGE_DAYS" ] && [ "$AGE_DAYS" -lt "$MIN_AGE" ]; then
        PENDING+=("${CNAME}:${TAG} (${AGE_DAYS}d)")
        continue
    fi

    BEHIND+=("${CNAME}:${TAG}${AGE_DAYS:+ (${AGE_DAYS}d)}")
    diag "${CNAME}"
    diag "  image           ${REF}"
    diag "  local digest    ${LOCAL}"
    diag "  registry digest ${REMOTE}"
    diag "  new image built ${CREATED:-unknown}${AGE_DAYS:+ (${AGE_DAYS} days ago)}"
    diag ""
done

# A reference with no successful registry answer for usrStaleAfterDays days.
kind_text() {
    case "$1" in
        ratelimited) echo "rate limited" ;; refused) echo "refused" ;; notfound) echo "not found" ;;
        timeout) echo "timeout" ;; *) echo "other error" ;;
    esac
}
STALE_REFS=()
if [ "$STALE_DAYS" -gt 0 ]; then
    for r in ${UNIQ[@]+"${UNIQ[@]}"}; do
        [ -n "${S_ERR[$r]:-}" ] && [ "${S_ERR[$r]}" != none ] || continue
        if [ "${S_OK[$r]:-0}" -gt 0 ]; then base="${S_OK[$r]}"; since="no registry answer since $(day "${S_OK[$r]}")"
        else base="${S_SINCE[$r]:-0}"; since="failing since $(day "${S_SINCE[$r]:-0}"), never answered"; fi
        [ $(( NOW - base )) -ge $(( STALE_DAYS * 86400 )) ] || continue
        STALE_REFS+=("${r} ($(kind_text "${S_ERR[$r]}"), ${since})")
        diag "${r}: no successful registry answer for $(( (NOW - base) / 86400 )) days (usrStaleAfterDays ${STALE_DAYS})"
        diag "  last error: $(kind_text "${S_ERR[$r]}"), errors since $(day "${S_SINCE[$r]:-0}")${R_MSG[$r]:+: ${R_MSG[$r]}}"
        diag "  Refused: check root's docker login on this host. Rate limited: docker login as root moves the host to a per-account allowance."
        diag ""
    done
fi

# ---------------------------------------------------------------------- verdict

SUMMARY=$(printf '%d checked: %d behind, %d current, %d pinned' \
    "${#NAMES[@]}" "${#BEHIND[@]}" "${#CURRENT[@]}" "${#PINNED[@]}")
[ "${#PENDING[@]}"     -gt 0 ] && SUMMARY="${SUMMARY}, ${#PENDING[@]} update(s) newer than ${MIN_AGE}d"
[ "${#RATELIMITED[@]}" -gt 0 ] && SUMMARY="${SUMMARY}, ${#RATELIMITED[@]} deferred (registry rate limit)"
[ "${#DEFERRED[@]}"    -gt 0 ] && SUMMARY="${SUMMARY}, ${#DEFERRED[@]} deferred (time limit)"
[ "${#UNCHECKED[@]}"   -gt 0 ] && SUMMARY="${SUMMARY}, ${#UNCHECKED[@]} unreadable"
[ "$EXCLUDED"          -gt 0 ] && SUMMARY="${SUMMARY}, ${EXCLUDED} excluded"
[ "${#SKIPPED[@]}"     -gt 0 ] && SUMMARY="${SUMMARY}, ${#SKIPPED[@]} not from a registry"
SUMMARY="${SUMMARY} [${CACHED} cached, ${QUERIED} queried"
[ "$STALE" -gt 0 ] && SUMMARY="${SUMMARY}, ${STALE} from stale cache"
[ -e "$BREAKER" ] && SUMMARY="${SUMMARY}, rate limited"
[ "$TIMED_OUT_RUN" -eq 1 ] && SUMMARY="${SUMMARY}, time limit reached"
SUMMARY="${SUMMARY}]${STATE_NOTE}"

ALERT=""
if [ "${#STALE_REFS[@]}" -gt 0 ]; then
    ALERT="No registry answer for ${STALE_DAYS}+ days: $(join '; ' "${STALE_REFS[@]}")"
fi
if [ "${#BEHIND[@]}" -gt 0 ]; then
    [ "${#PINNED[@]}"      -gt 0 ] && diag "Pinned, no update path: $(join ', ' "${PINNED[@]}")"
    [ "${#PENDING[@]}"     -gt 0 ] && diag "Update available but younger than ${MIN_AGE} days: $(join ', ' "${PENDING[@]}")"
    [ "${#RATELIMITED[@]}" -gt 0 ] && diag "Deferred to the next run, registry rate limit: $(join ', ' "${RATELIMITED[@]}")"
    [ "${#SKIPPED[@]}"     -gt 0 ] && diag "Not checked: $(join ', ' "${SKIPPED[@]}")"
    emit 1 "$(printf '%s. Behind: %s' "$SUMMARY" "$(join ', ' "${BEHIND[@]}")")${ALERT:+. $ALERT}"
fi
[ -n "$ALERT" ] && emit 1 "${SUMMARY}. ${ALERT}"

# Only a genuine total failure to read anything counts as the check not running.
if [ "${#UNCHECKED[@]}" -gt 0 ] && [ "${#UNCHECKED[@]}" -eq "${#NAMES[@]}" ]; then
    emit 1 "Check could not run: no image could be read from any registry (${#NAMES[@]} attempted)"
fi

emit 0 "$SUMMARY"
