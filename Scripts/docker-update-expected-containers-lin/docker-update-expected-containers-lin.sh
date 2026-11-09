#!/usr/bin/env bash
# Docker - Update Expected Containers [Lin]
#
# Datto RMM Scripts component. Runs as root.
#
# The only component that changes a host's expected-containers list,
# /etc/tc-docker/expected-containers, and its ignore list, /etc/tc-docker/ignore.
# "Docker - Configure Host Maintenance [Lin]" creates the list once; the
# weekly prune keeps stopped containers that are on it; the monitor
# "Docker - Containers Differ From Expected [Lin]" compares it with what runs.
#
# usrAction:
#   show            print both lists and how they compare with what is running (default)
#   accept-current  replace the expected list with the containers running now
#   add / remove    add or remove the entries in usrItems
#   add-ignore / remove-ignore   the same for ignore patterns
#
# The previous version of a changed file is kept as <file>.prev.
#
# Exit codes:
#   0  done
#   1  unexpected failure
#   2  an input variable is invalid; nothing was changed
#   3  needs the Docker daemon (accept-current) and it is not reachable

set -u
umask 022
RESULT=1
finish() {
    local rc=$?
    if [ "$RESULT" -ne 0 ] && [ "$rc" -eq 0 ]; then rc=$RESULT; fi
    [ "$rc" -ne 0 ] && echo "Finished with exit code $rc."
    exit "$rc"
}
trap finish EXIT
say()  { echo "$*"; }
fail() { local code=$1; shift; echo "ERROR: $*"; RESULT=$code; exit "$code"; }

usrAction="${usrAction:-show}"
usrItems="${usrItems:-}"
usrAction="$(printf '%s' "$usrAction" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$usrAction" in
    show|accept-current|add|remove|add-ignore|remove-ignore) ;;
    *) fail 2 "usrAction must be show, accept-current, add, remove, add-ignore or remove-ignore (got '$usrAction')." ;;
esac

DOCKER="$(command -v docker 2>/dev/null || true)"
if [ -z "$DOCKER" ]; then
    say "Docker is not installed on this host; nothing to do."
    RESULT=0; exit 0
fi
DAEMON=0; "$DOCKER" info >/dev/null 2>&1 && DAEMON=1

# >>> tc-docker shared: identical in every tc-docker component; change them together.
TC_DIR="/etc/tc-docker"
EXPECTED_FILE="$TC_DIR/expected-containers"
IGNORE_FILE="$TC_DIR/ignore"
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
# <<< tc-docker shared

# ---------------------------------------------------------------- inputs

ITEMS=()
case "$usrAction" in
    add|remove)
        # Entries: compose:<project>/<service>, name:<name>, or a bare container
        # name, which becomes that container's key if it exists, else name:<it>.
        read -r -a raw <<<"${usrItems//,/ }"
        [ "${#raw[@]}" -gt 0 ] || fail 2 "usrAction=$usrAction needs at least one entry in usrItems."
        for it in "${raw[@]}"; do
            if [[ "$it" =~ $KEY_RE ]]; then
                ITEMS+=("$it")
            elif [[ "$it" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
                k=""
                [ $DAEMON -eq 1 ] && k="$(tc_containers | awk -F'\t' -v n="$it" '$3 == n {print $2; exit}')"
                ITEMS+=("${k:-name:$it}")
            else
                fail 2 "usrItems: '$it' is not a container name, name:<name> or compose:<project>/<service>."
            fi
        done ;;
    add-ignore|remove-ignore)
        # Patterns are separated by spaces only; a regex may contain commas.
        read -r -a ITEMS <<<"$usrItems"
        [ "${#ITEMS[@]}" -gt 0 ] || fail 2 "usrAction=$usrAction needs at least one pattern in usrItems."
        for p in "${ITEMS[@]}"; do
            printf 'x\n' | grep -E -- "$p" >/dev/null 2>&1; [ $? -le 1 ] \
                || fail 2 "usrItems: '$p' is not a valid extended regular expression."
        done ;;
esac

# ---------------------------------------------------------------- helpers

# Writes the entries on stdin to file $1 under header comment $2,
# keeping the previous file as $1.prev. Prints added/removed lines.
write_list() {
    local file="$1" header="$2" new old
    new="$(sort -u | grep -v '^$' || true)"
    old="$(tc_list "$file" | sort -u)"
    if [ -e "$file" ] && [ "$new" = "$old" ]; then
        say "$file: no change."
        return 0
    fi
    mkdir -p "$TC_DIR" && chmod 755 "$TC_DIR" || return 1
    [ -e "$file" ] && cp -p "$file" "$file.prev"
    {
        printf '%s\n' "$header"
        echo "# Last changed $(date '+%Y-%m-%d %H:%M %Z') by Docker - Update Expected Containers [Lin] ($usrAction)."
        if [ -n "$new" ]; then printf '%s\n' "$new"; fi
    } >"$file.tmp" && chmod 644 "$file.tmp" && mv -f "$file.tmp" "$file" || return 1
    comm -13 <(printf '%s\n' "$old" | grep -v '^$') <(printf '%s\n' "$new" | grep -v '^$') | sed 's/^/  added:   /'
    comm -23 <(printf '%s\n' "$old" | grep -v '^$') <(printf '%s\n' "$new" | grep -v '^$') | sed 's/^/  removed: /'
    say "$file: written ($(printf '%s\n' "$new" | grep -c . || true) entries; previous version kept as $file.prev)."
}

EXPECTED_HEADER="# Containers expected on this host, one per line.
#   compose:<project>/<service>  a Docker Compose service
#   name:<container name>        any other container"
IGNORE_HEADER="# Extended regular expressions, one per line, matched against a
# container's key (see expected-containers). A match is never
# reported as unexpected. Example for GitLab CI job containers:
#   ^name:runner-"

show() {
    say "Expected list ($EXPECTED_FILE):"
    if [ -e "$EXPECTED_FILE" ]; then tc_list "$EXPECTED_FILE" | sed 's/^/  /'; else say "  (does not exist yet)"; fi
    say "Ignore patterns ($IGNORE_FILE):"
    if [ -n "$(tc_list "$IGNORE_FILE")" ]; then tc_list "$IGNORE_FILE" | sed 's/^/  /'; else say "  (none)"; fi
    if [ $DAEMON -eq 0 ]; then say "The Docker daemon is not reachable, so there is no comparison."; return 0; fi
    local rows; rows="$(tc_containers)"
    say "Compared with this host now:"
    local k state
    while IFS= read -r k; do
        if printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k && $4 == "true" {f=1} END {exit !f}'; then state="running"
        elif printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k {f=1} END {exit !f}'; then state="STOPPED"
        else state="MISSING"; fi
        say "  $state  $k"
    done < <(tc_list "$EXPECTED_FILE")
    printf '%s\n' "$rows" | awk -F'\t' '$4 == "true" && $9 == "n" {print $2}' | sort -u | while IFS= read -r k; do
        tc_list "$EXPECTED_FILE" | grep -qxF -- "$k" && continue
        if tc_ignored "$k"; then say "  ignored  $k"; else say "  UNLISTED $k"; fi
    done
}

# ---------------------------------------------------------------- run

case "$usrAction" in
    show)
        show ;;
    accept-current)
        [ $DAEMON -eq 1 ] || fail 3 "the Docker daemon is not reachable, so the running containers cannot be read; nothing was changed."
        tc_containers | awk -F'\t' '$4 == "true" && $9 == "n" {print $2}' | while IFS= read -r k; do
            tc_ignored "$k" || printf '%s\n' "$k"
        done | write_list "$EXPECTED_FILE" "$EXPECTED_HEADER" || fail 1 "could not write $EXPECTED_FILE." ;;
    add)
        { tc_list "$EXPECTED_FILE"; printf '%s\n' "${ITEMS[@]}"; } \
            | write_list "$EXPECTED_FILE" "$EXPECTED_HEADER" || fail 1 "could not write $EXPECTED_FILE." ;;
    remove)
        for it in "${ITEMS[@]}"; do
            tc_list "$EXPECTED_FILE" | grep -qxF -- "$it" || say "  not on the list: $it"
        done
        tc_list "$EXPECTED_FILE" | grep -vxF -f <(printf '%s\n' "${ITEMS[@]}") \
            | write_list "$EXPECTED_FILE" "$EXPECTED_HEADER" || fail 1 "could not write $EXPECTED_FILE." ;;
    add-ignore)
        { tc_list "$IGNORE_FILE"; printf '%s\n' "${ITEMS[@]}"; } \
            | write_list "$IGNORE_FILE" "$IGNORE_HEADER" || fail 1 "could not write $IGNORE_FILE." ;;
    remove-ignore)
        tc_list "$IGNORE_FILE" | grep -vxF -f <(printf '%s\n' "${ITEMS[@]}") \
            | write_list "$IGNORE_FILE" "$IGNORE_HEADER" || fail 1 "could not write $IGNORE_FILE." ;;
esac
[ "$usrAction" != "show" ] && { say ""; show; }

RESULT=0
say "Done."
exit 0
