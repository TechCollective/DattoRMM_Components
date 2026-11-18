#!/bin/bash
# Docker - Container Health and Resource Usage [Lin]
# TechCollective custom monitor for Datto RMM.
#
# Read-only. Runs docker info / version / ps / stats / inspect, and docker logs
# only when usrIncludeLogs is yes. Makes no change to any container, image or
# daemon. No network access. No code is downloaded at run time. Writes one state
# file so restart counts and resource breaches can be compared against the
# previous run (see the shared state block below).
#
# Before any docker command, and in this order:
#   - no docker command (PATH plus the usual system directories)
#       but /var/run/docker.sock is a socket or docker.service is loaded -> alert
#       otherwise: Docker is not installed                              -> healthy
#   - systemd says docker.service is not active: no docker command is run (any
#     would start Docker again through docker.socket)                    -> healthy
#   - docker info fails with no docker.service and no socket (a client only) -> healthy
#   - docker info fails otherwise                                        -> alert
# Every docker command is stopped if Docker has not answered DOCKER_TIMEOUT
# seconds after the monitor started, and the check says Docker did not answer.
#
# Input variables (Datto String/Selection types; all arrive as strings):
#   usrCpuThreshold     90      percent of the container's OWN available CPU
#   usrMemThreshold     90      percent of the container's memory limit
#   usrConsecutive      2       runs a container must breach before alerting
#   usrCheckHealth      alert   alert | warn | ignore
#   usrRestartThreshold 3       restarts since the previous run
#   usrExitedWindowMin  60      minutes; 0 disables the exited-container check
#   usrExclude          (empty) ERE matched against container names
#   usrIncludeLogs      no      yes | no - tail container logs into diagnostic
#   usrStoppedExitAction warn   warn | alert - a container that exited 143 or 137
#                               without being OOM-killed (usually docker stop)

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
# first still wins).
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

DOCKER_SOCK="/var/run/docker.sock"
# Every docker command of one run must have finished this many seconds after the
# monitor started; whatever is still running then is stopped. With the 5 seconds
# timeout(1) allows after TERM before KILL, the result is out inside 70 seconds.
DOCKER_TIMEOUT=60
# Saved restart counts and breach streaks older than this are not compared
# against: the run takes a new baseline instead.
BASELINE_MAX_AGE=21600
STATE_NAME="monitor-state.tsv"

die_cannot_run() { emit 1 "Check could not run: $1"; }

# --------------------------------------------------------------------------
# Dependencies - checked FIRST, so a missing tool is never misreported as a
# bad input variable, and nothing above this point depends on an external tool
# --------------------------------------------------------------------------

for tool in awk grep sed date timeout stat mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die_cannot_run "required tool '$tool' is not present on this host"
done
timeout -k 1 10 true >/dev/null 2>&1 \
    || die_cannot_run "this host's timeout command does not take -k (GNU coreutils timeout is needed)"

# --------------------------------------------------------------------------
# Input variables
# --------------------------------------------------------------------------

CPU_THRESHOLD="${usrCpuThreshold:-90}"
MEM_THRESHOLD="${usrMemThreshold:-90}"
CONSECUTIVE="${usrConsecutive:-2}"
HEALTH_MODE="${usrCheckHealth:-alert}"
RESTART_THRESHOLD="${usrRestartThreshold:-3}"
EXITED_WINDOW_MIN="${usrExitedWindowMin:-60}"
EXCLUDE_PATTERN="${usrExclude:-}"
INCLUDE_LOGS="${usrIncludeLogs:-no}"
STOPPED_ACTION="${usrStoppedExitAction:-warn}"

# tolerate a typed % and surrounding whitespace, refuse anything else loudly
clean_num() {
    local v="$1"
    v="${v//[[:space:]]/}"
    v="${v%\%}"
    printf '%s' "$v"
}

CPU_THRESHOLD="$(clean_num "$CPU_THRESHOLD")"
MEM_THRESHOLD="$(clean_num "$MEM_THRESHOLD")"
CONSECUTIVE="$(clean_num "$CONSECUTIVE")"
RESTART_THRESHOLD="$(clean_num "$RESTART_THRESHOLD")"
EXITED_WINDOW_MIN="$(clean_num "$EXITED_WINDOW_MIN")"

# pure parameter expansion - no external tool, so this cannot fail silently
HEALTH_MODE="${HEALTH_MODE//[[:space:]]/}"; HEALTH_MODE="${HEALTH_MODE,,}"
INCLUDE_LOGS="${INCLUDE_LOGS//[[:space:]]/}"; INCLUDE_LOGS="${INCLUDE_LOGS,,}"
STOPPED_ACTION="${STOPPED_ACTION//[[:space:]]/}"; STOPPED_ACTION="${STOPPED_ACTION,,}"

case "$CPU_THRESHOLD" in ''|*[!0-9]*) die_cannot_run "usrCpuThreshold must be a whole number of percent, got '${usrCpuThreshold:-}'";; esac
case "$MEM_THRESHOLD" in ''|*[!0-9]*) die_cannot_run "usrMemThreshold must be a whole number of percent, got '${usrMemThreshold:-}'";; esac
case "$CONSECUTIVE" in ''|*[!0-9]*) die_cannot_run "usrConsecutive must be a whole number, got '${usrConsecutive:-}'";; esac
case "$RESTART_THRESHOLD" in ''|*[!0-9]*) die_cannot_run "usrRestartThreshold must be a whole number, got '${usrRestartThreshold:-}'";; esac
case "$EXITED_WINDOW_MIN" in ''|*[!0-9]*) die_cannot_run "usrExitedWindowMin must be a whole number of minutes, got '${usrExitedWindowMin:-}'";; esac

[ "$CPU_THRESHOLD" -ge 1 ] && [ "$CPU_THRESHOLD" -le 100 ] || die_cannot_run "usrCpuThreshold must be between 1 and 100, got '$CPU_THRESHOLD'"
[ "$MEM_THRESHOLD" -ge 1 ] && [ "$MEM_THRESHOLD" -le 100 ] || die_cannot_run "usrMemThreshold must be between 1 and 100, got '$MEM_THRESHOLD'"
[ "$CONSECUTIVE" -ge 1 ] && [ "$CONSECUTIVE" -le 10 ] || die_cannot_run "usrConsecutive must be between 1 and 10, got '$CONSECUTIVE'"
[ "$RESTART_THRESHOLD" -ge 1 ] || die_cannot_run "usrRestartThreshold must be 1 or more, got '$RESTART_THRESHOLD'"

case "$HEALTH_MODE" in
    alert|warn|ignore) ;;
    *) die_cannot_run "usrCheckHealth must be alert, warn or ignore, got '${usrCheckHealth:-}'" ;;
esac
case "$INCLUDE_LOGS" in
    yes|no) ;;
    *) die_cannot_run "usrIncludeLogs must be yes or no, got '${usrIncludeLogs:-}'" ;;
esac
case "$STOPPED_ACTION" in
    warn|alert) ;;
    *) die_cannot_run "usrStoppedExitAction must be warn or alert, got '${usrStoppedExitAction:-}'" ;;
esac

if [ -n "$EXCLUDE_PATTERN" ]; then
    printf 'x' | grep -Eq -- "$EXCLUDE_PATTERN" 2>/dev/null
    grep_rc=$?
    # 0 = matched, 1 = no match, 2+ = the pattern itself is invalid
    if [ "$grep_rc" -gt 1 ]; then
        die_cannot_run "usrExclude is not a valid extended regular expression: '$EXCLUDE_PATTERN'"
    fi
fi

# --------------------------------------------------------------------------
# Docker - found, asked whether it is running without starting it, and every
# docker command bounded by one deadline
# --------------------------------------------------------------------------

START_EPOCH="$(date +%s)"
case "$START_EPOCH" in ''|*[!0-9]*) die_cannot_run "date +%s does not give the time in seconds" ;; esac
DOCKER_DEADLINE=$(( START_EPOCH + DOCKER_TIMEOUT ))

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
# A docker command with the run's deadline: dk SUBCOMMAND ARGS...
dk() { bounded '"$@"' "$DOCKER" "$@"; }

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

DOCKER="$(command -v docker 2>/dev/null || true)"
if [ -z "$DOCKER" ]; then
    seen=""
    [ -S "$DOCKER_SOCK" ] && seen="$DOCKER_SOCK is a socket"
    docker_unit_loaded && seen="${seen:+$seen and }docker.service is loaded"
    if [ -n "$seen" ]; then
        diag "No docker command was found in $PATH, but $seen, so Docker looks installed here. Find where its client went (a package removed only the CLI, a snap or a custom path) and put docker on one of those directories."
        emit 1 "Docker appears to be installed but no docker command was found"
    fi
    # Docker absent is a normal state on a broadly-assigned monitor, not a fault.
    emit 0 "Docker is not installed on this host; nothing to check"
fi

DSTATE="$(bounded "$(declare -f tc_docker_running)"$'\n''DOCKER=$1; tc_docker_running; rc=$?; printf "%s" "$DOCKER_STATE"; exit "$rc"' "$DOCKER")"
case $? in
    0) ;;
    1)  emit 0 "Docker is stopped (${DSTATE:-docker.service is not active}); nothing to check" ;;
    2)  if [ ! -S "$DOCKER_SOCK" ] && ! docker_unit_loaded; then
            emit 0 "Docker client installed ($DOCKER) but no Docker daemon on this host (no docker.service, no $DOCKER_SOCK); nothing to check"
        fi
        DOCKER_INFO_OUT="$(dk info 2>&1)"
        case $? in 124|137) docker_hung "docker info" ;; esac
        DOCKER_ERR="$(printf '%s' "$DOCKER_INFO_OUT" | grep -iE 'cannot connect|permission denied|daemon running|dial unix|timed out|failed to connect' | head -1 | tr -cd '[:print:]' | cut -c1-300)"
        [ -n "$DOCKER_ERR" ] || DOCKER_ERR="docker info failed with no recognisable error line"
        emit 1 "Docker is installed but the daemon is not reachable: ${DOCKER_ERR}" ;;
    124|137) docker_hung "docker info" ;;
    *) die_cannot_run "asking whether Docker is running failed unexpectedly" ;;
esac

# --------------------------------------------------------------------------
# State file - previous restart counts and breach streaks
# --------------------------------------------------------------------------

# >>> tc-docker monitor state: identical in the Health and Images monitors; change them together.
# The state directory these monitors share. There is no other directory: no
# fallback to /var/tmp, where another local user could have made the path first.
# tc_state_dir uses it only if it is a real directory (not a symlink) owned by
# root, creating it 0700 when it is missing and making it 0700 when it is not.
# It sets STATE_DIR, or leaves STATE_DIR empty and sets STATE_WHY. Never fatal:
# a monitor without its state directory runs without saved state and says so.
# tc_state_read NAME prints the file only when it is a regular file (not a
# symlink) owned by root; the caller keeps only the lines it can check.
# tc_state_write NAME replaces the file with its stdin by renaming a new
# root-only file into place, so a symlink there is replaced, never followed.
# Needs GNU stat (-c) and mv (-T).
TC_STATE_DIR=/var/lib/tc-docker-monitor
STATE_DIR=""
STATE_WHY=""
tc_state_dir() {
    local d="$TC_STATE_DIR"
    STATE_DIR=""; STATE_WHY=""
    if [ -L "$d" ]; then STATE_WHY="$d is a symlink"; return 1; fi
    if [ ! -e "$d" ]; then
        ( umask 077 && mkdir -m 700 -- "$d" ) 2>/dev/null
    fi
    if [ -L "$d" ] || [ ! -d "$d" ]; then STATE_WHY="$d is not a directory"; return 1; fi
    if [ "$(stat -c %u -- "$d" 2>/dev/null)" != "0" ]; then STATE_WHY="$d is not owned by root"; return 1; fi
    if [ "$(stat -c %a -- "$d" 2>/dev/null)" != "700" ] && ! chmod 700 -- "$d" 2>/dev/null; then
        STATE_WHY="$d cannot be made 0700"; return 1
    fi
    STATE_DIR="$d"
    return 0
}
tc_state_read() {
    local f="$STATE_DIR/$1"
    [ -n "$STATE_DIR" ] && [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %u -- "$f" 2>/dev/null)" = "0" ] || return 0
    cat -- "$f" 2>/dev/null
    return 0
}
tc_state_write() {
    local f="$STATE_DIR/$1" tmp
    [ -n "$STATE_DIR" ] || return 1
    tmp="$(mktemp -- "$STATE_DIR/.$1.XXXXXX" 2>/dev/null)" || return 1
    if ! cat > "$tmp" 2>/dev/null || ! chmod 600 -- "$tmp" 2>/dev/null || ! mv -fT -- "$tmp" "$f" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}
# <<< tc-docker monitor state

tc_state_dir
NOW_EPOCH="$(date +%s)"

declare -A PREV_RESTARTS=()
declare -A PREV_STREAK=()
STATE_AGE_MIN="no previous run recorded"
STATE_NOTE=""
[ -n "$STATE_DIR" ] || STATE_NOTE="; no saved state ($STATE_WHY), so restart and breach counts start again every run"

# Only well-formed lines are trusted: name, restarts, streak, epoch.
prev_epoch=0
while IFS=$'\t' read -r s_name s_restarts s_streak s_epoch s_extra; do
    [ -z "${s_extra:-}" ] || continue
    [[ "${s_name:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || continue
    [[ "${s_restarts:-}" =~ ^[0-9]{1,9}$ ]] && [[ "${s_streak:-}" =~ ^[0-9]{1,4}$ ]] && [[ "${s_epoch:-}" =~ ^[0-9]{1,12}$ ]] || continue
    [ -z "${PREV_RESTARTS[$s_name]+x}" ] || continue
    PREV_RESTARTS["$s_name"]="$s_restarts"
    PREV_STREAK["$s_name"]="$s_streak"
    [ "$s_epoch" -gt "$prev_epoch" ] && prev_epoch="$s_epoch"
done < <(tc_state_read "$STATE_NAME")

# A previous run long ago (or a clock that went backwards) is not a baseline:
# a restart count that grew over weeks is not a loop, and a breach streak with
# hours between its runs is not consecutive. Start again from this run.
if [ "${#PREV_RESTARTS[@]}" -gt 0 ]; then
    prev_age=$(( NOW_EPOCH - prev_epoch ))
    if [ "$prev_age" -gt "$BASELINE_MAX_AGE" ] || [ "$prev_age" -lt -3600 ]; then
        if [ "$prev_age" -lt 0 ]; then
            STATE_NOTE="${STATE_NOTE}; new baseline taken (the saved state is dated in the future)"
        else
            STATE_NOTE="${STATE_NOTE}; new baseline taken (previous run $(( prev_age / 3600 )) h ago, more than $(( BASELINE_MAX_AGE / 3600 )) h), so no restart alert and no breach streak this run"
        fi
        STATE_AGE_MIN="$(( prev_age / 60 )) min (too old; new baseline)"
        PREV_RESTARTS=()
        PREV_STREAK=()
    else
        STATE_AGE_MIN="$(( prev_age / 60 )) min"
    fi
fi

# --------------------------------------------------------------------------
# Gather
# --------------------------------------------------------------------------

HOST_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
case "$HOST_CPUS" in ''|*[!0-9]*) HOST_CPUS=1 ;; esac
[ "$HOST_CPUS" -ge 1 ] || HOST_CPUS=1

DOCKER_VERSION="$(dk version --format '{{.Server.Version}}' 2>/dev/null)"
case $? in 124|137) docker_hung "docker version" ;; esac
[ -n "$DOCKER_VERSION" ] || DOCKER_VERSION="unknown"

RUNNING_RAW="$(dk ps --format '{{.Names}}' 2>/dev/null)"
case $? in
    0) ;;
    124|137) docker_hung "docker ps" ;;
    *) die_cannot_run "Docker did not return its container list (docker ps failed)" ;;
esac

excluded_count=0
RUNNING=()
while IFS= read -r cname; do
    [ -n "$cname" ] || continue
    if [ -n "$EXCLUDE_PATTERN" ] && printf '%s' "$cname" | grep -Eq -- "$EXCLUDE_PATTERN" 2>/dev/null; then
        excluded_count=$((excluded_count + 1))
        continue
    fi
    RUNNING+=("$cname")
done <<< "$RUNNING_RAW"

RUNNING_COUNT="${#RUNNING[@]}"

declare -A IS_TARGET=()
for cname in ${RUNNING[@]+"${RUNNING[@]}"}; do
    IS_TARGET["$cname"]=1
done

# --- inspect: health, restart count, cpu and memory limits -----------------
declare -A C_HEALTH=()
declare -A C_RESTARTS=()
declare -A C_CPUS=()
declare -A C_MEMLIMIT=()

count_cpuset() {
    printf '%s' "$1" | awk -F, '{n=0; for(i=1;i<=NF;i++){ if($i ~ /-/){ split($i,r,"-"); n += (r[2]-r[1]+1) } else if(length($i)>0){ n++ } } print n}'
}

if [ "$RUNNING_COUNT" -gt 0 ]; then
    # Newer docker clients format inspect output as a map, where a missing
    # .State.Health is an error ("map has no entry for key"); older ones format
    # a struct, where index is an error. The map form is tried first.
    INSPECT_TAIL='|{{.RestartCount}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpusetCpus}}|{{.HostConfig.Memory}}'
    INSPECT_OUT="$(dk inspect \
        --format '{{.Name}}|{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}'"$INSPECT_TAIL" \
        "${RUNNING[@]}" 2>/dev/null)"
    case $? in
        0) ;;
        124|137) docker_hung "docker inspect" ;;
        *)  INSPECT_OUT="$(dk inspect \
                --format '{{.Name}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'"$INSPECT_TAIL" \
                "${RUNNING[@]}" 2>/dev/null)"
            case $? in 124|137) docker_hung "docker inspect" ;; esac ;;
    esac
    while IFS='|' read -r i_name i_health i_restarts i_nanocpus i_cpuset i_mem; do
        [ -n "${i_name:-}" ] || continue
        i_name="${i_name#/}"
        [ -n "${IS_TARGET[$i_name]:-}" ] || continue
        C_HEALTH["$i_name"]="${i_health:-none}"
        case "${i_restarts:-0}" in ''|*[!0-9]*) i_restarts=0 ;; esac
        C_RESTARTS["$i_name"]="$i_restarts"
        C_MEMLIMIT["$i_name"]="${i_mem:-0}"

        allowed="$HOST_CPUS"
        if [ -n "${i_nanocpus:-}" ] && [ "${i_nanocpus}" != "0" ]; then
            allowed="$(awk -v n="$i_nanocpus" 'BEGIN{c=n/1000000000; if(c<0.01)c=0.01; printf "%.4f", c}')"
        elif [ -n "${i_cpuset:-}" ]; then
            cs="$(count_cpuset "$i_cpuset")"
            case "$cs" in ''|*[!0-9]*) cs=0 ;; esac
            [ "$cs" -gt 0 ] && allowed="$cs"
        fi
        C_CPUS["$i_name"]="$allowed"
    done <<< "$INSPECT_OUT"
fi

# --- stats: one sample across all running containers -----------------------
declare -A C_CPUPCT=()
declare -A C_MEMPCT=()
declare -A C_MEMUSE=()
STATS_OK=0

if [ "$RUNNING_COUNT" -gt 0 ]; then
    STATS_OUT="$(dk stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}' 2>/dev/null)"
    case $? in 124|137) docker_hung "docker stats" ;; esac
    if [ -n "$STATS_OUT" ]; then
        STATS_OK=1
        while IFS='|' read -r s_name s_cpu s_mem s_use; do
            [ -n "${s_name:-}" ] || continue
            [ -n "${IS_TARGET[$s_name]:-}" ] || continue
            C_CPUPCT["$s_name"]="${s_cpu%\%}"
            C_MEMPCT["$s_name"]="${s_mem%\%}"
            C_MEMUSE["$s_name"]="${s_use:-unknown}"
        done <<< "$STATS_OUT"
    fi
fi

# --------------------------------------------------------------------------
# Evaluate
# --------------------------------------------------------------------------

ALERTS=()
NOTES=()
AFFECTED=()   # names with an alert, in order, for the logs
DIAG_ROWS=()
NEW_STATE=""
worst_cpu="0"; worst_cpu_name=""
worst_mem="0"; worst_mem_name=""
unmeasured=0

gte() { awk -v v="${1:-0}" -v t="${2:-0}" 'BEGIN{ exit !( (v+0) >= (t+0) ) }'; }

for cname in ${RUNNING[@]+"${RUNNING[@]}"}; do
    health="${C_HEALTH[$cname]:-unknown}"
    restarts="${C_RESTARTS[$cname]:-0}"
    allowed="${C_CPUS[$cname]:-$HOST_CPUS}"
    raw_cpu="${C_CPUPCT[$cname]:-}"
    mem_pct="${C_MEMPCT[$cname]:-}"
    mem_use="${C_MEMUSE[$cname]:-unknown}"

    # CPU normalised to the container's own allowance, so 100% means saturated
    if [ -n "$raw_cpu" ]; then
        cpu_norm="$(awk -v v="$raw_cpu" -v c="$allowed" 'BEGIN{ if(c+0<=0) c=1; printf "%.1f", (v+0)/(c+0) }')"
    else
        cpu_norm=""
        unmeasured=$((unmeasured + 1))
    fi

    # tidy "2.0000" down to "2" for anything a human reads
    allowed_txt="$allowed"
    if [ "${allowed_txt#*.}" != "$allowed_txt" ]; then
        while [ "${allowed_txt%0}" != "$allowed_txt" ]; do allowed_txt="${allowed_txt%0}"; done
        allowed_txt="${allowed_txt%.}"
    fi

    breached=0
    if [ -n "$cpu_norm" ] && gte "$cpu_norm" "$CPU_THRESHOLD"; then breached=1; fi
    if [ -n "$mem_pct" ] && gte "$mem_pct" "$MEM_THRESHOLD"; then breached=1; fi

    prev_streak="${PREV_STREAK[$cname]:-0}"
    case "$prev_streak" in ''|*[!0-9]*) prev_streak=0 ;; esac
    if [ "$breached" -eq 1 ]; then
        streak=$((prev_streak + 1))
    else
        streak=0
    fi

    if [ "$streak" -ge "$CONSECUTIVE" ]; then
        detail=""
        if [ -n "$cpu_norm" ] && gte "$cpu_norm" "$CPU_THRESHOLD"; then
            detail="CPU ${cpu_norm}% of its ${allowed_txt}-CPU allowance"
        fi
        if [ -n "$mem_pct" ] && gte "$mem_pct" "$MEM_THRESHOLD"; then
            [ -n "$detail" ] && detail="${detail}, "
            detail="${detail}memory ${mem_pct}% (${mem_use})"
        fi
        ALERTS+=("${cname}: ${detail}, for ${streak} consecutive runs")
        AFFECTED+=("$cname")
    fi

    if [ -n "$cpu_norm" ] && gte "$cpu_norm" "$worst_cpu"; then worst_cpu="$cpu_norm"; worst_cpu_name="$cname"; fi
    if [ -n "$mem_pct" ] && gte "$mem_pct" "$worst_mem"; then worst_mem="$mem_pct"; worst_mem_name="$cname"; fi

    # health
    case "$health" in
        unhealthy)
            case "$HEALTH_MODE" in
                alert) ALERTS+=("${cname}: healthcheck reporting unhealthy"); AFFECTED+=("$cname") ;;
                warn)  NOTES+=("${cname} unhealthy") ;;
            esac
            ;;
        starting) NOTES+=("${cname} healthcheck still starting") ;;
    esac

    # restart loop, measured as a delta against the previous run
    prev_r="${PREV_RESTARTS[$cname]:-}"
    if [ -n "$prev_r" ]; then
        case "$prev_r" in ''|*[!0-9]*) prev_r=0 ;; esac
        delta=$((restarts - prev_r))
        [ "$delta" -lt 0 ] && delta=0
        if [ "$delta" -ge "$RESTART_THRESHOLD" ]; then
            ALERTS+=("${cname}: restarted ${delta} times since the previous check (${restarts} total)")
            AFFECTED+=("$cname")
        fi
    fi

    # a container with no memory limit is measured against total host RAM,
    # which is worth seeing next to the percentage
    memlimit="${C_MEMLIMIT[$cname]:-0}"
    if [ "$memlimit" = "0" ] || [ -z "$memlimit" ]; then
        memlimit_txt="none (measured against host RAM)"
    else
        memlimit_txt="$(awk -v b="$memlimit" 'BEGIN{printf "%.2f GiB", b/1073741824}')"
    fi

    NEW_STATE="${NEW_STATE}$(printf '%s\t%s\t%s\t%s' "$cname" "$restarts" "$streak" "$NOW_EPOCH")"$'\n'
    DIAG_ROWS+=("$(printf '%-28s health=%-9s restarts=%-5s cpu=%s%% of %s allowed  mem=%s%% (%s, limit %s)  breach streak=%s' \
        "$cname" "$health" "$restarts" "${cpu_norm:-n/a}" "$allowed_txt" "${mem_pct:-n/a}" "$mem_use" "$memlimit_txt" "$streak")")
done

# --- containers that exited non-zero inside the window ---------------------
EXITED_LINES=()
if [ "$EXITED_WINDOW_MIN" -gt 0 ]; then
    EXITED_RAW="$(dk ps -a --filter 'status=exited' --format '{{.Names}}' 2>/dev/null)"
    case $? in 124|137) docker_hung "docker ps -a" ;; esac
    EXITED_NAMES=()
    while IFS= read -r xname; do
        [ -n "$xname" ] || continue
        if [ -n "$EXCLUDE_PATTERN" ] && printf '%s' "$xname" | grep -Eq -- "$EXCLUDE_PATTERN" 2>/dev/null; then continue; fi
        EXITED_NAMES+=("$xname")
    done <<< "$EXITED_RAW"

    if [ "${#EXITED_NAMES[@]}" -gt 0 ]; then
        X_OUT="$(dk inspect --format '{{.Name}}|{{.State.ExitCode}}|{{.State.FinishedAt}}|{{.State.OOMKilled}}' "${EXITED_NAMES[@]}" 2>/dev/null)"
        case $? in 124|137) docker_hung "docker inspect" ;; esac
        while IFS='|' read -r x_name x_code x_fin x_oom; do
            [ -n "${x_name:-}" ] || continue
            x_name="${x_name#/}"
            case "${x_code:-0}" in ''|*[!0-9-]*) continue ;; esac
            [ "$x_code" -ne 0 ] || continue
            x_epoch="$(date -u -d "${x_fin:-}" +%s 2>/dev/null || echo '')"
            [ -n "$x_epoch" ] || continue
            age_min=$(( (NOW_EPOCH - x_epoch) / 60 ))
            [ "$age_min" -ge 0 ] && [ "$age_min" -le "$EXITED_WINDOW_MIN" ] || continue
            if [ "${x_oom:-false}" = "true" ]; then
                # The kernel killed it for running out of memory: always an alert.
                ALERTS+=("${x_name}: killed for running out of memory (OOM) ${age_min} minutes ago, exit code ${x_code}")
                AFFECTED+=("$x_name")
                EXITED_LINES+=("${x_name} exit=${x_code} OOM-killed ${age_min}m ago")
            elif [ "$x_code" -eq 143 ] || [ "$x_code" -eq 137 ]; then
                # 143 is SIGTERM, 137 SIGKILL: what docker stop gives (KILL when
                # the container ignores TERM), and also what a kill from outside gives.
                if [ "$STOPPED_ACTION" = "alert" ]; then
                    ALERTS+=("${x_name}: stopped by a signal (exit code ${x_code}, as docker stop gives) ${age_min} minutes ago")
                    AFFECTED+=("$x_name")
                else
                    NOTES+=("${x_name} stopped (exit ${x_code}) ${age_min}m ago")
                fi
                EXITED_LINES+=("${x_name} exit=${x_code} stopped by a signal ${age_min}m ago")
            else
                ALERTS+=("${x_name}: exited with code ${x_code} ${age_min} minutes ago")
                AFFECTED+=("$x_name")
                EXITED_LINES+=("${x_name} exit=${x_code} ${age_min}m ago")
            fi
        done <<< "$X_OUT"
    fi
fi

# --------------------------------------------------------------------------
# Persist state
# --------------------------------------------------------------------------

if [ -n "$STATE_DIR" ]; then
    printf '%s' "$NEW_STATE" | tc_state_write "$STATE_NAME" \
        || STATE_NOTE="${STATE_NOTE}; saved state could not be written to $STATE_DIR"
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

suffix=""
[ "$excluded_count" -gt 0 ] && suffix="${suffix}; ${excluded_count} excluded by usrExclude"
[ "$unmeasured" -gt 0 ] && suffix="${suffix}; ${unmeasured} container(s) had no resource sample"
[ "$STATS_OK" -eq 0 ] && [ "$RUNNING_COUNT" -gt 0 ] && suffix="${suffix}; docker stats returned nothing, so CPU and memory were not measured this run"
if [ "${#NOTES[@]}" -gt 0 ]; then
    notes_txt="$(printf '%s, ' "${NOTES[@]}")"
    suffix="${suffix}; note: ${notes_txt%, }"
fi
suffix="${suffix}${STATE_NOTE}"

if [ "$RUNNING_COUNT" -eq 0 ] && [ "${#ALERTS[@]}" -eq 0 ]; then
    emit 0 "Docker is running but no containers are running on this host${suffix}"
fi

if [ "${#ALERTS[@]}" -gt 0 ]; then
    # Logs are read before the status is written, so the status can say they
    # are in the diagnostic: visible on the alert, not only in the assignment.
    LOGS_TEXT=""
    if [ "$INCLUDE_LOGS" = "yes" ]; then
        shown=0; log_late=0
        declare -A logged=()
        for cname in ${AFFECTED[@]+"${AFFECTED[@]}"}; do
            [ "$shown" -ge 3 ] && break
            [ -z "${logged[$cname]+x}" ] || continue
            logged[$cname]=1
            out="$(dk logs --tail 20 "$cname" 2>&1)"
            case $? in 124|137) log_late=1; break ;; esac
            LOGS_TEXT="${LOGS_TEXT}  --- ${cname} ---"$'\n'"$(printf '%s\n' "$out" | sed 's/^/  /')"$'\n'
            shown=$((shown + 1))
        done
        if [ "$shown" -gt 0 ]; then
            suffix="${suffix}; last 20 log lines of ${shown} container(s) included in the diagnostic"
        else
            suffix="${suffix}; container logs were requested but none could be read"
        fi
        [ "$log_late" -eq 1 ] && suffix="${suffix} (Docker did not return the logs in time)"
    fi

    diag "Docker server $DOCKER_VERSION | host CPUs $HOST_CPUS | $RUNNING_COUNT running container(s) checked | previous run: $STATE_AGE_MIN"
    diag "Thresholds: cpu>=${CPU_THRESHOLD}% of container allowance, mem>=${MEM_THRESHOLD}% of limit, $CONSECUTIVE consecutive run(s); restarts>=$RESTART_THRESHOLD since last run; exited window $EXITED_WINDOW_MIN min; health mode $HEALTH_MODE"
    diag ""
    diag "Conditions met:"
    for a in "${ALERTS[@]}"; do diag "  - $a"; done
    diag ""
    diag "All running containers:"
    for r in ${DIAG_ROWS[@]+"${DIAG_ROWS[@]}"}; do diag "  $r"; done
    if [ "${#EXITED_LINES[@]}" -gt 0 ]; then
        diag ""
        diag "Recently exited (non-zero):"
        for e in "${EXITED_LINES[@]}"; do diag "  $e"; done
    fi
    if [ -n "$LOGS_TEXT" ]; then
        diag ""
        diag "Last 20 log lines from up to 3 affected containers:"
        diag "${LOGS_TEXT%$'\n'}"
    fi

    first="${ALERTS[0]}"
    if [ "${#ALERTS[@]}" -eq 1 ]; then
        emit 1 "Docker: ${first}${suffix}"
    fi
    emit 1 "Docker: ${#ALERTS[@]} container problems - ${first} (and $(( ${#ALERTS[@]} - 1 )) more; see diagnostic)${suffix}"
fi

healthy_msg="All ${RUNNING_COUNT} running container(s) within thresholds"
if [ -n "$worst_cpu_name" ]; then
    healthy_msg="${healthy_msg}; highest CPU ${worst_cpu}% (${worst_cpu_name})"
fi
if [ -n "$worst_mem_name" ]; then
    healthy_msg="${healthy_msg}, highest memory ${worst_mem}% (${worst_mem_name})"
fi
emit 0 "${healthy_msg}${suffix}"
