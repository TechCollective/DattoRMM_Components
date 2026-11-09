#!/usr/bin/env bash
# Docker - Configure Host Maintenance [Lin]
#
# Datto RMM Scripts component. Runs as root.
#
# 1. Adds log rotation and build-cache limits to /etc/docker/daemon.json.
#    Only keys that are MISSING are added. An existing value is never changed,
#    so a host someone already tuned keeps its tuning.
# 2. Installs a systemd timer that prunes unused images, stopped containers,
#    unused networks and build cache older than N hours. Never volumes.
# 3. Optionally runs that prune once, now.
#
# It never restarts Docker. daemon.json changes take effect at the next
# Docker restart or reboot; the output says "RESTART PENDING" when that applies.
#
# Exit codes:
#   0  done, or nothing to do (including: Docker is not installed)
#   1  unexpected failure
#   2  an input variable is invalid; nothing was changed
#   3  could not apply safely (no JSON tool, config failed validation,
#      no systemd, snap-packaged Docker); nothing was changed for that part

set -u
umask 022

DAEMON_JSON="/etc/docker/daemon.json"
UNIT_DIR="/etc/systemd/system"
UNIT_NAME="tc-docker-prune"
RESULT=1
CHANGED_DAEMON=0

finish() {
    local rc=$?
    if [ "$RESULT" -ne 0 ] && [ "$rc" -eq 0 ]; then rc=$RESULT; fi
    if [ "$rc" -ne 0 ]; then
        echo "Finished with exit code $rc."
    fi
    exit "$rc"
}
trap finish EXIT

say()  { echo "$*"; }
fail() { local code=$1; shift; echo "ERROR: $*"; RESULT=$code; exit "$code"; }

# ---------------------------------------------------------------- inputs

usrMode="${usrMode:-apply}"
usrLogMaxSize="${usrLogMaxSize-10m}"
usrLogMaxFile="${usrLogMaxFile-3}"
usrBuildCacheReserved="${usrBuildCacheReserved-20GB}"
usrBuildCacheMax="${usrBuildCacheMax-100GB}"
usrPruneSchedule="${usrPruneSchedule-Sun *-*-* 04:00:00}"
usrPruneOlderThanHours="${usrPruneOlderThanHours-168}"
usrPruneNow="${usrPruneNow:-no}"

# Trim surrounding whitespace a pasted value tends to carry.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
for v in usrMode usrLogMaxSize usrLogMaxFile usrBuildCacheReserved usrBuildCacheMax \
         usrPruneSchedule usrPruneOlderThanHours usrPruneNow; do
    printf -v "$v" '%s' "$(trim "${!v}")"
done
usrMode="${usrMode,,}"; usrPruneNow="${usrPruneNow,,}"
usrLogMaxSize="${usrLogMaxSize,,}"; usrBuildCacheReserved="${usrBuildCacheReserved^^}"
usrBuildCacheMax="${usrBuildCacheMax^^}"

case "$usrMode" in apply|report) ;; *) fail 2 "usrMode must be apply or report (got '$usrMode')." ;; esac
case "$usrPruneNow" in yes|no) ;; *) fail 2 "usrPruneNow must be yes or no (got '$usrPruneNow')." ;; esac

if [ -n "$usrLogMaxSize" ] || [ -n "$usrLogMaxFile" ]; then
    [[ "$usrLogMaxSize" =~ ^[1-9][0-9]*[kmg]$ ]] \
        || fail 2 "usrLogMaxSize must be a number followed by k, m or g, e.g. 10m (got '$usrLogMaxSize')."
    [[ "$usrLogMaxFile" =~ ^[0-9]+$ ]] && [ "$usrLogMaxFile" -ge 1 ] && [ "$usrLogMaxFile" -le 20 ] \
        || fail 2 "usrLogMaxFile must be 1-20 (got '$usrLogMaxFile')."
fi

size_re='^[1-9][0-9]*(MB|GB|TB)$'
if [ -n "$usrBuildCacheMax" ]; then
    [[ "$usrBuildCacheMax" =~ $size_re ]] \
        || fail 2 "usrBuildCacheMax must look like 100GB (MB, GB or TB), or be blank (got '$usrBuildCacheMax')."
    [[ "$usrBuildCacheReserved" =~ $size_re ]] \
        || fail 2 "usrBuildCacheReserved must look like 20GB (MB, GB or TB) (got '$usrBuildCacheReserved')."
fi

if [ -n "$usrPruneSchedule" ]; then
    [[ "$usrPruneOlderThanHours" =~ ^[0-9]+$ ]] && [ "$usrPruneOlderThanHours" -ge 24 ] \
        && [ "$usrPruneOlderThanHours" -le 8760 ] \
        || fail 2 "usrPruneOlderThanHours must be 24-8760 (got '$usrPruneOlderThanHours')."
    case "$usrPruneSchedule" in *[\;\&\|\`\$\<\>\\\"\']*|*$'\n'*)
        fail 2 "usrPruneSchedule contains characters a systemd calendar never needs." ;; esac
    if command -v systemd-analyze >/dev/null 2>&1 \
       && ! systemd-analyze calendar "$usrPruneSchedule" >/dev/null 2>&1; then
        fail 2 "usrPruneSchedule '$usrPruneSchedule' is not a systemd calendar expression."
    fi
fi
if [ "$usrPruneNow" = "yes" ]; then
    [[ "$usrPruneOlderThanHours" =~ ^[0-9]+$ ]] && [ "$usrPruneOlderThanHours" -ge 24 ] \
        || fail 2 "usrPruneNow=yes needs usrPruneOlderThanHours of 24 or more (got '$usrPruneOlderThanHours')."
fi

# ---------------------------------------------------------------- is Docker here?

DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
if [ -z "$DOCKER_BIN" ]; then
    say "Docker is not installed on this host; nothing to do."
    RESULT=0; exit 0
fi
case "$DOCKER_BIN" in
    /snap/*)
        fail 3 "Docker here is the snap package ($DOCKER_BIN). Its daemon.json and lifecycle are managed by snap; this component does not handle it." ;;
esac

ENGINE_VER="$( (dockerd --version 2>/dev/null || "$DOCKER_BIN" version --format '{{.Server.Version}}' 2>/dev/null) \
    | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
ENGINE_MAJOR="${ENGINE_VER%%.*}"
say "Docker: $DOCKER_BIN, engine ${ENGINE_VER:-unknown}. Mode: $usrMode."

# ---------------------------------------------------------------- daemon.json

merge_daemon_json() {
    # Prints the merged JSON on stdout and one "ADDED:"/"KEPT:"/"SKIPPED:" line
    # per decision on stderr. Never changes an existing value.
    python3 - "$DAEMON_JSON" <<'PY'
import json, os, sys
path = sys.argv[1]
env = os.environ
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("daemon.json is not a JSON object")

def note(kind, msg): print(f"{kind}: {msg}", file=sys.stderr)

size, files = env.get("usrLogMaxSize", ""), env.get("usrLogMaxFile", "")
if size:
    driver = data.get("log-driver", "json-file")
    if driver not in ("json-file", "local"):
        note("SKIPPED", f"log rotation: log-driver is {driver}, which does not take max-size/max-file")
    else:
        opts = data.get("log-opts")
        if opts is None:
            opts = {}
        if not isinstance(opts, dict):
            note("SKIPPED", "log rotation: log-opts is not an object")
        else:
            for k, v in (("max-size", size), ("max-file", files)):
                if k in opts:
                    note("KEPT", f"log-opts.{k} = {opts[k]}")
                else:
                    opts[k] = v
                    note("ADDED", f"log-opts.{k} = {v}")
            data["log-opts"] = opts

cmax, cres = env.get("usrBuildCacheMax", ""), env.get("usrBuildCacheReserved", "")
major = env.get("ENGINE_MAJOR", "")
if cmax:
    builder = data.get("builder")
    if builder is None:
        builder = {}
    gc = builder.get("gc") if isinstance(builder, dict) else None
    if not isinstance(builder, dict):
        note("SKIPPED", "build cache: builder is not an object")
    elif gc is not None:
        note("KEPT", "builder.gc already configured: " + json.dumps(gc, separators=(",", ":")))
    else:
        if major.isdigit() and int(major) >= 28:
            gc = {"enabled": True, "policy": [{"all": True, "reservedSpace": cres, "maxUsedSpace": cmax}]}
        else:
            # Engines before 28 do not know reservedSpace/maxUsedSpace and
            # would silently ignore them inside a policy.
            gc = {"enabled": True, "defaultKeepStorage": cmax}
        builder["gc"] = gc
        data["builder"] = builder
        note("ADDED", "builder.gc = " + json.dumps(gc, separators=(",", ":")))

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
}

daemon_section() {
    if [ -z "$usrLogMaxSize" ] && [ -z "$usrBuildCacheMax" ]; then
        say "daemon.json: log rotation and build-cache limits both left blank; not touched."
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        say "daemon.json: python3 is not available, so the file cannot be merged safely; not touched."
        return 3
    fi

    local tmp notes rc
    tmp="$(mktemp)"; notes="$(mktemp)"
    export usrLogMaxSize usrLogMaxFile usrBuildCacheMax usrBuildCacheReserved ENGINE_MAJOR
    merge_daemon_json >"$tmp" 2>"$notes"; rc=$?
    if [ $rc -ne 0 ]; then
        say "daemon.json: could not read the existing file as JSON; not touched."
        sed 's/^/  /' "$notes" | tail -n 1
        rm -f "$tmp" "$notes"; return 3
    fi
    sed 's/^/  daemon.json /' "$notes"

    if [ -f "$DAEMON_JSON" ] && python3 - "$DAEMON_JSON" "$tmp" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])) if open(sys.argv[1]).read().strip() else {}
b = json.load(open(sys.argv[2]))
sys.exit(0 if a == b else 1)
PY
    then
        say "daemon.json: already has everything this component sets; no change."
        rm -f "$tmp" "$notes"; return 0
    fi
    if ! grep -q '^ADDED' "$notes"; then
        say "daemon.json: nothing to add; no change."
        rm -f "$tmp" "$notes"; return 0
    fi

    if dockerd --help 2>/dev/null | grep -q -- '--validate'; then
        if ! dockerd --validate --config-file "$tmp" >/dev/null 2>"$notes"; then
            say "daemon.json: the merged file failed dockerd --validate; not written."
            sed 's/^/  /' "$notes" | tail -n 3
            rm -f "$tmp" "$notes"; return 3
        fi
        say "daemon.json: merged file passes dockerd --validate."
    else
        say "daemon.json: this dockerd has no --validate; merged file checked as JSON only."
    fi

    if [ "$usrMode" = "report" ]; then
        say "daemon.json: REPORT MODE, would write the change above."
        rm -f "$tmp" "$notes"; return 0
    fi

    mkdir -p "$(dirname "$DAEMON_JSON")"
    if [ -f "$DAEMON_JSON" ]; then
        local bak
        bak="$DAEMON_JSON.tc-bak-$(date +%Y%m%d%H%M%S)"
        cp -p "$DAEMON_JSON" "$bak" || { rm -f "$tmp" "$notes"; return 1; }
        say "daemon.json: previous file saved as $bak"
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$DAEMON_JSON" || { rm -f "$notes"; return 1; }
    rm -f "$notes"
    CHANGED_DAEMON=1
    say "daemon.json: written."
    return 0
}

# ---------------------------------------------------------------- prune timer

timer_section() {
    if [ -z "$usrPruneSchedule" ]; then
        say "Prune timer: usrPruneSchedule is blank; not installed or changed."
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        say "Prune timer: this host is not running systemd; not installed."
        return 3
    fi
    local svc timer
    svc="[Unit]
Description=Prune unused Docker images, stopped containers, networks and build cache (TechCollective)
Documentation=https://github.com/TechCollective/DattoRMM_Components/tree/main/Scripts/docker-configure-host-maintenance-lin
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=$DOCKER_BIN system prune --all --force --filter until=${usrPruneOlderThanHours}h --filter label!=tc.keep
"
    timer="[Unit]
Description=Weekly Docker prune (TechCollective)

[Timer]
OnCalendar=$usrPruneSchedule
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
"
    local changed=0 f content
    for f in service timer; do
        if [ "$f" = service ]; then content="$svc"; else content="$timer"; fi
        if [ -f "$UNIT_DIR/$UNIT_NAME.$f" ] && [ "$(cat "$UNIT_DIR/$UNIT_NAME.$f")" = "${content%$'\n'}" ]; then
            continue
        fi
        changed=1
        if [ "$usrMode" = "apply" ]; then
            printf '%s' "$content" >"$UNIT_DIR/$UNIT_NAME.$f.tmp" \
                && mv -f "$UNIT_DIR/$UNIT_NAME.$f.tmp" "$UNIT_DIR/$UNIT_NAME.$f" || return 1
        fi
    done

    if [ "$usrMode" = "report" ]; then
        if [ $changed -eq 1 ]; then
            say "Prune timer: REPORT MODE, would install $UNIT_NAME.timer ($usrPruneSchedule, older than ${usrPruneOlderThanHours}h)."
        else
            say "Prune timer: already installed with these settings."
        fi
        return 0
    fi

    if [ $changed -eq 1 ]; then
        systemctl daemon-reload || return 1
    fi
    if ! systemctl is-enabled --quiet "$UNIT_NAME.timer" 2>/dev/null \
       || ! systemctl is-active --quiet "$UNIT_NAME.timer" 2>/dev/null \
       || [ $changed -eq 1 ]; then
        systemctl enable "$UNIT_NAME.timer" >/dev/null 2>&1 || return 1
        systemctl restart "$UNIT_NAME.timer" || return 1
    fi
    if [ $changed -eq 1 ]; then
        say "Prune timer: installed $UNIT_NAME.timer ($usrPruneSchedule, removes unused items older than ${usrPruneOlderThanHours}h; volumes are never removed)."
    else
        say "Prune timer: already installed with these settings."
    fi
    local next
    next="$(systemctl show "$UNIT_NAME.timer" -p NextElapseUSecRealtime --value 2>/dev/null)"
    [ -n "$next" ] && say "Prune timer: next run $next."
    return 0
}

# ---------------------------------------------------------------- prune now

prune_now() {
    [ "$usrPruneNow" = "yes" ] || return 0
    if [ "$usrMode" = "report" ]; then
        say "Prune now: REPORT MODE, skipped."
        return 0
    fi
    if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
        say "Prune now: the Docker daemon is not reachable; skipped."
        return 3
    fi
    say "Prune now: removing unused items older than ${usrPruneOlderThanHours}h (volumes are never removed)."
    say "Disk before: $(df -h --output=avail,pcent "$("$DOCKER_BIN" info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | tail -n1 | awk '{print $1" free, "$2" used"}')"
    "$DOCKER_BIN" system prune --all --force --filter "until=${usrPruneOlderThanHours}h" --filter "label!=tc.keep" 2>&1 \
        | grep -iE 'reclaimed|error' || true
    say "Disk after:  $(df -h --output=avail,pcent "$("$DOCKER_BIN" info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | tail -n1 | awk '{print $1" free, "$2" used"}')"
    return 0
}

# ---------------------------------------------------------------- run

worst=0
daemon_section;  rc=$?; [ $rc -gt $worst ] && worst=$rc
timer_section;   rc=$?; [ $rc -gt $worst ] && worst=$rc
prune_now;       rc=$?; [ $rc -gt $worst ] && worst=$rc

if [ $CHANGED_DAEMON -eq 1 ]; then
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
        say "RESTART PENDING: daemon.json changed. It takes effect when Docker restarts or the host reboots; this component never restarts Docker. Log rotation applies to containers created after that."
    else
        say "daemon.json changed; Docker is not running, so it applies at next start."
    fi
fi

RESULT=$worst
if [ $worst -eq 0 ]; then say "Docker host maintenance: done."; fi
exit $worst
