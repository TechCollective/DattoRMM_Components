# Docker Images monitor [Lin]

A Datto RMM custom monitor for Linux Docker hosts. It alerts when a running
container's image has fallen behind the image its tag now points to in the
registry.

> **Status: Not Validated.** Added to the repo 2026-11-09, exactly as it is
> deployed in the Component Library (uid `2fcd5983-d1dd-42fd-a459-15cc8ac0af64`,
> version 1). `cpt.py pack` on this folder rebuilds that export's
> `resource.xml` and body byte for byte. The script has been in production
> since before it was version controlled. It has not been reviewed against
> the monitor contract here; see [Known issues](#known-issues).

## What it does

Each run checks every running container. It compares the image digest the
container is running with the digest its tag currently points to in the
registry.

**Read-only.** It never pulls, so it cannot move a local tag or start an
upgrade. The only thing it writes is its own cache file. Its network calls are
registry lookups through `docker buildx imagetools inspect`, which:

- uses the host's existing `docker login`,
- honours the daemon's proxy settings,
- handles no credentials itself.

| Outcome | Alerts? |
|---|---|
| **Behind**: the registry digest differs and the new image is at least `minAgeDays` old | **Yes** |
| **Pending**: the registry digest differs but the new image is younger than `minAgeDays` | No; counted in the status |
| **Current**: same digest, on a moving tag (`latest`, `stable`) | No |
| **Pinned**: same digest, on a version-looking tag (`1.25`, `v3.2`) | No; reported, never alerted |
| **Deferred**: the registry rate-limited the lookup | No; served from stale cache where possible |
| **Unreadable**: the lookup failed for another reason | No, unless *every* container is unreadable |

It classifies by outcome. A tag that looks pinned but whose digest has moved
(`alpine3.19`, `php8.3-fpm`) is correctly reported as behind.

### Registry load

The main design constraint is how often it asks the registry. Three things
keep that low:

1. **Digest lookups are cheap.** Each is one HEAD request. The build date costs
   a manifest walk and a config blob, so it is fetched only for images that
   moved.
2. **Results are cached** for `cacheHours`. When `cacheHours` is 24 or more,
   each host shaves a stable slice of up to 10% off it. That stops many hosts
   behind one NAT address from all refreshing at once.
3. **The first HTTP 429 stops all further lookups** for that run. Anything
   unresolved falls back to the cache.

Several Docker hosts behind one NAT address share Docker Hub's anonymous
per-IP allowance. Running `docker login` as root with any free Docker account
moves a host to a per-account allowance.

### State file

The cache is `/var/lib/tc-docker-monitor/image-digests.tsv`, falling back to
`/var/tmp/tc-docker-monitor/`. It has mode 600 and four tab-separated columns:
ref, digest, created, and the epoch checked. It shares that directory with
`Docker - Container Health and Resource Usage [Lin]`.

## Installing it in Datto

These are the values the deployed component carries.

| Field | Value |
|---|---|
| Name | `Docker Images monitor [Lin]` |
| Description | Alerts when a container on a moving tag is behind its registry tag by over N days; containers on pinned tags are reported, never alerted. |
| Category | **Monitors**. Permanent; cannot be changed after the first save. |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | 4, as deployed. Not standardised. |
| Timeout | 3600 seconds, as deployed. See Known issues. |
| Attachments | none |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `minAgeDays` | String | `7` | Days a new image must exist before it counts. `0` disables the wait. |
| `excludePattern` | String | *(empty)* | Extended regex matched against container names, e.g. `^(postgres\|mysql)`. |
| `inspectTimeout` | String | `20` | Seconds per registry lookup. 10–60. |
| `maxParallel` | String | `3` | Concurrent lookups, clamped to 1–8. |
| `cacheHours` | String | `12` | How long a lookup is reused. `168` = weekly. |

No customer-specific value is hardcoded. A non-numeric value is **silently
replaced with the default**; see Known issues.

## Exit behaviour

| Host state | Result |
|---|---|
| Docker not installed | **Exit 0**: "Docker is not installed on this host; nothing to check" |
| Docker installed, no containers running | **Exit 0**, and says so |
| Daemon unreachable | **Exit 1**: "Check could not run: cannot talk to the Docker daemon" |
| `docker buildx` missing | **Exit 1**, naming the `docker-buildx-plugin` package |
| No container uses a registry image | **Exit 0**, counted in the status |
| One or more containers behind | **Exit 1**, with a diagnostic per container: image, local and registry digests, build date |
| Every lookup failed (not rate limiting) | **Exit 1**: "no image could be read from any registry" |
| Rate limited | **Exit 0**. Reported, never alerted on. |
| The script dies unexpectedly | **Not handled.** No fallback result block; see Known issues. |

Safe to assign to every Linux device, because a host without Docker exits 0.

## How to tell it worked

A healthy status reads like:

    STATUS=4 checked: 0 behind, 3 current, 1 pinned [0 cached, 4 queried]

On the next run within `cacheHours`, it should show the lookups as cached
(`[4 cached, 0 queried]`). If it never does, the state directory isn't
writable.

## Test order

1. One internal Docker host, saved as a **Scripts** component. Run it twice and
   read the raw output.
2. One site, one device, with the job scoped to that device.
3. Save as a Monitor and widen.

## Known issues

These are to be fixed in a follow-up change. The fixes go in by pasting a new
body over this component in Datto, not by re-importing, so its uid and
monitoring policies stay in place.

- **Two names.** The script header calls it
  `Docker - Container Images Behind Registry [Lin]`, which follows the naming
  standard. The Datto name, `Docker Images monitor [Lin]`, does not.
- **Bad input is silently replaced.** For example, `inspectTimeout=abc` becomes
  `20`. The repo standard is to refuse with `STATUS=Check could not run: ...`.
- **No `EXIT` trap.** An unexpected death prints no result block, which Datto
  shows as an alert with no text.
- **The timeout is 3600 seconds.** That is far more than its lookups need.

## Known limits

- Docker only. Podman is not handled.
- It needs the `docker buildx` plugin.
- `date -d` for the build date is a GNU spelling. Elsewhere the age is unknown,
  and an unknown age is reported as behind rather than hidden.
- It only checks *running* containers.
