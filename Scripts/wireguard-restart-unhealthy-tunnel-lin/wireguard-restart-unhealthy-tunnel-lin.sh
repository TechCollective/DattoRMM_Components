#!/usr/bin/env bash
# WireGuard - Restart Unhealthy Tunnel [Lin]
#
# Datto RMM script component. Runs as root.
#
# Restarts a wg-quick WireGuard tunnel, but only when that is warranted:
#
#   1. It is unhealthy: the interface is missing or administratively down, or
#      no peer has completed a handshake within usrHandshakeMaxAgeSec (the same
#      test as the Connection Health monitor). usrMode=always skips this gate.
#   2. It is meant to be running: the interface exists now, or the
#      wg-quick@<iface> unit is enabled. A tunnel someone took down on purpose
#      stays down.
#   3. It is managed by wg-quick (systemd unit or /etc/wireguard/<iface>.conf),
#      and its config parses. Anything else is reported, not touched.
#   4. It has not been restarted by this component within usrCooldownMin, so a
#      monitor response cannot restart it in a loop. usrMode=always skips this.
#
# After restarting it waits up to usrVerifySec for a peer to handshake, sending
# a ping into the tunnel to prompt one, and reports whether it did.
#
# Exit codes, each with a STATUS= line as the last line of output:
#   0  HEALTHY          healthy; nothing done
#   0  RESTARTED        restarted, and a peer handshaked afterwards
#   1  STILL_UNHEALTHY  restarted, but no peer handshaked within usrVerifySec
#   1  FAILED           a restart step failed, or the config does not parse
#   2  REFUSED          an input is invalid, or the interface is not WireGuard
#   3  NOT_ACTIVE       not running and not enabled: down on purpose; not started
#   3  UNMANAGED        not managed by wg-quick; not touched
#   3  NO_PEERS         no peers configured; a restart cannot help
#   3  COOLDOWN         restarted less than usrCooldownMin ago; not again
#   3  NOT_INSTALLED    wireguard-tools (wg, wg-quick) is not installed
#
# Reads WireGuard state only with `wg show <iface> latest-handshakes` and
# `allowed-ips`; never prints keys. Writes one file:
# /var/lib/tc-wireguard/restart-<iface>.last, the time of its last restart.
#
# Source: https://github.com/TechCollective/DattoRMM_Components

set -u
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

FINISHED=0
finish() {  # exit code, STATUS keyword, message
    echo "$3"
    echo "STATUS=$2"
    FINISHED=1
    exit "$1"
}
on_exit() {
    local rc=$?
    if [ "$FINISHED" -eq 0 ]; then
        echo "The script stopped unexpectedly (exit ${rc}). The tunnel may be mid-restart: check it."
        echo "STATUS=FAILED"
        exit 1
    fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
refuse() { finish 2 REFUSED "Refused: $1"; }

# ---- Inputs ---------------------------------------------------------------
IF="$(trim "${usrWgInterface:-}")"
MODE="$(trim "${usrMode:-ifunhealthy}")"; MODE="${MODE,,}"
MAXAGE="$(trim "${usrHandshakeMaxAgeSec:-300}")"
VERIFY="$(trim "${usrVerifySec:-30}")"
COOLDOWN="$(trim "${usrCooldownMin:-15}")"
PINGT="$(trim "${usrPingTarget:-}")"

[ -n "$IF" ] || refuse "usrWgInterface is empty; set the WireGuard interface to check, such as wg0"
[[ "$IF" =~ ^[A-Za-z0-9][A-Za-z0-9_.=+-]{0,14}$ ]] || refuse "usrWgInterface '${IF:0:40}' is not a valid interface name"
case "$MODE" in ifunhealthy|always) ;; *) refuse "usrMode must be ifunhealthy or always (got '${MODE:0:40}')" ;; esac
[[ "$MAXAGE" =~ ^[0-9]+$ ]] && [ "$MAXAGE" -ge 150 ] && [ "$MAXAGE" -le 3600 ] || refuse "usrHandshakeMaxAgeSec must be 150-3600 (got '${MAXAGE:0:40}')"
[[ "$VERIFY" =~ ^[0-9]+$ ]] && [ "$VERIFY" -ge 10 ] && [ "$VERIFY" -le 120 ] || refuse "usrVerifySec must be 10-120 (got '${VERIFY:0:40}')"
[[ "$COOLDOWN" =~ ^[0-9]+$ ]] && [ "$COOLDOWN" -le 1440 ] || refuse "usrCooldownMin must be 0-1440 (got '${COOLDOWN:0:40}')"
if [ -n "$PINGT" ]; then
    [[ "$PINGT" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] && [ "${#PINGT}" -le 253 ] || refuse "usrPingTarget '${PINGT:0:60}' is not an IP address or hostname"
fi

command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 \
    || finish 3 NOT_INSTALLED "wireguard-tools (wg and wg-quick) is not installed on this host; there is no wg-quick tunnel to restart."

HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
bounded() {  # seconds, command...
    local s="$1"; shift
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then timeout "$s" "$@"; else "$@"; fi
}

fmt_age() {
    local s="$1"
    if   [ "$s" -lt 120 ];    then printf '%ss' "$s"
    elif [ "$s" -lt 7200 ];   then printf '%sm' $((s / 60))
    elif [ "$s" -lt 172800 ]; then printf '%sh' $((s / 3600))
    else printf '%sd' $((s / 86400)); fi
}

# ---- Health -----------------------------------------------------------------
link_state() {  # prints missing, down or up
    if command -v ip >/dev/null 2>&1; then
        local l; l="$(ip -o link show dev "$IF" 2>/dev/null)" || { echo missing; return; }
        if [[ "$l" =~ [\<,]UP[,\>] ]]; then echo up; else echo down; fi
    else
        [ -e "/sys/class/net/${IF}" ] || { echo missing; return; }
        local f; f="$(cat "/sys/class/net/${IF}/flags" 2>/dev/null)"
        if [[ "$f" =~ ^0x[0-9a-fA-F]+$ ]] && (( f & 1 )); then echo up; else echo down; fi
    fi
}

# Sets HEALTH (healthy, unhealthy, nopeers) and REASON. Peers count as current
# when they handshaked within MAXAGE seconds, or at/after $1 when $1 is given.
check_health() {
    local since="${1:-}"
    local link; link="$(link_state)"
    if [ "$link" = missing ]; then HEALTH=unhealthy; REASON="interface ${IF} does not exist"; LINK=missing; return; fi
    LINK="$link"
    if [ "$link" = down ];    then HEALTH=unhealthy; REASON="interface ${IF} is administratively down"; return; fi
    local hs rc
    hs="$(bounded 10 wg show "$IF" latest-handshakes 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        if [[ "$hs" == *"not supported"* ]]; then
            finish 2 REFUSED "Refused: ${IF} is not a WireGuard interface."
        fi
        finish 1 FAILED "wg show ${IF} failed (exit ${rc}): $(printf '%s\n' "$hs" | grep -v '^$' | tail -n 1 | cut -c1-200)"
    fi
    local now n=0 ok=0 key ts age parts=()
    now="$(date +%s)"
    while IFS=$'\t' read -r key ts; do
        [ -n "$key" ] || continue
        [[ "$ts" =~ ^[0-9]+$ ]] || finish 1 FAILED "Unexpected output from wg show ${IF} latest-handshakes."
        n=$((n + 1))
        if [ "$ts" -eq 0 ]; then parts+=("peer ${n} never"); continue; fi
        age=$((now - ts)); [ "$age" -lt 0 ] && age=0
        parts+=("peer ${n} $(fmt_age "$age") ago")
        if [ -n "$since" ]; then [ "$ts" -ge "$since" ] && ok=$((ok + 1))
        elif [ "$age" -le "$MAXAGE" ]; then ok=$((ok + 1)); fi
    done <<< "$hs"
    local detail; detail="$(IFS=';'; printf '%s' "${parts[*]:-}")"; detail="${detail//;/,}"
    if [ "$n" -eq 0 ]; then HEALTH=nopeers; REASON="interface ${IF} is up but has no peers configured"; return; fi
    if [ "$ok" -ge 1 ]; then
        HEALTH=healthy; REASON="${ok} of ${n} peer(s) handshaked within ${MAXAGE}s (${detail})"
        [ -n "$since" ] && REASON="${ok} of ${n} peer(s) handshaked since the restart (${detail})"
    else
        HEALTH=unhealthy; REASON="no peer has handshaked within ${MAXAGE}s (${detail})"
        [ -n "$since" ] && REASON="no peer has handshaked since the restart (${detail})"
    fi
}

check_health
echo "Before: ${REASON}."
[ "$HEALTH" = nopeers ] && finish 3 NO_PEERS "${IF} has no peers configured, so a restart cannot bring the tunnel up. Fix its configuration."
if [ "$HEALTH" = healthy ] && [ "$MODE" = ifunhealthy ]; then
    finish 0 HEALTHY "${IF} is healthy; nothing to do."
fi

# ---- Is it meant to be running, and how is it managed? -----------------------
UNIT="wg-quick@${IF}.service"
CONF="/etc/wireguard/${IF}.conf"
ENABLED=0; ACTIVE=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    [ "$(systemctl is-enabled "$UNIT" 2>/dev/null)" = enabled ] && ENABLED=1
    systemctl is-active --quiet "$UNIT" 2>/dev/null && ACTIVE=1
fi

if [ "$LINK" = missing ]; then
    if [ "$ENABLED" -eq 0 ]; then
        finish 3 NOT_ACTIVE "${IF} is not running and ${UNIT} is not enabled, so it was taken down on purpose or never set to start. Not started. To bring it up for good: systemctl enable --now ${UNIT}"
    fi
    METHOD=systemd
elif [ "$ACTIVE" -eq 1 ]; then
    METHOD=systemd
elif [ -f "$CONF" ]; then
    METHOD=wg-quick
else
    finish 3 UNMANAGED "${IF} is not managed by wg-quick (no ${UNIT} running and no ${CONF}). It may belong to systemd-networkd or NetworkManager; restart it with the tool that manages it. Not touched."
fi
[ -f "$CONF" ] || finish 1 FAILED "${UNIT} is enabled but ${CONF} is missing, so wg-quick cannot start it. Not touched."
STRIP="$(bounded 10 wg-quick strip "$IF" 2>&1)" \
    || finish 1 FAILED "${CONF} does not parse, so ${IF} was not touched: $(printf '%s\n' "$STRIP" | grep -v '^$' | tail -n 1 | cut -c1-200)"
# wg-quick strip removes wg-quick's own keys but passes anything else through,
# and `wg setconf` would then fail halfway through bringing the tunnel up. Check
# what is left against the keys wg accepts, so a broken config is caught while
# the tunnel is still as it was.
LINT="$(printf '%s\n' "$STRIP" | awk '
    BEGIN { sec = ""; bad = "" }
    { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
    $0 == "" { next }
    tolower($0) == "[interface]" { sec = "i"; ni++; next }
    tolower($0) == "[peer]"      { sec = "p"; next }
    {
        k = $0; sub(/[ \t]*=.*/, "", k); k = tolower(k)
        # Never echo config text: a stray line could hold a key.
        if (index($0, "=") == 0 || k !~ /^[a-z]+$/) { bad = bad " (malformed line)"; next }
        if (sec == "i" && k ~ /^(privatekey|listenport|fwmark)$/) next
        if (sec == "p" && k ~ /^(publickey|presharedkey|allowedips|endpoint|persistentkeepalive)$/) next
        bad = bad " " k
    }
    END {
        if (ni != 1) print "expected one [Interface] section, found " ni + 0
        if (bad != "") print "unknown key(s):" bad
    }')"
[ -z "$LINT" ] || finish 1 FAILED "${CONF} does not parse, so ${IF} was not touched: $(printf '%s' "$LINT" | tr '\n' ';' | cut -c1-200)"

# ---- Cooldown -----------------------------------------------------------------
STATE_DIR=/var/lib/tc-wireguard
STAMP="${STATE_DIR}/restart-${IF}.last"
NOW="$(date +%s)"
if [ "$MODE" = ifunhealthy ] && [ "$COOLDOWN" -gt 0 ] && [ -f "$STAMP" ]; then
    LAST="$(head -c 20 "$STAMP" 2>/dev/null)"
    if [[ "$LAST" =~ ^[0-9]+$ ]] && [ $((NOW - LAST)) -lt $((COOLDOWN * 60)) ] && [ $((NOW - LAST)) -ge 0 ]; then
        finish 3 COOLDOWN "${IF} was restarted by this component $(fmt_age $((NOW - LAST))) ago; the cooldown is ${COOLDOWN} minutes. Not restarted again. If restarts are not fixing it, the cause is elsewhere (far side, ISP, config)."
    fi
fi

# ---- Restart ------------------------------------------------------------------
mkdir -p "$STATE_DIR" && printf '%s\n' "$NOW" > "$STAMP" \
    || echo "Warning: could not write ${STAMP}; the cooldown will not apply to the next run."

if [ "$METHOD" = systemd ]; then
    echo "Restarting ${UNIT}..."
    OUT="$(bounded 60 systemctl restart "$UNIT" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ]; then
        finish 1 FAILED "systemctl restart ${UNIT} failed (exit ${RC}): ${OUT:0:200}. Recent log: $(systemctl status --no-pager -n 5 "$UNIT" 2>&1 | tail -n 5 | tr '\n' ' ' | cut -c1-400)"
    fi
else
    echo "Restarting ${IF} with wg-quick down and up..."
    OUT="$(bounded 30 wg-quick down "$IF" 2>&1)"; RC=$?
    [ "$RC" -eq 0 ] || finish 1 FAILED "wg-quick down ${IF} failed (exit ${RC}): $(printf '%s\n' "$OUT" | tail -n 1 | cut -c1-200). Not brought back up."
    OUT="$(bounded 30 wg-quick up "$IF" 2>&1)"; RC=$?
    [ "$RC" -eq 0 ] || finish 1 FAILED "wg-quick up ${IF} failed (exit ${RC}): $(printf '%s\n' "$OUT" | tail -n 1 | cut -c1-200). THE TUNNEL IS DOWN."
fi

# ---- Verify -------------------------------------------------------------------
# Any packet routed into the tunnel makes WireGuard start a handshake, whether
# or not the target answers. Ping usrPingTarget, or else the first address of
# each peer's first IPv4 allowed-ips range (skipping a 0.0.0.0/0 default route).
NUDGE=()
if [ -n "$PINGT" ]; then
    NUDGE=("$PINGT")
else
    while read -r a; do [ -n "$a" ] && NUDGE+=("$a"); done < <(
        bounded 10 wg show "$IF" allowed-ips 2>/dev/null | awk -F'\t' '{
            n = split($2, r, " ");
            for (i = 1; i <= n; i++) {
                if (r[i] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ || r[i] ~ /\/0$/) continue;
                split(r[i], p, "/"); split(p[1], o, ".");
                if (p[2] == 32) print p[1]; else print o[1] "." o[2] "." o[3] "." (o[4] + 1);
                break
            }
        }')
fi
echo "Waiting up to ${VERIFY}s for a handshake${NUDGE[0]:+ (prompting with ping to ${NUDGE[*]})}..."

DEADLINE=$(( $(date +%s) + VERIFY ))
while :; do
    if [ "${#NUDGE[@]}" -gt 0 ] && command -v ping >/dev/null 2>&1; then
        for t in "${NUDGE[@]}"; do ping -n -c 1 -W 1 -- "$t" >/dev/null 2>&1; done
    fi
    check_health "$NOW"
    [ "$HEALTH" = healthy ] && break
    [ "$(date +%s)" -ge "$DEADLINE" ] && break
    sleep 2
done

echo "After: ${REASON}."
if [ "$HEALTH" = healthy ]; then
    finish 0 RESTARTED "${IF} restarted (${METHOD}) and a peer handshaked $(( $(date +%s) - NOW ))s later."
fi
if [ "$LINK" != up ]; then
    finish 1 FAILED "${IF} was restarted (${METHOD}) but the interface is not up."
fi
finish 1 STILL_UNHEALTHY "${IF} restarted (${METHOD}), but no peer handshaked within ${VERIFY}s. The far side may be down or unreachable, or nothing sent traffic: set usrPingTarget to a far-side address, or PersistentKeepalive on the peer."
