#!/usr/bin/env bash
# Docker - Configure Host Maintenance [Lin]
#
# Datto RMM Scripts component. Runs as root.
#
# 1. Adds log rotation and build-cache limits to /etc/docker/daemon.json.
#    Only keys that are MISSING are added. An existing value is never changed,
#    so a host someone already tuned keeps its tuning. First it reads how the
#    daemon is really started, from the running dockerd's command line. Log
#    rotation is skipped when the daemon uses a driver that does not rotate,
#    is started with --log-opt, or its flags cannot be read. They cannot be
#    read while Docker is not running: build-cache limits are still added
#    then, and the next run with Docker running adds log rotation (exit 3
#    until it has). Nothing is written when the daemon reads a
#    --config-file other than /etc/docker/daemon.json, or when the file already
#    holds log-opts that will stop Docker starting ("DAEMON WILL NOT START").
#    The write is a same-directory rename, so Docker never reads a half-written
#    file; the file keeps its mode, owner and group (a new one is 0644
#    root:root); a symlinked daemon.json stays a symlink and its target is what
#    changes; and only the newest 5 daemon.json.tc-bak-* backups are kept.
# 2. Creates the host's expected-containers list, /etc/tc-docker/expected-containers,
#    from every container present now, running or stopped -- only if the list
#    does not exist yet. After that it never changes the list; "Docker -
#    Update Expected Containers [Lin]" does. A new list is NOT REVIEWED.
# 3. Installs a systemd timer that runs /usr/local/sbin/tc-docker-prune.
#    Until a person confirms the list (Update Expected Containers, Confirm
#    reviewed), the prune touches only unused networks and build cache:
#    no container and no image is removed. After review:
#    - a stopped container on the list, with an always/unless-stopped restart
#      policy, labelled tc.keep, or whose Compose labels are not plain names is
#      kept, with its image. Any other that has been stopped for
#      usrPruneOlderThanHours is first recorded in
#      /var/lib/tc-docker/pending-removal, and removed by a later run once it has
#      waited usrPruneGraceHours and is still stopped and unprotected. The
#      monitor reports what is waiting. If that file cannot be written, no
#      container is removed;
#    - images, by usrPruneImages: Dangling (the default) removes untagged images
#      only and makes no network call; All also removes a tagged image no
#      container uses, but only when its registry confirms, at that moment,
#      that it still has the image (a lookup with Docker's own client and
#      root's docker login, at most 100 lookups and 300 seconds a run). Never
#      forced; each tagged image removed is printed with the repo@sha256 its
#      registry confirmed.
#    If Docker does not return its container list, nothing at all is removed.
#    Never volumes.
#    The prune reads its three settings (OLDER_THAN_HOURS, GRACE_HOURS,
#    PRUNE_IMAGES) from /etc/default/tc-docker-prune as text. Nothing in that
#    file is run, and the prune checks each value again: with an
#    OLDER_THAN_HOURS that is not 24-8760 it removes nothing at all.
#    The installed prune carries its version (TC_PRUNE_VERSION=<the component's
#    version>) and prints it first, so a host's prune can be told apart from an
#    older one; the monitor "Docker - Containers Differ From Expected [Lin]"
#    flags a host whose prune is older than its PRUNE_MIN_VERSION.
# 4. Optionally runs that prune once, now.
#
# It never starts or restarts Docker. Before any docker command it asks whether
# Docker is running without waking it (systemd, where it manages
# docker.service), and a stopped Docker stays stopped: the prune's service has
# Requisite=docker.service, not Requires=. daemon.json changes take effect at
# the next Docker restart or reboot; the output says "RESTART PENDING" when that
# applies. The timer is restarted only when the timer unit itself changed.
#
# Exit codes:
#   0  done, or nothing to do (including: Docker is not installed)
#   1  unexpected failure (including daemon.json could not be replaced, for
#      example because it is immutable; the old file is then unchanged)
#   2  an input variable is invalid; nothing was changed
#   3  could not apply safely (no JSON tool, config failed validation,
#      Docker's start flags unknown, which includes Docker not running,
#      a --config-file elsewhere, daemon.json
#      already stops Docker starting, daemon.json is a symlink that does not
#      end at a regular file, no systemd, snap-packaged Docker, Docker
#      stopped or the daemon unreachable for the list or a prune-now, or the
#      daemon answered but did not return its container list, so the list was
#      not created); nothing was changed for that part

set -u
umask 022

DAEMON_JSON="/etc/docker/daemon.json"
UNIT_DIR="/etc/systemd/system"
UNIT_NAME="tc-docker-prune"
PRUNE_BIN="/usr/local/sbin/tc-docker-prune"
PRUNE_CONF="/etc/default/tc-docker-prune"
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
usrPruneSchedule="${usrPruneSchedule-Sun *-*-* 04:00:00}"
usrPruneOlderThanHours="${usrPruneOlderThanHours-168}"
usrPruneGraceHours="${usrPruneGraceHours-144}"
usrPruneImages="${usrPruneImages:-dangling}"
usrPruneNow="${usrPruneNow:-no}"

# Trim surrounding whitespace a pasted value tends to carry.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
for v in usrMode usrLogMaxSize usrLogMaxFile usrBuildCacheReserved usrBuildCacheMax \
         usrPruneSchedule usrPruneOlderThanHours usrPruneGraceHours usrPruneImages usrPruneNow; do
    printf -v "$v" '%s' "$(trim "${!v}")"
done
usrMode="${usrMode,,}"; usrPruneNow="${usrPruneNow,,}"; usrPruneImages="${usrPruneImages,,}"
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

# Written to the prune's settings whenever the prune is installed (a schedule or
# Prune now), as a plain decimal number, and checked again by the prune itself.
if [ -n "$usrPruneSchedule" ] || [ "$usrPruneNow" = "yes" ]; then
    [[ "$usrPruneOlderThanHours" =~ ^[0-9]{1,5}$ ]] && [ $((10#$usrPruneOlderThanHours)) -ge 24 ] \
        && [ $((10#$usrPruneOlderThanHours)) -le 8760 ] \
        || fail 2 "usrPruneOlderThanHours must be 24-8760 (got '$usrPruneOlderThanHours')."
    usrPruneOlderThanHours=$((10#$usrPruneOlderThanHours))
fi
if [ -n "$usrPruneSchedule" ]; then
    case "$usrPruneSchedule" in *[\;\&\|\`\$\<\>\\\"\']*|*$'\n'*)
        fail 2 "usrPruneSchedule contains characters a systemd calendar never needs." ;; esac
    if command -v systemd-analyze >/dev/null 2>&1 \
       && ! systemd-analyze calendar "$usrPruneSchedule" >/dev/null 2>&1; then
        fail 2 "usrPruneSchedule '$usrPruneSchedule' is not a systemd calendar expression."
    fi
fi
# The same goes for the wait and the image mode.
if [ -n "$usrPruneSchedule" ] || [ "$usrPruneNow" = "yes" ]; then
    [[ "$usrPruneGraceHours" =~ ^[0-9]{1,5}$ ]] && [ $((10#$usrPruneGraceHours)) -ge 24 ] \
        && [ $((10#$usrPruneGraceHours)) -le 8760 ] \
        || fail 2 "usrPruneGraceHours must be 24-8760 (got '$usrPruneGraceHours')."
    usrPruneGraceHours=$((10#$usrPruneGraceHours))
    case "$usrPruneImages" in dangling|all) ;; *) fail 2 "usrPruneImages must be dangling or all (got '$usrPruneImages')." ;; esac
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

# >>> tc-docker running: identical in Host Maintenance and the prune it installs; change them together.
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
# <<< tc-docker shared

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
# running does the rest. (Up to version 11 a stopped Docker's flags were worked
# out from docker.service, its drop-ins and its environment files; that was a
# second copy of systemd's own rules, and a guess wherever they differed.)
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

# ---------------------------------------------------------------- prune script

# The prune itself lives in one script on the host, so the weekly timer and a
# prune-now run exactly the same code, safety check included.
read -r -d '' PRUNE_SCRIPT <<'EOS'
#!/bin/bash
# tc-docker-prune -- installed by the Datto RMM component
# "Docker - Configure Host Maintenance [Lin]". Do not edit here; re-run the
# component. Settings: /etc/default/tc-docker-prune, read as text and never run.
TC_PRUNE_VERSION=12
# The line above is the version of the component that installed this script,
# and the first thing a run prints is that version, so the journal shows which
# prune ran. "Docker - Containers Differ From Expected [Lin]" reads it to flag
# a host whose prune is older than the monitor's PRUNE_MIN_VERSION. Keep it the
# only line starting TC_PRUNE_VERSION=, equal to "version" in component.json.
#
# Always removes, when older than OLDER_THAN_HOURS: unused networks and build
# cache. Before /etc/tc-docker/reviewed exists (a person confirmed the list) it
# removes no container and no image. After review:
#   - A stopped container is protected, and kept with its image, when it is on
#     /etc/tc-docker/expected-containers, has restart policy always or
#     unless-stopped, is labelled tc.keep, or its Compose labels are not plain
#     names. Any other stopped container that has been stopped for
#     OLDER_THAN_HOURS (State.FinishedAt; Created if it never ran) is first
#     RECORDED in /var/lib/tc-docker/pending-removal and left alone. A later run
#     removes it once it has been recorded for GRACE_HOURS and is still stopped,
#     unprotected and old enough; an entry for anything else is dropped. If the
#     file cannot be written, no container is removed and the exit is 1.
#   - Images, by PRUNE_IMAGES: "dangling" (the default) removes untagged images
#     only, and makes no network call; "all" also removes a tagged image, but
#     only when its registry confirms, now, that it still has one of the
#     image's repo@sha256 references. The lookup is made last, after every
#     local check has passed, with Docker's own client (docker buildx
#     imagetools inspect, else docker manifest inspect), so it uses root's
#     docker login; this script handles no credentials. Anything but a
#     confirmed yes keeps the image, with the reason: the registry does not
#     have it or refuses access, no answer in LOOKUP_TIMEOUT seconds, a network
#     error, a rate limit (which also ends all lookups for the run), or no
#     lookup tool. At most LOOKUP_MAX lookups and LOOKUP_SECONDS of lookups a
#     run; images not reached are kept as "not checked this run". None of
#     these makes the exit non-zero.
#     Never an image a container uses, one labelled tc.keep, or one younger than
#     OLDER_THAN_HOURS. Removed by reference, never forced, so Docker's own
#     in-use check is a second guard. Each tagged image removed is printed with
#     the repo@sha256 its registry confirmed, so it can be pulled again.
# If Docker does not return its container list, nothing at all is removed and
# the exit is 1. If the image list or the second container list cannot be read,
# no image is removed and the exit is 1. Never volumes. Exit: 0 done, 1 error.
# The three settings are checked here too: with an OLDER_THAN_HOURS that is not
# a whole number 24-8760 nothing at all is recorded or removed; with such a
# GRACE_HOURS no container is; with a PRUNE_IMAGES that is not dangling or all
# no image is. Each is an ERROR line and exit 1.
# With Docker stopped (systemd says docker.service is not active) it runs no
# docker command, says so in one line, removes nothing and exits 0.
set -u
echo "tc-docker-prune version $TC_PRUNE_VERSION"
# Tests may LOWER the lookup limits through the environment: a value here is
# only ever used to lower one. The settings file cannot set them at all.
TEST_LOOKUP_MAX="${TC_PRUNE_TEST_LOOKUP_MAX:-}"
TEST_LOOKUP_SECONDS="${TC_PRUNE_TEST_LOOKUP_SECONDS:-}"
PRUNE_CONF=/etc/default/tc-docker-prune
# The settings file is read as text and never run. A setting is a line
# NAME=value; for each of the three names below the last such line is used, with
# the default when there is none. Every other line is ignored (comments, blank
# lines, names this script does not know), so nothing in the file can run a
# command or set any other variable here. A file that is missing, or is not a
# regular file root can read, leaves all three defaults. What comes back is not
# trusted: each value is checked further down, before anything uses it.
setting() {  # name, default
    local line=""
    if [ -f "$PRUNE_CONF" ] && [ -r "$PRUNE_CONF" ]; then
        line="$(sed -n -e 's/[[:space:]]*$//' -e "s/^[[:space:]]*\\($1=\\)/\\1/p" "$PRUNE_CONF" 2>/dev/null | tail -n 1 | tr -d '\000')"
    fi
    if [ -n "$line" ]; then printf '%s' "${line#*=}"; else printf '%s' "$2"; fi
}
OLDER_THAN_HOURS="$(setting OLDER_THAN_HOURS 168)"
GRACE_HOURS="$(setting GRACE_HOURS 144)"
PRUNE_IMAGES="$(setting PRUNE_IMAGES dangling)"
PENDING_DIR=/var/lib/tc-docker
PENDING_FILE="$PENDING_DIR/pending-removal"

DOCKER="$(command -v docker)" || { echo "ERROR: docker not found"; exit 1; }

# >>> tc-docker running: identical in Host Maintenance and the prune it installs; change them together.
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

# Before any docker command: a stopped Docker stays stopped. Someone stopped it
# on purpose (a maintenance window, a move of its data directory), and any
# docker command would start it again through docker.socket.
tc_docker_running; up=$?
if [ "$up" -eq 1 ]; then
    echo "Docker is not running ($DOCKER_STATE): nothing was pruned, and Docker was left stopped."
    exit 0
fi
[ "$up" -eq 0 ] || { echo "ERROR: the Docker daemon is not reachable"; exit 1; }

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
# <<< tc-docker shared

root="$("$DOCKER" info --format '{{.DockerRootDir}}' 2>/dev/null)"; root="${root:-/}"
free() { df -h --output=avail,pcent "$root" 2>/dev/null | tail -n1 | awk '{print $1" free, "$2" used"}'; }
NOW="$(date +%s)"
expected=" $(tc_list "$EXPECTED_FILE" | tr '\n' ' ') "
errors=0
NL=$'\n'
when() { date -d "@$1" '+%Y-%m-%d %H:%M %Z'; }
# Seconds since the epoch for a time Docker printed, or status 1 when it is not
# one (an age that cannot be read means keep).
tc_epoch() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
    date -d "$1" +%s 2>/dev/null
}
# Printable, short: for echoing a setting that failed its check.
shown() { printf '%s' "$1" | tr -cd 'a-zA-Z0-9._ -' | cut -c1-20; }
# What a settings line has to look like, for the same messages: the file is not
# a shell file, so a value in quotes or with a comment after it is refused.
SETTING_FORM="A setting is one line, NAME=value, with no quotes and nothing after the value."

# The settings file is written by the component, but every value is checked
# again here, before it is used in any arithmetic: a hand edit must not shorten
# either wait or widen which images are removed.
OLDER_OK=1
if [[ "$OLDER_THAN_HOURS" =~ ^[0-9]{1,5}$ ]] && [ $((10#$OLDER_THAN_HOURS)) -ge 24 ] && [ $((10#$OLDER_THAN_HOURS)) -le 8760 ]; then
    OLDER_THAN_HOURS=$((10#$OLDER_THAN_HOURS))
else
    OLDER_OK=0
fi
GRACE_OK=1
if [[ "$GRACE_HOURS" =~ ^[0-9]{1,5}$ ]] && [ $((10#$GRACE_HOURS)) -ge 24 ] && [ $((10#$GRACE_HOURS)) -le 8760 ]; then
    GRACE_HOURS=$((10#$GRACE_HOURS))
else
    GRACE_OK=0
fi
IMAGES_OK=1
PRUNE_IMAGES="$(printf '%s' "${PRUNE_IMAGES:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[ -n "$PRUNE_IMAGES" ] || PRUNE_IMAGES=dangling
case "$PRUNE_IMAGES" in dangling|all) ;; *) IMAGES_OK=0 ;; esac
# Registry lookups (All mode only). The settings file cannot change these; a
# test can only lower the last two.
LOOKUP_TIMEOUT=20
LOOKUP_MAX=100
LOOKUP_SECONDS=300
[[ "$TEST_LOOKUP_MAX" =~ ^[0-9]{1,3}$ ]] && [ $((10#$TEST_LOOKUP_MAX)) -lt "$LOOKUP_MAX" ] \
    && LOOKUP_MAX=$((10#$TEST_LOOKUP_MAX))
[[ "$TEST_LOOKUP_SECONDS" =~ ^[0-9]{1,3}$ ]] && [ $((10#$TEST_LOOKUP_SECONDS)) -lt "$LOOKUP_SECONDS" ] \
    && LOOKUP_SECONDS=$((10#$TEST_LOOKUP_SECONDS))

# Everything this prune removes is chosen by its age, so without a usable
# OLDER_THAN_HOURS there is nothing it can safely record or remove.
if [ "$OLDER_OK" -eq 0 ]; then
    echo "ERROR: OLDER_THAN_HOURS in $PRUNE_CONF must be a whole number of hours, 24-8760 (it is '$(shown "$OLDER_THAN_HOURS")'). Every removal depends on it, so nothing is recorded or removed this run. $SETTING_FORM"
    exit 1
fi
cutoff=$(( NOW - OLDER_THAN_HOURS * 3600 ))

# Read the containers before anything is removed. If Docker does not answer,
# nothing is removed at all: an empty answer would look like "no containers".
if ! ROWS="$(tc_containers)"; then
    echo "ERROR: Docker did not return its container list (docker ps or docker inspect failed 3 times). Nothing was removed."
    exit 1
fi

echo "Pruning unused items older than ${OLDER_THAN_HOURS}h. Volumes are never removed."
echo "Disk before: $(free)"

REVIEWED=0; tc_reviewed && REVIEWED=1
if [ "$REVIEWED" -eq 0 ]; then
    echo "List not reviewed yet: no containers and no images are removed on this host."
    echo "Review $EXPECTED_FILE, then run Docker - Update Expected Containers [Lin] with Confirm reviewed."
    # A record made while the list was reviewed must not count towards the wait
    # after a later review: the wait starts again then.
    if [ -e "$PENDING_FILE" ] || [ -L "$PENDING_FILE" ]; then
        if rm -f -- "$PENDING_FILE" 2>/dev/null; then
            echo "Pending removals cleared: the list is not reviewed, so no container is waiting to be removed."
        else
            echo "ERROR: could not clear $PENDING_FILE."; errors=$((errors + 1))
        fi
    fi
fi
# A container whose Compose labels could not be read is never removed, and is
# named whatever its state, so someone looks at where it came from.
unreadable="$(printf '%s\n' "$ROWS" | awk -F'\t' '$2 ~ /^unreadable:/ {print "  " $3 " (" substr($1, 1, 12) ", " ($4 == "true" ? "running" : "stopped") ")"}')"
if [ -n "$unreadable" ]; then
    echo "WARNING: containers whose Compose labels are not plain names; they are never removed here:"
    printf '%s\n' "$unreadable"
fi

# ---- stopped containers: recorded first, removed GRACE_HOURS later

# The well-formed lines of the pending file (id, key, name, epoch first
# recorded; tab separated), then one "BAD<tab>n" line if n lines were not.
pending_lines() {
    { [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] && [ -r "$PENDING_FILE" ]; } || return 0
    awk -F'\t' -v OFS='\t' -v keyre="$KEY_RE" '
        /^#/ || /^[ \t]*$/ { next }
        NF == 4 && length($1) == 64 && $1 !~ /[^0-9a-f]/ && $2 ~ keyre && $3 ~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && $4 ~ /^[0-9]+$/ && length($4) <= 10 { print; next }
        { bad++ }
        END { if (bad) print "BAD", bad }' "$PENDING_FILE"
}

# Replaces the pending file with a header and $1 (lines ending in newlines):
# a new file in the same root-only directory, checked, then renamed over the
# old one. Returns 1, with PENDING_WHY set, when it cannot.
PENDING_WHY=""
pending_write() {
    local tmp body
    body="# Stopped containers that tc-docker-prune will remove. Written by the prune; do not edit.
# id<TAB>key<TAB>name<TAB>first recorded (seconds since 1970). The prune removes a
# container GRACE_HOURS after it first recorded it, if it is still stopped and
# unprotected then; otherwise the line is dropped. To keep one, add it to the
# expected list with Docker - Update Expected Containers [Lin] (Add).
$1"
    if [ -L "$PENDING_DIR" ] || { [ -e "$PENDING_DIR" ] && [ ! -d "$PENDING_DIR" ]; }; then
        PENDING_WHY="$PENDING_DIR is not a directory"; return 1
    fi
    if [ -L "$PENDING_FILE" ] || { [ -e "$PENDING_FILE" ] && [ ! -f "$PENDING_FILE" ]; }; then
        PENDING_WHY="$PENDING_FILE is not a regular file"; return 1
    fi
    local err
    if ! err="$(mkdir -p -- "$PENDING_DIR" 2>&1)"; then
        PENDING_WHY="${err:-mkdir failed}"; return 1
    fi
    if ! err="$( { chown 0:0 -- "$PENDING_DIR" && chmod 700 -- "$PENDING_DIR"; } 2>&1)"; then
        PENDING_WHY="$PENDING_DIR cannot be made root-only (0700): ${err:-failed}"; return 1
    fi
    if ! err="$(mktemp "$PENDING_DIR/.pending-removal.XXXXXX" 2>&1)"; then
        PENDING_WHY="${err:-no file can be created in $PENDING_DIR}"; return 1
    fi
    tmp="$err"
    # Compared after writing: a full disk can leave a short file.
    if ! printf '%s' "$body" >"$tmp" 2>/dev/null || [ "$(cat -- "$tmp")" != "$(printf '%s' "$body")" ] \
       || ! chmod 600 -- "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"; PENDING_WHY="writing it failed (is the disk full?)"; return 1
    fi
    if ! mv -fT -- "$tmp" "$PENDING_FILE" 2>/dev/null; then
        rm -f -- "$tmp"; PENDING_WHY="the new file could not be renamed into place"; return 1
    fi
    return 0
}

kept=(); recorded=(); waiting=(); due=(); removed=(); removed_ids=()
CONTAINERS=0
if [ "$REVIEWED" -eq 1 ]; then
    if [ "$GRACE_OK" -eq 1 ]; then
        CONTAINERS=1
    else
        echo "ERROR: GRACE_HOURS in /etc/default/tc-docker-prune must be a whole number of hours, 24-8760 (it is '$(shown "$GRACE_HOURS")'). No container is recorded or removed this run. $SETTING_FORM"
        errors=$((errors + 1))
    fi
fi
if [ "$CONTAINERS" -eq 1 ]; then
    declare -A PEND_AT=() PEND_KEY=() PEND_NAME=()
    pend="$(pending_lines)"
    pend_bad=0
    while IFS=$'\t' read -r pid pkey pname pat; do
        if [ "$pid" = "BAD" ]; then pend_bad="$pkey"; continue; fi
        [ "${#pid}" -eq 64 ] || continue
        [ -z "${PEND_AT[$pid]:-}" ] || continue        # the first line for an id wins
        PEND_AT[$pid]=$((10#$pat)); PEND_KEY[$pid]="$pkey"; PEND_NAME[$pid]="$pname"
    done <<<"$pend"
    [ "$pend_bad" = 0 ] || echo "WARNING: $PENDING_FILE had $pend_bad unreadable line(s); they are not trusted and are dropped."

    grace=$(( GRACE_HOURS * 3600 ))
    new_pending=""
    while IFS=$'\t' read -r id key name running policy created _started keep _transient; do
        [ -n "$id" ] || continue
        [ "$running" = "true" ] && continue
        why=""
        case "$key" in unreadable:*) why="Compose labels unreadable, never removed" ;; esac
        case "$expected" in *" $key "*) why="${why:-on the expected list}" ;; esac
        case "$policy" in always|unless-stopped) why="${why:-restart policy $policy}" ;; esac
        [ "$keep" = "y" ] && why="${why:-labelled tc.keep}"
        if [ -n "$why" ]; then kept+=("$name ($why)"); continue; fi
        # Its age is from when it stopped; one that never ran counts from when
        # it was created. Read here, for candidates only. Unreadable: keep.
        fin="$("$DOCKER" container inspect -f '{{.State.FinishedAt}}' "$id" 2>/dev/null)" || continue
        case "$fin" in 0001-01-01T00:00:00*) fin="$created" ;; esac
        t="$(tc_epoch "$fin")" || continue
        [ "$t" -lt "$cutoff" ] || continue
        if [ -n "${PEND_AT[$id]:-}" ] && [ "${PEND_KEY[$id]}" = "$key" ] && [ "${PEND_NAME[$id]}" = "$name" ]; then
            at="${PEND_AT[$id]}"
            if [ $(( NOW - at )) -ge "$grace" ]; then
                due+=("$id"$'\t'"$name"$'\t'"$key")
            else
                waiting+=("$name ($key), recorded $(when "$at"), can be removed from $(when $(( at + grace )))")
            fi
        else
            at="$NOW"
            recorded+=("$name ($key), can be removed from $(when $(( at + grace )))")
        fi
        new_pending="${new_pending}${id}"$'\t'"${key}"$'\t'"${name}"$'\t'"${at}"$'\n'
    done <<<"$ROWS"

    # The record comes first. Without it nothing is removed: a removal nobody
    # could see coming is what the wait exists to prevent.
    if ! pending_write "$new_pending"; then
        echo "ERROR: could not write $PENDING_FILE: $PENDING_WHY. No container was removed this run."
        errors=$((errors + 1))
        [ "${#recorded[@]}" -eq 0 ] || echo "Not recorded, so not waiting yet: ${#recorded[@]} stopped container(s)."
        recorded=(); waiting=(); due=()
    fi
    for d in ${due[@]+"${due[@]}"}; do
        IFS=$'\t' read -r id name key <<<"$d"
        if "$DOCKER" rm "$id" >/dev/null 2>&1; then
            removed+=("$name ($key)"); removed_ids+=("$id")
        else
            echo "WARNING: could not remove stopped container $name"; errors=$((errors + 1))
        fi
    done
    if [ "${#removed_ids[@]}" -gt 0 ]; then
        rest="$(printf '%s' "$new_pending" | grep -vF -f <(printf '%s\n' "${removed_ids[@]}"))"
        if ! pending_write "${rest:+$rest$NL}"; then
            echo "ERROR: could not update $PENDING_FILE after removing containers: $PENDING_WHY. The next run drops the lines of containers that are gone."
            errors=$((errors + 1))
        fi
    fi

    if [ "${#recorded[@]}" -gt 0 ]; then
        echo "Stopped containers recorded for removal this run (removed ${GRACE_HOURS}h from now if still stopped and not protected):"
        printf '  %s\n' "${recorded[@]}"
    fi
    if [ "${#waiting[@]}" -gt 0 ]; then
        echo "Stopped containers waiting to be removed:"
        printf '  %s\n' "${waiting[@]}"
    fi
    echo "Stopped containers removed: ${#removed[@]}"
    [ "${#removed[@]}" -eq 0 ] || printf '  %s\n' "${removed[@]}"
fi
if [ "${#kept[@]}" -gt 0 ]; then
    echo "Stopped containers kept, with their images:"
    printf '  %s\n' "${kept[@]}"
fi

# ---- images

# One line per image, tab separated, every field non-empty ("-" for none):
#   id  tags  names  digests  created  readable(y/n)
# tags are its repo:tag names; names every name it has (the tags, plus any
# repo@sha256 name the containerd image store keeps), which is what removing it
# takes; digests its repo@sha256 references. All three are space separated.
# They are read JSON-encoded, so nothing in an image can add a row or a field,
# and each must look like a reference; when any does not, readable is n and all
# three are "-". Returns 1 when docker image ls or docker image inspect fails
# three times.
image_rows() {
    local try ids dangling out
    for try in 1 2 3; do
        [ "$try" -gt 1 ] && sleep 1
        # Top-level images, plus the untagged ones a newer docker image ls hides.
        # Not -a: that adds the classic builder's intermediate layers, which are
        # untagged but belong to an image that is still there.
        ids="$("$DOCKER" image ls -q --no-trunc 2>"${DOCKER_ERR:-/dev/null}")" || continue
        dangling="$("$DOCKER" image ls -q --no-trunc --filter dangling=true 2>"${DOCKER_ERR:-/dev/null}")" || continue
        ids="$(printf '%s\n%s\n' "$ids" "$dangling" | sort -u | grep -v '^$')"
        [ -n "$ids" ] || return 0
        out="$(printf '%s\n' "$ids" | xargs "$DOCKER" image inspect -f \
'{{.Id}}{{"\t"}}{{json .RepoTags}}{{"\t"}}{{json .RepoDigests}}{{"\t"}}{{.Created}}' 2>"${DOCKER_ERR:-/dev/null}")" || continue
        printf '%s\n' "$out" | awk -F'\t' -v OFS='\t' '
            function digest_ok(r,   p, h) {
                p = index(r, "@sha256:"); if (p < 2) return 0
                h = substr(r, p + 8)
                return length(h) == 64 && h !~ /[^0-9a-f]/ && substr(r, 1, p - 1) !~ /@/
            }
            function add(l, r) { return l (l == "" ? "" : " ") r }
            function has(l, r) { return index(" " l " ", " " r " ") > 0 }
            function dash(l)   { return l == "" ? "-" : l }
            # Adds the references in JSON array v (RepoTags when from_tags) to
            # T, N and D. Returns 0 when any of them is not a plain reference.
            function take(v, from_tags,   s, n, a, i) {
                if (v == "null" || v == "[]") return 1
                if (v !~ /^\[".*"\]$/) return 0
                s = substr(v, 3, length(v) - 4); n = split(s, a, "\",\"")
                for (i = 1; i <= n; i++) {
                    if (a[i] !~ /^[a-zA-Z0-9][a-zA-Z0-9._\/:@-]*$/) return 0
                    if (a[i] ~ /@/) {
                        if (!digest_ok(a[i])) return 0
                        if (!has(D, a[i])) D = add(D, a[i])
                        if (from_tags) N = add(N, a[i])
                    } else {
                        if (!from_tags || a[i] !~ /:/) return 0
                        T = add(T, a[i]); N = add(N, a[i])
                    }
                }
                return 1
            }
            NF != 4 || length($1) != 71 || substr($1, 1, 7) != "sha256:" || substr($1, 8) ~ /[^0-9a-f]/ { next }
            {
                T = ""; N = ""; D = ""
                ok = take($2, 1) && take($3, 0)
                if (!ok) { T = ""; N = ""; D = "" }
                print $1, dash(T), dash(N), dash(D), dash($4), (ok ? "y" : "n")
            }'
        return 0
    done
    return 1
}

# The ids of the images labelled tc.keep, tagged or not, one per line, as
# Docker's own label filter finds them. (Not read from docker image inspect:
# how an image's labels can be addressed in a template differs between Docker
# versions, and an image with none has no Labels at all on some.) Returns 1
# when the list cannot be read.
keep_images() {
    local tagged untagged
    tagged="$("$DOCKER" image ls -q --no-trunc --filter label=tc.keep 2>"${DOCKER_ERR:-/dev/null}")" || return 1
    untagged="$("$DOCKER" image ls -q --no-trunc --filter dangling=true --filter label=tc.keep 2>"${DOCKER_ERR:-/dev/null}")" || return 1
    printf '%s\n%s\n' "$tagged" "$untagged" | sort -u | grep -v '^$'
    return 0
}

# The image ids every container uses, running or stopped, one per line.
# Returns 1 when the list cannot be read.
used_images() {
    local try ids out
    for try in 1 2 3; do
        [ "$try" -gt 1 ] && sleep 1
        ids="$("$DOCKER" ps -aq --no-trunc 2>/dev/null)" || continue
        [ -n "$ids" ] || return 0
        out="$(printf '%s\n' "$ids" | xargs "$DOCKER" container inspect -f '{{.Image}}' 2>"${DOCKER_ERR:-/dev/null}")" || continue
        printf '%s\n' "$out" | awk 'length($0) == 71 && substr($0, 1, 7) == "sha256:" && substr($0, 8) !~ /[^0-9a-f]/ { print; next } { bad = 1 } END { exit bad }' \
            || { [ -z "$DOCKER_ERR" ] || echo "a container's image is not an image id" >"$DOCKER_ERR"; return 1; }
        return 0
    done
    return 1
}

# The last thing Docker printed on stderr in image_rows or used_images, made
# printable and short, for the ERROR line when one of them fails.
DOCKER_ERR="$(mktemp 2>/dev/null)" || DOCKER_ERR=""
trap '[ -z "$DOCKER_ERR" ] || rm -f -- "$DOCKER_ERR"' EXIT
docker_said() {
    local m
    [ -n "$DOCKER_ERR" ] || return 0
    m="$(tail -n 1 "$DOCKER_ERR" 2>/dev/null | tr -cd '[:print:]' | cut -c1-200)"
    [ -z "$m" ] || printf ' Docker said: %s' "$m"
}

# ---- registry lookups (PRUNE_IMAGES=all only)

LOOKUP_TOOL=""   # buildx, manifest or none, once lookup_setup has run
LOOKUP_STOP=""   # why no more lookups are made this run, once that is so
LOOKUP_NOTE=""   # how the lookups reach the registry, for the output
LOOKUPS=0        # lookups made
LOOKUP_USED=0    # milliseconds spent in them
now_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null)"
    [[ "$t" =~ ^[0-9]+$ ]] || t=$(( $(date +%s) * 1000 ))
    printf '%s' "$t"
}

# Picks the lookup tool and sets up its environment, once, when the first
# tagged image has passed every local check. Credentials: Docker's client reads
# them from root's docker login ($DOCKER_CONFIG, else this user's home in
# /etc/passwd, so the timer, a Datto job and a shell all find the same file).
# Proxy: the client does not use the daemon's proxy on its own, so when this
# process has none, the daemon's (from docker info) is used for the lookups.
lookup_setup() {
    local home p hp hsp np ok=1
    [ -z "$LOOKUP_TOOL" ] || return 0
    if ! command -v timeout >/dev/null 2>&1; then
        LOOKUP_TOOL=none; LOOKUP_STOP="this host has no timeout command, which every lookup needs"; return 0
    fi
    # By the help each command prints: without the plugin, docker prints its
    # own help for "docker buildx ... --help" and still exits 0.
    if "$DOCKER" buildx version >/dev/null 2>&1 \
       && "$DOCKER" buildx imagetools inspect --help 2>&1 | grep -q -e '--raw'; then LOOKUP_TOOL=buildx
    elif "$DOCKER" manifest inspect --help 2>&1 | grep -q -e '--insecure'; then LOOKUP_TOOL=manifest
    else
        LOOKUP_TOOL=none; LOOKUP_STOP="neither docker buildx imagetools nor docker manifest works on this host, so no registry can be asked"; return 0
    fi
    if [ -z "${DOCKER_CONFIG:-}" ]; then
        home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
        [ -n "$home" ] || home="${HOME:-/root}"
        export DOCKER_CONFIG="$home/.docker"
    fi
    if [ -z "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ]; then
        # One per line: an empty one must not shift the others.
        p="$("$DOCKER" info --format '{{.HTTPProxy}}{{"\n"}}{{.HTTPSProxy}}{{"\n"}}{{.NoProxy}}' 2>/dev/null)" || p=""
        { IFS= read -r hp; IFS= read -r hsp; IFS= read -r np; } <<<"$p"
        if [ -n "$hp$hsp" ]; then
            for p in "$hp" "$hsp" "$np"; do
                [[ "$p" =~ ^[A-Za-z0-9._:/@%+,*=-]*$ ]] || ok=0
            done
            case "$hp$hsp" in *xxxxx*) ok=2 ;; esac
            if [ "$ok" -eq 1 ]; then
                [ -z "$hp" ] || export HTTP_PROXY="$hp"
                [ -z "$hsp" ] || export HTTPS_PROXY="$hsp"
                [ -z "$np" ] || export NO_PROXY="$np"
                LOOKUP_NOTE="through the Docker daemon's proxy"
            elif [ "$ok" -eq 2 ]; then
                LOOKUP_NOTE="without a proxy: the Docker daemon's proxy has a password docker info does not show"
            else
                LOOKUP_NOTE="without a proxy: the Docker daemon's proxy setting is not a plain URL"
            fi
        fi
    else
        LOOKUP_NOTE="through this process's own proxy setting"
    fi
    return 0
}

# Asks the image's registry whether it has reference $1 (repo@sha256:<digest>,
# already checked by image_rows). Sets LOOKUP_RESULT to one of:
#   yes      the registry returned that manifest
#   no       the registry says it does not have it
#   refused  the registry refused access (no login here, or the wrong one)
#   timeout  no answer within the time left for this lookup
#   ratelimit  429 Too Many Requests / toomanyrequests; no more lookups this run
#   error    anything else (network, TLS, an answer not understood)
#   skipped  not asked: no lookup tool, or a limit or rate limit already hit
# and LOOKUP_MSG to a short printable reason.
lookup_ref() {
    local ref="$1" out rc left t t0 last
    LOOKUP_RESULT=skipped; LOOKUP_MSG=""
    [ -z "$LOOKUP_STOP" ] || return 0
    if [ "$LOOKUPS" -ge "$LOOKUP_MAX" ]; then
        LOOKUP_STOP="the limit of $LOOKUP_MAX registry lookups a run was reached"; return 0
    fi
    left=$(( LOOKUP_SECONDS * 1000 - LOOKUP_USED ))
    if [ "$left" -le 0 ]; then
        LOOKUP_STOP="the $LOOKUP_SECONDS seconds of registry lookups a run were used"; return 0
    fi
    t=$(( (left + 999) / 1000 )); [ "$t" -le "$LOOKUP_TIMEOUT" ] || t=$LOOKUP_TIMEOUT
    LOOKUPS=$((LOOKUPS + 1))
    t0="$(now_ms)"
    if [ "$LOOKUP_TOOL" = buildx ]; then
        out="$(timeout -k 5 "$t" "$DOCKER" buildx imagetools inspect --raw "$ref" 2>&1 </dev/null)"; rc=$?
    else
        out="$(timeout -k 5 "$t" "$DOCKER" manifest inspect "$ref" 2>&1 </dev/null)"; rc=$?
    fi
    LOOKUP_USED=$(( LOOKUP_USED + $(now_ms) - t0 ))
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '"schemaVersion"'; then
        LOOKUP_RESULT=yes; return 0
    fi
    # The cause is at the end of Docker's message, so that end is kept.
    last="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -cd '[:print:]' \
        | sed -E 's#"https?://[^"]*"#(registry URL)#g')"
    last="${last#ERROR: }"
    [ "${#last}" -le 160 ] || last="...${last: -160}"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        LOOKUP_RESULT=timeout; LOOKUP_MSG="no answer within ${t}s"
    elif printf '%s\n' "$out" | grep -qiF -e '429 Too Many Requests' -e 'toomanyrequests'; then
        LOOKUP_RESULT=ratelimit; LOOKUP_MSG="the registry is rate-limiting: $last"
        LOOKUP_STOP="a registry rate-limited a lookup"
    elif printf '%s\n' "$out" | grep -qiE '401 Unauthorized|403 Forbidden|unauthorized|denied|no basic auth credentials|authentication required'; then
        LOOKUP_RESULT=refused; LOOKUP_MSG="the registry refused access: $last"
    elif printf '%s\n' "$out" | grep -qF -e "$ref: not found"; then
        LOOKUP_RESULT=no
    elif printf '%s\n' "$out" | grep -qiE 'manifest unknown|no such manifest'; then
        LOOKUP_RESULT=no
    else
        LOOKUP_RESULT=error; LOOKUP_MSG="${last:-the lookup failed (exit $rc)}"
    fi
    return 0
}

image_section() {
    local used keepers rows id tags names digs created readable short t ref ok n_tagged=0
    local found why unsure skipped
    local n_removed=0 n_absent=0 n_unsure=0 n_unchecked=0
    local -a img_removed=() img_kept=()
    if [ "$IMAGES_OK" -eq 0 ]; then
        echo "ERROR: PRUNE_IMAGES in /etc/default/tc-docker-prune must be dangling or all (it is '$(shown "$PRUNE_IMAGES")'). No image was removed. $SETTING_FORM"
        errors=$((errors + 1)); return
    fi
    # After the containers above were removed, so an image they used can go.
    if ! used="$(used_images)"; then
        echo "ERROR: Docker did not return its container list for the image check. No image was removed.$(docker_said)"
        errors=$((errors + 1)); return
    fi
    if ! keepers="$(keep_images)"; then
        echo "ERROR: Docker did not return its image list (the images labelled tc.keep: docker image ls failed). No image was removed.$(docker_said)"
        errors=$((errors + 1)); return
    fi
    if ! rows="$(image_rows)"; then
        echo "ERROR: Docker did not return its image list (docker image ls or docker image inspect failed 3 times). No image was removed.$(docker_said)"
        errors=$((errors + 1)); return
    fi
    while IFS=$'\t' read -r id tags names digs created readable; do
        [ -n "$id" ] || continue
        short="${id#sha256:}"; short="${short:0:12}"
        if [ "$readable" != "y" ]; then
            img_kept+=("$short - its tags or digests are not plain references, so it is never removed here"); continue
        fi
        case $'\n'"$keepers"$'\n' in *$'\n'"$id"$'\n'*) continue ;; esac  # labelled tc.keep
        case $'\n'"$used"$'\n' in *$'\n'"$id"$'\n'*) continue ;; esac  # a container uses it
        t="$(tc_epoch "$created")" || continue                        # age unknown: keep
        [ "$t" -lt "$cutoff" ] || continue                            # too new
        if [ "$tags" = "-" ]; then
            # Untagged: by its id, or by the repo@sha256 names it still has.
            # Never --force, so Docker refuses if anything uses it.
            ok=1
            [ "$names" != "-" ] || names="$id"
            for ref in $names; do
                "$DOCKER" image rm "$ref" >/dev/null 2>&1 || { ok=0; echo "WARNING: could not remove untagged image $short"; errors=$((errors + 1)); break; }
            done
            if [ "$ok" -eq 1 ]; then
                if [ "$digs" = "-" ]; then img_removed+=("untagged $short")
                else img_removed+=("untagged $short - pull again: $digs"); fi
            fi
            continue
        fi
        if [ "$PRUNE_IMAGES" = "dangling" ]; then n_tagged=$((n_tagged + 1)); continue; fi
        # All: every local check has passed. Removed only if its registry
        # confirms, now, that it has one of the image's repo@sha256 references.
        if [ "$digs" = "-" ]; then
            n_absent=$((n_absent + 1))
            img_kept+=("$tags - no registry digest: built or loaded on this host, so there is nothing to look up"); continue
        fi
        lookup_setup
        found=""; why=""; unsure=0; skipped=0
        for ref in $digs; do
            lookup_ref "$ref"
            case "$LOOKUP_RESULT" in
                yes)     found="$ref"; break ;;
                no)      why="${why:+$why; }its registry does not have $ref" ;;
                skipped) skipped=1; break ;;
                *)       unsure=1; why="${why:+$why; }could not check $ref: $LOOKUP_MSG" ;;
            esac
        done
        if [ -z "$found" ]; then
            if [ "$LOOKUP_TOOL" = none ]; then
                n_unsure=$((n_unsure + 1)); img_kept+=("$tags - could not check: $LOOKUP_STOP")
            elif [ "$unsure" -eq 1 ]; then
                n_unsure=$((n_unsure + 1)); img_kept+=("$tags - $why")
            elif [ "$skipped" -eq 1 ]; then
                n_unchecked=$((n_unchecked + 1)); img_kept+=("$tags - not checked this run: $LOOKUP_STOP${why:+ ($why)}")
            else
                n_absent=$((n_absent + 1)); img_kept+=("$tags - $why")
            fi
            continue
        fi
        # Each name in turn, without --force; the last one removes the image.
        ok=1
        for ref in $names; do
            "$DOCKER" image rm "$ref" >/dev/null 2>&1 || { ok=0; echo "WARNING: could not remove image $ref"; errors=$((errors + 1)); break; }
        done
        if [ "$ok" -eq 1 ]; then
            n_removed=$((n_removed + 1)); img_removed+=("$tags - its registry has it, pull again: $found")
        fi
    done <<<"$rows"

    echo "Images removed (PRUNE_IMAGES=$PRUNE_IMAGES): ${#img_removed[@]}"
    [ "${#img_removed[@]}" -eq 0 ] || printf '  %s\n' "${img_removed[@]}"
    if [ "${#img_kept[@]}" -gt 0 ]; then
        echo "Images kept that no container uses:"
        printf '  %s\n' "${img_kept[@]}"
    fi
    [ "$n_tagged" -eq 0 ] || echo "Images kept: $n_tagged tagged image(s) that no container uses (PRUNE_IMAGES=dangling removes untagged images only)."
    if [ "$PRUNE_IMAGES" = "all" ]; then
        echo "Tagged images, registry check: removed $n_removed, kept (registry does not have it) $n_absent, kept (could not check) $n_unsure, not checked this run $n_unchecked. Lookups made: $LOOKUPS${LOOKUP_NOTE:+, $LOOKUP_NOTE}."
        [ -z "$LOOKUP_STOP" ] || [ "$LOOKUP_TOOL" = none ] || echo "Registry lookups stopped: $LOOKUP_STOP."
    fi
}
[ "$REVIEWED" -eq 1 ] && image_section

step() {  # label, then the prune command
    local label="$1" out; shift
    if out="$("$@" 2>&1)"; then
        local r n
        r="$(printf '%s\n' "$out" | grep -iE '^total' | tail -n1 | sed -E 's/^Total( reclaimed space)?:[[:space:]]*//')"
        n="$(printf '%s\n' "$out" | grep -vciE '^(deleted|total|untagged:|$)' || true)"
        if [ -n "$r" ]; then echo "$label: $r reclaimed"
        elif [ "$n" -gt 0 ]; then echo "$label: $n removed"
        else echo "$label: nothing to remove"; fi
    else
        echo "ERROR: $label failed: $(printf '%s\n' "$out" | tail -n1)"; errors=$((errors + 1))
    fi
}
step "Networks"    "$DOCKER" network prune --force --filter "until=${OLDER_THAN_HOURS}h"
step "Build cache" "$DOCKER" builder prune --all --force --filter "until=${OLDER_THAN_HOURS}h"

echo "Disk after:  $(free)"
[ "$errors" -eq 0 ] || exit 1
exit 0
EOS

# Writes $2 to $1 (mode $3) if it differs. Sets WROTE=1 when it did, or would.
WROTE=0
put_file() {
    local path="$1" content="$2" mode="$3"
    if [ -f "$path" ] && [ "$(cat "$path")" = "${content%$'\n'}" ]; then
        return 0
    fi
    WROTE=1
    [ "$usrMode" = "apply" ] || return 0
    mkdir -p "$(dirname "$path")" || return 1
    printf '%s\n' "${content%$'\n'}" >"$path.tmp" && chmod "$mode" "$path.tmp" \
        && mv -f "$path.tmp" "$path" || return 1
}

install_prune_script() {
    local conf
    conf="# Written by the Datto RMM component \"Docker - Configure Host Maintenance [Lin]\".
# Re-run the component to change these; edits here are overwritten.
OLDER_THAN_HOURS=$usrPruneOlderThanHours
GRACE_HOURS=$usrPruneGraceHours
PRUNE_IMAGES=$usrPruneImages"
    put_file "$PRUNE_BIN"  "$PRUNE_SCRIPT" 755 || return 1
    put_file "$PRUNE_CONF" "$conf"         644 || return 1
}

# ---------------------------------------------------------------- expected list

# Names the containers whose Compose labels could not be read ($1, one per line).
report_unreadable() {
    [ -n "$1" ] || return 0
    say "Expected list: $2 - Compose labels are not plain names, so these have no key to list:"
    printf '%s\n' "$1" | sed 's/^/  /'
}

# Creates /etc/tc-docker/expected-containers from what is running, ONLY when
# it does not exist. It is never rewritten here afterwards: a list that
# re-seeded itself would accept whatever turned up and stop meaning anything.
seed_section() {
    if [ -e "$EXPECTED_FILE" ]; then
        say "Expected list: $EXPECTED_FILE exists ($(tc_list "$EXPECTED_FILE" | wc -l) entries); not changed. Use Docker - Update Expected Containers [Lin] to change it."
        if tc_reviewed; then say "Expected list: reviewed ($(head -n1 "$REVIEWED_FILE"))."
        else say "Expected list: NOT REVIEWED. Until someone confirms it, the prune removes no containers or images here."; fi
        return 0
    fi
    local up
    tc_docker_running; up=$?
    if [ "$up" -eq 1 ]; then
        say "Expected list: Docker is not running ($DOCKER_STATE), so the list was not created and Docker was left stopped; the next run will try again."
        return 3
    elif [ "$up" -ne 0 ]; then
        say "Expected list: the Docker daemon is not reachable, so the list was not created; the next run will try again."
        return 3
    fi
    local rows keys old unreadable
    # Docker answered "info" but not the listing: an empty list now would be
    # read later as "this host runs nothing". Leave it for the next run.
    if ! rows="$(tc_containers)"; then
        say "Expected list: Docker did not return its container list, so the list was not created; the next run will try again."
        return 3
    fi
    # Every container present, running or stopped: one that exists when we take
    # a host on is assumed wanted until a person says otherwise.
    keys="$(printf '%s\n' "$rows" | awk -F'\t' '$9 == "n" {print $2}')"
    # A container whose Compose labels cannot be read has no key to list.
    unreadable="$(printf '%s\n' "$rows" | awk -F'\t' '$2 ~ /^unreadable:/ {print $3 " (" substr($1, 1, 12) ")"}')"
    # Carry over names from the version 2 setting, if this host had one.
    old="$(sed -n 's/^REQUIRED_CONTAINERS="\(.*\)"$/\1/p' /etc/default/tc-docker-prune 2>/dev/null)"
    for n in $old; do
        [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] && keys="$keys"$'\n'"name:$n"
    done
    keys="$(printf '%s\n' "$keys" | grep -E "$KEY_RE" | sort -u)"
    local count; count="$(printf '%s\n' "$keys" | grep -c . || true)"

    if [ "$usrMode" = "report" ]; then
        say "Expected list: REPORT MODE, would create $EXPECTED_FILE with $count entries:"
        [ "$count" -gt 0 ] && printf '%s\n' "$keys" | sed 's/^/  /'
        report_unreadable "$unreadable" "would be left off"
        return 0
    fi
    mkdir -p "$TC_DIR" && chmod 755 "$TC_DIR" || return 1
    {
        echo "# Containers expected on this host, one per line."
        echo "#   compose:<project>/<service>  a Docker Compose service"
        echo "#   name:<container name>        any other container"
        echo "# Created $(date '+%Y-%m-%d %H:%M %Z') by Docker - Configure Host Maintenance [Lin]"
        echo "# from every container present then, running or stopped. Change it with"
        echo "# Docker - Update Expected Containers [Lin]. Until a person runs its"
        echo "# Confirm reviewed action, the prune removes no containers or images."
        if [ "$count" -gt 0 ]; then printf '%s\n' "$keys"; fi
    } >"$EXPECTED_FILE.tmp" && chmod 644 "$EXPECTED_FILE.tmp" && mv -f "$EXPECTED_FILE.tmp" "$EXPECTED_FILE" || return 1
    if [ ! -e "$IGNORE_FILE" ]; then
        {
            echo "# Extended regular expressions, one per line, matched against a"
            echo "# container's key (see expected-containers). A match is never"
            echo "# reported as unexpected. Example for GitLab CI job containers:"
            echo "#   ^name:runner-"
        } >"$IGNORE_FILE" && chmod 644 "$IGNORE_FILE"
    fi
    say "Expected list: created $EXPECTED_FILE with $count entries:"
    [ "$count" -gt 0 ] && printf '%s\n' "$keys" | sed 's/^/  /'
    report_unreadable "$unreadable" "left off"
    say "Expected list: NOT REVIEWED. Until someone confirms it, the prune removes no containers or images here."
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
    # Requisite, not Requires: the prune runs only while Docker is already
    # running, and starting it never starts Docker. Requires= would start a
    # Docker someone stopped on purpose, and every restart: always container
    # with it. Without a docker.service unit Requisite could never be met, so
    # the lines are left out and the prune checks Docker itself.
    local svc timer deps=""
    if [ "$(systemctl show docker.service -p LoadState 2>/dev/null)" = "LoadState=loaded" ]; then
        deps="
Requisite=docker.service
After=docker.service"
    else
        say "Prune timer: this host has no docker.service unit, so $UNIT_NAME.service is written without a dependency on it; the prune checks for itself whether Docker is running."
    fi
    svc="[Unit]
Description=Prune unused Docker images, stopped containers, networks and build cache (TechCollective)
Documentation=https://github.com/TechCollective/DattoRMM_Components/tree/main/Scripts/docker-configure-host-maintenance-lin$deps

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=$PRUNE_BIN"
    # FixedRandomDelay keeps the random part of the time the same across
    # daemon-reloads (systemd 247+; older systemd ignores the line), so a reload
    # does not move the next run.
    timer="[Unit]
Description=Weekly Docker prune (TechCollective)

[Timer]
OnCalendar=$usrPruneSchedule
RandomizedDelaySec=30min
FixedRandomDelay=true
Persistent=true

[Install]
WantedBy=timers.target"

    WROTE=0
    install_prune_script                         || return 1
    put_file "$UNIT_DIR/$UNIT_NAME.service" "$svc"   644 || return 1
    local changed_svc=$WROTE
    WROTE=0
    put_file "$UNIT_DIR/$UNIT_NAME.timer"   "$timer" 644 || return 1
    local changed_timer=$WROTE
    local changed=$(( changed_svc | changed_timer ))

    local guard="keeps stopped containers on the expected list, removes other stopped ones ${usrPruneGraceHours}h after recording them, images: $usrPruneImages"

    if [ "$usrMode" = "report" ]; then
        if [ $changed_timer -eq 1 ]; then
            say "Prune timer: REPORT MODE, would install or update $UNIT_NAME.timer ($usrPruneSchedule, older than ${usrPruneOlderThanHours}h, $guard)."
        elif [ $changed_svc -eq 1 ]; then
            say "Prune timer: REPORT MODE, would update the prune service, script or settings (older than ${usrPruneOlderThanHours}h, $guard), and would not restart the timer."
        else
            say "Prune timer: already installed with these settings."
        fi
        return 0
    fi

    # A change to the service, the script or its settings needs only a
    # daemon-reload: the next run uses it. The timer is restarted only when the
    # timer itself changed, because restarting a Persistent timer can run a
    # missed prune at once.
    if [ $changed -eq 1 ]; then
        systemctl daemon-reload || return 1
    fi
    if ! systemctl is-enabled --quiet "$UNIT_NAME.timer" 2>/dev/null; then
        systemctl enable "$UNIT_NAME.timer" >/dev/null 2>&1 || return 1
    fi
    if [ $changed_timer -eq 1 ]; then
        systemctl restart "$UNIT_NAME.timer" || return 1
    elif ! systemctl is-active --quiet "$UNIT_NAME.timer" 2>/dev/null; then
        systemctl start "$UNIT_NAME.timer" || return 1
    fi
    if [ $changed_timer -eq 1 ]; then
        say "Prune timer: installed $UNIT_NAME.timer ($usrPruneSchedule, removes unused items older than ${usrPruneOlderThanHours}h; volumes are never removed; $guard)."
    elif [ $changed_svc -eq 1 ]; then
        say "Prune timer: updated the prune service, script or settings (removes unused items older than ${usrPruneOlderThanHours}h; volumes are never removed; $guard). The timer was not restarted."
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
    install_prune_script || return 1
    local up
    tc_docker_running; up=$?
    if [ "$up" -eq 1 ]; then
        say "Prune now: Docker is not running ($DOCKER_STATE); not run, and Docker was left stopped."
        return 3
    elif [ "$up" -ne 0 ]; then
        say "Prune now: the Docker daemon is not reachable; not run."
        return 3
    fi
    say "Prune now:"
    local out rc
    out="$("$PRUNE_BIN" 2>&1)"; rc=$?
    # The full list of deleted IDs belongs in the journal, not the job output.
    printf '%s\n' "$out" | grep -vE '^(deleted|untagged): |^sha256:|^[0-9a-f]{12,64}$|^Deleted (Containers|Images|Networks|build cache objects):$|^$' \
        | sed 's/^/  /'
    [ $rc -eq 0 ] && return 0
    return 1
}

# ---------------------------------------------------------------- run

worst=0
daemon_section;  rc=$?; [ $rc -gt $worst ] && worst=$rc
seed_section;    rc=$?; [ $rc -gt $worst ] && worst=$rc
timer_section;   rc=$?; [ $rc -gt $worst ] && worst=$rc
prune_now;       rc=$?; [ $rc -gt $worst ] && worst=$rc

if [ $CHANGED_DAEMON -eq 1 ]; then
    if tc_docker_running; then
        say "RESTART PENDING: daemon.json changed. It takes effect when Docker restarts or the host reboots; this component never restarts Docker. Log rotation applies to containers created after that."
    else
        say "daemon.json changed; Docker is not running, so it applies at next start."
    fi
fi

RESULT=$worst
if [ $worst -eq 0 ]; then say "Docker host maintenance: done."; fi
exit $worst
