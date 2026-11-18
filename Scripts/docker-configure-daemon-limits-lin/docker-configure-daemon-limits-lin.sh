#!/usr/bin/env bash
# Docker - Configure Daemon Limits [Lin]
#
# Datto RMM Scripts component. Runs as root. Adds log-rotation and build-cache
# limits to the Docker daemon's configuration, so that container logs and build
# cache stop growing without limit. It adds the keys that are missing and never
# changes a value that is already set.
#
# Changes on the host (usrMode Report changes nothing):
#   /etc/docker/daemon.json             log-rotation and build-cache keys that
#                                       are missing are added; no value that is
#                                       there is changed; the old file is kept
#                                       as daemon.json.tc-bak-<time> (the
#                                       newest 5 are kept)
# Nothing else. The expected-containers list, the prune and its timer belong to
# "Docker - Configure Host Maintenance [Lin]", which had this code up to its
# version 14.
# It never starts or restarts Docker: a daemon.json change waits for the next
# restart, and the output then says RESTART PENDING.
#
# Exit codes:
#   0  done, or nothing to do (also: Docker is not installed)
#   1  unexpected failure (daemon.json could not be replaced; the old file is
#      as it was)
#   2  an input variable is invalid; nothing was changed
#   3  something could not be applied safely and was left as it was (Docker
#      stopped, its start flags unknown, a daemon.json that is not valid JSON
#      or already stops Docker starting, the snap package, and more); the
#      output says what, and build-cache limits may still have been added
#
# How the file is merged and written, every input variable and every cause of
# exit 3:
# https://github.com/TechCollective/DattoRMM_Components/tree/main/Scripts/docker-configure-daemon-limits-lin

set -u
umask 022

DAEMON_JSON="/etc/docker/daemon.json"
RESULT=1
CHANGED_DAEMON=0
# The file that is renamed into place as daemon.json, while it exists. Removed
# on every way out of the daemon.json part, and by finish() if the run is
# stopped part-way.
DAEMON_STAGE=""
# The file a daemon.json write replaces: daemon.json, or the file it links to.
DAEMON_REAL="$DAEMON_JSON"

drop_daemon_stage() {
    if [ -n "$DAEMON_STAGE" ]; then rm -f -- "$DAEMON_STAGE"; fi
    DAEMON_STAGE=""
    return 0
}

finish() {
    local rc=$?
    drop_daemon_stage
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

# Trim surrounding whitespace a pasted value tends to carry.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
for v in usrMode usrLogMaxSize usrLogMaxFile usrBuildCacheReserved usrBuildCacheMax; do
    printf -v "$v" '%s' "$(trim "${!v}")"
done
usrMode="${usrMode,,}"
usrLogMaxSize="${usrLogMaxSize,,}"; usrBuildCacheReserved="${usrBuildCacheReserved^^}"
usrBuildCacheMax="${usrBuildCacheMax^^}"

case "$usrMode" in apply|report) ;; *) fail 2 "usrMode must be apply or report (got '$usrMode')." ;; esac

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

DOCKER="$DOCKER_BIN"

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

# The engine version from dockerd itself; only if that fails, from the daemon,
# and only when it is running, so asking never starts Docker.
ENGINE_VER="$(dockerd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
if [ -z "$ENGINE_VER" ] && tc_docker_running; then
    ENGINE_VER="$("$DOCKER_BIN" version --format '{{.Server.Version}}' 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
fi
ENGINE_MAJOR="${ENGINE_VER%%.*}"
say "Docker: $DOCKER_BIN, engine ${ENGINE_VER:-unknown}. Mode: $usrMode."

# ---------------------------------------------------------------- daemon.json

# daemon.json is not the whole of Docker's configuration: dockerd can also be
# given --log-driver, --log-opt and --config-file on its command line, by the
# systemd unit, a drop-in or an environment file. A daemon.json that clashes
# with those flags stops Docker at its next start, and dockerd --validate does
# not catch every clash (an unknown log opt for the flag's driver only fails a
# real start). So before merging, find out how the daemon is really started.
#
# Only a running dockerd is read: its own command line is what it was started
# with. With no dockerd running the flags are unknown (exit 3): log rotation is
# skipped, build-cache limits are still merged, and the next run with Docker
# running does the rest. (Host Maintenance, which had this code up to its
# version 14, worked a stopped Docker's flags out from docker.service, its
# drop-ins and its environment files up to its version 11; that was a second
# copy of systemd's own rules, and a guess wherever they differed.)
#
# Writes a JSON description to $1 and the daemon's logging flags, NUL
# separated, to $2 (for dockerd --validate). Prints one "daemon.json:" line.
# Exit: 0 flags known; 3 flags could not be determined with confidence;
#       5 the daemon reads a --config-file other than $DAEMON_JSON.
detect_daemon_flags() {
    python3 - "$DAEMON_JSON" "$1" "$2" "$DOCKER_BIN" <<'PY'
import json, os, shutil, subprocess, sys
target, out_json, out_args, docker = sys.argv[1:5]

class Unsure(Exception):
    pass

def run(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout, universal_newlines=True)
        return p.returncode, p.stdout
    except Exception:
        return 1, ""

def read(path):
    with open(path) as f:
        return f.read()

def is_host_root_dockerd(pid):
    # A root dockerd in this host's own PID namespace: not a rootless
    # per-user daemon, and not Docker-in-Docker inside a container.
    try:
        if read(f"/proc/{pid}/comm").strip() != "dockerd":
            return False
        if os.readlink(f"/proc/{pid}/ns/pid") != os.readlink("/proc/self/ns/pid"):
            return False
        for line in read(f"/proc/{pid}/status").splitlines():
            if line.startswith("Uid:"):
                return line.split()[1] == "0"
    except OSError:
        return False
    return False

systemd = os.path.isdir("/run/systemd/system") and shutil.which("systemctl")

def find_running_dockerd():
    if systemd:
        rc, o = run(["systemctl", "show", "docker.service", "-p", "MainPID", "--value"])
        o = o.strip()
        if rc == 0 and o.isdigit() and o != "0" and is_host_root_dockerd(o):
            return o
    try:
        p = read("/var/run/docker.pid").strip()
        if p.isdigit() and is_host_root_dockerd(p):
            return p
    except OSError:
        pass
    found = [d for d in os.listdir("/proc") if d.isdigit() and is_host_root_dockerd(d)]
    if len(found) > 1:
        raise Unsure(f"{len(found)} dockerd processes are running on this host")
    return found[0] if found else None

def parse_flags(args):
    driver, opts, cfg = None, [], None
    names = ("--log-driver", "--log-opt", "--config-file")
    i = 0
    while i < len(args):
        a, name, val = args[i], None, None
        if a == "--":
            break
        for n in names:
            if a == n:
                if i + 1 >= len(args):
                    raise Unsure(f"{n} is given without a value")
                name, val = n, args[i + 1]
                i += 1
                break
            if a.startswith(n + "="):
                name, val = n, a[len(n) + 1:]
                break
        i += 1
        if name == "--log-driver":
            driver = val
        elif name == "--log-opt":
            opts.append(val)
        elif name == "--config-file":
            cfg = val
    return driver, opts, cfg

det = {"known": False, "why": "", "stopped": False, "source": "", "driver_flag": None,
       "opt_keys": [], "config_file": None, "live_driver": None}
vargs = []
rc = 0
try:
    pid = find_running_dockerd()
    if not pid:
        det["stopped"] = True
        raise Unsure("Docker is not running, so its start flags cannot be read")
    try:
        raw = read(f"/proc/{pid}/cmdline")
    except OSError:
        raise Unsure(f"the command line of the running dockerd (pid {pid}) cannot be read")
    args = raw.split("\0")
    if args and args[-1] == "":
        args.pop()
    args = args[1:]
    det["source"] = f"the running dockerd, pid {pid}"
    # Safe to ask: a dockerd is running, so this cannot be what starts one.
    r, o = run([docker, "info", "--format", "{{.LoggingDriver}}"])
    if r == 0 and o.strip():
        det["live_driver"] = o.strip()
    driver, opts, cfg = parse_flags(args)
    det.update(known=True, driver_flag=driver, opt_keys=[o.split("=", 1)[0] for o in opts],
               config_file=cfg)
    if driver:
        vargs += ["--log-driver", driver]
    for o in opts:
        vargs += ["--log-opt", o]
    flags = []
    if driver:
        flags.append(f"--log-driver={driver}")
    if opts:
        flags.append("--log-opt " + ", ".join(det["opt_keys"]))
    if cfg:
        flags.append(f"--config-file={cfg}")
    said = "; ".join(flags) if flags else "no --log-driver, --log-opt or --config-file flag"
    print(f"daemon.json: Docker starts with {said} (read from {det['source']}).")
    if cfg and os.path.realpath(os.path.join("/", cfg)) != os.path.realpath(target):
        print(f"daemon.json: NOT CHANGED. Docker reads its configuration from {cfg}, not {target}, "
              f"so this component does not edit either file. Add these settings to {cfg} by hand if that host needs them.")
        rc = 5
except Unsure as e:
    det["why"] = str(e)
    print(f"daemon.json: could not tell which flags Docker starts with: {det['why']}.")
    rc = 3

with open(out_json, "w") as f:
    json.dump(det, f)
with open(out_args, "w") as f:
    f.write("".join(a + "\0" for a in vargs))
sys.exit(rc)
PY
}

merge_daemon_json() {
    # Prints the merged JSON on stdout and one "ADDED:"/"KEPT:"/"SKIPPED:" line
    # per decision on stderr. Never changes an existing value.
    # Exits 4, with one "CONFLICT:" line on stderr and nothing on stdout, when
    # the file ALREADY holds log-opts that stop this daemon starting.
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
with open(env["TC_DAEMON_DET"]) as f:
    det = json.load(f)

def note(kind, msg): print(f"{kind}: {msg}", file=sys.stderr)

# The log driver Docker will use at its next start: the flag wins, then this
# file, then whatever the running daemon reports, then Docker's default.
if det["driver_flag"]:
    driver, src = det["driver_flag"], "from the --log-driver flag"
elif data.get("log-driver"):
    driver, src = data["log-driver"], "from daemon.json"
elif det["live_driver"]:
    driver, src = det["live_driver"], "as the running daemon reports it"
else:
    driver, src = "json-file", "Docker's default"
rotates = driver in ("json-file", "local")

# A host an earlier version already broke: this file carries max-size or
# max-file, and the daemon's own flags mean it will refuse them.
opts_now = data.get("log-opts")
ours = [k for k in ("max-size", "max-file") if isinstance(opts_now, dict) and k in opts_now]
if ours and det["known"]:
    conflict = None
    if det["opt_keys"]:
        conflict = (f"daemon.json has log-opts ({', '.join(ours)}) and dockerd is also started with "
                    f"--log-opt ({', '.join(det['opt_keys'])}); Docker refuses log-opts set in both places")
    elif not rotates:
        # Name every key: Docker stops at whichever it checks first, so
        # removing only one would leave the next to fail.
        conflict = (f"daemon.json has log-opts {' and '.join(ours)}, but the log driver is {driver} ({src}), "
                    f"which does not accept {'them' if len(ours) > 1 else 'it'}")
    if conflict:
        print(f"CONFLICT: {conflict}", file=sys.stderr)
        sys.exit(4)

size, files = env.get("usrLogMaxSize", ""), env.get("usrLogMaxFile", "")
if size:
    if not det["known"]:
        note("SKIPPED", "log rotation: Docker's start flags could not be determined, so it cannot be "
                        "known whether Docker would accept log-opts in daemon.json"
                        + ("; run this component again while Docker is running" if det.get("stopped") else ""))
    elif det["opt_keys"]:
        note("SKIPPED", f"log rotation: dockerd is started with --log-opt ({', '.join(det['opt_keys'])}); "
                        "Docker will not start with log-opts both as a flag and in daemon.json")
    elif not rotates:
        note("SKIPPED", f"log rotation: log-driver is {driver} ({src}), which does not take max-size/max-file")
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

# Works out which file a write to daemon.json replaces, and sets DAEMON_REAL to
# it: daemon.json itself, or the regular file it is a symlink to (the link stays
# where it is). Returns 3, saying why and changing nothing, when daemon.json is
# a symlink that does not end at a regular file.
resolve_daemon_json() {
    DAEMON_REAL="$DAEMON_JSON"
    [ -L "$DAEMON_JSON" ] || return 0
    local real
    real="$(readlink -f -- "$DAEMON_JSON" 2>/dev/null)"
    if [ -z "$real" ]; then
        say "daemon.json: $DAEMON_JSON is a symbolic link that cannot be followed to an end (a loop, say); not touched."
        return 3
    fi
    if [ ! -e "$real" ]; then
        say "daemon.json: $DAEMON_JSON is a symbolic link to $real, which does not exist; not touched."
        return 3
    fi
    if [ ! -f "$real" ]; then
        say "daemon.json: $DAEMON_JSON is a symbolic link to $real, which is not a regular file; not touched."
        return 3
    fi
    DAEMON_REAL="$real"
    say "daemon.json: $DAEMON_JSON is a symbolic link to $real; changes go to that file and the link stays."
    return 0
}

# Removes the staging files a run that did not finish (a crash, a power cut)
# left beside daemon.json. One is 0600 and can hold the same proxy password as
# daemon.json itself. Looks in daemon.json's directory and the real file's.
sweep_daemon_stage() {
    local d f dirs=("$(dirname "$DAEMON_JSON")")
    [ "$(dirname "$DAEMON_REAL")" = "${dirs[0]}" ] || dirs+=("$(dirname "$DAEMON_REAL")")
    for d in "${dirs[@]}"; do
        for f in "$d"/.daemon.json.tc-*; do
            { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
            if rm -f -- "$f"; then
                say "daemon.json: removed $f, left by an earlier run that did not finish."
            fi
        done
    done
    return 0
}

# Keeps the newest 5 daemon.json.tc-bak-<14 digits>[-n] files and removes the
# rest. The name sorts by time (a same-second backup gets -n added), which is
# why it is sorted by name: cp -p gives a backup its source's mtime, not its
# own. A file that does not have that name, such as one saved by hand, is
# never counted or removed.
prune_daemon_backups() {
    local keep=5 f n=0 i=0 removed=0 re='\.tc-bak-[0-9]{14}(-[0-9]+)?$' sorted
    local -a all=()
    for f in "$DAEMON_JSON".tc-bak-*; do
        { [ -f "$f" ] && [ ! -L "$f" ] && [[ "$f" =~ $re ]]; } || continue
        all+=("$f"); n=$((n + 1))
    done
    [ "$n" -gt "$keep" ] || return 0
    sorted="$(printf '%s\n' "${all[@]}" | LC_ALL=C sort)"
    while IFS= read -r f; do
        i=$((i + 1))
        [ "$i" -le $((n - keep)) ] || break
        if rm -f -- "$f"; then removed=$((removed + 1)); else say "daemon.json: could not remove old backup $f."; fi
    done <<<"$sorted"
    say "daemon.json: kept the newest $keep backups, removed $removed older."
    return 0
}

# Replaces DAEMON_REAL with $1, the merged and validated JSON, so that Docker
# reads the old file or the new one and never a part-written one. The new file
# is made inside the directory of the real target (a rename there is one
# filesystem, so it is atomic), is 0600 until it holds the content, and then
# takes the mode, owner and group of the file it replaces (0644 root:root when
# there was none). Returns 0 when written, 1 when not, saying why; on 1 the
# existing file is exactly as it was. The staging file is DAEMON_STAGE and is
# removed by the caller on every way out.
write_daemon_json() {
    local src="$1" real="$DAEMON_REAL" dir st mode=644 uid=0 gid=0 base bak="" n=0 err
    dir="$(dirname "$real")"
    if ! mkdir -p -- "$dir"; then
        say "daemon.json: could not create $dir; not written."
        return 1
    fi
    if [ -f "$real" ]; then
        if ! st="$(stat -c '%a %u %g' -- "$real")" || ! read -r mode uid gid <<<"$st" \
           || ! [[ "$mode" =~ ^[0-7]+$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]]; then
            say "daemon.json: could not read the mode and owner of $real; not written, the existing file is unchanged."
            return 1
        fi
    fi

    DAEMON_STAGE="$(mktemp "$dir/.daemon.json.tc-XXXXXX")" || {
        DAEMON_STAGE=""
        say "daemon.json: could not create a temporary file in $dir; not written, the existing file is unchanged."
        return 1
    }
    # Compared after the copy: a full disk can leave a short file and an exit 0.
    if ! cat -- "$src" >"$DAEMON_STAGE" || ! cmp -s -- "$src" "$DAEMON_STAGE"; then
        say "daemon.json: could not write the new file in $dir (is the disk full?); not written, the existing file is unchanged."
        return 1
    fi
    if ! chown -- "$uid:$gid" "$DAEMON_STAGE" || ! chmod -- "$mode" "$DAEMON_STAGE"; then
        say "daemon.json: could not give the new file the mode and owner of $real; not written, the existing file is unchanged."
        return 1
    fi
    # Data to disk before the rename makes the new name visible. coreutils 8.24
    # and later take a file; older ones sync everything. Best effort.
    sync "$DAEMON_STAGE" >/dev/null 2>&1 || true

    if [ -f "$real" ]; then
        base="$DAEMON_JSON.tc-bak-$(date +%Y%m%d%H%M%S)"; bak="$base"
        while [ -e "$bak" ] || [ -L "$bak" ]; do n=$((n + 1)); bak="$base-$n"; done
        if ! cp -p -- "$real" "$bak"; then
            rm -f -- "$bak"
            say "daemon.json: could not save a backup of $real; not written, the existing file is unchanged."
            return 1
        fi
    fi
    if ! err="$(mv -f -- "$DAEMON_STAGE" "$real" 2>&1)"; then
        [ -z "$bak" ] || rm -f -- "$bak"      # nothing changed, so no backup is needed
        say "daemon.json: could not replace $real: ${err:-mv failed}. The existing file is unchanged."
        return 1
    fi
    DAEMON_STAGE=""
    if command -v restorecon >/dev/null 2>&1; then restorecon "$real" >/dev/null 2>&1 || true; fi
    [ -z "$bak" ] || say "daemon.json: previous file saved as $bak"
    return 0
}

daemon_section() {
    local rc
    daemon_section_run; rc=$?
    drop_daemon_stage
    return $rc
}

daemon_section_run() {
    if [ -z "$usrLogMaxSize" ] && [ -z "$usrBuildCacheMax" ]; then
        say "daemon.json: log rotation and build-cache limits both left blank; not touched."
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        say "daemon.json: python3 is not available, so the file cannot be merged safely; not touched."
        return 3
    fi
    resolve_daemon_json || return $?
    [ "$usrMode" = "report" ] || sweep_daemon_stage

    local tmp notes det vfile rc section_rc=0 a
    local -a vargs=()
    det="$(mktemp)"; vfile="$(mktemp)"
    detect_daemon_flags "$det" "$vfile"; rc=$?
    case $rc in
        0) ;;
        3) section_rc=3 ;;     # flags unknown (or Docker not running): log rotation is skipped below
        5) rm -f "$det" "$vfile"; return 3 ;;
        *) say "daemon.json: could not work out how Docker is started; not touched."
           rm -f "$det" "$vfile"; return 3 ;;
    esac
    while IFS= read -r -d '' a; do vargs+=("$a"); done <"$vfile"
    rm -f "$vfile"

    tmp="$(mktemp)"; notes="$(mktemp)"
    TC_DAEMON_DET="$det"
    export usrLogMaxSize usrLogMaxFile usrBuildCacheMax usrBuildCacheReserved ENGINE_MAJOR TC_DAEMON_DET
    merge_daemon_json >"$tmp" 2>"$notes"; rc=$?
    rm -f "$det"
    if [ $rc -eq 4 ]; then
        local conflict bak="" f
        conflict="$(sed -n 's/^CONFLICT: //p' "$notes" | head -n 1)"
        # The glob sorts, and the timestamp suffix sorts by time: last is newest.
        for f in "$DAEMON_JSON".tc-bak-*; do [ -e "$f" ] && bak="$f"; done
        say "DAEMON WILL NOT START: $conflict. Newest backup: ${bak:-none found (no $DAEMON_JSON.tc-bak-* file)}."
        say "daemon.json: NOT CHANGED. Docker fails at its next start or reboot until a person restores that backup or removes the conflicting setting."
        rm -f "$tmp" "$notes"; return 3
    fi
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
        rm -f "$tmp" "$notes"; return $section_rc
    fi
    if ! grep -q '^ADDED' "$notes"; then
        say "daemon.json: nothing to add; no change."
        rm -f "$tmp" "$notes"; return $section_rc
    fi

    if dockerd --help 2>/dev/null | grep -q -- '--validate'; then
        # With the daemon's own logging flags, so the check covers the
        # combination that will actually run.
        if ! dockerd --validate --config-file "$tmp" ${vargs[@]+"${vargs[@]}"} >/dev/null 2>"$notes"; then
            say "daemon.json: the merged file failed dockerd --validate; not written."
            # Flag values can carry a logging token; print the keys only.
            sed -e 's/map\[[^]]*\]/map[...]/g' -e 's/^/  /' "$notes" | tail -n 3
            rm -f "$tmp" "$notes"; return 3
        fi
        if [ ${#vargs[@]} -gt 0 ]; then
            say "daemon.json: merged file passes dockerd --validate with the daemon's logging flags."
        else
            say "daemon.json: merged file passes dockerd --validate."
        fi
    else
        say "daemon.json: this dockerd has no --validate; merged file checked as JSON only."
    fi

    if [ "$usrMode" = "report" ]; then
        say "daemon.json: REPORT MODE, would write the change above."
        rm -f "$tmp" "$notes"; return $section_rc
    fi

    # Not in report mode: that returned above, so nothing here has been made
    # in /etc/docker yet. $tmp, in $TMPDIR, is only where the merge was checked.
    if ! write_daemon_json "$tmp"; then
        rm -f "$tmp" "$notes"; return 1
    fi
    rm -f "$tmp" "$notes"
    CHANGED_DAEMON=1
    say "daemon.json: written."
    prune_daemon_backups
    return $section_rc
}

# ---------------------------------------------------------------- run

worst=0
daemon_section;  rc=$?; [ $rc -gt $worst ] && worst=$rc

if [ $CHANGED_DAEMON -eq 1 ]; then
    if tc_docker_running; then
        say "RESTART PENDING: daemon.json changed. It takes effect when Docker restarts or the host reboots; this component never restarts Docker. Log rotation applies to containers created after that."
    else
        say "daemon.json changed; Docker is not running, so it applies at next start."
    fi
fi

RESULT=$worst
if [ $worst -eq 0 ]; then say "Docker daemon limits: done."; fi
exit $worst
