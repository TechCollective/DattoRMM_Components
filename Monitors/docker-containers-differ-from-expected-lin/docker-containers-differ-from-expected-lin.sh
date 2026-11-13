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
# Compose one-offs, --rm containers and anything matching /etc/tc-docker/ignore
# are never "unlisted". A host without Docker, or without a list yet, is healthy
# and says so. A daemon that cannot be reached, or that does not return its
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

usrUnlistedAfterHours="${usrUnlistedAfterHours:-24}"
usrUnlistedAction="$(printf '%s' "${usrUnlistedAction:-warn}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrMissingAction="$(printf '%s' "${usrMissingAction:-alert}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
usrUnreviewedAction="$(printf '%s' "${usrUnreviewedAction:-warn}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$usrUnlistedAfterHours" =~ ^[0-9]+$ ]] && [ "$usrUnlistedAfterHours" -le 8760 ] \
    || emit 1 "Check could not run: usrUnlistedAfterHours must be 0-8760 (got '$usrUnlistedAfterHours')"
case "$usrUnlistedAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrUnlistedAction must be alert, warn or ignore (got '$usrUnlistedAction')" ;; esac
case "$usrMissingAction"  in alert|warn) ;;        *) emit 1 "Check could not run: usrMissingAction must be alert or warn (got '$usrMissingAction')" ;; esac
case "$usrUnreviewedAction" in alert|warn|ignore) ;; *) emit 1 "Check could not run: usrUnreviewedAction must be alert, warn or ignore (got '$usrUnreviewedAction')" ;; esac
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

[ -e "$EXPECTED_FILE" ] || emit 0 "No expected-containers list on this host yet; Docker - Configure Host Maintenance [Lin] creates it"

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

ALERT=0
# Before review, stopped or missing containers are part of the review, not
# separate alerts: onboarding raises one "not reviewed" item, not one per container.
if [ $(( ${#STOPPED[@]} + ${#MISSING[@]} )) -gt 0 ] && [ "$usrMissingAction" = "alert" ] && [ "$UNREVIEWED" -eq 0 ]; then ALERT=1; fi
if [ "${#UNLISTED[@]}" -gt 0 ] && [ "$usrUnlistedAction" = "alert" ]; then ALERT=1; fi
if [ "${#UNREADABLE[@]}" -gt 0 ] && [ "$usrUnlistedAction" = "alert" ]; then ALERT=1; fi
if [ "$UNREVIEWED" -eq 1 ] && [ "$usrUnreviewedAction" = "alert" ]; then ALERT=1; fi

if [ "$ALERT" -eq 1 ]; then
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
