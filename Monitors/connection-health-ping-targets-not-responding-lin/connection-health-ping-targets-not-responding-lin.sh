#!/usr/bin/env bash
# Connection Health - Ping Targets Not Responding [Lin]
#
# Datto RMM custom monitor. Runs as root. Read-only; changes nothing.
#
# Checks a connection (typically a site-to-site tunnel) in one or both of two
# ways, depending on which inputs are set:
#
#   usrTargets       ping 1-8 hosts on the far side
#   usrWgInterface   WireGuard: the interface exists and is up, and its peers
#                    have completed a handshake within usrHandshakeMaxAgeSec
#
#   usrRequire=any   alert only when no target replies / no peer is current (default)
#   usrRequire=all   alert when any target does not reply / any peer is stale
#
# Pings run first. Traffic through the tunnel makes WireGuard re-handshake with
# a live peer, so the handshake age read afterwards reflects the peer rather
# than an idle tunnel.
#
# WireGuard state is read only with `wg show <iface> latest-handshakes`,
# `transfer` and `allowed-ips`. Never `dump`, `private-key` or `showconf`, which
# print the interface's private key.
#
# Not knowing is treated as a fault: bad input, no ping or wg binary, ping
# failing outright on every target, or the script dying all exit 1 with
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
WGIF="$(trim "${usrWgInterface:-}")"
MAXAGE="$(trim "${usrHandshakeMaxAgeSec:-300}")"

[ -n "$TARGETS_RAW" ] || [ -n "$WGIF" ] \
    || emit 1 "Check could not run: nothing to check; set usrTargets (addresses to ping), usrWgInterface (WireGuard interface), or both"

TARGETS=()
if [ -n "$TARGETS_RAW" ]; then
    read -r -a TARGETS <<< "${TARGETS_RAW//,/ }"
    [ "${#TARGETS[@]}" -ge 1 ] || emit 1 "Check could not run: usrTargets has no addresses in it"
    [ "${#TARGETS[@]}" -le "$MAX_TARGETS" ] \
        || emit 1 "Check could not run: usrTargets has ${#TARGETS[@]} entries; the most allowed is ${MAX_TARGETS}"
    for t in "${TARGETS[@]}"; do
        # IPv4, IPv6 or a hostname. No leading dash, so nothing can reach ping as an option.
        if ! [[ "$t" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] || [ "${#t}" -gt 253 ]; then
            emit 1 "Check could not run: usrTargets entry '${t:0:60}' is not an IP address or hostname"
        fi
    done
fi

case "$REQUIRE" in any|all) ;; *) emit 1 "Check could not run: usrRequire must be any or all (got '${REQUIRE:0:40}')" ;; esac
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 10 ] \
    || emit 1 "Check could not run: usrPingCount must be 1-10 (got '${COUNT:0:40}')"
[[ "$WAIT" =~ ^[0-9]+$ ]] && [ "$WAIT" -ge 1 ] && [ "$WAIT" -le 5 ] \
    || emit 1 "Check could not run: usrReplyTimeoutSec must be 1-5 (got '${WAIT:0:40}')"
if [ -n "$SOURCE" ]; then
    [[ "$SOURCE" =~ ^[A-Za-z0-9:][A-Za-z0-9.:_-]{0,63}$ ]] \
        || emit 1 "Check could not run: usrSource '${SOURCE:0:60}' is not an interface name or IP address"
fi
if [ -n "$WGIF" ]; then
    # Linux interface names: at most 15 characters, no '/' or whitespace.
    [[ "$WGIF" =~ ^[A-Za-z0-9][A-Za-z0-9_.=+-]{0,14}$ ]] \
        || emit 1 "Check could not run: usrWgInterface '${WGIF:0:40}' is not a valid interface name"
fi
[[ "$MAXAGE" =~ ^[0-9]+$ ]] && [ "$MAXAGE" -ge 150 ] && [ "$MAXAGE" -le 3600 ] \
    || emit 1 "Check could not run: usrHandshakeMaxAgeSec must be 150-3600 (got '${MAXAGE:0:40}')"

# Each target gets COUNT pings one second apart, plus WAIT for the last reply.
# The input limits cap the worst case at 8 x (10 + 5) = 120 seconds; the
# WireGuard reads are capped at 10 seconds each.
DEADLINE=$((COUNT + WAIT))

HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
HAVE_IP=0; command -v ip >/dev/null 2>&1 && HAVE_IP=1

# ---- Ping each target -------------------------------------------------------
# Result: PING_V is none, up, down, degraded or error; PING_TXT says why.
PING_V=none; PING_TXT=""
TOTAL=${#TARGETS[@]}
FROM=""; [ -n "$SOURCE" ] && FROM=" from ${SOURCE}"

if [ "$TOTAL" -gt 0 ]; then
    PING="$(command -v ping 2>/dev/null || true)"
    PING6="$(command -v ping6 2>/dev/null || true)"
fi

if [ "$TOTAL" -gt 0 ] && [ -z "$PING" ]; then
    PING_V=error; PING_TXT="the ping command is not installed"
elif [ "$TOTAL" -gt 0 ]; then
    UP=0; ERRORS=0
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
            SUMMARY+=("${t} no reply")
        elif [[ "$out" =~ No\ route\ to\ host|[Nn]etwork\ is\ (unreachable|down)|[Uu]nreachable|connect:\ Invalid\ argument|sendmsg ]]; then
            # ping exits 2 when the kernel has no usable route: the tunnel route has
            # gone, or a blackhole/unreachable route took its place. That is the
            # connection being down, not the check failing.
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

    NOUN="targets"; [ "$TOTAL" -eq 1 ] && NOUN="target"
    DETAIL="$(IFS=';'; printf '%s' "${SUMMARY[*]}")"
    DETAIL="${DETAIL//;/; }"

    if [ "$ERRORS" -eq "$TOTAL" ]; then
        PING_V=error; PING_TXT="ping failed on every target${FROM} (${FIRST_ERROR})"
    elif [ "$REQUIRE" = "any" ]; then
        if [ "$UP" -ge 1 ]; then
            PING_V=up;   PING_TXT="${UP} of ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
        else
            PING_V=down; PING_TXT="0 of ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
        fi
    elif [ "$UP" -eq "$TOTAL" ]; then
        PING_V=up;       PING_TXT="all ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
    elif [ "$UP" -eq 0 ]; then
        PING_V=down;     PING_TXT="0 of ${TOTAL} ${NOUN} replied${FROM} (${DETAIL})"
    else
        PING_V=degraded; PING_TXT="$((TOTAL - UP)) of ${TOTAL} targets did not reply and all are required${FROM} (${DETAIL})"
    fi
fi

# ---- WireGuard ----------------------------------------------------------------
# Result: WG_V is none, up, down, degraded or error; WG_TXT says why.
WG_V=none; WG_TXT=""

fmt_age() {  # seconds -> 42s, 17m, 3h, 2d
    local s="$1"
    if   [ "$s" -lt 120 ];    then printf '%ss' "$s"
    elif [ "$s" -lt 7200 ];   then printf '%sm' $((s / 60))
    elif [ "$s" -lt 172800 ]; then printf '%sh' $((s / 3600))
    else printf '%sd' $((s / 86400)); fi
}

wg_show() {  # wg show <iface> <field>, bounded in time
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
        timeout 10 "$WGBIN" show "$WGIF" "$1" 2>&1
    else
        "$WGBIN" show "$WGIF" "$1" 2>&1
    fi
}

wg_check() {
    # 1. The interface exists and is administratively up. wg-quick down deletes
    #    it; `ip link set <iface> down` leaves it present without the UP flag.
    local link rc up=""
    if [ "$HAVE_IP" -eq 1 ]; then
        link="$(ip -o link show dev "$WGIF" 2>&1)"; rc=$?
        if [ "$rc" -ne 0 ]; then
            if [[ "$link" == *"does not exist"* ]]; then
                WG_V=down; WG_TXT="interface does not exist (tunnel not started)"
            else
                WG_V=error; WG_TXT="ip link failed: ${link:0:120}"
            fi
            diag "   link: ${link:0:200}"
            return
        fi
        [[ "$link" =~ [\<,]UP[,\>] ]] && up=1
        diag "   link: $(printf '%s' "$link" | awk '{print $3, $9}')"
    else
        if [ ! -e "/sys/class/net/${WGIF}" ]; then
            WG_V=down; WG_TXT="interface does not exist (tunnel not started)"; return
        fi
        local flags; flags="$(cat "/sys/class/net/${WGIF}/flags" 2>/dev/null)"
        [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]] && (( flags & 1 )) && up=1
        diag "   link: flags ${flags:-unreadable}"
    fi
    if [ -z "$up" ]; then
        WG_V=down; WG_TXT="interface is administratively down"; return
    fi

    # 2. Handshake age per peer.
    WGBIN="$(command -v wg 2>/dev/null || true)"
    if [ -z "$WGBIN" ]; then
        WG_V=error; WG_TXT="the wg command (wireguard-tools) is not installed"; return
    fi
    local hs
    hs="$(wg_show latest-handshakes)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        local why; why="$(printf '%s\n' "$hs" | grep -v '^$' | tail -n 1)"
        if [[ "$why" == *"not supported"* ]]; then
            WG_V=error; WG_TXT="interface is not a WireGuard interface"
        elif [ "$rc" -eq 124 ]; then
            WG_V=error; WG_TXT="wg show hung and was stopped"
        else
            WG_V=error; WG_TXT="wg show failed: ${why:0:120}"
        fi
        diag "   wg show (exit ${rc}): ${why:0:200}"
        return
    fi
    local xfer allowed now
    xfer="$(wg_show transfer || true)"
    allowed="$(wg_show allowed-ips || true)"
    now="$(date +%s)"

    local n=0 ok=0 key ts age state parts=()
    while IFS=$'\t' read -r key ts; do
        [ -n "$key" ] || continue
        if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
            WG_V=error; WG_TXT="unexpected output from wg show latest-handshakes"; return
        fi
        n=$((n + 1))
        if [ "$ts" -eq 0 ]; then
            state="never handshaked"; parts+=("peer ${n} never")
        else
            age=$((now - ts)); [ "$age" -lt 0 ] && age=0
            state="last handshake $(fmt_age "$age") ago"
            if [ "$age" -le "$MAXAGE" ]; then
                ok=$((ok + 1)); parts+=("peer ${n} $(fmt_age "$age") ago")
            else
                parts+=("peer ${n} $(fmt_age "$age") ago (stale)")
            fi
        fi
        # Key prefix and allowed IPs identify the peer; endpoints are left out.
        diag "   peer ${n} (key ${key:0:8}...): ${state}; allowed-ips $(printf '%s\n' "$allowed" | awk -F'\t' -v k="$key" '$1==k{print $2}'); rx/tx bytes $(printf '%s\n' "$xfer" | awk -F'\t' -v k="$key" '$1==k{print $2 "/" $3}')"
    done <<< "$hs"

    if [ "$n" -eq 0 ]; then
        WG_V=down; WG_TXT="no peers configured"; return
    fi
    local pn="peers"; [ "$n" -eq 1 ] && pn="peer"
    local detail; detail="$(IFS=';'; printf '%s' "${parts[*]}")"; detail="${detail//;/; }"
    local within="handshaked within ${MAXAGE}s"
    if [ "$REQUIRE" = "any" ]; then
        if [ "$ok" -ge 1 ]; then WG_V=up;   WG_TXT="${ok} of ${n} ${pn} ${within} (${detail})"
        else                     WG_V=down; WG_TXT="0 of ${n} ${pn} ${within} (${detail})"; fi
    elif [ "$ok" -eq "$n" ]; then WG_V=up;       WG_TXT="all ${n} ${pn} ${within} (${detail})"
    elif [ "$ok" -eq 0 ];    then WG_V=down;     WG_TXT="0 of ${n} ${pn} ${within} (${detail})"
    else                          WG_V=degraded; WG_TXT="$((n - ok)) of ${n} peers stale and all are required (${detail})"
    fi
}

if [ -n "$WGIF" ]; then
    diag "== WireGuard ${WGIF}"
    wg_check
fi

diag "== settings: targets=${TOTAL} require=${REQUIRE} count=${COUNT} wait=${WAIT}s source=${SOURCE:-default} wg=${WGIF:-none} max-handshake-age=${MAXAGE}s"

# ---- Decide -----------------------------------------------------------------
# Worst result wins: down, then degraded, then could-not-run, then up.
PARTS=()
if [ "$PING_V" != none ]; then
    if [ "$WG_V" != none ]; then PARTS+=("ping: ${PING_TXT}"); else PARTS+=("$PING_TXT"); fi
fi
[ "$WG_V" != none ] && PARTS+=("WireGuard ${WGIF}: ${WG_TXT}")
MSG="${PARTS[0]}"; [ "${#PARTS[@]}" -gt 1 ] && MSG="${MSG} | ${PARTS[1]}"

if   [ "$PING_V" = down ]     || [ "$WG_V" = down ];     then emit 1 "Connection down: ${MSG}"
elif [ "$PING_V" = degraded ] || [ "$WG_V" = degraded ]; then emit 1 "Connection degraded: ${MSG}"
elif [ "$PING_V" = error ]    || [ "$WG_V" = error ];    then emit 1 "Check could not run: ${MSG}"
fi
emit 0 "Connection up: ${MSG}"
