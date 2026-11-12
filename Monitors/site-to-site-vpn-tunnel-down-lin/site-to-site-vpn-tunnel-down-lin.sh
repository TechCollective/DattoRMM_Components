#!/usr/bin/env bash
# Site-to-Site VPN - Tunnel Down [Lin]
#
# Datto RMM custom monitor. Runs as root. Read-only; changes nothing.
#
# Pings one or more hosts on the far side of a site-to-site tunnel and alerts
# when the tunnel looks down:
#
#   usrRequire=any   alert only when no target replies (default)
#   usrRequire=all   alert when any target does not reply
#
# This version is a generic reachability check and knows nothing about the
# tunnel technology, so it works for WireGuard, IPsec or anything else that
# routes. WireGuard-specific checks (interface up, handshake age per peer) are
# planned for this same component, not a new one.
#
# Not knowing is treated as a fault: bad input, no ping binary, ping failing
# outright on every target, or the script dying all exit 1 with
# "Check could not run". A monitor that cannot see the tunnel is blind.
#
# Source: https://github.com/TechCollective/DattoRMM_Components

set -u
export LC_ALL=C

EMITTED=0
DIAG=""
diag() { DIAG="${DIAG}${1}"$'\n'; }

emit() {  # exit code, status line
    local msg="${2//$'\n'/ }"
    msg="${msg//$'\r'/ }"
    [ "${#msg}" -gt 400 ] && msg="${msg:0:397}..."
    echo '<-Start Result->'
    echo "STATUS=${msg}"
    echo '<-End Result->'
    EMITTED=1
    if [ "$1" -ne 0 ] && [ -n "$DIAG" ]; then
        echo '<-Start Diagnostic->'
        printf '%s' "$DIAG"
        echo '<-End Diagnostic->'
    fi
    exit "$1"
}
on_exit() {
    local rc=$?
    if [ "$EMITTED" -eq 0 ]; then
        echo '<-Start Result->'
        echo "STATUS=Check could not run: the monitor stopped unexpectedly (exit ${rc})"
        echo '<-End Result->'
        exit 1
    fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ---- Inputs ---------------------------------------------------------------
MAX_TARGETS=8

TARGETS_RAW="$(trim "${usrTargets:-}")"
REQUIRE="$(trim "${usrRequire:-any}")"; REQUIRE="${REQUIRE,,}"
COUNT="$(trim "${usrPingCount:-3}")"
WAIT="$(trim "${usrReplyTimeoutSec:-2}")"
SOURCE="$(trim "${usrSource:-}")"

[ -n "$TARGETS_RAW" ] || emit 1 "Check could not run: usrTargets is empty; set the far-side address(es) to ping"
read -r -a TARGETS <<< "${TARGETS_RAW//,/ }"
[ "${#TARGETS[@]}" -ge 1 ] || emit 1 "Check could not run: usrTargets is empty; set the far-side address(es) to ping"
[ "${#TARGETS[@]}" -le "$MAX_TARGETS" ] \
    || emit 1 "Check could not run: usrTargets has ${#TARGETS[@]} entries; the most allowed is ${MAX_TARGETS}"
for t in "${TARGETS[@]}"; do
    # IPv4, IPv6 or a hostname. No leading dash, so nothing can reach ping as an option.
    if ! [[ "$t" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] || [ "${#t}" -gt 253 ]; then
        emit 1 "Check could not run: usrTargets entry '${t:0:60}' is not an IP address or hostname"
    fi
done

case "$REQUIRE" in any|all) ;; *) emit 1 "Check could not run: usrRequire must be any or all (got '${REQUIRE:0:40}')" ;; esac
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 10 ] \
    || emit 1 "Check could not run: usrPingCount must be 1-10 (got '${COUNT:0:40}')"
[[ "$WAIT" =~ ^[0-9]+$ ]] && [ "$WAIT" -ge 1 ] && [ "$WAIT" -le 5 ] \
    || emit 1 "Check could not run: usrReplyTimeoutSec must be 1-5 (got '${WAIT:0:40}')"
if [ -n "$SOURCE" ]; then
    [[ "$SOURCE" =~ ^[A-Za-z0-9:][A-Za-z0-9.:_-]{0,63}$ ]] \
        || emit 1 "Check could not run: usrSource '${SOURCE:0:60}' is not an interface name or IP address"
fi

# Each target gets COUNT pings one second apart, plus WAIT for the last reply.
# The input limits cap the worst case at 8 x (10 + 5) = 120 seconds.
DEADLINE=$((COUNT + WAIT))

PING="$(command -v ping 2>/dev/null || true)"
[ -n "$PING" ] || emit 1 "Check could not run: the ping command is not installed"
PING6="$(command -v ping6 2>/dev/null || true)"
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
HAVE_IP=0; command -v ip >/dev/null 2>&1 && HAVE_IP=1

# ---- Ping each target -------------------------------------------------------
UP=0; DOWN=0; ERRORS=0
SUMMARY=()
FIRST_ERROR=""

for t in "${TARGETS[@]}"; do
    bin="$PING"
    if [[ "$t" == *:* ]] && [ -n "$PING6" ]; then bin="$PING6"; fi
    args=(-n -c "$COUNT" -w "$DEADLINE")
    [ -n "$SOURCE" ] && args+=(-I "$SOURCE")

    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
        out="$(timeout $((DEADLINE + 5)) "$bin" "${args[@]}" -- "$t" 2>&1)"; rc=$?
    else
        out="$("$bin" "${args[@]}" -- "$t" 2>&1)"; rc=$?
    fi

    tx=""; rx=""; avg=""
    if [[ "$out" =~ ([0-9]+)\ packets\ transmitted,\ ([0-9]+)\ (packets\ )?received ]]; then
        tx="${BASH_REMATCH[1]}"; rx="${BASH_REMATCH[2]}"
    fi
    if [[ "$out" =~ \ =\ [0-9.]+/([0-9.]+)/ ]]; then
        avg="${BASH_REMATCH[1]%%.*}"
        [ "$avg" = "0" ] || [ -z "$avg" ] && avg="<1"
    fi

    if [ "$rc" -eq 0 ]; then
        UP=$((UP + 1))
        SUMMARY+=("${t} ${rx:-?}/${tx:-$COUNT}${avg:+ ${avg} ms}")
    elif [ "$rc" -eq 1 ]; then
        DOWN=$((DOWN + 1))
        SUMMARY+=("${t} no reply")
    elif [[ "$out" =~ No\ route\ to\ host|[Nn]etwork\ is\ (unreachable|down)|[Uu]nreachable|connect:\ Invalid\ argument|sendmsg ]]; then
        # ping exits 2 when the kernel has no usable route: the tunnel route has
        # gone, or a blackhole/unreachable route took its place. That is the
        # tunnel being down, not the check failing.
        DOWN=$((DOWN + 1))
        SUMMARY+=("${t} no route")
    else
        # ping could not run for this target: unknown host, bad usrSource, or
        # rc 124 when our own timeout fired.
        ERRORS=$((ERRORS + 1))
        if [ "$rc" -eq 124 ]; then err="ping hung and was stopped"; else err="$(printf '%s\n' "$out" | grep -v '^$' | tail -n 1)"; fi
        err="${err#"$bin": }"; err="${err:0:120}"
        [ -z "$FIRST_ERROR" ] && FIRST_ERROR="$err"
        SUMMARY+=("${t} error: ${err}")
    fi

    diag "== ${t} (exit ${rc})"
    diag "$(printf '%s\n' "$out" | grep -E 'transmitted|min/avg|unknown|nreachable|No route|Name or service|resolution|bind|BINDTODEVICE|Cannot|nvalid|Usage|not permitted' | head -n 4)"
    if [ "$HAVE_IP" -eq 1 ] && [[ "$t" =~ ^[0-9.]+$|: ]]; then
        diag "route: $( (timeout 5 ip route get "$t" 2>&1 || true) | head -n 1)"
    elif command -v getent >/dev/null 2>&1 && ! [[ "$t" =~ ^[0-9.]+$|: ]]; then
        diag "resolves to: $(timeout 5 getent ahosts "$t" 2>/dev/null | awk 'NR==1{print $1}')"
    fi
done

TOTAL=${#TARGETS[@]}
NOUN="targets"; [ "$TOTAL" -eq 1 ] && NOUN="target"
DETAIL="$(IFS=';'; printf '%s' "${SUMMARY[*]}")"
DETAIL="${DETAIL//;/; }"
FROM=""; [ -n "$SOURCE" ] && FROM=" from ${SOURCE}"

diag "== settings: targets=${TOTAL} require=${REQUIRE} count=${COUNT} wait=${WAIT}s source=${SOURCE:-default}"

# ---- Decide -----------------------------------------------------------------
if [ "$ERRORS" -eq "$TOTAL" ]; then
    emit 1 "Check could not run: ping failed on every target${FROM} (${FIRST_ERROR})"
fi

if [ "$REQUIRE" = "any" ]; then
    if [ "$UP" -ge 1 ]; then
        emit 0 "Tunnel up: ${UP} of ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
    fi
    emit 1 "Tunnel down: 0 of ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
fi

# REQUIRE=all
if [ "$UP" -eq "$TOTAL" ]; then
    emit 0 "Tunnel up: all ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
fi
if [ "$UP" -eq 0 ]; then
    emit 1 "Tunnel down: 0 of ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
fi
emit 1 "Tunnel degraded: $((TOTAL - UP)) of ${TOTAL} targets did not reply and all are required${FROM} (${DETAIL})"
