#!/usr/bin/env bash
# Docker - Containers Differ From Expected [Lin]
#
# Datto RMM custom monitor. Runs as root. Read-only; changes nothing.
#
# Compares the containers on this host with its expected-containers list,
# /etc/tc-docker/expected-containers (created by "Docker - Configure Host
# Maintenance [Lin]", changed with "Docker - Update Expected Containers [Lin]"):
#
#   - an expected container that is stopped or gone      -> usrMissingAction
#     (reported, but not alerted on, while the list is unreviewed)
#   - a running container not on the list, running for
#     usrUnlistedAfterHours or more, and not ignored       -> usrUnlistedAction
#   - a list no person has confirmed yet                   -> usrUnreviewedAction
#     (until it is, the weekly prune removes no containers or images)
#
#   - a container whose Compose labels are not plain names  -> usrUnlistedAction
#     (it has no key, so it can never be listed; the label is never printed)
#
#   - a prune installed by an older version of Host Maintenance  -> usrStalePruneAction
#     (/usr/local/sbin/tc-docker-prune older than PRUNE_MIN_VERSION, with no
#     version stamp, or the version 1 layout where the systemd service runs
#     docker directly; until the component is run on the host again the OLD
#     prune's rules apply). Read from two files only; checked before the
#     "no list yet" exit, because hosts on versions 1 and 2 have no list.
#
# Compose one-offs, --rm containers and anything matching /etc/tc-docker/ignore
# are never "unlisted". A host without Docker, or without a list yet, is healthy
# and says so (unless its prune is stale). A daemon that cannot be reached, or that does not return its
# container list, is an alert: not knowing is the failure this monitor exists
# to catch.

set -u
EMITTED=0
emit() {  # exit code, status line
    local msg="${2//$'\n'/ }"
    [ "${#msg}" -gt 400 ] && msg="${msg:0:397}..."
    echo '<-Start Result->'
    echo "STATUS=${msg}"
    echo '<-End Result->'
    EMITTED=1
    if [ "$1" -ne 0 ] && [ -n "${DIAG:-}" ]; then
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
DIAG=""
diag() { DIAG="${DIAG}${1}"$'\n'; }

# The oldest prune this monitor accepts: the version of "Docker - Configure Host
# Maintenance [Lin]" that installed /usr/local/sbin/tc-docker-prune (it stamps
# TC_PRUNE_VERSION=<its own version> at the top of the script). Raise this when a
# safety fix to the prune ships, and every host still on an older prune is
# flagged on its next run.
PRUNE_MIN_VERSION=7
PRUNE_BIN="/usr/local/sbin/tc-docker-prune"
PRUNE_UNIT="/etc/systemd/system/tc-docker-prune.service"

usrUnlistedAfterHours="${usrUnlistedAfterHours:-24}"
usrUnlistedAction="$(printf '%s' "${usrUnlistedAction:-warn}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrMissingAction="$(printf '%s' "${usrMissingAction:-alert}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrUnreviewedAction="$(printf '%s' "${usrUnreviewedAction:-warn}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrStalePruneAction="$(printf '%s' "${usrStalePruneAction:-alert}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$usrUnlistedAfterHours" =~ ^[0-9]+$ ]] && [ "$usrUnlistedAfterHours" -le 8760 ] \
    || emit 1 "Check could not run: usrUnlistedAfterHours must be 0-8760 (got '$usrUnlistedAfterHours')"
case "$usrUnlistedAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrUnlistedAction must be alert, warn or ignore (got '$usrUnlistedAction')" ;; esac
case "$usrMissingAction"  in alert|warn) ;;        *) emit 1 "Check could not run: usrMissingAction must be alert or warn (got '$usrMissingAction')" ;; esac
case "$usrUnreviewedAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrUnreviewedAction must be alert, warn or ignore (got '$usrUnreviewedAction')" ;; esac
case "$usrStalePruneAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrStalePruneAction must be alert, warn or ignore (got '$usrStalePruneAction')" ;; esac
for t in awk grep sed date xargs; do
    command -v "$t" >/dev/null 2>&1 || emit 1 "Check could not run: required tool '$t' is missing"
done

DOCKER="$(command -v docker 2>/dev/null || true)"
[ -n "$DOCKER" ] || emit 0 "Docker is not installed on this host; nothing to check"
if ! err="$("$DOCKER" info 2>&1 >/dev/null)"; then
    diag "docker info said: $(printf '%s' "$err" | tail -n 2)"
    emit 1 "Check could not run: cannot talk to the Docker daemon"
fi

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

# A prune installed by an older Host Maintenance. Reads two files and nothing
# else. STALE_STATUS is the status text ("" when nothing is stale or the action
# is ignore); STALE_DIAG the diagnostic lines for an alert.
STALE_STATUS=""
STALE_DIAG=()
stale_prune_check() {
    local found=() v n line bad="" val
    # The version 1 layout: the service runs docker itself, not the script.
    if [ -e "$PRUNE_UNIT" ] || [ -L "$PRUNE_UNIT" ]; then
        local seen=0
        while IFS= read -r line; do
            seen=1
            val="${line#"${line%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
            [ "$val" = "$PRUNE_BIN" ] || bad="${bad:-${val:-(empty)}}"
        done < <(sed -n 's/^[[:space:]]*ExecStart=//p' "$PRUNE_UNIT" 2>/dev/null)
        [ "$seen" -eq 1 ] || bad="(no ExecStart line)"
        if [ -n "$bad" ]; then
            found+=("prune service on this host does not run $PRUNE_BIN (version 1 layout)")
            STALE_DIAG+=("STALE PRUNE  $PRUNE_UNIT has ExecStart: $(printf '%s' "$bad" | tr -cd '[:print:]' | cut -c1-200)")
        fi
    fi
    # The script: a readable TC_PRUNE_VERSION whole number, at least PRUNE_MIN_VERSION.
    # The stamp was introduced in version 7, so a script without one is older than 7
    # whatever PRUNE_MIN_VERSION is by now.
    if [ -e "$PRUNE_BIN" ] || [ -L "$PRUNE_BIN" ]; then
        line="$(grep -a -m 1 '^TC_PRUNE_VERSION=' "$PRUNE_BIN" 2>/dev/null)" || line=""
        if [ -z "$line" ]; then
            found+=("prune on this host has no version (installed before version 7)")
            STALE_DIAG+=("STALE PRUNE  $PRUNE_BIN has no TC_PRUNE_VERSION line, so it was installed before version 7 of Docker - Configure Host Maintenance [Lin]")
        else
            v="${line#TC_PRUNE_VERSION=}"; v="${v%"${v##*[![:space:]]}"}"
            if [[ ! "$v" =~ ^[0-9]+$ ]]; then
                found+=("prune on this host has an unreadable version (not a whole number)")
                STALE_DIAG+=("STALE PRUNE  $PRUNE_BIN has a TC_PRUNE_VERSION line that is not a whole number")
            else
                n="${v#"${v%%[!0]*}"}"; n="${n:-0}"      # no leading zeros: never octal
                # More than 9 digits is a number far above any minimum; skip the arithmetic.
                if [ "${#n}" -le 9 ] && [ "$n" -lt "$PRUNE_MIN_VERSION" ]; then
                    found+=("prune on this host is version $n, older than $PRUNE_MIN_VERSION")
                    STALE_DIAG+=("STALE PRUNE  $PRUNE_BIN is version $n; this monitor wants $PRUNE_MIN_VERSION or newer")
                fi
            fi
        fi
    fi
    [ "${#found[@]}" -gt 0 ] || return 0
    local f
    for f in "${found[@]}"; do STALE_STATUS="${STALE_STATUS:+$STALE_STATUS; }$f"; done
    STALE_DIAG+=("             Run Docker - Configure Host Maintenance [Lin] on this host to install the current prune. Until then the old prune's rules apply.")
}
[ "$usrStalePruneAction" = "ignore" ] || stale_prune_check

# Before the "no list" exit: hosts on versions 1 and 2 have no list, and they are
# the ones this check exists to find.
if [ ! -e "$EXPECTED_FILE" ]; then
    NO_LIST="No expected-containers list on this host yet; Docker - Configure Host Maintenance [Lin] creates it"
    if [ -n "$STALE_STATUS" ]; then
        if [ "$usrStalePruneAction" = "alert" ]; then
            for line in "${STALE_DIAG[@]}"; do diag "$line"; done
            emit 1 "$STALE_STATUS; ${NO_LIST,}"
        fi
        emit 0 "$STALE_STATUS; ${NO_LIST,}"
    fi
    emit 0 "$NO_LIST"
fi

mapfile -t EXPECTED < <(tc_list "$EXPECTED_FILE")
BAD=()
for k in "${EXPECTED[@]}"; do [[ "$k" =~ $KEY_RE ]] || BAD+=("$k"); done

if ! ROWS="$(tc_containers)"; then
    diag "docker ps or docker inspect failed 3 times in a row, so the containers on this host are unknown."
    emit 1 "Check could not run: Docker did not return its container list"
fi
NOW="$(date +%s)"
MIN_AGE=$(( usrUnlistedAfterHours * 3600 ))

RUNNING=(); STOPPED=(); MISSING=()
for k in "${EXPECTED[@]}"; do
    [[ "$k" =~ $KEY_RE ]] || continue
    if   printf '%s\n' "$ROWS" | awk -F'\t' -v k="$k" '$2 == k && $4 == "true" {f=1} END {exit !f}'; then RUNNING+=("$k")
    elif printf '%s\n' "$ROWS" | awk -F'\t' -v k="$k" '$2 == k {f=1} END {exit !f}'; then STOPPED+=("$k")
    else MISSING+=("$k"); fi
done

UNLISTED=(); UNREADABLE=(); YOUNG=0; IGNORED=0
declare -A SEEN=()
while IFS=$'\t' read -r id key name running _policy _created started _keep transient; do
    [ -n "$id" ] || continue
    # Compose labels that are not plain names: counted whatever the state, age
    # or ignore list, and named by container name and short id only.
    case "$key" in unreadable:*) UNREADABLE+=("$name (${id:0:12})"); continue ;; esac
    [ "$running" = "true" ] && [ "$transient" = "n" ] || continue
    [ -n "${SEEN[$key]:-}" ] && continue
    SEEN[$key]=1
    printf '%s\n' "${EXPECTED[@]}" | grep -qxF -- "$key" && continue
    if tc_ignored "$key"; then IGNORED=$((IGNORED + 1)); continue; fi
    s="$(date -d "$started" +%s 2>/dev/null || echo "$NOW")"
    if [ $(( NOW - s )) -lt "$MIN_AGE" ]; then YOUNG=$((YOUNG + 1)); continue; fi
    UNLISTED+=("$key")
done <<<"$ROWS"

join() { local IFS=','; printf '%s' "$*" | sed 's/,/, /g'; }

SUMMARY="$(( ${#EXPECTED[@]} - ${#BAD[@]} )) expected: ${#RUNNING[@]} running"
[ "${#STOPPED[@]}" -gt 0 ] && SUMMARY="$SUMMARY, ${#STOPPED[@]} stopped ($(join "${STOPPED[@]}"))"
[ "${#MISSING[@]}" -gt 0 ] && SUMMARY="$SUMMARY, ${#MISSING[@]} missing ($(join "${MISSING[@]}"))"
if [ "${#UNLISTED[@]}" -gt 0 ] && [ "$usrUnlistedAction" != "ignore" ]; then
    SUMMARY="$SUMMARY; ${#UNLISTED[@]} unlisted ($(join "${UNLISTED[@]}"))"
fi
[ "${#UNREADABLE[@]}" -gt 0 ] && SUMMARY="$SUMMARY; ${#UNREADABLE[@]} with unreadable Compose labels"
[ "$YOUNG" -gt 0 ] && SUMMARY="$SUMMARY; $YOUNG new, under ${usrUnlistedAfterHours}h"
[ "$IGNORED" -gt 0 ] && SUMMARY="$SUMMARY; $IGNORED ignored"
[ "${#BAD[@]}" -gt 0 ] && SUMMARY="$SUMMARY; ${#BAD[@]} unreadable list line(s)"
UNREVIEWED=0; tc_reviewed || UNREVIEWED=1
if [ "$UNREVIEWED" -eq 1 ] && [ "$usrUnreviewedAction" != "ignore" ]; then
    SUMMARY="$SUMMARY; list NOT REVIEWED, so no containers or images are pruned"
fi
# A stale prune goes first: it is what the old prune may delete that matters
# most here, and emit cuts the status at 400 characters.
[ -n "$STALE_STATUS" ] && SUMMARY="$STALE_STATUS; $SUMMARY"

ALERT=0
# Before review, stopped or missing containers are part of the review, not
# separate alerts: onboarding raises one "not reviewed" item, not one per container.
if [ $(( ${#STOPPED[@]} + ${#MISSING[@]} )) -gt 0 ] && [ "$usrMissingAction" = "alert" ] && [ "$UNREVIEWED" -eq 0 ]; then ALERT=1; fi
if [ "${#UNLISTED[@]}" -gt 0 ] && [ "$usrUnlistedAction" = "alert" ]; then ALERT=1; fi
if [ "${#UNREADABLE[@]}" -gt 0 ] && [ "$usrUnlistedAction" = "alert" ]; then ALERT=1; fi
if [ "$UNREVIEWED" -eq 1 ] && [ "$usrUnreviewedAction" = "alert" ]; then ALERT=1; fi
if [ -n "$STALE_STATUS" ] && [ "$usrStalePruneAction" = "alert" ]; then ALERT=1; fi

if [ "$ALERT" -eq 1 ]; then
    if [ -n "$STALE_STATUS" ] && [ "$usrStalePruneAction" = "alert" ]; then
        for k in "${STALE_DIAG[@]}"; do diag "$k"; done
    fi
    for k in ${STOPPED[@]+"${STOPPED[@]}"}; do diag "STOPPED   $k  - start it, or remove it from the list if it was retired"; done
    for k in ${MISSING[@]+"${MISSING[@]}"}; do diag "MISSING   $k  - no container with this key exists; redeploy it, or remove it from the list"; done
    for k in ${UNLISTED[@]+"${UNLISTED[@]}"}; do diag "UNLISTED  $k  - add it to the list, add an ignore pattern, or remove the container"; done
    for k in ${UNREADABLE[@]+"${UNREADABLE[@]}"}; do diag "UNREADABLE  $k  - its Compose labels are not plain names, so it cannot be listed and is never pruned; find out where it came from"; done
    for k in ${BAD[@]+"${BAD[@]}"}; do diag "BAD LINE  $k  - not name:<name> or compose:<project>/<service>"; done
    [ "$UNREVIEWED" -eq 1 ] && diag "NOT REVIEWED  - run Show, fix the list, then Confirm reviewed. Until then the prune removes no containers or images."
    diag ""
    diag "Change the list with Docker - Update Expected Containers [Lin] (usrAction add, remove, accept-current, add-ignore)."
    diag "List: $EXPECTED_FILE   Ignore patterns: $IGNORE_FILE"
    emit 1 "$SUMMARY"
fi
emit 0 "$SUMMARY"
