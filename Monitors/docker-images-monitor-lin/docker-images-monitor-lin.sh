#!/bin/bash
# Docker - Container Images Behind Registry [Lin]
# Datto RMM custom monitor. Runs as root. Safe to assign to every Linux device.
#
# Walks every running container, compares its local image digest against the
# digest its tag currently points to in the registry, and alerts on the ones
# that have fallen behind. Never pulls, so it cannot repoint a local tag or
# stage an unplanned upgrade.
#
# Containers on pinned version tags are reported in the status line but never
# alerted. Classification is by outcome, not by guesswork -- every image is
# checked, and a "pinned-looking" tag whose digest HAS moved (alpine3.19,
# php8.3-fpm and friends) is correctly treated as behind.
#
# A host with no Docker exits 0 and says so, so blanket assignment is safe.
#
# REGISTRY LOAD is the main design constraint. Three things keep it low:
#   1. A digest-only lookup is one cheap HEAD. The image build date, which
#      costs a manifest walk plus a config blob per platform, is fetched ONLY
#      for images that actually moved -- usually none.
#   2. Results are cached on disk for cacheHours, so a monitor on a 15-minute
#      schedule does not re-ask the registry 96 times a day for the same tags.
#   3. The first HTTP 429 trips a circuit breaker: no further lookups are made
#      this run, and everything unresolved falls back to cache. Being rate
#      limited is reported, never alerted on.
#
# Registry access goes through `docker buildx imagetools inspect`, which does
# the bearer-token handshake, reuses the host's existing docker login and
# honours the daemon's proxy settings. This script handles no credentials.
#
# Sites with several Docker hosts behind one NAT share Docker Hub's anonymous
# per-IP allowance. `docker login` as root with any free Docker account moves
# the host to a per-account allowance and largely removes the 429s.
#
# Input variables (all arrive as strings):
#   minAgeDays      String  default 7   ignore an update until the new image is this many days old
#   excludePattern  String  default ""  ERE matched against container names; matches are skipped
#   inspectTimeout  String  default 20  seconds allowed per registry lookup
#   maxParallel     String  default 3   concurrent registry lookups
#   cacheHours      String  default 12  reuse a previous lookup for this long

PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/snap/bin"

MIN_AGE="${minAgeDays:-7}"
EXCLUDE="${excludePattern:-}"
TIMEOUT="${inspectTimeout:-20}"
MAXPAR="${maxParallel:-3}"
CACHE_HOURS="${cacheHours:-12}"

# Free-text numeric inputs are attacker-adjacent; validate rather than trust.
[[ "$MIN_AGE"     =~ ^[0-9]+$ ]] || MIN_AGE=7
[[ "$TIMEOUT"     =~ ^[0-9]+$ ]] || TIMEOUT=20
[[ "$MAXPAR"      =~ ^[0-9]+$ ]] || MAXPAR=3
[[ "$CACHE_HOURS" =~ ^[0-9]+$ ]] || CACHE_HOURS=12
[ "$MAXPAR" -lt 1 ] && MAXPAR=1
[ "$MAXPAR" -gt 8 ] && MAXPAR=8

DIAG=""
diag() { DIAG="${DIAG}${1}"$'\n'; }

emit_result() {
    local msg="$1"
    msg="${msg//$'\n'/ }"
    [ "${#msg}" -gt 400 ] && msg="${msg:0:397}..."
    echo '<-Start Result->'
    echo "STATUS=${msg}"
    echo '<-End Result->'
}

emit_diag() {
    [ -z "$DIAG" ] && return 0
    echo '<-Start Diagnostic->'
    printf '%s' "$DIAG"
    echo '<-End Diagnostic->'
}

ok()   { save_cache; emit_result "$1"; exit 0; }
fail() { save_cache; emit_result "$1"; emit_diag; exit 1; }

join() {
    local sep="$1"; shift
    [ "$#" -eq 0 ] && return 0
    local out="$1" i; shift
    for i in "$@"; do out="${out}${sep}${i}"; done
    printf '%s' "$out"
}

strip_tag() {
    local r="${1%%@*}"
    case "${r##*/}" in *:*) printf '%s' "${r%:*}" ;; *) printf '%s' "$r" ;; esac
}
image_tag() {
    local r="${1%%@*}"
    case "${r##*/}" in *:*) printf '%s' "${r##*:}" ;; *) printf 'latest' ;; esac
}

# ---------------------------------------------------------------------- cache

# ref <TAB> digest <TAB> created <TAB> epoch-checked
CACHE=""
NEWCACHE=""
CACHE_FILE=""

init_cache() {
    local d
    for d in /var/lib/tc-docker-monitor /var/tmp/tc-docker-monitor; do
        if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
            CACHE_FILE="${d}/image-digests.tsv"
            break
        fi
    done
    [ -z "$CACHE_FILE" ] && return 0
    [ -r "$CACHE_FILE" ] && CACHE=$(cat "$CACHE_FILE" 2>/dev/null)
    return 0
}

# A long TTL means every host refreshes in one burst. Hosts built from the same
# image would then all refresh together and hammer the site's shared NAT address,
# so shave a stable per-host slice of up to 10% off the TTL. Stable, not random:
# a fresh roll each run would expire entries early at random.
JITTER=0
if [ "$CACHE_HOURS" -ge 24 ]; then
    JITTER=$(( $( (hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo host) \
                  | cksum | cut -d' ' -f1 ) % (CACHE_HOURS * 360) ))
fi
TTL=$(( CACHE_HOURS * 3600 - JITTER ))

# Prints the cached line for $1 if it is younger than the effective TTL.
cache_fresh() {
    local line age
    line=$(awk -F'\t' -v r="$1" '$1==r {print; exit}' <<< "$CACHE")
    [ -z "$line" ] && return 1
    age=$(printf '%s' "$line" | cut -f4)
    [[ "$age" =~ ^[0-9]+$ ]] || return 1
    [ $(( NOW - age )) -lt "$TTL" ] || return 1
    printf '%s' "$line"
}

cache_any() {  # cached line regardless of age, for fallback when rate limited
    awk -F'\t' -v r="$1" '$1==r {print; exit}' <<< "$CACHE"
}

save_cache() {
    [ -z "$CACHE_FILE" ] && return 0
    [ -z "$NEWCACHE" ] && return 0
    # Keep this run's entries, plus any older entry for a ref we did not revisit.
    {
        printf '%s\n' "$NEWCACHE"
        awk -F'\t' 'NR==FNR {seen[$1]; next} !($1 in seen)' \
            <(printf '%s\n' "$NEWCACHE") <(printf '%s\n' "$CACHE")
    } | grep -v '^$' > "${CACHE_FILE}.tmp" 2>/dev/null && \
        mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE" 2>/dev/null
    chmod 600 "$CACHE_FILE" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------- pre-flight

NOW=$(date +%s)

# Not a Docker host. Nothing to watch, nothing wrong -- this is why the monitor
# can be assigned to the whole Linux estate.
command -v docker >/dev/null 2>&1 || ok "Docker is not installed on this host; nothing to check"

if ! PS_OUT=$(docker ps --no-trunc --format '{{.ID}}' 2>&1); then
    diag "docker ps said: ${PS_OUT}"
    fail "Check could not run: cannot talk to the Docker daemon"
fi

[ -z "${PS_OUT//[[:space:]]/}" ] && ok "Docker is installed but no containers are running"

docker buildx version >/dev/null 2>&1 || \
    fail "Check could not run: docker buildx is missing; install the docker-buildx-plugin package on this host"

TMP=$(mktemp -d) || fail "Check could not run: cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT
BREAKER="${TMP}/rate-limited"

init_cache

# ------------------------------------------------------- gather local state

CIDS=(); NAMES=(); REFS=(); LOCALS=()
SKIPPED=(); EXCLUDED=0

while read -r CID; do
    [ -z "$CID" ] && continue

    CNAME=$(docker inspect -f '{{.Name}}' "$CID" 2>/dev/null); CNAME="${CNAME#/}"
    [ -z "$CNAME" ] && CNAME="${CID:0:12}"

    if [ -n "$EXCLUDE" ] && printf '%s' "$CNAME" | grep -qE "$EXCLUDE"; then
        EXCLUDED=$((EXCLUDED + 1))
        continue
    fi

    REF=$(docker inspect -f '{{.Config.Image}}' "$CID" 2>/dev/null)
    IMGID=$(docker inspect -f '{{.Image}}' "$CID" 2>/dev/null)

    if [ -z "$REF" ] || [[ "$REF" =~ ^(sha256:)?[0-9a-f]{12,}$ ]]; then
        REF=$(docker image inspect -f '{{index .RepoTags 0}}' "$IMGID" 2>/dev/null)
    fi
    if [ -z "$REF" ] || [ "$REF" = "<none>:<none>" ]; then
        SKIPPED+=("${CNAME} (no image tag)")
        continue
    fi

    REPO=$(strip_tag "$REF")
    LOCAL=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$IMGID" 2>/dev/null \
            | grep -F "${REPO}@" | head -1 | cut -d@ -f2)

    if [ -z "$LOCAL" ]; then
        SKIPPED+=("${CNAME} (local image, not from a registry)")
        continue
    fi

    CIDS+=("$CID"); NAMES+=("$CNAME"); REFS+=("$REF"); LOCALS+=("$LOCAL")
done <<< "$PS_OUT"

TOTAL=$(( ${#CIDS[@]} + ${#SKIPPED[@]} + EXCLUDED ))

if [ "${#CIDS[@]}" -eq 0 ]; then
    ok "$(printf '%d container(s) running, none checkable (%d excluded, %d without a registry image)' \
        "$TOTAL" "$EXCLUDED" "${#SKIPPED[@]}")"
fi

# --------------------------------------------- phase 1: digests, cheap and cached

mapfile -t UNIQ < <(printf '%s\n' "${REFS[@]}" | sort -u)

RESULTS=""
CACHED=0; QUERIED=0

TO_QUERY=()
for ref in "${UNIQ[@]}"; do
    if line=$(cache_fresh "$ref"); then
        RESULTS="${RESULTS}${line}"$'\n'
        CACHED=$((CACHED + 1))
    else
        TO_QUERY+=("$ref")
    fi
done

# Digest only. This is a single HEAD against the manifest -- asking for the
# image config here is what makes a sweep expensive, so it is deferred.
lookup_digest() {
    local ref="$1" out="$2" raw digest
    [ -e "$BREAKER" ] && { printf '%s\tSKIP\trate limited earlier this run\n' "$ref" > "$out"; return; }
    raw=$(timeout "$TIMEOUT" docker buildx imagetools inspect \
          --format '{{.Manifest.Digest}}' "$ref" 2>&1)
    digest=$(printf '%s' "$raw" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
    if [ -n "$digest" ]; then
        printf '%s\t%s\t\t%s\n' "$ref" "$digest" "$NOW" > "$out"
        return
    fi
    case "$raw" in
        *429*|*"Too Many Requests"*|*"toomanyrequests"*)
            : > "$BREAKER"
            printf '%s\tRATELIMIT\t%s\n' "$ref" "$(printf '%s' "$raw" | tr '\n\t' '  ' | cut -c1-160)" > "$out"
            ;;
        *)
            printf '%s\tERR\t%s\n' "$ref" "$(printf '%s' "$raw" | tr '\n\t' '  ' | cut -c1-160)" > "$out"
            ;;
    esac
}

n=0
for ref in "${TO_QUERY[@]}"; do
    [ -e "$BREAKER" ] && break
    while [ "$(jobs -rp | wc -l)" -ge "$MAXPAR" ]; do sleep 0.2; done
    n=$((n + 1))
    QUERIED=$((QUERIED + 1))
    lookup_digest "$ref" "${TMP}/d${n}" &
done
wait

[ "$n" -gt 0 ] && RESULTS="${RESULTS}$(cat "${TMP}"/d* 2>/dev/null)"$'\n'

# Rate limited or cut short by the breaker: a stale answer beats no answer, so
# fall back to whatever we knew before. Only refs we have never resolved are
# reported as deferred.
STALE=0
FILLED=""
for ref in "${UNIQ[@]}"; do
    cur=$(awk -F'\t' -v r="$ref" '$1==r {print $2; exit}' <<< "$RESULTS")
    case "$cur" in
        sha256:*) continue ;;                       # already have a real answer
        ERR)      continue ;;                       # a real failure, not a rate limit
    esac
    old=$(cache_any "$ref")
    if [ -n "$old" ] && [[ "$(printf '%s' "$old" | cut -f2)" == sha256:* ]]; then
        FILLED="${FILLED}${old}"$'\n'
        STALE=$((STALE + 1))
    elif [ -z "$cur" ]; then
        FILLED="${FILLED}${ref}"$'\tRATELIMIT\tnot attempted; rate limited earlier this run\n'
    fi
done
if [ -n "$FILLED" ]; then
    # Drop the placeholder lines the fallback supersedes, then append.
    RESULTS=$(awk -F'\t' 'NR==FNR {rep[$1]; next} !($1 in rep)' \
        <(printf '%s' "$FILLED") <(printf '%s' "$RESULTS"))$'\n'"${FILLED}"
fi

# --------------------------------- phase 2: build dates, only for images that moved

# Which unique refs actually differ from the local digest of a container using them?
MOVERS=()
for ref in "${UNIQ[@]}"; do
    remote=$(awk -F'\t' -v r="$ref" '$1==r {print $2; exit}' <<< "$RESULTS")
    case "$remote" in ""|ERR|RATELIMIT|SKIP) continue ;; esac
    have=$(awk -F'\t' -v r="$ref" '$1==r {print $3; exit}' <<< "$RESULTS")
    [ -n "$have" ] && continue          # created date already known from cache
    for i in "${!REFS[@]}"; do
        if [ "${REFS[$i]}" = "$ref" ] && [ "${LOCALS[$i]}" != "$remote" ]; then
            MOVERS+=("$ref"); break
        fi
    done
done

lookup_created() {
    local ref="$1" out="$2" raw created
    [ -e "$BREAKER" ] && { : > "$out"; return; }
    raw=$(timeout "$TIMEOUT" docker buildx imagetools inspect \
          --format '{{json .Image}}' "$ref" 2>&1)
    case "$raw" in *429*|*"Too Many Requests"*|*"toomanyrequests"*) : > "$BREAKER"; : > "$out"; return ;; esac
    # .Image is a map keyed by platform on multi-arch images and a bare config
    # on single-arch ones; the first "created" is right in both shapes.
    created=$(printf '%s' "$raw" | grep -oE '"created"[[:space:]]*:[[:space:]]*"[^"]+"' \
              | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    printf '%s\t%s\n' "$ref" "$created" > "$out"
}

m=0
for ref in "${MOVERS[@]}"; do
    [ -e "$BREAKER" ] && break
    while [ "$(jobs -rp | wc -l)" -ge "$MAXPAR" ]; do sleep 0.2; done
    m=$((m + 1))
    lookup_created "$ref" "${TMP}/c${m}" &
done
wait

if [ "$m" -gt 0 ]; then
    CREATED_MAP=$(cat "${TMP}"/c* 2>/dev/null)
    MERGED=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        r=$(printf '%s' "$line" | cut -f1)
        c=$(awk -F'\t' -v r="$r" '$1==r {print $2; exit}' <<< "$CREATED_MAP")
        if [ -n "$c" ]; then
            MERGED="${MERGED}$(printf '%s\t%s\t%s\t%s' \
                "$r" "$(printf '%s' "$line" | cut -f2)" "$c" "$(printf '%s' "$line" | cut -f4)")"$'\n'
        else
            MERGED="${MERGED}${line}"$'\n'
        fi
    done <<< "$RESULTS"
    RESULTS="$MERGED"
fi

# Only real answers go in the cache; errors and rate limits must not be sticky.
NEWCACHE=$(awk -F'\t' '$2 ~ /^sha256:/ {print}' <<< "$RESULTS")

# ------------------------------------------------------------------ classify

BEHIND=(); PENDING=(); CURRENT=(); PINNED=(); UNCHECKED=(); RATELIMITED=()

for i in "${!CIDS[@]}"; do
    CNAME="${NAMES[$i]}"; REF="${REFS[$i]}"; LOCAL="${LOCALS[$i]}"
    TAG=$(image_tag "$REF")

    LINE=$(awk -F'\t' -v r="$REF" '$1==r {print; exit}' <<< "$RESULTS")
    REMOTE=$(printf '%s' "$LINE" | cut -f2)
    CREATED=$(printf '%s' "$LINE" | cut -f3)

    case "$REMOTE" in
        RATELIMIT|SKIP)
            RATELIMITED+=("${CNAME}")
            continue ;;
        ""|ERR)
            UNCHECKED+=("${CNAME}")
            diag "${CNAME} (${REF}): registry lookup failed"
            diag "  ${CREATED:-no detail}"
            continue ;;
    esac

    if [ "$REMOTE" = "$LOCAL" ]; then
        if [[ "$TAG" =~ (^|[^a-zA-Z0-9])[vV]?[0-9]+\.[0-9]+ ]]; then
            PINNED+=("${CNAME}:${TAG}")
        else
            CURRENT+=("${CNAME}:${TAG}")
        fi
        continue
    fi

    AGE_DAYS=""
    if [ -n "$CREATED" ]; then
        BUILT=$(date -d "$CREATED" +%s 2>/dev/null)
        [ -n "$BUILT" ] && [ "$BUILT" -gt 0 ] && AGE_DAYS=$(( (NOW - BUILT) / 86400 ))
    fi

    # Unknown or nonsensical build date fails open: report rather than hide.
    if [ -n "$AGE_DAYS" ] && [ "$AGE_DAYS" -lt "$MIN_AGE" ]; then
        PENDING+=("${CNAME}:${TAG} (${AGE_DAYS}d)")
        continue
    fi

    BEHIND+=("${CNAME}:${TAG}${AGE_DAYS:+ (${AGE_DAYS}d)}")
    diag "${CNAME}"
    diag "  image           ${REF}"
    diag "  local digest    ${LOCAL}"
    diag "  registry digest ${REMOTE}"
    diag "  new image built ${CREATED:-unknown}${AGE_DAYS:+ (${AGE_DAYS} days ago)}"
    diag ""
done

# ---------------------------------------------------------------------- verdict

SUMMARY=$(printf '%d checked: %d behind, %d current, %d pinned' \
    "${#CIDS[@]}" "${#BEHIND[@]}" "${#CURRENT[@]}" "${#PINNED[@]}")
[ "${#PENDING[@]}"     -gt 0 ] && SUMMARY="${SUMMARY}, ${#PENDING[@]} update(s) newer than ${MIN_AGE}d"
[ "${#RATELIMITED[@]}" -gt 0 ] && SUMMARY="${SUMMARY}, ${#RATELIMITED[@]} deferred (registry rate limit)"
[ "${#UNCHECKED[@]}"   -gt 0 ] && SUMMARY="${SUMMARY}, ${#UNCHECKED[@]} unreadable"
[ "$EXCLUDED"          -gt 0 ] && SUMMARY="${SUMMARY}, ${EXCLUDED} excluded"
[ "${#SKIPPED[@]}"     -gt 0 ] && SUMMARY="${SUMMARY}, ${#SKIPPED[@]} not from a registry"
SUMMARY="${SUMMARY} [${CACHED} cached, ${QUERIED} queried"
[ "$STALE" -gt 0 ] && SUMMARY="${SUMMARY}, ${STALE} from stale cache"
SUMMARY="${SUMMARY}]"

if [ "${#BEHIND[@]}" -gt 0 ]; then
    [ "${#PINNED[@]}"      -gt 0 ] && diag "Pinned, no update path: $(join ', ' "${PINNED[@]}")"
    [ "${#PENDING[@]}"     -gt 0 ] && diag "Update available but younger than ${MIN_AGE} days: $(join ', ' "${PENDING[@]}")"
    [ "${#RATELIMITED[@]}" -gt 0 ] && diag "Deferred to the next run, registry rate limit: $(join ', ' "${RATELIMITED[@]}")"
    [ "${#SKIPPED[@]}"     -gt 0 ] && diag "Not checked: $(join ', ' "${SKIPPED[@]}")"
    fail "$(printf '%s. Behind: %s' "$SUMMARY" "$(join ', ' "${BEHIND[@]}")")"
fi

# Rate limiting is a registry telling us to slow down, not a fault on this host.
# Only a genuine total failure to read anything counts as the check not running.
if [ "${#UNCHECKED[@]}" -gt 0 ] && [ "${#UNCHECKED[@]}" -eq "${#CIDS[@]}" ]; then
    fail "Check could not run: no image could be read from any registry (${#CIDS[@]} attempted)"
fi

ok "$SUMMARY"