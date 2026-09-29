#!/usr/bin/env bash
# Tier 1 test for a macOS or Linux Datto RMM component: run it the way Datto
# would, then check that it did what its test.json says it should.
#
#   tools/test-harness/invoke-component-test.sh Applications/<component-folder>
#
# The macOS/Linux counterpart of Invoke-ComponentTest.ps1, reading the same
# test.json format (see README.md in this folder). The component runs as root
# with a clean environment, its input variables as environment variables and
# its attachments (files/) in the working directory - the shape Datto gives it.
# Steps that need a user run as a local standard user the harness creates.
#
# Built for DISPOSABLE machines - GitHub-hosted runners. It creates a local
# account and leaves behind whatever the component installed. It refuses to
# run outside GitHub Actions unless ALLOW_LOCAL=1, and even then only belongs
# on a VM you are about to throw away.
#
# Needs bash 3.2+ (macOS ships 3.2), jq, and passwordless sudo.
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "1" ]; then
    echo "This harness creates a local user and changes the machine. It only runs in GitHub Actions unless ALLOW_LOCAL=1 - and then only on a throwaway VM." >&2
    exit 2
fi
[ $# -eq 1 ] || { echo "usage: $0 <component-folder>" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
sudo -n true 2>/dev/null || { echo "passwordless sudo is required" >&2; exit 2; }

IN_CI=false; [ "${GITHUB_ACTIONS:-}" = "true" ] && IN_CI=true
COMP=$(cd "$1" && pwd) || exit 2
MANIFEST="$COMP/component.json"; SPEC="$COMP/test.json"
for f in "$MANIFEST" "$SPEC"; do [ -f "$f" ] || { echo "Missing $f" >&2; exit 2; }; done

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *) echo "Unsupported OS $(uname -s)" >&2; exit 2 ;;
esac

NAME=$(jq -r '.general.name // empty' "$MANIFEST"); [ -n "$NAME" ] || NAME=$(basename "$COMP")
INSTALL_TYPE=$(jq -r '.general.installType // "unix"' "$MANIFEST")
TIMEOUT=$(jq -r '.general.timeout // "600"' "$MANIFEST")
BODY="$COMP/$(jq -r '.body' "$MANIFEST")"
[ "$INSTALL_TYPE" = "unix" ] || { echo "installType '$INSTALL_TYPE' is not supported by the macOS/Linux harness" >&2; exit 2; }
[ -f "$BODY" ] || { echo "Missing component body $BODY" >&2; exit 2; }

WORK="${RUNNER_TEMP:-/tmp}/component-test"
mkdir -p "$WORK" && chmod 777 "$WORK"

TESTUSER=tctest
TESTUSER_HOME=""
# The PATH a root job gets from the agent, not the runner's developer PATH.
ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ROOT_HOME=/root; [ "$PLATFORM" = macos ] && ROOT_HOME=/var/root

# ---------------------------------------------------------------- output

R_STATUS=(); R_STEP=(); R_DETAIL=()
add_result() {   # status step detail
    R_STATUS+=("$1"); R_STEP+=("$2"); R_DETAIL+=("$3")
    echo "[$1] $2 - $3"
    if [ "$1" = FAIL ] && $IN_CI; then
        echo "::error title=$2::$(printf '%s' "$3" | tr '\r\n' '  ')"
    fi
}
block() {        # title text
    if $IN_CI; then echo "::group::$1"; else echo "----- $1"; fi
    if [ -n "$2" ]; then printf '%s\n' "$2"; else echo "(empty)"; fi
    if $IN_CI; then echo "::endgroup::"; fi
}

# ---------------------------------------------------------------- helpers

# Run "$@" with a time limit. macOS has no timeout(1), so this is portable.
# Sets RC; RC=124 means it was stopped for running too long.
run_limited() {
    local secs=$1; shift
    local flag="$WORK/.timeout.$$.$RANDOM"
    "$@" & local pid=$!
    ( sleep "$secs"; touch "$flag"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) &
    local wd=$!
    wait "$pid"; RC=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    if [ -e "$flag" ]; then RC=124; rm -f "$flag"; fi
}

# Fill {testuser} and {testuser_home} in a string from test.json.
expand() {
    local s=$1
    s=${s//\{testuser_home\}/$TESTUSER_HOME}
    s=${s//\{testuser\}/$TESTUSER}
    printf '%s' "$s"
}

create_test_user() {
    [ -n "$TESTUSER_HOME" ] && return 0
    # Not `tr </dev/urandom | head`: if SIGPIPE is ignored, BSD tr can keep
    # writing forever once head has exited. openssl reads a fixed amount.
    local pw; pw="Tc$(openssl rand -hex 12)1"
    if [ "$PLATFORM" = macos ]; then
        # dscl rather than sysadminctl/createhomedir, which can prompt or stall
        # on a headless Mac. Every command is time-limited, so a stall fails
        # the step instead of hanging the job.
        local uid
        uid=$(dscl . -list /Users UniqueID | awk '$2 > max { max = $2 } END { print (max < 600 ? 600 : max + 1) }')
        TESTUSER_HOME="/Users/$TESTUSER"
        local c
        for c in "-create /Users/$TESTUSER" \
                 "-create /Users/$TESTUSER UserShell /bin/bash" \
                 "-create /Users/$TESTUSER RealName Component-Test" \
                 "-create /Users/$TESTUSER UniqueID $uid" \
                 "-create /Users/$TESTUSER PrimaryGroupID 20" \
                 "-create /Users/$TESTUSER NFSHomeDirectory $TESTUSER_HOME"; do
            # shellcheck disable=SC2086  # c is deliberately split into arguments
            run_limited 60 sudo dscl . $c </dev/null >/dev/null 2>&1
            [ "$RC" -eq 0 ] || { echo "dscl . $c failed (exit $RC)" >&2; TESTUSER_HOME=""; return 1; }
        done
        run_limited 60 sudo dscl . -passwd "/Users/$TESTUSER" "$pw" </dev/null >/dev/null 2>&1
        sudo mkdir -p "$TESTUSER_HOME" && sudo chown "$TESTUSER:staff" "$TESTUSER_HOME" && sudo chmod 755 "$TESTUSER_HOME"
    else
        run_limited 60 sudo useradd -m -s /bin/bash "$TESTUSER" </dev/null >/dev/null 2>&1
        TESTUSER_HOME="/home/$TESTUSER"
    fi
    id "$TESTUSER" >/dev/null 2>&1 && sudo test -d "$TESTUSER_HOME" || { TESTUSER_HOME=""; return 1; }
    return 0
}

# Run a shell command string as root, the test user or the runner, stdin
# closed. Sets RC, OUT (stdout+stderr).
run_as() {   # who timeout command
    local who=$1 secs=$2 cmd=$3 out="$WORK/cmd.$$.$RANDOM.out"
    case "$who" in
        root)     run_limited "$secs" sudo env -i PATH="$ROOT_PATH" HOME="$ROOT_HOME" /bin/bash -c "$cmd" </dev/null >"$out" 2>&1 ;;
        testuser) run_limited "$secs" sudo -u "$TESTUSER" -H env PATH="$ROOT_PATH" /bin/bash -lc "$cmd" </dev/null >"$out" 2>&1 ;;
        runner)   run_limited "$secs" /bin/bash -c "$cmd" </dev/null >"$out" 2>&1 ;;
        *) echo "unknown 'as': $who" >"$out"; RC=2 ;;
    esac
    OUT=$(cat "$out" 2>/dev/null); rm -f "$out"
}

# Check OUT against a step's outputContains / outputNotContains.
# Sets MISSING (text of the first unmet expectation, or empty).
check_output() {   # step-json
    local t
    MISSING=""
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        grep -qiF -- "$t" <<<"$OUT" || { MISSING="output is missing: $t"; return; }
    done < <(jq -r '.outputContains[]? // empty' <<<"$1")
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        grep -qiF -- "$t" <<<"$OUT" && { MISSING="output should not contain: $t"; return; }
    done < <(jq -r '.outputNotContains[]? // empty' <<<"$1")
}

# ---------------------------------------------------------------- steps

STEP_COUNT=$(jq '.steps | length' "$SPEC")
[ "$STEP_COUNT" -gt 0 ] || { echo "$SPEC has no steps" >&2; exit 2; }
echo "Component: $NAME"
echo "Body:      $BODY (unix, timeout ${TIMEOUT}s)"
echo "Platform:  $PLATFORM ($(uname -sr), $(uname -m))"
echo "Steps:     $STEP_COUNT"
echo

stop=false
n=0
for ((i = 0; i < STEP_COUNT; i++)); do
    step=$(jq -c ".steps[$i]" "$SPEC")
    j() { jq -r "$1" <<<"$step"; }

    # A step limited to other platforms is not this run's business at all.
    plats=$(j '(.platforms // []) | join(",")')
    if [ -n "$plats" ] && [[ ",$plats," != *",$PLATFORM,"* ]]; then continue; fi
    n=$((n + 1))
    type=$(j '.type // ""'); label=$(j '.label // ""'); [ -n "$label" ] || label=$type
    label="$n. $label"

    if [ "$(j '.tier // 1')" -gt 1 ]; then
        add_result SKIP "$label" "Tier $(j .tier) only - needs a real logon or a real account, which a CI runner cannot provide."
        continue
    fi
    if $stop; then add_result FAIL "$label" "Skipped: an earlier component run failed."; continue; fi
    # A timestamp per step, so a slow or stuck step shows where it is.
    echo "--- $label (started $(date '+%H:%M:%S'))"
    as=$(j '.as // "root"')
    if [ "$as" = testuser ] && [ -z "$TESTUSER_HOME" ]; then create_test_user || { add_result FAIL "$label" "Could not create the test user."; continue; }; fi

    case "$type" in

    testUser)
        # Create the test user before the component runs, for components
        # that act on the users already on the machine.
        if ! create_test_user; then add_result FAIL "$label" "Could not create the test user '$TESTUSER'."; continue; fi
        if [ "$(j '.desktop // true')" = true ]; then
            sudo -u "$TESTUSER" mkdir -p "$TESTUSER_HOME/Desktop"
        fi
        add_result PASS "$label" "Created '$TESTUSER' ($(id -u "$TESTUSER")), home $TESTUSER_HOME$( [ "$(j '.desktop // true')" = true ] && echo ', with a Desktop folder')."
        ;;

    runComponent)
        # A fresh working directory per run: the body plus its attachments,
        # which is where Datto puts them.
        rundir="$WORK/run-$n"; rm -rf "$rundir"; mkdir -p "$rundir"
        cp "$BODY" "$rundir/"; [ -d "$COMP/files" ] && cp -R "$COMP/files/." "$rundir/"
        runbody="$rundir/$(basename "$BODY")"; chmod 755 "$runbody"
        # Variables: component.json defaults, then test.json, then this step.
        envargs=()
        while IFS= read -r -d '' kv; do envargs+=("$kv"); done < <(
            jq -j -n --slurpfile m "$MANIFEST" --slurpfile s "$SPEC" --argjson st "$step" '
                ([ $m[0].variables[]? | { (.name): (.defaultVal // "") } ] | add // {})
                + ($s[0].variables // {}) + ($st.variables // {})
                | to_entries[] | "\(.key)=\(.value | tostring)\u0000"')
        out="$rundir/stdout.txt"
        # Honour the shebang, as Datto does for unix components.
        # (${envargs[@]+...}: bash 3.2 on macOS treats an empty array as unset under set -u.)
        run_limited "$TIMEOUT" sudo env -i PATH="$ROOT_PATH" HOME="$ROOT_HOME" ${envargs[@]+"${envargs[@]}"} /bin/sh -c 'cd "$1" && exec "$2"' _ "$rundir" "$runbody" </dev/null >"$out" 2>&1
        OUT=$(cat "$out")
        block "$label - output" "$OUT"
        want=$(j '.expectExitCode // 0')
        if [ "$RC" -eq 124 ]; then
            add_result FAIL "$label" "Timed out after ${TIMEOUT}s (component.json timeout)."; stop=true
        elif [ "$RC" -ne "$want" ]; then
            add_result FAIL "$label" "Exit code $RC, expected $want."; stop=true
        else
            check_output "$step"
            if [ -n "$MISSING" ]; then add_result FAIL "$label" "Exit code $RC as expected, but $MISSING"
            else add_result PASS "$label" "Exit code $RC as expected."; fi
        fi
        ;;

    file)
        path=$(expand "$(j '.path')")
        if [ "$(j '.exists // true')" = false ]; then
            if sudo test -e "$path"; then add_result FAIL "$label" "Present but should not be: $path"
            else add_result PASS "$label" "Absent as expected: $path"; fi
            continue
        fi
        if ! sudo test -e "$path"; then
            near=$(sudo find "$(dirname "$path")" -maxdepth 1 2>/dev/null | head -n 10 | tr '\n' ' ')
            add_result FAIL "$label" "Not found: $path.${near:+ That folder holds: $near}"
            continue
        fi
        problems=()
        if [ "$(j '.executable // false')" = true ] && ! sudo test -x "$path"; then problems+=("not executable"); fi
        owner=$(j '.owner // empty')
        if [ -n "$owner" ]; then
            [ "$owner" = testuser ] && owner=$TESTUSER
            if [ "$PLATFORM" = macos ]; then actual=$(sudo stat -f '%Su' "$path"); else actual=$(sudo stat -c '%U' "$path"); fi
            [ "$actual" = "$owner" ] || problems+=("owned by $actual, not $owner")
        fi
        if [ "$(j '(.contains // []) + (.notContains // []) | length')" -gt 0 ]; then
            text=$(sudo cat "$path" 2>/dev/null)
            while IFS= read -r t; do
                [ -n "$t" ] && ! grep -qF -- "$(expand "$t")" <<<"$text" && problems+=("does not contain: $(expand "$t")")
            done < <(j '.contains[]? // empty')
            while IFS= read -r t; do
                [ -n "$t" ] && grep -qF -- "$(expand "$t")" <<<"$text" && problems+=("still contains: $(expand "$t")")
            done < <(j '.notContains[]? // empty')
        fi
        if [ ${#problems[@]} -eq 0 ]; then add_result PASS "$label" "Found: $path"
        else add_result FAIL "$label" "$path: $(IFS='; '; echo "${problems[*]}")"; fi
        ;;

    command)
        # Run a command and check its exit code and output. The workhorse for
        # "does the installed thing actually work, as the user who will use it".
        cmd=$(expand "$(j '.run')")
        secs=$(j '.timeoutSeconds // 120')
        run_as "$as" "$secs" "$cmd"
        block "$label - output" "$OUT"
        want=$(j '.expectExitCode // 0')
        if [ "$RC" -eq 124 ]; then add_result FAIL "$label" "Timed out after ${secs}s: $cmd"
        elif [ "$RC" -ne "$want" ]; then add_result FAIL "$label" "Exit code $RC, expected $want, as $as: $cmd"
        else
            check_output "$step"
            if [ -n "$MISSING" ]; then add_result FAIL "$label" "Exit code $RC as expected, but $MISSING"
            else add_result PASS "$label" "Exit code $RC as expected, as $as: $cmd"; fi
        fi
        ;;

    *)
        add_result FAIL "$label" "Step type '$type' is not supported by the macOS/Linux harness. See tools/test-harness/README.md."
        ;;
    esac
done

# ---------------------------------------------------------------- report

pass=0; fail=0; skip=0
for s in ${R_STATUS[@]+"${R_STATUS[@]}"}; do
    case "$s" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; SKIP) skip=$((skip+1));; esac
done
echo
echo "$NAME on $PLATFORM: $pass passed, $fail failed, $skip skipped (Tier 2)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### $NAME ($PLATFORM)"
        echo
        echo "| | Step | Detail |"
        echo "|---|---|---|"
        for ((k = 0; k < ${#R_STATUS[@]}; k++)); do
            icon=${R_STATUS[$k]}; [ "$icon" = FAIL ] && icon="**FAIL**"
            detail=$(printf '%s' "${R_DETAIL[$k]}" | tr '\r\n' '  ' | sed 's/|/\\|/g')
            echo "| $icon | ${R_STEP[$k]} | $detail |"
        done
        echo
    } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$fail" -eq 0 ]
