#!/usr/bin/env bash
# Docker - Configure Host Maintenance [Lin]
#
# Datto RMM Scripts component. Runs as root.
#
# 1. Adds log rotation and build-cache limits to /etc/docker/daemon.json.
#    Only keys that are MISSING are added. An existing value is never changed,
#    so a host someone already tuned keeps its tuning. First it reads how the
#    daemon is really started (the running dockerd's command line, or
#    docker.service when Docker is stopped). Log rotation is skipped when the
#    daemon uses a driver that does not rotate, is started with --log-opt, or
#    its flags cannot be determined. Nothing is written when the daemon reads a
#    --config-file other than /etc/docker/daemon.json, or when the file already
#    holds log-opts that will stop Docker starting ("DAEMON WILL NOT START").
# 2. Creates the host's expected-containers list, /etc/tc-docker/expected-containers,
#    from every container present now, running or stopped -- only if the list
#    does not exist yet. After that it never changes the list; "Docker -
#    Update Expected Containers [Lin]" does. A new list is NOT REVIEWED.
# 3. Installs a systemd timer that runs /usr/local/sbin/tc-docker-prune.
#    Until a person confirms the list (Update Expected Containers, Confirm
#    reviewed), the prune touches only unused networks and build cache:
#    no container and no image is removed. After review it also removes
#    stopped containers and unused images older than N hours, except a
#    stopped container on the list, with an always/unless-stopped restart
#    policy, or labelled tc.keep -- those are kept, with their images.
#    Never volumes.
# 4. Optionally runs that prune once, now.
#
# It never restarts Docker. daemon.json changes take effect at the next
# Docker restart or reboot; the output says "RESTART PENDING" when that applies.
#
# Exit codes:
#   0  done, or nothing to do (including: Docker is not installed)
#   1  unexpected failure
#   2  an input variable is invalid; nothing was changed
#   3  could not apply safely (no JSON tool, config failed validation,
#      Docker's start flags unknown, a --config-file elsewhere, daemon.json
#      already stops Docker starting, no systemd, snap-packaged Docker, daemon
#      unreachable for the list or a prune-now); nothing was changed for that
#      part

set -u
umask 022

DAEMON_JSON="/etc/docker/daemon.json"
UNIT_DIR="/etc/systemd/system"
UNIT_NAME="tc-docker-prune"
PRUNE_BIN="/usr/local/sbin/tc-docker-prune"
PRUNE_CONF="/etc/default/tc-docker-prune"
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
DOCKER="$DOCKER_BIN"

# >>> tc-docker shared: identical in every tc-docker component; change them together.
TC_DIR="/etc/tc-docker"
EXPECTED_FILE="$TC_DIR/expected-containers"
IGNORE_FILE="$TC_DIR/ignore"
# Written by "Docker - Update Expected Containers [Lin]" (Confirm reviewed). Until it
# exists, the prune removes no containers and no images on this host.
REVIEWED_FILE="$TC_DIR/reviewed"
# shellcheck disable=SC2034  # not every component uses every name
KEY_RE='^(name:[a-zA-Z0-9][a-zA-Z0-9_.-]*|compose:[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*)$'

# One line per container, tab separated:
#   id  key  name  running  restart-policy  created  started  tc.keep(y/n)  transient(y/n)
# key is compose:<project>/<service> for a Compose service, otherwise name:<name>.
# transient is y for Compose one-offs (compose run) and --rm containers.
tc_containers() {
    "$DOCKER" ps -aq --no-trunc 2>/dev/null | xargs -r "$DOCKER" inspect -f \
'{{.Id}}{{"\t"}}{{.Name}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.oneoff"}}{{"\t"}}{{.HostConfig.AutoRemove}}{{"\t"}}{{.State.Running}}{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{.Created}}{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{range $k, $v := .Config.Labels}}{{if eq $k "tc.keep"}}y{{end}}{{end}}' 2>/dev/null \
    | awk -F'\t' -v OFS='\t' '{
        for (i = 3; i <= 5; i++) if ($i == "<no value>") $i = ""
        name = $2; sub(/^\//, "", name)
        key = ($3 != "" && $4 != "") ? "compose:" $3 "/" $4 : "name:" name
        print $1, key, name, $7, $8, $9, $10, ($11 == "y" ? "y" : "n"), (($5 == "True" || $6 == "true") ? "y" : "n")
    }'
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
# Writes a JSON description to $1 and the daemon's logging flags, NUL
# separated, to $2 (for dockerd --validate). Prints one "daemon.json:" line.
# Exit: 0 flags known; 3 flags could not be determined with confidence;
#       5 the daemon reads a --config-file other than $DAEMON_JSON.
detect_daemon_flags() {
    python3 - "$DAEMON_JSON" "$1" "$2" "$DOCKER_BIN" <<'PY'
import json, os, re, shlex, shutil, subprocess, sys
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

def read_env_file(path):
    # systemd EnvironmentFile= syntax. Returns {name: value}; a name whose
    # value this cannot reproduce exactly maps to an Unsure instead.
    vals, bad_line = {}, False
    text = re.sub(r"\\\n", "", read(path))
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
        if not m:
            bad_line = True
            continue
        k, v = m.groups()
        if v[:1] in ("'", '"'):
            try:
                parts = shlex.split(v)
            except ValueError:
                parts = []
            if len(parts) != 1:
                vals[k] = Unsure(f"{path} sets {k} in a form this component cannot read")
                continue
            v = parts[0]
        if "$" in v or "`" in v:
            vals[k] = Unsure(f"{path} sets {k} from another variable")
        else:
            vals[k] = v
    return vals, bad_line

def unit_args():
    # The dockerd arguments docker.service would start with, from the unit as
    # systemd has loaded it (drop-ins included), with its variables expanded
    # the way systemd expands them.
    if not systemd:
        raise Unsure("Docker is not running, and this host has no systemd unit to read its start flags from")
    rc, o = run(["systemctl", "show", "docker.service", "-p", "LoadState",
                 "-p", "ExecStart", "-p", "Environment", "-p", "EnvironmentFiles"])
    if rc != 0:
        raise Unsure("Docker is not running, and systemctl show docker.service failed")
    props = {}
    for line in o.splitlines():
        k, _, v = line.partition("=")
        props.setdefault(k, []).append(v)
    if props.get("LoadState", [""])[0] != "loaded":
        raise Unsure("Docker is not running, and there is no docker.service unit to read its start flags from")
    argvs = re.findall(r"argv\[\]=(.*?) ;", " ".join(props.get("ExecStart", [])))
    if len(argvs) != 1:
        raise Unsure(f"Docker is not running, and docker.service has {len(argvs)} ExecStart commands")
    words = argvs[0].split()
    if not words or os.path.basename(words[0]) != "dockerd":
        raise Unsure("Docker is not running, and docker.service does not start dockerd directly")

    env, files_unreadable = {}, []
    try:
        for e in shlex.split(" ".join(props.get("Environment", []))):
            k, _, v = e.partition("=")
            env[k] = Unsure(f"docker.service sets {k} from another variable") if "$" in v else v
    except ValueError:
        files_unreadable.append("the unit's Environment= setting")
    # Files listed later override earlier ones, and all override Environment=.
    for path, ignore in re.findall(r"(\S+) \(ignore_errors=(yes|no)\)",
                                   " ".join(props.get("EnvironmentFiles", []))):
        if not os.path.exists(path):
            if ignore == "yes":
                continue
            raise Unsure(f"Docker is not running, and its required environment file {path} is missing")
        try:
            vals, bad = read_env_file(path)
        except OSError:
            files_unreadable.append(path)
            continue
        if bad:
            files_unreadable.append(path)
        env.update(vals)

    def lookup(name):
        if files_unreadable:
            raise Unsure(f"Docker is not running, and docker.service uses ${name} but {files_unreadable[0]} cannot be read with confidence")
        v = env.get(name, "")      # systemd expands an unset variable to nothing
        if isinstance(v, Unsure):
            raise Unsure(f"Docker is not running, and {v}")
        return v

    args = []
    for w in words[1:]:
        if re.fullmatch(r"\$[A-Za-z_][A-Za-z0-9_]*", w):
            try:
                args.extend(shlex.split(lookup(w[1:])))
            except ValueError:
                raise Unsure(f"Docker is not running, and ${w[1:]} is not a list of arguments this component can split")
            continue
        if "$" in re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", "", w):
            raise Unsure(f"Docker is not running, and docker.service uses a variable in a form this component cannot expand ({w})")
        args.append(re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: lookup(m.group(1)), w))
    return args

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

det = {"known": False, "why": "", "source": "", "driver_flag": None, "opt_keys": [],
       "config_file": None, "live_driver": None}
vargs = []
rc = 0
try:
    pid = find_running_dockerd()
    if pid:
        try:
            raw = read(f"/proc/{pid}/cmdline")
        except OSError:
            raise Unsure(f"the command line of the running dockerd (pid {pid}) cannot be read")
        args = raw.split("\0")
        if args and args[-1] == "":
            args.pop()
        args = args[1:]
        det["source"] = f"the running dockerd, pid {pid}"
        r, o = run([docker, "info", "--format", "{{.LoggingDriver}}"])
        if r == 0 and o.strip():
            det["live_driver"] = o.strip()
    else:
        args = unit_args()
        det["source"] = "docker.service, as it would start Docker; Docker is not running"
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
        conflict = (f"daemon.json has log-opts.{ours[0]} but the log driver is {driver} ({src}), "
                    f"which does not accept {ours[0]}")
    if conflict:
        print(f"CONFLICT: {conflict}", file=sys.stderr)
        sys.exit(4)

size, files = env.get("usrLogMaxSize", ""), env.get("usrLogMaxFile", "")
if size:
    if not det["known"]:
        note("SKIPPED", "log rotation: Docker's start flags could not be determined, so it cannot be "
                        "known whether Docker would accept log-opts in daemon.json")
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

daemon_section() {
    if [ -z "$usrLogMaxSize" ] && [ -z "$usrBuildCacheMax" ]; then
        say "daemon.json: log rotation and build-cache limits both left blank; not touched."
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        say "daemon.json: python3 is not available, so the file cannot be merged safely; not touched."
        return 3
    fi

    local tmp notes det vfile rc section_rc=0 a
    local -a vargs=()
    det="$(mktemp)"; vfile="$(mktemp)"
    detect_daemon_flags "$det" "$vfile"; rc=$?
    case $rc in
        0) ;;
        3) section_rc=3 ;;     # flags unknown: log rotation is skipped below
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
    return $section_rc
}

# ---------------------------------------------------------------- prune script

# The prune itself lives in one script on the host, so the weekly timer and a
# prune-now run exactly the same code, safety check included.
read -r -d '' PRUNE_SCRIPT <<'EOS'
#!/bin/bash
# tc-docker-prune -- installed by the Datto RMM component
# "Docker - Configure Host Maintenance [Lin]". Do not edit here; re-run the
# component. Settings: /etc/default/tc-docker-prune.
#
# Always removes, when older than OLDER_THAN_HOURS: unused networks and build
# cache. Once /etc/tc-docker/reviewed exists (a person confirmed the list),
# it also removes:
#   - stopped containers, EXCEPT any that is on /etc/tc-docker/expected-containers,
#     has restart policy always or unless-stopped, or is labelled tc.keep.
#     Those are kept, so their images stay "in use" and are kept too;
#   - images no container uses (tc.keep-labelled images are kept).
# Before review, no container and no image is touched.
# Never volumes. Exit: 0 done, 1 error.
set -u
OLDER_THAN_HOURS=168
[ -r /etc/default/tc-docker-prune ] && . /etc/default/tc-docker-prune

DOCKER="$(command -v docker)" || { echo "ERROR: docker not found"; exit 1; }
"$DOCKER" info >/dev/null 2>&1 || { echo "ERROR: the Docker daemon is not reachable"; exit 1; }

# >>> tc-docker shared: identical in every tc-docker component; change them together.
TC_DIR="/etc/tc-docker"
EXPECTED_FILE="$TC_DIR/expected-containers"
IGNORE_FILE="$TC_DIR/ignore"
# Written by "Docker - Update Expected Containers [Lin]" (Confirm reviewed). Until it
# exists, the prune removes no containers and no images on this host.
REVIEWED_FILE="$TC_DIR/reviewed"
# shellcheck disable=SC2034  # not every component uses every name
KEY_RE='^(name:[a-zA-Z0-9][a-zA-Z0-9_.-]*|compose:[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*)$'

# One line per container, tab separated:
#   id  key  name  running  restart-policy  created  started  tc.keep(y/n)  transient(y/n)
# key is compose:<project>/<service> for a Compose service, otherwise name:<name>.
# transient is y for Compose one-offs (compose run) and --rm containers.
tc_containers() {
    "$DOCKER" ps -aq --no-trunc 2>/dev/null | xargs -r "$DOCKER" inspect -f \
'{{.Id}}{{"\t"}}{{.Name}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.oneoff"}}{{"\t"}}{{.HostConfig.AutoRemove}}{{"\t"}}{{.State.Running}}{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{.Created}}{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{range $k, $v := .Config.Labels}}{{if eq $k "tc.keep"}}y{{end}}{{end}}' 2>/dev/null \
    | awk -F'\t' -v OFS='\t' '{
        for (i = 3; i <= 5; i++) if ($i == "<no value>") $i = ""
        name = $2; sub(/^\//, "", name)
        key = ($3 != "" && $4 != "") ? "compose:" $3 "/" $4 : "name:" name
        print $1, key, name, $7, $8, $9, $10, ($11 == "y" ? "y" : "n"), (($5 == "True" || $6 == "true") ? "y" : "n")
    }'
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
cutoff=$(( $(date +%s) - OLDER_THAN_HOURS * 3600 ))
expected=" $(tc_list "$EXPECTED_FILE" | tr '\n' ' ') "

echo "Pruning unused items older than ${OLDER_THAN_HOURS}h. Volumes are never removed."
echo "Disk before: $(free)"

removed=0; kept=(); errors=0
REVIEWED=0; tc_reviewed && REVIEWED=1
if [ "$REVIEWED" -eq 0 ]; then
    echo "List not reviewed yet: no containers and no images are removed on this host."
    echo "Review $EXPECTED_FILE, then run Docker - Update Expected Containers [Lin] with Confirm reviewed."
fi
while [ "$REVIEWED" -eq 1 ] && IFS=$'\t' read -r id key name running policy created _started keep _transient; do
    [ "$running" = "true" ] && continue
    why=""
    case "$expected" in *" $key "*) why="on the expected list" ;; esac
    case "$policy" in always|unless-stopped) why="${why:-restart policy $policy}" ;; esac
    [ "$keep" = "y" ] && why="${why:-labelled tc.keep}"
    if [ -n "$why" ]; then kept+=("$name ($why)"); continue; fi
    c="$(date -d "$created" +%s 2>/dev/null)" || continue     # age unknown: leave it
    [ "$c" -lt "$cutoff" ] || continue
    if "$DOCKER" rm "$id" >/dev/null 2>&1; then removed=$((removed + 1))
    else echo "WARNING: could not remove stopped container $name"; errors=$((errors + 1)); fi
done < <(tc_containers)

[ "$REVIEWED" -eq 1 ] && echo "Stopped containers removed: $removed"
if [ "${#kept[@]}" -gt 0 ]; then
    echo "Stopped containers kept, with their images:"
    printf '  %s\n' "${kept[@]}"
fi

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
[ "$REVIEWED" -eq 1 ] && step "Images" "$DOCKER" image prune --all --force --filter "until=${OLDER_THAN_HOURS}h" --filter "label!=tc.keep"
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
OLDER_THAN_HOURS=$usrPruneOlderThanHours"
    put_file "$PRUNE_BIN"  "$PRUNE_SCRIPT" 755 || return 1
    put_file "$PRUNE_CONF" "$conf"         644 || return 1
}

# ---------------------------------------------------------------- expected list

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
    if ! "$DOCKER" info >/dev/null 2>&1; then
        say "Expected list: the Docker daemon is not reachable, so the list was not created; the next run will try again."
        return 3
    fi
    local keys old
    # Every container present, running or stopped: one that exists when we take
    # a host on is assumed wanted until a person says otherwise.
    keys="$(tc_containers | awk -F'\t' '$9 == "n" {print $2}')"
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
ExecStart=$PRUNE_BIN"
    timer="[Unit]
Description=Weekly Docker prune (TechCollective)

[Timer]
OnCalendar=$usrPruneSchedule
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target"

    WROTE=0
    install_prune_script                         || return 1
    put_file "$UNIT_DIR/$UNIT_NAME.service" "$svc"   644 || return 1
    put_file "$UNIT_DIR/$UNIT_NAME.timer"   "$timer" 644 || return 1
    local changed=$WROTE

    local guard="keeps stopped containers on the expected list"

    if [ "$usrMode" = "report" ]; then
        if [ $changed -eq 1 ]; then
            say "Prune timer: REPORT MODE, would install or update $UNIT_NAME.timer ($usrPruneSchedule, older than ${usrPruneOlderThanHours}h, $guard)."
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
        say "Prune timer: installed $UNIT_NAME.timer ($usrPruneSchedule, removes unused items older than ${usrPruneOlderThanHours}h; volumes are never removed; $guard)."
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
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
        say "RESTART PENDING: daemon.json changed. It takes effect when Docker restarts or the host reboots; this component never restarts Docker. Log rotation applies to containers created after that."
    else
        say "daemon.json changed; Docker is not running, so it applies at next start."
    fi
fi

RESULT=$worst
if [ $worst -eq 0 ]; then say "Docker host maintenance: done."; fi
exit $worst
