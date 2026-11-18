# Docker Images monitor [Lin]

A Datto RMM custom monitor for Linux Docker hosts. It alerts when a running
container's image has fallen behind the image its tag now points to in the
registry, and when an image's registry has not answered for days.

> **Status: Not Validated.** Version 1 was added to the repo 2026-11-09,
> exactly as it is deployed in the Component Library (uid
> `2fcd5983-d1dd-42fd-a459-15cc8ac0af64`); it had been in production since
> before it was version controlled. **Version 2** (2026-11-17) hardens it: a
> root-only state directory with no `/var/tmp` fallback, a result inside 90
> seconds on every path, a stopped Docker left stopped, one PATH rule, a
> rate-limit match that no longer trips on any `429` in an error, per-image
> staleness (`staleAfterDays`), invalid input refused, and a fallback result
> block on an unexpected exit. Version 2 was exercised through its Tier 1
> `test.json` against a live Docker 29 daemon and a local test registry in a
> sandbox, except the stopped-Docker steps, which need systemd (run in CI). It
> has not yet run through a Datto agent. **Version 3** (2026-11-17) brings it
> to the repo standard: the input variables take the `usr` prefix (the old
> names are still read; see [Input variables](#input-variables)), the script
> runs under `set -u`, and the container list takes three docker commands
> whatever the number of containers, instead of four or five per container
> (see [Listing the containers](#listing-the-containers)). Version 3 was
> exercised through its Tier 1 `test.json` against a live Docker 29 daemon in
> a sandbox, except the steps that need systemd or GNU bash 4.2 (run in CI);
> it has not run through a Datto agent. **Version 4** (2026-11-17) changes
> comments only: the time-limit code (`bounded`, `systemd_up`,
> `docker_unit_loaded`) is marked as a shared block, `tc-docker bounded`, with
> the other two Docker monitors, and the first line of the `tc-docker running`
> block says it is identical in every tc-docker component. Every line of code
> is the same as version 3's. Through its Tier 1 `test.json` in a sandbox with
> no systemd and no bash 4.2, every step gave the result it gave for version
> 3 there; the bash 4.2 and stopped-Docker steps run in CI, and version 4 has
> not run through a Datto agent. Run its script once as a **Scripts**
> component first; see [Test order](#test-order).
>
> **Version 5** (2026-11-17): the result and diagnostic code is now the block
> marked `tc-docker result`, shared with the other two Docker monitors: one
> `emit`, one `diag`, one `EXIT` trap, one status limit. See
> [One result block](#one-result-block). **The status is cut at 900
> characters, not 400**, so a long status (many containers behind, several
> stale references) now shows more of itself; a run of spaces in it becomes
> one. **And one defect is fixed.** Versions 2 to 4 removed, on every early
> exit, whatever directory a `TMP` variable in the monitor's environment
> named, with everything in it: the `EXIT` trap (new in version 2) ran
> `rm -rf "$TMP"`, and `TMP` was the script's own only once its scratch
> directory had been made. An exit before that point (Docker not installed,
> Docker stopped, an invalid input) with `TMP=/tmp` inherited from the agent
> would have removed `/tmp`. Linux does not set `TMP` by default, so a host is
> exposed only where the agent's environment carries one. Version 5 keeps its
> scratch directory under a name of its own, set before anything can exit,
> and never reads `TMP`. Version 1 set its trap after making the directory and
> did not have the defect. **The cache file moves** from
> `/var/lib/tc-docker-monitor` to `/var/lib/tc-docker`, the directory the
> prune and the Containers monitor already use, and is written with the
> function they use (`tc_state_write`, in the shared block `tc-docker
> state`). The first run of version 5 reads the old file once, so nothing is
> looked up again and no error history is lost; the old directory is never
> changed or removed, and can be deleted by hand once every monitor on the
> host is on its new version. Two things differ from version 4: **a symlink
> in the cache file's place is refused**, not replaced (the run then caches
> nothing and says so), and the status says `state not saved (<why>)` where
> version 4 said `no saved state (<why>)` or `saved state could not be
> written to ...`. See [State file](#state-file).

## What it does

Each run checks every running container. It compares the image digest the
container is running with the digest its tag currently points to in the
registry.

**Read-only.** It never pulls, so it cannot move a local tag or start an
upgrade. The only thing it keeps is its own cache file, in `/var/lib/tc-docker`
(which it creates, root-only, when it is not there); during a run it also
has a scratch directory from `mktemp -d` (under `$TMPDIR`, else `/tmp`), one
small file per registry lookup, removed on every way out. Its network calls are
registry lookups through `docker buildx imagetools inspect`, which:

- uses the host's existing `docker login`,
- honours the daemon's proxy settings,
- handles no credentials itself.

| Outcome | Alerts? |
|---|---|
| **Behind**: the registry digest differs and the new image is at least `usrMinAgeDays` old | **Yes** |
| **Pending**: the registry digest differs but the new image is younger than `usrMinAgeDays` | No; counted in the status |
| **Current**: same digest, on a moving tag (`latest`, `stable`) | No |
| **Pinned**: same digest, on a version-looking tag (`1.25`, `v3.2`) | No; reported, never alerted |
| **Deferred**: rate limited, or not reached before the run's time limit | No; served from the cache where possible |
| **Unreadable**: the lookup failed for another reason | No, unless *every* container is unreadable |
| **Stale**: an image reference has had no successful registry answer for `usrStaleAfterDays` | **Yes**, naming the reference, the last error and since when |

It classifies by outcome. A tag that looks pinned but whose digest has moved
(`alpine3.19`, `php8.3-fpm`) is correctly reported as behind.

### Docker stopped, missing or not answering

Checked before anything else, in this order:

| Host state | Result |
|---|---|
| No `docker` command on PATH or in the usual system directories, and no socket or `docker.service` | Exit 0: not installed |
| No `docker` command, but `/var/run/docker.sock` is a socket or `docker.service` is loaded | **Exit 1**: Docker looks installed but its client is missing |
| systemd says `docker.service` is not active | Exit 0: `Docker is stopped (docker.service is inactive); nothing to check`. **No docker command is run**, because any one would start Docker again through `docker.socket` |
| A docker client, but no `docker.service` and no socket | Exit 0: no daemon on this host |
| `docker info` fails otherwise | **Exit 1**: cannot talk to the Docker daemon |
| Docker accepts the connection and never answers | **Exit 1** after 40 seconds: `Check could not run: Docker did not answer within 40 seconds` |

Every command that talks to the daemon shares one deadline, 40 seconds after
the monitor starts. What is still running then is stopped: `timeout(1)` sends
TERM to the process group of the docker commands this run started, then KILL to
anything left in it. Nothing else is signalled. The whole check uses the same
mechanism as `Docker - Containers Differ From Expected [Lin]`, and the same
shared "is Docker running" block: the time limit is the block marked
`tc-docker bounded` (three copies, one in each Docker monitor) and the check
is the block marked `tc-docker running` (six copies, one in every Docker
component and in the prune). From version 5 the result code is the block
`tc-docker result` (the three monitors), the cache file is written by
`tc-docker state` (the three monitors and the prune) and read by `tc-docker
monitor state` (this monitor and the Health monitor).
`tools/check-shared-blocks.py` keeps the copies identical.

### Listing the containers

The container list takes three docker commands, whatever the number of
running containers: one `docker ps`, one `docker inspect` over every container
(name, image reference, image id), and one `docker image inspect` over the
distinct images (tags, repo digests). Version 2 ran four or five per container.
Measured with a shim that counts docker commands, on 10 running containers:

| | docker ps | docker inspect | docker image inspect | Total for the list |
|---|---|---|---|---|
| Version 2 | 1 | 30 | 10 | **41** |
| Version 3 | 1 | 1 | 1 | **3** |

- **A container that goes away mid-listing.** A container removed between
  `docker ps` and `docker inspect` (or its image between the two inspects)
  makes that call fail, so the whole listing is retried: three tries, one
  second apart. When no try succeeds the result is exit 1, `Check could not
  run: Docker did not return its container list`. It is never read as "no
  containers". Version 2 counted such a container as one with no image tag.
- **Values are read JSON-encoded.** Each value is kept only when it is a plain
  name, image reference, digest or id. Nothing in a name, tag or digest can add
  a row or a field. A name that is not plain is shown as the first 12
  characters of the container id. A reference or tag that is not plain counts
  as no image tag. A digest that is not plain is ignored.
- **No map keys.** The templates read only fixed fields, never a map key. On
  Docker 29 a template that addresses a missing map key can fail the whole
  call.

The rows are the same as version 2's, with the same skip reasons. A container
whose image reference is empty or an image id (run by id) is checked under its
image's first tag. A container with no usable tag is skipped as `no image
tag`. A container whose image has no repo digest for that repository is skipped
as `local image, not from a registry`.

### Registry load

The main design constraint is how often it asks the registry. Three things
keep that low:

1. **Digest lookups are cheap.** Each is one HEAD request. The build date costs
   a manifest walk and a config blob, so it is fetched only for images that
   moved.
2. **Results are cached** for `usrCacheHours`. When `usrCacheHours` is 24 or more,
   each host shaves a stable slice of up to 10% off it. That stops many hosts
   behind one NAT address from all refreshing at once.
3. **The first rate-limit answer stops all further lookups** for that run.
   Anything unresolved falls back to the cache. Only the registry's own words
   count as a rate limit: `429 Too Many Requests` or `toomanyrequests`. Version
   1 matched the digits `429` anywhere in the error, so an error naming port
   4290 or an address containing 429 tripped the breaker and deferred every
   other lookup.

Each lookup has its own time limit, `usrInspectTimeout`, and no lookup runs past
75 seconds after the monitor started. What was not looked up by then is served
from the cache and counted as deferred; the next run carries on, because what
was answered is now cached.

Several Docker hosts behind one NAT address share Docker Hub's anonymous
per-IP allowance. Running `docker login` as root with any free Docker account
moves a host to a per-account allowance.

### Staleness: a registry that stopped answering

Version 1 alerted only when *every* image was unreadable, so a broken registry
login for one image, or permanent rate limiting, never surfaced. Version 2
records, for each image reference, when the registry last answered it and the
kind of the last error:

| Error kind | What the registry said |
|---|---|
| rate limited | `429 Too Many Requests`, `toomanyrequests` |
| refused | `401 Unauthorized`, `403 Forbidden`, denied, authentication required |
| not found | manifest unknown, name unknown, `404 Not Found` |
| timeout | no answer within the lookup's time limit |
| other | anything else (network, TLS, connection refused) |

A reference with no successful answer for `usrStaleAfterDays` (default 7) makes
the monitor alert, for example:

    STATUS=3 checked: 0 behind, 3 current, 0 pinned [0 cached, 1 queried, 2 from stale cache, rate limited]. No registry answer for 7+ days: registry.example/app:latest (rate limited, no registry answer since 2026-11-09)

The diagnostic gives the last error text. A stale cached digest is still used
for the behind/current comparison, as in version 1. The all-unreadable alert
is kept. A cache hit is not a lookup, so a reference served from the cache is
never stale; only failed lookups age it.

### State file

`/var/lib/tc-docker/image-digests.tsv`: the cache of registry answers, and
each reference's error history.

How it is written, and when it is not (the same rules, and from version 5 the
same code, for every file the Docker components keep in that directory):

- **One directory**, `/var/lib/tc-docker`, for everything the Docker components
  keep on a host: the prune's `pending-removal`, the Containers monitor's
  `monitor-first-seen`, the Health monitor's `monitor-state.tsv` and the
  Images monitor's `image-digests.tsv`. There is no fallback directory.
- **One way to write a file there**, `tc_state_write`, in the block marked
  `tc-docker state` (four copies: the prune and the three monitors; CI's
  "Shared blocks match" check compares them). A new file (0600) is made in the
  directory, written, read back and compared, then renamed over the old one,
  so a reader sees the old file or the new one and never part of one.
- **The directory** is created when missing and made `root:root 0700` when it
  is root's but is not that.
- **Nothing is written** when the directory is a symlink or is not a
  directory, **is not owned by root**, or cannot be created or made
  root-only; when the file's name is there as a symlink or as anything but a
  regular file (a symlink is never followed, written through or replaced);
  when no file can be created in the directory; when what was written does
  not read back the same (a full disk); or when the rename fails.

**How it is read.** Only when `/var/lib/tc-docker` is a real directory (not a
symlink) owned by root and the file is a regular file (not a symlink) owned by
root, and then only its well-formed lines. So a cache someone else could have
written is never what the comparison trusts.

**It never fails the check.** A run that cannot save its state still makes
every lookup, and the status says why:

    STATUS=2 checked: 0 behind, 2 current, 0 pinned [0 cached, 2 queried]; state not saved (/var/lib/tc-docker is not owned by root), so nothing is cached and lookup failures are not tracked over time

**Moved in version 5.** Versions 1 to 4 kept this file in
`/var/lib/tc-docker-monitor` (version 1 could also fall back to
`/var/tmp/tc-docker-monitor`, which no later version reads). While
`/var/lib/tc-docker/image-digests.tsv` does not exist, the file of that name
in `/var/lib/tc-docker-monitor` is read instead, under the same rule (a real
directory and a regular file, both root's). That run writes the new file, so
the old one is read once. **The old directory is never changed or removed**;
delete it by hand once the Health and Images monitors on the host are both on
their new versions. This fallback is temporary: the block marked `tc-docker
monitor state` says what to remove.

Six tab-separated columns, one line per image reference:

| Column | Meaning |
|---|---|
| ref | the image reference, e.g. `registry.example/app:1` |
| digest | the last digest the registry gave, or `-` |
| created | the build date of that digest, or `-` when not fetched |
| last ok | when the registry last answered (seconds since 1970; `0` never) |
| error kind | `none`, `ratelimited`, `refused`, `notfound`, `timeout`, `other` |
| error since | when the current run of errors began; `0` when the kind is `none` |

One line of each kind (tabs shown as spaces):

    registry.example/app:1      sha256:3f…e1  -                      1794952297  none         0
    registry.example/db:16      sha256:9a…07  2026-11-02T08:14:00Z   1794300000  ratelimited  1794390000
    registry.example/tool:2     -             -                      0           refused      1794952297

The first was answered on its last lookup; the second was last answered a week
earlier and has been rate limited since; the third has never been answered.
Version 1 lines (ref, digest, created, checked) are read as a success at
"checked" and rewritten in this format. An entry for an image no running
container uses is dropped 90 days after anything was last recorded for it.

## Installing it in Datto

| Field | Value |
|---|---|
| Name | `Docker Images monitor [Lin]` (as deployed; see Known issues) |
| Description | Alerts when a container on a moving tag is behind its registry tag by over N days; containers on pinned tags are reported, never alerted. |
| Category | **Monitors**. Permanent; cannot be changed after the first save. |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | 4, as deployed. Not standardised. |
| Timeout | **120 seconds** (version 1: 3600). See below. |
| Attachments | none |

**Why 120 seconds.** Every daemon command is stopped 40 seconds after the
start (45 with the KILL grace), no registry lookup runs past 75 seconds after
the start (80 with the grace), and what follows is local work, so every path
prints its result inside 90 seconds. 120 leaves 30 seconds of headroom for a
slow host without letting a hung run sit for an hour.

Version 2 goes in by pasting the new body over this component in Datto and
adding the `staleAfterDays` variable, not by re-importing, so its uid and
monitoring policies stay in place. Lower the timeout to 120 in the same edit.

Version 3 goes in the same way: paste the body, and rename the six variables
in the component to their `usr` names (table below). Monitor policies saved
before then still send the old names, and version 3 reads those (see below),
so they keep working until each policy is saved again with the new names.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMinAgeDays` | String | `7` | 0–365. Days a new image must exist before it counts. `0` disables the wait. |
| `usrExcludePattern` | String | *(empty)* | Extended regex matched against container names, e.g. `^(postgres\|mysql)`. A pattern starting with `-` is a pattern, not an option. |
| `usrInspectTimeout` | String | `20` | 10–60. Seconds per registry lookup. |
| `usrMaxParallel` | String | `3` | 1–8. Concurrent lookups. |
| `usrCacheHours` | String | `12` | 0–720. How long a lookup is reused. `168` = weekly. |
| `usrStaleAfterDays` | String | `7` | 0–365. Alert on a reference with no registry answer this long. `0` turns it off. |

No customer-specific value is hardcoded. Surrounding spaces are ignored and a
leading zero is read as decimal. **Any other invalid value is refused**: exit 1
with `STATUS=Check could not run: <name> must be a whole number from <min> to
<max> (got '<value>')`, or `usrExcludePattern is not a valid extended regular
expression`. The message names the variable the value was read from. Version 1
silently replaced bad input with the default (and clamped `maxParallel`).

**Old names (before version 3).** Until version 3 the variables had no `usr`
prefix: `minAgeDays`, `excludePattern`, `inspectTimeout`, `maxParallel`,
`cacheHours`, `staleAfterDays`. Monitor policies saved before the rename still
send those names, so each value is read from its `usr` name and, only when the
`usr` name is not set at all, from its old name. When both are set the `usr`
name wins, even when it is empty. **This fallback is temporary:** remove it
(the inner `${old-...}` in each input line and `from_name`, both marked
`OLD-NAME FALLBACK` in the script) once no policy in Datto sends the old
names.

Not yet checked against Datto: whether a policy saved before the rename gets
the new names too, with the component's defaults. If it does, those defaults
win over the values the policy set under the old names. After renaming the
variables in Datto, read the output of one run from a policy that sets a
non-default value, and save each policy again if its value was lost.

## Exit behaviour

| Host state | Result |
|---|---|
| Docker not installed | **Exit 0**: "Docker is not installed on this host; nothing to check" |
| No `docker` command but a socket or `docker.service` | **Exit 1** |
| Docker stopped (systemd) | **Exit 0**, says so; no docker command run |
| A docker client and no daemon at all | **Exit 0**, says so |
| Daemon unreachable | **Exit 1**: "Check could not run: cannot talk to the Docker daemon" |
| Daemon does not answer | **Exit 1** inside 45 seconds: "Docker did not answer within 40 seconds" |
| `docker ps`, `docker inspect` or `docker image inspect` fails on three tries | **Exit 1**: "Check could not run: Docker did not return its container list" |
| `docker buildx` missing | **Exit 1**, naming the `docker-buildx-plugin` package |
| Docker installed, no containers running | **Exit 0**, and says so |
| No container uses a registry image | **Exit 0**, counted in the status |
| One or more containers behind | **Exit 1**, with a diagnostic per container: image, local and registry digests, build date |
| A reference with no registry answer for `usrStaleAfterDays` | **Exit 1**, naming it, the error kind and since when |
| Every lookup failed (not rate limiting) | **Exit 1**: "no image could be read from any registry" |
| Rate limited, or deferred by the time limit | **Exit 0**, reported in the status |
| The state file cannot be saved | The check still runs; the status says `state not saved (<why>)`. Never fails |
| An input variable is invalid | **Exit 1**: "Check could not run: ..." |
| The script dies unexpectedly | **Exit 1** via an `EXIT` trap: "Check could not run: the monitor stopped unexpectedly (exit N)". TERM, INT and HUP go through the same trap. The script runs under `set -u`; every lookup that could be unset has a default, so the trap is a last resort, not the way an unset value is handled |

Safe to assign to every Linux device, because a host without Docker exits 0.

### One result block

The result and diagnostic code is the block marked `tc-docker result`, the
same in the three Docker monitors (CI's "Shared blocks match" check compares
the copies):

- **One result on every way out**: `<-Start Result->`, one `STATUS=` line,
  `<-End Result->`. The diagnostic block follows only when the exit code is
  not 0.
- **The status is one line.** A carriage return, newline or tab in it becomes
  a space, and a run of spaces becomes one.
- **The status is cut at 900 characters** (897 and three dots), so what
  matters most goes first.
- **A run that ends any other way** (an unset variable, a signal) goes through
  an `EXIT` trap that prints `Check could not run: the monitor stopped
  unexpectedly (exit N)` and makes the exit non-zero. Once a result is being
  printed, HUP, INT and TERM are ignored, so it is printed once and whole.
  This monitor also traps HUP, INT and TERM (exit 129, 130, 143), so a signal
  is acted on when the docker command or lookup in progress returns, its
  result says `(exit 143)` and the like, and its scratch directory is removed
  on the way out.

## How to tell it worked

A healthy status reads like:

    STATUS=4 checked: 0 behind, 3 current, 1 pinned [0 cached, 4 queried]

On the next run within `usrCacheHours`, it should show the lookups as cached
(`[4 cached, 0 queried]`). If it never does, the status says why the state
was not saved.

## Test order

1. One internal Docker host, saved as a **Scripts** component. Run it twice and
   read the raw output.
2. One site, one device, with the job scoped to that device.
3. Paste the body over the monitor and widen.

## Known issues

- **The name does not follow the naming standard.** `component.json`, the
  script header and this heading all use the name saved in Datto,
  `Docker Images monitor [Lin]`. The standard (`[Subject] - [Condition
  watched]`) would give something like
  `Docker - Container Images Behind Registry [Lin]`, which version 2's script
  header used. Renaming is a decision for a person and is done in Datto (the
  name field of the existing component, so its uid and policies stay); then
  change `general.name`, the script header and this heading together. The
  folder name stays as it is.

## Known limits

- Docker only. Podman is not handled.
- It needs the `docker buildx` plugin, GNU `timeout` (with `-k`), GNU `stat`
  and GNU `mv` (`-T`).
- `date -d` for the build date is a GNU spelling. Elsewhere the age is unknown,
  and an unknown age is reported as behind rather than hidden.
- It only checks *running* containers.
- "Docker is stopped" relies on systemd. Without systemd, `docker info` is
  asked, and on such a host a socket-activated daemon could be started by it.
- Staleness needs the state file: while it cannot be saved nothing is tracked
  over time, and the status says so.
- On a host with very many uncached references and a slow registry, one run
  may not reach them all inside its 75 seconds; the rest are deferred to the
  next runs, which make progress because answers are cached.
- bash 4.2 or later (tested under GNU bash 4.2 in CI).
- **Docker's containerd image store** (the default for new installs from
  Docker 29) gives an image that never came from a registry a repo digest of
  its own (seen on Docker 29.9.3: an image made with `docker import` and never
  pushed lists `name@sha256:<its id>`). Such a container is therefore not
  skipped as `local image, not from a registry`. Its reference is looked up in
  the registry and, when that fails, it is counted as unreadable and can
  become stale. Versions 2 and 3 behave the same here. Use
  `usrExcludePattern` for such containers until this is handled.
