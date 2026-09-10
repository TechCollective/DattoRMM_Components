#!/bin/bash
# Docker - Container Health and Resource Usage [Lin]
# TechCollective custom monitor for Datto RMM.
#
# Read-only. Runs docker ps / stats / inspect only. Makes no change to any
# container, image or daemon. No network access. No code is downloaded at run
# time. Writes one state file so restart counts and resource breaches can be
# compared against the previous run.
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

set -u

RESULT_EMITTED=0
STATE_DIR=""
STATE_FILE=""

# --------------------------------------------------------------------------
# Result contract
# --------------------------------------------------------------------------

emit_result() {
    local msg="$1"
    msg="${msg//$'\r'/ }"
    msg="${msg//$'\n'/ }"
    msg="${msg//$'\t'/ }"
    if [ "${#msg}" -gt 900 ]; then
        msg="${msg:0:897}..."
    fi
    while [ "${msg}" != "${msg//  / }" ]; do msg="${msg//  / }"; done
    msg="${msg# }"
    msg="${msg% }"
    [ -n "$msg" ] || msg="Check produced no status text"
    printf '<-Start Result->\n'
    printf 'STATUS=%s\n' "$msg"
    printf '<-End Result->\n'
    RESULT_EMITTED=1
}

on_exit() {
    local rc=$?
    if [ "$RESULT_EMITTED" -eq 0 ]; then
        printf '<-Start Result->\n'
        printf 'STATUS=Check failed before it could measure anything (exit %s)\n' "$rc"
        printf '<-End Result->\n'
        [ "$rc" -eq 0 ] && rc=1
    fi
    exit "$rc"
}
trap on_exit EXIT

die_cannot_run() {
    emit_result "Check could not run: $1"
    exit 1
}

# timeout(1) when present, plain execution when not
run_t() {
    local secs="$1"; shift
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" "$secs" "$@"
    else
        "$@"
    fi
}

# --------------------------------------------------------------------------
# Dependencies - checked FIRST, so a missing tool is never misreported as a
# bad input variable, and nothing above this point depends on an external tool
# --------------------------------------------------------------------------

TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="$(command -v timeout)"

for tool in awk grep date; do
    command -v "$tool" >/dev/null 2>&1 || die_cannot_run "required tool '$tool' is not present on this host"
done

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

if [ -n "$EXCLUDE_PATTERN" ]; then
    printf 'x' | grep -Eq "$EXCLUDE_PATTERN" 2>/dev/null
    grep_rc=$?
    # 0 = matched, 1 = no match, 2+ = the pattern itself is invalid
    if [ "$grep_rc" -gt 1 ]; then
        die_cannot_run "usrExclude is not a valid extended regular expression: '$EXCLUDE_PATTERN'"
    fi
fi

# --------------------------------------------------------------------------
# Docker
# --------------------------------------------------------------------------

# Docker absent is a normal state on a broadly-assigned monitor, not a fault.
if ! command -v docker >/dev/null 2>&1; then
    emit_result "Docker is not installed on this host; nothing to check"
    exit 0
fi

DOCKER_INFO_OUT="$(run_t 20 docker info 2>&1)"
DOCKER_INFO_RC=$?
if [ "$DOCKER_INFO_RC" -ne 0 ]; then
    DOCKER_ERR="$(printf '%s' "$DOCKER_INFO_OUT" | grep -iE 'cannot connect|permission denied|daemon running|dial unix|timed out' | head -1)"
    [ -n "$DOCKER_ERR" ] || DOCKER_ERR="docker info exited ${DOCKER_INFO_RC} with no recognisable error line"
    emit_result "Docker is installed but the daemon is not reachable: ${DOCKER_ERR}"
    exit 1
fi

# --------------------------------------------------------------------------
# State file - previous restart counts and breach streaks
# --------------------------------------------------------------------------

if mkdir -p /var/lib/tc-docker-monitor 2>/dev/null && [ -w /var/lib/tc-docker-monitor ]; then
    STATE_DIR=/var/lib/tc-docker-monitor
elif mkdir -p /var/tmp/tc-docker-monitor 2>/dev/null && [ -w /var/tmp/tc-docker-monitor ]; then
    STATE_DIR=/var/tmp/tc-docker-monitor
fi
if [ -n "$STATE_DIR" ]; then
    chmod 700 "$STATE_DIR" 2>/dev/null
    STATE_FILE="$STATE_DIR/monitor-state.tsv"
fi

declare -A PREV_RESTARTS=()
declare -A PREV_STREAK=()
STATE_AGE_MIN="never"

if [ -n "$STATE_FILE" ] && [ -r "$STATE_FILE" ]; then
    while IFS=$'\t' read -r s_name s_restarts s_streak _s_epoch; do
        [ -n "${s_name:-}" ] || continue
        PREV_RESTARTS["$s_name"]="${s_restarts:-0}"
        PREV_STREAK["$s_name"]="${s_streak:-0}"
    done < "$STATE_FILE"
    s_mtime="$(date -r "$STATE_FILE" +%s 2>/dev/null || echo '')"
    if [ -n "$s_mtime" ]; then
        STATE_AGE_MIN="$(( ( $(date +%s) - s_mtime ) / 60 )) min"
    fi
fi
[ "$STATE_AGE_MIN" = "never" ] && STATE_AGE_MIN="no previous run recorded"

# --------------------------------------------------------------------------
# Gather
# --------------------------------------------------------------------------

NOW_EPOCH="$(date +%s)"
HOST_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
case "$HOST_CPUS" in ''|*[!0-9]*) HOST_CPUS=1 ;; esac
[ "$HOST_CPUS" -ge 1 ] || HOST_CPUS=1

DOCKER_VERSION="$(run_t 10 docker version --format '{{.Server.Version}}' 2>/dev/null)"
[ -n "$DOCKER_VERSION" ] || DOCKER_VERSION="unknown"

RUNNING_RAW="$(run_t 20 docker ps --format '{{.Names}}' 2>/dev/null)"

excluded_count=0
RUNNING=()
while IFS= read -r cname; do
    [ -n "$cname" ] || continue
    if [ -n "$EXCLUDE_PATTERN" ] && printf '%s' "$cname" | grep -Eq "$EXCLUDE_PATTERN" 2>/dev/null; then
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
    INSPECT_OUT="$(run_t 30 docker inspect \
        --format '{{.Name}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpusetCpus}}|{{.HostConfig.Memory}}' \
        "${RUNNING[@]}" 2>/dev/null)"
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
    STATS_OUT="$(run_t 45 docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}' 2>/dev/null)"
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
    fi

    if [ -n "$cpu_norm" ] && gte "$cpu_norm" "$worst_cpu"; then worst_cpu="$cpu_norm"; worst_cpu_name="$cname"; fi
    if [ -n "$mem_pct" ] && gte "$mem_pct" "$worst_mem"; then worst_mem="$mem_pct"; worst_mem_name="$cname"; fi

    # health
    case "$health" in
        unhealthy)
            case "$HEALTH_MODE" in
                alert) ALERTS+=("${cname}: healthcheck reporting unhealthy") ;;
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
    EXITED_RAW="$(run_t 20 docker ps -a --filter 'status=exited' --format '{{.Names}}' 2>/dev/null)"
    EXITED_NAMES=()
    while IFS= read -r xname; do
        [ -n "$xname" ] || continue
        if [ -n "$EXCLUDE_PATTERN" ] && printf '%s' "$xname" | grep -Eq "$EXCLUDE_PATTERN" 2>/dev/null; then continue; fi
        EXITED_NAMES+=("$xname")
    done <<< "$EXITED_RAW"

    if [ "${#EXITED_NAMES[@]}" -gt 0 ]; then
        X_OUT="$(run_t 30 docker inspect --format '{{.Name}}|{{.State.ExitCode}}|{{.State.FinishedAt}}' "${EXITED_NAMES[@]}" 2>/dev/null)"
        while IFS='|' read -r x_name x_code x_fin; do
            [ -n "${x_name:-}" ] || continue
            x_name="${x_name#/}"
            case "${x_code:-0}" in ''|*[!0-9-]*) continue ;; esac
            [ "$x_code" -ne 0 ] || continue
            x_epoch="$(date -u -d "${x_fin:-}" +%s 2>/dev/null || echo '')"
            [ -n "$x_epoch" ] || continue
            age_min=$(( (NOW_EPOCH - x_epoch) / 60 ))
            [ "$age_min" -ge 0 ] && [ "$age_min" -le "$EXITED_WINDOW_MIN" ] || continue
            ALERTS+=("${x_name}: exited with code ${x_code} ${age_min} minutes ago")
            EXITED_LINES+=("${x_name} exit=${x_code} ${age_min}m ago")
        done <<< "$X_OUT"
    fi
fi

# --------------------------------------------------------------------------
# Persist state
# --------------------------------------------------------------------------

if [ -n "$STATE_FILE" ]; then
    if printf '%s' "$NEW_STATE" > "${STATE_FILE}.tmp" 2>/dev/null; then
        chmod 600 "${STATE_FILE}.tmp" 2>/dev/null
        mv -f "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || rm -f "${STATE_FILE}.tmp" 2>/dev/null
    fi
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

suffix=""
[ "$excluded_count" -gt 0 ] && suffix="${suffix}; ${excluded_count} excluded by usrExclude"
[ "$unmeasured" -gt 0 ] && suffix="${suffix}; ${unmeasured} container(s) had no resource sample"
[ "$STATS_OK" -eq 0 ] && [ "$RUNNING_COUNT" -gt 0 ] && suffix="${suffix}; docker stats returned nothing, so CPU and memory were not measured this run"
if [ "${#NOTES[@]}" -gt 0 ]; then
    suffix="${suffix}; note: $(IFS=', '; printf '%s' "${NOTES[*]}")"
fi

if [ "$RUNNING_COUNT" -eq 0 ] && [ "${#ALERTS[@]}" -eq 0 ]; then
    emit_result "Docker is running but no containers are running on this host${suffix}"
    exit 0
fi

if [ "${#ALERTS[@]}" -gt 0 ]; then
    first="${ALERTS[0]}"
    if [ "${#ALERTS[@]}" -eq 1 ]; then
        emit_result "Docker: ${first}${suffix}"
    else
        emit_result "Docker: ${#ALERTS[@]} container problems - ${first} (and $(( ${#ALERTS[@]} - 1 )) more; see diagnostic)${suffix}"
    fi

    printf '<-Start Diagnostic->\n'
    printf 'Docker server %s | host CPUs %s | %s running container(s) checked | previous run: %s\n' \
        "$DOCKER_VERSION" "$HOST_CPUS" "$RUNNING_COUNT" "$STATE_AGE_MIN"
    printf 'Thresholds: cpu>=%s%% of container allowance, mem>=%s%% of limit, %s consecutive run(s); restarts>=%s since last run; exited window %s min; health mode %s\n' \
        "$CPU_THRESHOLD" "$MEM_THRESHOLD" "$CONSECUTIVE" "$RESTART_THRESHOLD" "$EXITED_WINDOW_MIN" "$HEALTH_MODE"
    printf '\nConditions met:\n'
    for a in "${ALERTS[@]}"; do printf '  - %s\n' "$a"; done
    printf '\nAll running containers:\n'
    for r in ${DIAG_ROWS[@]+"${DIAG_ROWS[@]}"}; do printf '  %s\n' "$r"; done
    if [ "${#EXITED_LINES[@]}" -gt 0 ]; then
        printf '\nRecently exited (non-zero):\n'
        for e in "${EXITED_LINES[@]}"; do printf '  %s\n' "$e"; done
    fi
    if [ "$INCLUDE_LOGS" = "yes" ]; then
        printf '\nLast 20 log lines from up to 3 affected containers:\n'
        shown=0
        for cname in ${RUNNING[@]+"${RUNNING[@]}"}; do
            [ "$shown" -ge 3 ] && break
            affected=0
            for a in "${ALERTS[@]}"; do
                case "$a" in "${cname}: "*) affected=1 ;; esac
            done
            [ "$affected" -eq 1 ] || continue
            printf '  --- %s ---\n' "$cname"
            run_t 5 docker logs --tail 20 "$cname" 2>&1 | sed 's/^/  /'
            shown=$((shown + 1))
        done
    fi
    printf '<-End Diagnostic->\n'
    exit 1
fi

healthy_msg="All ${RUNNING_COUNT} running container(s) within thresholds"
if [ -n "$worst_cpu_name" ]; then
    healthy_msg="${healthy_msg}; highest CPU ${worst_cpu}% (${worst_cpu_name})"
fi
if [ -n "$worst_mem_name" ]; then
    healthy_msg="${healthy_msg}, highest memory ${worst_mem}% (${worst_mem_name})"
fi
emit_result "${healthy_msg}${suffix}"
exit 0
