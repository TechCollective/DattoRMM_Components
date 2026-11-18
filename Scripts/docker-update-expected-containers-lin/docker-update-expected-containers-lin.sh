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
#   show            print both lists, the review state, and how they compare with
#                   the containers on this host (default). A stopped container
#                   the prune would remove is shown as waiting (recorded in
#                   /var/lib/tc-docker/pending-removal, with the time from which
#                   the prune can remove it) or not yet recorded
#   accept-current  replace the expected list with every container present now,
#                   running or stopped (not ignored, not one-offs or --rm)
#   confirm-reviewed  record that a person has checked the list. Until this has
#                   run once, the weekly prune removes no containers and no images.
#                   usrItems may carry a short note, e.g. who reviewed it.
#   add / remove    add or remove the entries in usrItems
#   add-ignore / remove-ignore   the same for ignore patterns
#
# The previous version of a changed file is kept as <file>.prev.
#
# It never starts a stopped Docker. Where systemd says docker.service is not
# active, it runs no docker command at all (on most installs docker.socket
# keeps listening while the service is stopped, and any docker command would
# start Docker again): show prints the lists and the review state with no
# comparison; accept-current, and add with a bare name, change nothing (exit 3);
# add with a key, remove, the ignore actions and confirm-reviewed need no daemon
# and work as usual. A bare name given to remove is then taken as name:<name>.
# The same holds when Docker does not answer docker info.
#
# Exit codes:
#   0  done
#   1  unexpected failure
#   2  an input variable is invalid; nothing was changed
#   3  nothing was changed because: accept-current or add (a bare name) needs
#      Docker's container list and Docker is stopped, did not answer, or did
#      not return it; accept-current found no containers and the list is not
#      empty (use remove for that); add was given a bare name whose container
#      has unreadable Compose labels; or confirm-reviewed was run on a host
#      that has no list yet

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
    show|accept-current|confirm-reviewed|add|remove|add-ignore|remove-ignore) ;;
    *) fail 2 "usrAction must be show, accept-current, confirm-reviewed, add, remove, add-ignore or remove-ignore (got '$usrAction')." ;;
esac

# One PATH rule, whatever PATH the agent gives the script: the usual system
# directories are appended (never prepended, so what the agent's PATH finds
# first still wins), so whether docker is found does not depend on the agent.
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

DOCKER="$(command -v docker 2>/dev/null || true)"
if [ -z "$DOCKER" ]; then
    say "Docker is not installed on this host; nothing to do."
    RESULT=0; exit 0
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

# Is Docker running? Asked once, without starting it: where systemd manages
# docker.service and says it is not active, no docker command is run at all,
# by this or by anything after it (any docker command would start Docker again
# through docker.socket). DAEMON is running, stopped or noanswer; NOT_RUNNING
# says why, for the messages.
DAEMON=running; NOT_RUNNING=""
tc_docker_running
case $? in
    0) ;;
    1) DAEMON=stopped
       NOT_RUNNING="Docker is stopped (${DOCKER_STATE:-docker.service is not active}) and was left stopped: this component ran no docker command" ;;
    *) DAEMON=noanswer
       NOT_RUNNING="the Docker daemon did not answer (docker info failed)" ;;
esac

# ---------------------------------------------------------------- inputs

ITEMS=()
NOTE=""
case "$usrAction" in
    confirm-reviewed)
        # A free-text note: printable characters only, at most 120 of them.
        NOTE="$(printf '%s' "$usrItems" | tr -cd '[:print:]' | cut -c1-120)" ;;
    add|remove)
        # Entries: compose:<project>/<service>, name:<name>, or a bare container
        # name, which becomes that container's key if it exists, else name:<it>.
        # A bare name needs Docker's container list. When Docker is not running
        # (stopped, or not answering), Add refuses one rather than guess, and
        # Remove takes it as name:<it>: removing only ever takes off what was named.
        read -r -a raw <<<"${usrItems//,/ }"
        [ "${#raw[@]}" -gt 0 ] || fail 2 "usrAction=$usrAction needs at least one entry in usrItems."
        ROWS=""; LISTED=0
        for it in "${raw[@]}"; do
            if [[ "$it" =~ $KEY_RE ]]; then
                ITEMS+=("$it")
            elif [[ "$it" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
                k=""
                if [ "$DAEMON" != running ] && [ "$usrAction" = add ]; then
                    fail 3 "$NOT_RUNNING, so '$it' cannot be matched to its container; nothing was changed. Give the key instead (name:$it or compose:<project>/<service>), or run Add again once Docker is running."
                elif [ "$DAEMON" != running ]; then
                    say "${NOT_RUNNING^}, so '$it' is taken as name:$it (a Compose service needs compose:<project>/<service>)."
                else
                    # Docker answers: a guess of name:<it> could be the wrong key for
                    # a Compose container, so a listing that fails stops here.
                    if [ $LISTED -eq 0 ]; then
                        ROWS="$(tc_containers)" || fail 3 "Docker did not return its container list, so '$it' cannot be matched to its container; nothing was changed. Give the key instead (name:$it or compose:<project>/<service>)."
                        LISTED=1
                    fi
                    k="$(printf '%s\n' "$ROWS" | awk -F'\t' -v n="$it" '$3 == n {print $2; exit}')"
                    case "$k" in unreadable:*)
                        fail 3 "container '$it' has Compose labels that are not plain names, so it has no key to add; nothing was changed." ;;
                    esac
                fi
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
# What the prune has recorded for removal: "id<TAB>epoch first recorded" for
# each well-formed line of its pending file (written by tc-docker-prune, version
# 9 and later). A missing file means nothing is waiting.
PENDING_FILE="/var/lib/tc-docker/pending-removal"
pending_records() {
    { [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] && [ -r "$PENDING_FILE" ]; } || return 0
    awk -F'\t' -v OFS='\t' -v keyre="$KEY_RE" '
        /^#/ { next }
        NF == 4 && length($1) == 64 && $1 !~ /[^0-9a-f]/ && $2 ~ keyre && $3 ~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && $4 ~ /^[0-9]+$/ && length($4) <= 10 { print $1, $2, $4 + 0 }' "$PENDING_FILE"
}
# A setting from the prune's settings file, as the component wrote it
# (NAME=whole number), or $2 when it is missing or not a whole number.
prune_setting() {
    local v
    v="$(sed -n "s/^$1=\([0-9]\{1,5\}\)\$/\1/p" /etc/default/tc-docker-prune 2>/dev/null | tail -n 1)"
    if [ -n "$v" ]; then printf '%s' "$((10#$v))"; else printf '%s' "$2"; fi
}

IGNORE_HEADER="# Extended regular expressions, one per line, matched against a
# container's key (see expected-containers). A match is never
# reported as unexpected. Example for GitLab CI job containers:
#   ^name:runner-"

show() {
    say "Expected list ($EXPECTED_FILE):"
    if [ -e "$EXPECTED_FILE" ]; then tc_list "$EXPECTED_FILE" | sed 's/^/  /'; else say "  (does not exist yet)"; fi
    say "Ignore patterns ($IGNORE_FILE):"
    if [ -n "$(tc_list "$IGNORE_FILE")" ]; then tc_list "$IGNORE_FILE" | sed 's/^/  /'; else say "  (none)"; fi
    if tc_reviewed; then say "Review: confirmed - $(head -n1 "$REVIEWED_FILE")"
    else say "Review: NOT REVIEWED. The weekly prune removes no containers and no images on this host until Confirm reviewed is run."; fi
    if [ "$DAEMON" != running ]; then say "${NOT_RUNNING^}, so there is no comparison."; return 0; fi
    local rows
    if ! rows="$(tc_containers)"; then
        say "Docker did not return its container list, so there is no comparison."
        return 0
    fi
    say "Compared with this host now:"
    local k state
    while IFS= read -r k; do
        if printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k && $4 == "true" {f=1} END {exit !f}'; then state="running"
        elif printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k {f=1} END {exit !f}'; then state="STOPPED"
        else state="MISSING"; fi
        say "  $state  $k"
    done < <(tc_list "$EXPECTED_FILE")
    printf '%s\n' "$rows" | awk -F'\t' '$4 == "true" && $9 == "n" && $2 !~ /^unreadable:/ {print $2}' | sort -u | while IFS= read -r k; do
        tc_list "$EXPECTED_FILE" | grep -qxF -- "$k" && continue
        if tc_ignored "$k"; then say "  ignored  $k"; else say "  UNLISTED $k"; fi
    done
    # Stopped containers the list does not protect (and no restart policy or
    # tc.keep does): once the list is reviewed the prune records each one that
    # has been stopped OLDER_THAN_HOURS, and removes it GRACE_HOURS later.
    local older grace pending id at
    older="$(prune_setting OLDER_THAN_HOURS 168)"; grace="$(prune_setting GRACE_HOURS 144)"
    pending="$(pending_records)"
    printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' '$4 != "true" && $9 == "n" && $8 == "n" && $5 != "always" && $5 != "unless-stopped" && $2 !~ /^unreadable:/ {print $2, $1}' \
        | sort -u | while IFS=$'\t' read -r k id; do
        tc_list "$EXPECTED_FILE" | grep -qxF -- "$k" && continue
        printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k && $4 == "true" {f=1} END {exit !f}' && continue
        if ! tc_reviewed; then
            say "  STOPPED, UNLISTED  $k  - nothing is removed until the list is reviewed; after that the prune records it, then removes it ${grace}h later; Add it to keep it"
            continue
        fi
        at="$(printf '%s\n' "$pending" | awk -F'\t' -v id="$id" -v k="$k" '$1 == id && $2 == k {print $3; exit}')"
        if [ -n "$at" ]; then
            say "  STOPPED, UNLISTED  $k  - WAITING: recorded for removal $(date -d "@$at" '+%Y-%m-%d %H:%M %Z'); the prune can remove it from $(date -d "@$(( at + grace * 3600 ))" '+%Y-%m-%d %H:%M %Z'); Add it to keep it"
        else
            say "  STOPPED, UNLISTED  $k  - not yet recorded for removal: the prune records it once it has been stopped ${older}h, then removes it ${grace}h later; Add it to keep it"
        fi
    done
    # Compose labels that are not plain names: no key, so never listed, and
    # never pruned. Named, not quoted - the label itself is untrusted.
    printf '%s\n' "$rows" | awk -F'\t' '$2 ~ /^unreadable:/ {print $3 " (" substr($1, 1, 12) ", " ($4 == "true" ? "running" : "stopped") ")"}' \
        | while IFS= read -r k; do
        say "  UNREADABLE  $k  - its Compose labels are not plain names; it cannot be listed and the prune never removes it"
    done
}

# ---------------------------------------------------------------- run

case "$usrAction" in
    show)
        show ;;
    accept-current)
        [ "$DAEMON" = running ] || fail 3 "$NOT_RUNNING, so its containers cannot be read; nothing was changed."
        ROWS="$(tc_containers)" || fail 3 "Docker did not return its container list; nothing was changed."
        KEYS="$(printf '%s\n' "$ROWS" | awk -F'\t' '$9 == "n" && $2 !~ /^unreadable:/ {print $2}' | sort -u | while IFS= read -r k; do
            [ -n "$k" ] || continue
            tc_ignored "$k" || printf '%s\n' "$k"
        done)"
        OLD_COUNT="$(tc_list "$EXPECTED_FILE" | grep -c . || true)"
        if [ -z "$KEYS" ] && [ "$OLD_COUNT" -gt 0 ]; then
            fail 3 "Accept current found no containers to list, and would replace the $OLD_COUNT entries on $EXPECTED_FILE with none; nothing was changed. If an empty list is really intended, use Remove."
        fi
        UNREADABLE="$(printf '%s\n' "$ROWS" | awk -F'\t' '$2 ~ /^unreadable:/ {print $3 " (" substr($1, 1, 12) ")"}')"
        if [ -n "$UNREADABLE" ]; then
            say "Left off the list - Compose labels are not plain names, so these have no key:"
            printf '%s\n' "$UNREADABLE" | sed 's/^/  /'
        fi
        printf '%s\n' "$KEYS" | write_list "$EXPECTED_FILE" "$EXPECTED_HEADER" || fail 1 "could not write $EXPECTED_FILE." ;;
    confirm-reviewed)
        [ -e "$EXPECTED_FILE" ] || fail 3 "$EXPECTED_FILE does not exist yet; run Docker - Configure Host Maintenance [Lin] first."
        mkdir -p "$TC_DIR" || fail 1 "could not create $TC_DIR."
        {
            printf '%s, %s entries%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$(tc_list "$EXPECTED_FILE" | wc -l)" "${NOTE:+, $NOTE}"
            echo "# Written by Docker - Update Expected Containers [Lin] (confirm-reviewed)."
            echo "# While this file exists, the weekly prune may remove stopped containers"
            echo "# that are not protected, and unused images. Delete it to stop that."
        } >"$REVIEWED_FILE.tmp" && chmod 644 "$REVIEWED_FILE.tmp" && mv -f "$REVIEWED_FILE.tmp" "$REVIEWED_FILE" \
            || fail 1 "could not write $REVIEWED_FILE."
        say "Review recorded in $REVIEWED_FILE: $(head -n1 "$REVIEWED_FILE")" ;;
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
