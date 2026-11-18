#!/usr/bin/env bash
# Docker - Configure Host Maintenance [Lin]
#
# Datto RMM Scripts component. Runs as root. Keeps a Docker host's disk from
# filling up with containers and images nothing uses: an expected-containers
# list, and a weekly prune that removes nothing of a host's until a person has
# reviewed that list, and no stopped container without recording it first.
# (Up to version 14 it also set log and build-cache limits in daemon.json.
# That part is "Docker - Configure Daemon Limits [Lin]" now; this component
# does not read or write daemon.json.)
#
# Changes on the host (usrMode Report changes nothing):
#   /etc/tc-docker/expected-containers  created once, from every container
#   /etc/tc-docker/ignore               present, and never changed after that
#   /usr/local/sbin/tc-docker-prune     the prune (the text in PRUNE_SCRIPT
#                                       below), /etc/default/tc-docker-prune
#                                       (its settings) and the systemd units
#                                       tc-docker-prune.service and .timer
#   and, with usrPruneNow, whatever that prune removes. The prune keeps its
#   own record, /var/lib/tc-docker/pending-removal.
# It never starts or restarts Docker.
#
# Exit codes:
#   0  done, or nothing to do (also: Docker is not installed)
#   1  unexpected failure (a write, a systemctl call or the prune failed)
#   2  an input variable is invalid; nothing was changed
#   3  one part could not be applied safely and was left as it was (Docker
#      stopped or not answering, no systemd, the snap package); the output
#      names the part, and the other parts may have run
#
# What each part does, every input variable and every cause of exit 3:
# https://github.com/TechCollective/DattoRMM_Components/tree/main/Scripts/docker-configure-host-maintenance-lin

set -u
umask 022

UNIT_DIR="/etc/systemd/system"
UNIT_NAME="tc-docker-prune"
PRUNE_BIN="/usr/local/sbin/tc-docker-prune"
PRUNE_CONF="/etc/default/tc-docker-prune"
RESULT=1

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
usrPruneSchedule="${usrPruneSchedule-Sun *-*-* 04:00:00}"
usrPruneOlderThanHours="${usrPruneOlderThanHours-168}"
usrPruneGraceHours="${usrPruneGraceHours-144}"
usrPruneImages="${usrPruneImages:-dangling}"
usrPruneNow="${usrPruneNow:-no}"

# Trim surrounding whitespace a pasted value tends to carry.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
for v in usrMode usrPruneSchedule usrPruneOlderThanHours usrPruneGraceHours usrPruneImages usrPruneNow; do
    printf -v "$v" '%s' "$(trim "${!v}")"
done
usrMode="${usrMode,,}"; usrPruneNow="${usrPruneNow,,}"; usrPruneImages="${usrPruneImages,,}"

case "$usrMode" in apply|report) ;; *) fail 2 "usrMode must be apply or report (got '$usrMode')." ;; esac
case "$usrPruneNow" in yes|no) ;; *) fail 2 "usrPruneNow must be yes or no (got '$usrPruneNow')." ;; esac

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

# The well-formed lines of pending-removal file $1 (the stopped containers
# tc-docker-prune has recorded and will remove), tab separated:
#   id  key  name  first-recorded
# first-recorded is seconds since 1970, printed without leading zeros. Then,
# when the file has any other line, one last line:
#   BAD  n  line-numbers
# n is how many lines are not well formed, line-numbers which ones (", "
# between them). Comment lines (#) and blank lines are neither. The file is
# untrusted: a line is well formed only when it is exactly four fields, a 64
# hex character id, a key, a plain name and a number of at most 10 digits; an
# id may appear on more than one line, and the caller decides which one counts.
# Prints nothing when $1 is missing or is not a regular file (a symlink is not
# one) that can be read.
tc_pending_lines() {
    { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; } || return 0
    awk -F'\t' -v OFS='\t' -v keyre="$KEY_RE" '
        /^#/ || /^[ \t]*$/ { next }
        NF == 4 && length($1) == 64 && $1 !~ /[^0-9a-f]/ && $2 ~ keyre && $3 ~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && $4 ~ /^[0-9]+$/ && length($4) <= 10 {
            sub(/^0+/, "", $4); if ($4 == "") $4 = "0"
            print; next
        }
        { bad++; where = where (bad > 1 ? ", " : "") NR }
        END { if (bad) print "BAD", bad, where }' "$1"
}
# <<< tc-docker shared

# ---------------------------------------------------------------- prune script

# The prune itself lives in one script on the host, so the weekly timer and a
# prune-now run exactly the same code, safety check included.
read -r -d '' PRUNE_SCRIPT <<'EOS'
#!/bin/bash
# tc-docker-prune -- installed by the Datto RMM component
# "Docker - Configure Host Maintenance [Lin]". Do not edit here; re-run the
# component. Settings: /etc/default/tc-docker-prune, read as text and never run.
TC_PRUNE_VERSION=15
# The line above is the version of the component that installed this script,
# and the first thing a run prints is that version, so the journal shows which
# prune ran. "Docker - Containers Differ From Expected [Lin]" reads it to flag
# a host whose prune is older than the monitor's PRUNE_MIN_VERSION. Keep it the
# only line starting TC_PRUNE_VERSION=, equal to "version" in component.json.
#
# Removes what is unused and older than OLDER_THAN_HOURS: networks and build
# cache always; and, once /etc/tc-docker/reviewed exists (a person confirmed
# the host's expected-containers list):
#   - stopped containers, unless protected (on the list, restart policy always
#     or unless-stopped, labelled tc.keep, or Compose labels that are not plain
#     names), and only GRACE_HOURS after first recording them in
#     /var/lib/tc-docker/pending-removal; if that record cannot be written, no
#     container is removed;
#   - images no container uses: untagged ones, and with PRUNE_IMAGES=all also
#     tagged ones whose registry confirms, at that moment, that it has them.
# Never volumes. Nothing at all when Docker does not return its container
# list. With Docker stopped it runs no docker command and leaves it stopped.
# Exit: 0 done (also: Docker stopped, nothing pruned); 1 an error, each one
# named in an ERROR line. Every rule, setting and message:
# https://github.com/TechCollective/DattoRMM_Components/tree/main/Scripts/docker-configure-host-maintenance-lin
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

DOCKER="$(command -v docker)" || { echo "ERROR: docker not found"; exit 1; }

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

# The well-formed lines of pending-removal file $1 (the stopped containers
# tc-docker-prune has recorded and will remove), tab separated:
#   id  key  name  first-recorded
# first-recorded is seconds since 1970, printed without leading zeros. Then,
# when the file has any other line, one last line:
#   BAD  n  line-numbers
# n is how many lines are not well formed, line-numbers which ones (", "
# between them). Comment lines (#) and blank lines are neither. The file is
# untrusted: a line is well formed only when it is exactly four fields, a 64
# hex character id, a key, a plain name and a number of at most 10 digits; an
# id may appear on more than one line, and the caller decides which one counts.
# Prints nothing when $1 is missing or is not a regular file (a symlink is not
# one) that can be read.
tc_pending_lines() {
    { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; } || return 0
    awk -F'\t' -v OFS='\t' -v keyre="$KEY_RE" '
        /^#/ || /^[ \t]*$/ { next }
        NF == 4 && length($1) == 64 && $1 !~ /[^0-9a-f]/ && $2 ~ keyre && $3 ~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && $4 ~ /^[0-9]+$/ && length($4) <= 10 {
            sub(/^0+/, "", $4); if ($4 == "") $4 = "0"
            print; next
        }
        { bad++; where = where (bad > 1 ? ", " : "") NR }
        END { if (bad) print "BAD", bad, where }' "$1"
}
# <<< tc-docker shared

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
# The record of the stopped containers this prune will remove: see "stopped
# containers" below. Written with tc_state_write, read with tc_pending_lines.
PENDING_FILE="$TC_STATE_DIR/pending-removal"

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

# Replaces the pending file with a header and $1 (lines ending in newlines),
# through tc_state_write (the tc-docker state block above): a new root-only
# file in the same root-only directory, read back, then renamed over the old
# one. Returns 1 when it cannot, with the reason in TC_STATE_WHY (and
# TC_STATE_ERR); the caller then removes no container.
pending_write() {
    tc_state_write pending-removal "# Stopped containers that tc-docker-prune will remove. Written by the prune; do not edit.
# id<TAB>key<TAB>name<TAB>first recorded (seconds since 1970). The prune removes a
# container GRACE_HOURS after it first recorded it, if it is still stopped and
# unprotected then; otherwise the line is dropped. To keep one, add it to the
# expected list with Docker - Update Expected Containers [Lin] (Add).
$1"
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
    # The pending file, read by tc_pending_lines (in the shared block above):
    # its well-formed lines, then one "BAD<tab>n<tab>..." line if n were not.
    pend="$(tc_pending_lines "$PENDING_FILE")"
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
        echo "ERROR: could not write $PENDING_FILE: $TC_STATE_WHY${TC_STATE_ERR:+ ($TC_STATE_ERR)}. No container was removed this run."
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
            echo "ERROR: could not update $PENDING_FILE after removing containers: $TC_STATE_WHY${TC_STATE_ERR:+ ($TC_STATE_ERR)}. The next run drops the lines of containers that are gone."
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
seed_section;    rc=$?; [ $rc -gt $worst ] && worst=$rc
timer_section;   rc=$?; [ $rc -gt $worst ] && worst=$rc
prune_now;       rc=$?; [ $rc -gt $worst ] && worst=$rc

RESULT=$worst
if [ $worst -eq 0 ]; then say "Docker host maintenance: done."; fi
exit $worst
