# Docker - Containers Differ From Expected [Lin]

A Datto RMM custom monitor for Linux Docker hosts. It compares the containers
on a host with that host's expected-containers list. It alerts when an
expected container is stopped or gone, and reports containers that run but
aren't on the list, counting their age from when it first saw them. It
reports the stopped containers the prune has recorded
and will remove, with the date each one goes, so nobody is surprised when it
is gone. It also reports a host whose installed weekly prune is out of date,
because the prune is only replaced when Host Maintenance is run on that host
again.

> **Status: Not Validated.** Written 2026-11-09; version 2 adds review state
> on 2026-11-10; version 3 (2026-11-13) reports containers with unreadable
> Compose labels and alerts when Docker does not return its container list;
> version 4 (2026-11-13) flags a host whose installed prune is older than
> `PRUNE_MIN_VERSION` (7). Every outcome below was exercised against a live
> Docker 29 daemon in a sandbox, and the monitor has a Tier 1 `test.json`
> (the stale-prune cases use stand-in prune files, not the real prune). It has
> not yet run through a Datto agent. Run its
> script once as a **Scripts** component first; see
> [Test order](#test-order).
>
> **Version 5** (2026-11-16) raises `PRUNE_MIN_VERSION` to **9**, so every host
> whose prune is older than Host Maintenance version 9 alerts (by default)
> until Host Maintenance runs on it, and reads the prune's
> `/var/lib/tc-docker/pending-removal`: a stopped container waiting to be
> removed alerts by default (`usrPendingRemovalAction`). Exercised through the
> Tier 1 harness against a live Docker 29 daemon in a sandbox, with
> pending-removal files written by the test; not yet through a Datto agent.
> **Expect a wave of stale-prune alerts when version 5 goes out;** consider
> `usrStalePruneAction` = Warn until Host Maintenance 9 has reached every host.
>
> **Version 6** (2026-11-17) stops an unreviewed list being silent for ever.
> Under `usrUnreviewedAction` Warn (the default), a list still unreviewed
> `usrUnreviewedAfterDays` (default **14**) days after it was created or last
> changed now **alerts**, and the status says how long it has waited:
> `list NOT REVIEWED for 16 days, so no containers or images are pruned`.
> **Every host whose list is already unreviewed for 14 days or more alerts as
> soon as version 6 is deployed.** Expect one alert per such host; set
> `usrUnreviewedAfterDays` higher, or `0` to turn this off, if they cannot be
> reviewed straight away. `PRUNE_MIN_VERSION` stays 9. Exercised through the
> Tier 1 harness against a live Docker 29 daemon in a sandbox, with the
> list's modification time set back by the test; not yet through a Datto
> agent.
>
> **Version 7** (2026-11-17) closes five blind spots. **It is no longer
> read-only:** it keeps `/var/lib/tc-docker/monitor-first-seen` (see
> [First seen](#first-seen)), so a container that restarts or is redeployed
> more often than `usrUnlistedAfterHours` is reported instead of being new for
> ever. **It never starts a stopped Docker**: it asks systemd first, and a
> stopped `docker.service` with containers on the list is now an alert of its
> own (`Docker is stopped (docker.service is inactive); its expected
> containers are not running`), not a Docker it quietly woke up. **A hung
> daemon gives a result**: every docker command is stopped 40 seconds after the
> monitor starts (`Check could not run: Docker did not answer within 40
> seconds`). The usual system directories are appended to `PATH`, and a host
> with Docker's socket or unit but no `docker` command alerts. And it runs on
> **bash 4.2** (CentOS 7): an empty list used to crash it there. **Expect new
> alerts** from hosts whose Docker is stopped with containers on the list, and,
> after `usrUnlistedAfterHours`, from containers that were only ever "new"
> because they kept restarting. `PRUNE_MIN_VERSION` stays 9. Exercised through
> the Tier 1 harness against Docker 29 under systemd 255 in a sandbox
> (141 steps, including runs under GNU bash 4.2 built from source); not yet
> through a Datto agent.
>
> **Version 8** (2026-11-17) raises `PRUNE_MIN_VERSION` from 9 to **11**, and
> changes nothing else. Host Maintenance version 11 is the first whose prune
> never starts a stopped Docker; the prunes of versions 9 and 10 start one
> (their service has `Requires=docker.service`, and they run `docker info`
> first), and every `restart: always` container with it. **Every host whose
> prune is version 9 or 10 is reported as stale, and alerts by default, as
> soon as version 8 is deployed, until Host Maintenance is run on it again.**
> Run Host Maintenance (version 11 or later) across the Docker hosts first, or
> set `usrStalePruneAction` = Warn until it has reached them. A version 11
> prune is accepted: version 12 only changes how the prune reads its own
> settings file. The Tier 1 `test.json` covers the new minimum with stand-in
> prune files stamped 10, 11 and 12. Those steps were run through the Tier 1
> harness against a live Docker 29 daemon in a sandbox with no systemd and no
> bash 4.2, so the bash 4.2 and stopped-Docker steps were **not** run for this
> version; CI runs them. Not yet through a Datto agent.
>
> **Version 9** (2026-11-17) moves code and changes no behaviour.
> `/var/lib/tc-docker/pending-removal` is now read with `tc_pending_lines`, a
> function in the block the Docker components share (`tc-docker shared`),
> which the prune and Update Expected Containers use too, instead of a parser
> of its own. The time-limit code (`bounded`, `systemd_up`,
> `docker_unit_loaded`) is marked as a shared block, `tc-docker bounded`, with
> the Health and Images monitors, so CI now fails if the three copies drift
> apart. The first line of the `tc-docker running` block says it is identical
> in every tc-docker component. `PRUNE_MIN_VERSION` stays **11**. Versions 8
> and 9 were run side by side on the same 33 pending-removal files (well
> formed, and malformed in each way the parser checks) with a stand-in
> `docker`, under gawk, mawk 1.3.4 and busybox awk: the result block, the
> diagnostic and the exit code were the same every time. Where `awk` is mawk
> 1.3.3 (the default on Debian 10, Ubuntu 18.04 and older) there is one
> difference, and it is a repair: at a record dated 2038-01-19 or later (which
> the prune cannot write before then, so today only a hand edit puts one
> there), version 8 hit an arithmetic error and reported neither that record
> nor any after it; version 9 reports them. Through the Tier 1 harness against
> a live Docker 29 daemon in a sandbox with no systemd and no bash 4.2, every
> step gave the result it gave for version 8 there and the six new steps pass;
> with systemd's answers simulated, every step passes except the ones that
> need bash 4.2, which were **not** run for this version. CI builds bash 4.2
> and has a real systemd, so read its result before merging. Not yet through
> a Datto agent.
>
> **Version 10** (2026-11-17): the result and diagnostic code is now the block
> marked `tc-docker result`, shared with the Health and Images monitors: one
> `emit`, one `diag`, one `EXIT` trap, one status limit. See
> [One result block](#one-result-block). Two things can read differently from
> version 9. **The status is cut at 900 characters, not 400**, so a long status
> (many stopped, missing or unlisted containers) now shows more of itself. And
> a tab or carriage return in the status becomes a space and a run of spaces
> becomes one, which only an invalid input value echoed back can show.
> **The first-seen file is written with `tc_state_write`**, one function in a
> block (`tc-docker state`) the prune and the three Docker monitors now share,
> in the directory they all use, `/var/lib/tc-docker`. The file it writes is
> the same, and so is every refusal this monitor already had (see
> [First seen](#first-seen)). **One refusal is new:** a `/var/lib/tc-docker`
> that is **not owned by root** is not used. Version 9 made such a directory
> root's and wrote there; version 10 leaves it as it is, does not believe a
> first-seen file in it, counts ages from each container's start and says
> `first-seen times not saved (/var/lib/tc-docker is not owned by root)`.
> Nothing in these components makes that directory anything but root's.
> `PRUNE_MIN_VERSION` stays **11**. **The script's header comment is short**
> (what it is, what it changes, the result states) and points here; what it
> said about the order of the checks is now under
> [Exit behaviour](#exit-behaviour). Through its Tier 1 `test.json` in a
> sandbox with no bash 4.2, with systemd's answers simulated: every step that
> passed for version 9 passes, unedited, and the new steps pass; the bash 4.2
> steps were **not** run and run in CI. Versions 9 and 10 were also run side
> by side, with a stand-in `docker`, on 51 states of `/var/lib/tc-docker` and
> its two files: the result block, the diagnostic, the exit code and the
> files left behind were the same every time, except where the directory was
> not root's. Not yet through a Datto agent.

## What it does

It reads `docker info`, `docker ps`, `docker inspect` and six files (and the
modification time of the list). It makes no network calls.

**It writes one file**, `/var/lib/tc-docker/monitor-first-seen`, and nothing
else: when it first saw each running container that is not on the list, so
that a container restarted or recreated more often than
`usrUnlistedAfterHours` is still reported once the hours have passed. See
[First seen](#first-seen). It creates `/var/lib/tc-docker` (root-only, 0700) if
the prune has not already.

**It never starts Docker.** Where systemd manages `docker.service`, systemd is
asked first, and no docker command is run while the service is stopped: on
most installs `docker.socket` keeps listening, and any docker command would
start Docker again (with every `restart: always` container). This is the same
`tc-docker running` code Host Maintenance uses.

**It always finishes.** Every docker command one run makes must be done 40
seconds (`DOCKER_TIMEOUT`) after the monitor started. One that is not is
stopped with everything it started, and the check says Docker did not answer.

**`PATH`.** `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin`
is appended to whatever `PATH` the agent gives it (appended, never
prepended), so whether `docker` is found does not depend on the agent's
`PATH`.

The two list files:

| File | Created by | Changed by |
|---|---|---|
| `/etc/tc-docker/expected-containers` | [`Docker - Configure Host Maintenance [Lin]`](../../Scripts/docker-configure-host-maintenance-lin/), once | [`Docker - Update Expected Containers [Lin]`](../../Scripts/docker-update-expected-containers-lin/) |
| `/etc/tc-docker/ignore` | The same | The same |

Each list entry is a key: `compose:<project>/<service>` for a Docker Compose
service, `name:<container name>` for anything else. Compose services are
matched by project and service, so a recreated or scaled service still
matches.

| Condition | Result |
|---|---|
| An expected container exists but **none of its containers is running** | **Stopped.** Alerts, set by `usrMissingAction` |
| **No container** has an expected key | **Missing.** Alerts, set by `usrMissingAction` |
| A running container is **not on the list**, was first seen running at least `usrUnlistedAfterHours` ago, and doesn't match the ignore file | **Unlisted.** Named in the status; alerts only if `usrUnlistedAction` is Alert. First seen survives restarts and redeploys; see [First seen](#first-seen). |
| A container, running or stopped, has **Compose labels that are not plain names** | **Unreadable.** Counted in the status (`1 with unreadable Compose labels`) whatever `usrUnlistedAction` says; alerts only if `usrUnlistedAction` is Alert, and then named by container name and short id in the diagnostic. Not age-gated and not matched against the ignore file. |
| A list line is neither key form | Counted as unreadable list lines in the status |
| The host's **prune is stale** (see below) | **Stale prune.** Named first in the status; alerts, set by `usrStalePruneAction` (default Alert). Checked **before** the "no list yet" exit, with or without a list. |
| A stopped container is **waiting to be removed** by the prune (see below) | Named first after a stale prune, with the date it goes: `2 stopped containers will be removed by the prune (name:a from 2026-11-22, name:b from 2026-11-23)`. Alerts, set by `usrPendingRemovalAction` (default Alert). One whose key matches the ignore file is counted, marked `(ignored)`, and never alerts. |
| The list has **not been reviewed** (no `/etc/tc-docker/reviewed`) | Named in the status with how long it has waited (`list NOT REVIEWED for 16 days`). Alerts if `usrUnreviewedAction` is Alert; under Warn (the default), alerts once it has waited `usrUnreviewedAfterDays` (default 14) or more. **Until review, stopped or missing containers are reported but never alert on their own**, so onboarding a host raises one item, not one per container. |

### First seen

Up to version 6 an unlisted container's age was its `State.StartedAt`. A
container restarted or recreated more often than `usrUnlistedAfterHours` (a
nightly redeploy, a crash loop) was therefore "new" on every run and never
reported. Version 7 remembers instead.

**What it writes.** `/var/lib/tc-docker/monitor-first-seen`, a comment header
and one line per key:

    name:surprise	1795000000	1795100000

key, first seen, last seen, tab separated, in seconds since 1970. Nothing else
about the container is stored. Only this monitor writes it.

**The rule**, on each run:

1. For each running, non-transient, unlisted, not-ignored key: if the file has
   a line for it, its age counts from the earlier of that line's first seen
   and the container's start; if not, from the container's start (so the first
   run after the upgrade gives the version 6 result). Its last seen becomes now.
2. A line whose key is on the list is dropped.
3. A line whose key has not been seen running for 7 days
   (`FIRST_SEEN_KEEP_DAYS`) is dropped. A stopped unlisted container is not
   "seen", so after a week stopped its clock starts again.
4. The file is written only when this changes it, and not at all while it
   does not exist and there is nothing to put in it.

**How it is written.** The same way the prune writes its pending-removal
file, and the Health and Images monitors their state, in the same directory
(from version 10, with the same code):

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

**What it trusts.** Only well-formed lines: a valid key, two whole numbers of
at most 10 digits, first seen no later than last seen, last seen no more than
an hour ahead of the clock, and the first such line for each key. Anything
else is ignored and dropped at the next write.

**When it cannot be written** (a read-only or immutable directory, a full
disk, a symlink in the way, a directory that is not root's) the check still
runs: every age counts from the
container's start, as in version 6, and the status says so, e.g.
`first-seen times not saved (no file can be created in /var/lib/tc-docker),
so unlisted ages count from each container's start`. That is never an alert
on its own.

Unreadable containers (Compose labels that are not plain names) are not in
the file: they are reported whatever their age, as before.

### A list nobody reviews

Until a person confirms a host's list (Docker - Update Expected Containers
[Lin], **Confirm reviewed**), the prune removes no containers and no images on
it, and this monitor does not alert on its stopped or missing containers. With
`usrUnreviewedAction` Warn and nothing more, such a host would stay quiet for
ever and never get its images cleaned up. So under Warn, once the list has
gone unreviewed for `usrUnreviewedAfterDays` days (default 14), the monitor
alerts. `0` turns this off. Alert alerts from the first day, as before; Ignore
says nothing, as before.

**How long** is the age of `/etc/tc-docker/expected-containers`: its
modification time. Host Maintenance writes it once when it creates the list,
and Update Expected Containers rewrites it on every Add, Remove or Accept
current, so the count is from the list's creation or its last change.
An age that cannot be read (the file's time is in the future, or `stat`
fails) is left out of the status and never escalates.

The status says it in whole days: `list NOT REVIEWED for less than a day`,
`for 1 day`, `for 16 days`. On the alert the diagnostic says why it alerts now
and how to clear it:

    NOT REVIEWED for 16 days  - this alerts because the list has gone unreviewed for 14 days or more (usrUnreviewedAfterDays). Until it is reviewed, the prune removes no containers or images on this host, and stopped or missing containers do not alert. Review it with Docker - Update Expected Containers [Lin]: run Show, fix the list (Add, Remove, Accept current), then Confirm reviewed.

Stopped and missing containers on such a list are named in the status and the
diagnostic, as before, but are not alerts of their own.

### Containers waiting to be removed

From Host Maintenance version 9, the prune does not remove a stopped
container the first time it finds one old enough. It records it in
`/var/lib/tc-docker/pending-removal` (id, key, name, the time it was first
recorded) and removes it on a run at least `GRACE_HOURS` later (from
`/etc/default/tc-docker-prune`, default 144). This monitor reads that file
and reports each container in it that is:

- still there, still stopped, with the same key and name, and
- still unprotected: not on the list, no `always` or `unless-stopped` restart
  policy, no `tc.keep` label.

The others are left out: the prune drops their lines on its next run. The
date shown is the recorded time plus `GRACE_HOURS`, in the host's time zone;
the prune removes the container at its first run on or after it. Nothing is
reported while the list is not reviewed: the prune removes nothing then, and
clears the file. A missing file means nothing is waiting.

On an alert the diagnostic has one `PENDING` line per container, with when it
was recorded and when it goes, and says how to keep it (**Add** it to the list
with Docker - Update Expected Containers [Lin]) or let it go (do nothing).
Five are named in the status at most, then `and <n> more`.

**A line that is not well formed is not trusted.** It is never shown; the
status counts it (`pending-removal file has 2 unreadable line(s)`), it alerts
under Alert, and the diagnostic gives its line numbers only. The same holds
for a pending-removal path that is not a regular file.

### The prune check

[`Docker - Configure Host Maintenance [Lin]`](../../Scripts/docker-configure-host-maintenance-lin/)
installs a prune that a systemd timer runs weekly, and only replaces it when
the component is run on that host again. Nothing else reports which prune a
host has, and the earlier ones are unsafe: version 1 ran
`docker system prune --all` from the service with no list and no review;
version 2 ran it behind a required-containers check; version 3 protected
containers one by one but had no review gate; versions 4 and 5 had the review
gate but a container label could still make them delete a protected container;
versions 7 and 8 removed a stopped container at the first prune after it was
old enough, counting from when it was created; and versions 9 and 10 start a
Docker that was stopped on purpose (the weekly timer does, and so does a run by
hand), bringing every `restart: always` container back with it.

Since version 7 of Host Maintenance, the installed script
`/usr/local/sbin/tc-docker-prune` carries a line `TC_PRUNE_VERSION=<n>`, where
`<n>` is the component's version, and prints `tc-docker-prune version <n>` as
its first output line. This monitor reads that line and, from the unit,
`/etc/systemd/system/tc-docker-prune.service`. A host has a **stale prune**
when any of these is true:

- the unit exists and its `ExecStart` is not exactly
  `/usr/local/sbin/tc-docker-prune` (the version 1 layout);
- the script exists with no `TC_PRUNE_VERSION=` line (every version before 7),
  or one whose value is not a whole number;
- the script's `TC_PRUNE_VERSION` is lower than `PRUNE_MIN_VERSION`, a constant
  near the top of the script (**11** now: the first prune that never starts a
  stopped Docker).

A host with neither file has no prune installed, which is not stale. A
leading zero in the stamp is read as decimal.

The status names what was found, for example `prune on this host is version 3,
older than 11`, `prune on this host has no version (installed before version
7)`, or `prune service on this host does not run
/usr/local/sbin/tc-docker-prune (version 1 layout)`. It goes first in the
status, because the status is cut at 900 characters (400 before version
10). On an alert the
diagnostic says to run Docker - Configure Host Maintenance [Lin] on the host,
and that until then **the old prune's rules apply**.

The check runs before the "no list yet" exit on purpose: version 1 and 2 hosts
have no list, and they are the ones it exists to find. A host with a current
prune is reported exactly as before.

**Raising `PRUNE_MIN_VERSION`** is how a future safety fix to the prune gets
flagged across the fleet: bump the prune's stamp by shipping a new Host
Maintenance version, raise the constant to that version here, and every host
still on an older prune alerts on its next run. The constant does not have to
follow every Host Maintenance version: it is 11 while Host Maintenance is 14,
because version 12 changes only how the prune reads its settings file (as
text, never run, with `OLDER_THAN_HOURS` checked), which matters on a host
where someone edited that file by hand, version 13 only moves code, and
version 14 only refuses a `/var/lib/tc-docker` that is not owned by root,
which nothing in these components causes.

A container's labels are untrusted: it inherits them from its image. They are
read JSON-encoded, so a tab or newline in a label cannot add a field or a
container to what the monitor sees, and a label's value is never printed.

These are **never** counted as unlisted:

- Compose one-offs (`docker compose run`)
- `--rm` containers
- anything matching `/etc/tc-docker/ignore`

It fills the gap the Health monitor's README names: *"It does not check
whether an expected container is missing entirely."* The two are meant to run
side by side:

- **Health** watches each container's CPU, memory, healthcheck and restarts.
- **This monitor** watches whether the right set of containers is there.

## Installing it in Datto

Automation → Components → New Component. Category **Monitors**, which is
permanent and cannot be changed after the first save. Or import the `.cpt`
from the latest release.

| Field | Value |
|---|---|
| Name | `Docker - Containers Differ From Expected [Lin]` |
| Description | Alerts when an expected Docker container is stopped or gone (including when Docker is stopped), Docker does not answer within 40 seconds, a stopped container is waiting to be removed by the prune, the host's prune is out of date, or the list has gone unreviewed for usrUnreviewedAfterDays; reports unlisted containers, aged from when first seen. Never starts a stopped Docker; writes only its first-seen file. |
| Category | **Monitors** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | Not standardised yet; decide at save time (`component.json` carries 4) |
| Timeout | 120 seconds |
| Attachments | none |
| Monitor interval | 15–60 minutes. Nothing here changes by the minute. |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMissingAction` | **Selection** | `Alert` | `Alert` / `Warn`. Warn names stopped and missing containers in the status without alerting. |
| `usrUnlistedAction` | **Selection** | `Warn` | `Warn` / `Alert` / `Ignore`. Starts at Warn on purpose; see Open questions. |
| `usrStalePruneAction` | **Selection** | `Alert` | `Alert` / `Warn` / `Ignore`. What a stale prune does. Warn names it in the status without alerting; Ignore turns the prune check off. Starts at Alert on purpose: a host on an old prune can still delete containers a reviewed list would protect. |
| `usrPendingRemovalAction` | **Selection** | `Alert` | `Alert` / `Warn` / `Ignore`. What a stopped container the prune has recorded for removal does. Warn names it in the status without alerting; Ignore leaves it out. A container whose key matches an ignore pattern is counted but never alerts. |
| `usrUnreviewedAction` | **Selection** | `Warn` | `Warn` / `Alert` / `Ignore`. What an unreviewed list does. Warn names it in the status, and alerts once it has waited `usrUnreviewedAfterDays`. Alert turns every unreviewed host into a ticket from day one, which suits onboarding a single client, but not turning the monitor on across the whole fleet. |
| `usrUnreviewedAfterDays` | String | `14` | 0–365. Under Warn, a list still unreviewed this many days after it was created or last changed alerts. `0` never escalates. |
| `usrUnlistedAfterHours` | String | `24` | 0–8760. A new container only counts as unlisted once this long has passed since the monitor first saw it running (a restart or a redeploy does not reset that), which keeps upgrades and short tests quiet. |

No customer-specific value is hardcoded. An invalid value makes it report
`Check could not run: …` and alert, rather than fall back to a default.

## Exit behaviour

| Host state | Result |
|---|---|
| No `docker` command (after the `PATH` append), no `/var/run/docker.sock` socket, no loaded `docker.service` | **Exit 0**: "Docker is not installed on this host; nothing to check" |
| No `docker` command, but `/var/run/docker.sock` is a socket or `docker.service` is loaded | **Exit 1**: "Docker appears to be installed but no docker command was found", the diagnostic saying which was found |
| systemd says `docker.service` is not active, and the list has entries | **Exit 1**: "Docker is stopped (docker.service is inactive); its expected containers are not running". No docker command is run, so Docker stays stopped. |
| systemd says `docker.service` is not active, and there is no list or it is empty | **Exit 0**: "Docker is stopped (…); no expected-containers list on this host yet, so nothing is expected to run" (or "…its expected-containers list is empty…") |
| `docker info` fails, and there is no `docker.service`, no `/var/run/docker.sock` and no list (a docker client with no daemon on this host) | **Exit 0**: "Docker client installed (…) but no Docker daemon on this host (no docker.service, no /var/run/docker.sock); nothing to check" |
| Docker installed, no list yet, prune current or not installed | **Exit 0**: says Host Maintenance creates it |
| Prune stale, `usrStalePruneAction` Alert, with or without a list, and with Docker stopped or absent (the check reads two files and needs no daemon) | **Exit 1**, the finding first in the status, and `STALE PRUNE` in the diagnostic saying to run Host Maintenance. After a `Check could not run: …` it comes second. |
| Prune stale, `usrStalePruneAction` Warn | **Exit 0**, the finding named in the status; the rest of the result is as before |
| Prune stale, `usrStalePruneAction` Ignore | **Exit 0**, not named; the check is not made |
| Daemon should be there (a list, a socket or a `docker.service`) and `docker info` fails | **Exit 1**: "Check could not run: cannot talk to the Docker daemon", quoting Docker's error and systemd's view in the diagnostic |
| Docker takes the connection and does not answer (`docker info`, `docker ps` or `docker inspect` still running 40 seconds after the monitor started) | **Exit 1** within 45 seconds: "Check could not run: Docker did not answer within 40 seconds". The docker commands it started are stopped (TERM to their own process group from `timeout`, then KILL to whatever is left in it); no docker client is left running, and nothing else is signalled. |
| Daemon answers `docker info`, but `docker ps` or `docker inspect` fails 3 times | **Exit 1**: "Check could not run: Docker did not return its container list". Never read as "no containers". |
| Every expected container running, nothing unlisted | **Exit 0**: e.g. `3 expected: 3 running` |
| Stopped container waiting to be removed, `usrPendingRemovalAction` Alert | **Exit 1**, `N stopped container(s) will be removed by the prune (...)` in the status and a `PENDING` line for each in the diagnostic; exit 0 when every one matches an ignore pattern |
| Stopped container waiting to be removed, `usrPendingRemovalAction` Warn | **Exit 0**, named in the status |
| Stopped container waiting to be removed, `usrPendingRemovalAction` Ignore | **Exit 0**, not named |
| `pending-removal` has lines that are not well formed | Counted in the status, never shown; **exit 1** under Alert, with `BAD PENDING` and the line numbers in the diagnostic |
| List not reviewed, `usrUnreviewedAction` Warn, list younger than `usrUnreviewedAfterDays` (or that is `0`, or its age cannot be read) | **Exit 0**, with `list NOT REVIEWED for <n> days` in the status, even when stopped containers are listed |
| List not reviewed, `usrUnreviewedAction` Warn, list `usrUnreviewedAfterDays` old or more | **Exit 1**, the same status, and a `NOT REVIEWED for <n> days` diagnostic saying why it alerts and naming the review steps |
| List not reviewed, `usrUnreviewedAction` Alert | **Exit 1**, whatever its age |
| List not reviewed, `usrUnreviewedAction` Ignore | Not mentioned; the rest decides |
| Reviewed list, expected container stopped or missing, `usrMissingAction` Alert | **Exit 1**, naming them, with a diagnostic saying what to do |
| Unlisted container, `usrUnlistedAction` Warn | **Exit 0**, naming it in the status |
| The first-seen file cannot be written | Same result as version 6 (ages from container start), and `first-seen times not saved (<why>)` in the status; never an alert on its own |
| Unlisted container, `usrUnlistedAction` Alert | **Exit 1** |
| Container with unreadable Compose labels, `usrUnlistedAction` Warn or Ignore | **Exit 0**, counted in the status |
| Container with unreadable Compose labels, `usrUnlistedAction` Alert | **Exit 1**, `UNREADABLE  <name> (<short id>)` in the diagnostic |
| An input variable is invalid | **Exit 1**, `Check could not run: …` |
| A required tool is missing | **Exit 1**, `Check could not run: …` |
| The script dies unexpectedly | **Exit 1**, through an `EXIT` trap that prints a result block, `Check could not run: the monitor stopped unexpectedly (exit N)`, so an alert is never empty |

Exactly one result block, with `STATUS=` and no space after the equals, on
every path.

**The order of the checks.** Before any docker command: is there a `docker`
command; then the prune check (two files, no daemon needed); then whether
Docker is running, asked of systemd first. A stale prune is therefore named on
every result after the first two rows of the table, and alerts under Alert.
Only then is the list looked for ("no list yet"), and only then the
containers. A daemon that cannot be reached, does not answer in time or does
not return its container list is always an alert: not knowing is the failure
this monitor exists to catch.

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

## How to tell it worked

Healthy:

    STATUS=4 expected: 4 running; 1 new, under 24h; 2 ignored

Alerting:

    STATUS=4 expected: 3 running, 1 stopped (name:legacy); 1 unlisted (name:surprise)
    <-Start Diagnostic->
    STOPPED   name:legacy  - start it, or remove it from the list if it was retired
    UNLISTED  name:surprise  - add it to the list, add an ignore pattern, or remove the container
    ...

A container waiting to be removed:

    STATUS=1 stopped container will be removed by the prune (name:old-report from 2026-11-26); 4 expected: 4 running
    <-Start Diagnostic->
    PENDING   name:old-report  - stopped container old-report, recorded 2026-11-20 04:09; the prune removes it from 2026-11-26 04:09. To keep it: Docker - Update Expected Containers [Lin], usrAction Add, usrItems name:old-report. To let it go: do nothing.
    ...

Every alert has a fix through **Docker - Update Expected Containers [Lin]**:

- **Add** the container, or **Remove** it from the list.
- **Accept current**, after a deliberate redeploy.
- **Add ignore**, for containers that churn.
- **Confirm reviewed**, once a new host's list is right.

## Test order

0. CI's "Component tests" check on the pull request (`test.json`, Tier 1).
1. One internal Docker host, saved as a **Scripts** component. Run it and read
   the raw output.
2. One site, one device, with the job scoped to that device.
3. Save as a Monitor and widen, starting with TechCollective's own hosts.
   Route its alerts to TI before Support sees them.

## Known limits

- **The prune check reads two files and nothing else.** A host whose prune is
  run some other way, or whose unit is overridden by a drop-in
  (`tc-docker-prune.service.d/`), is judged by the two files alone. The stamp
  is what Host Maintenance wrote, not a checksum: a script someone edited by
  hand and left the stamp on still reads as current.
- The "Docker is not installed" and "no docker command" exits come before the
  prune check: a host with no Docker has nothing for a prune to delete. Every
  other exit, Docker stopped or unreachable included, carries the prune check.
- `PRUNE_MIN_VERSION` is a constant in the script, not an input variable, so a
  change to it is a reviewed change to the script.
- **Pending removals are what the prune recorded at its last run.** A
  container started since is left out (it is running); one started and
  stopped again since is still shown with its old date until the next prune
  drops it. The date assumes the `GRACE_HOURS` in the settings file; when the
  prune refuses that value it removes nothing, and the date shown is wrong.
- **The pending-removal file is trusted as the prune wrote it.** It is
  root-only. A well-formed line edited by hand is believed.
- **The unreviewed age restarts when the list changes.** It is the list
  file's modification time, so an Add or Remove without Confirm reviewed, or
  an edit over SSH, starts the count again. Touching the file silences the
  escalation for another `usrUnreviewedAfterDays`.
- **Hosts already unreviewed for longer than `usrUnreviewedAfterDays` alert
  as soon as version 6 is deployed.** With the default of 14, that is every
  host whose list was created more than two weeks ago and never confirmed.
- **A Docker stopped on purpose alerts** while the list has entries, until it
  is started again. The monitor no longer wakes it to find out. Pause the
  monitor on such a host, or empty its list.
- **"Stopped" is systemd's word.** Without systemd (or without a
  `docker.service`), `docker info` is asked, and a daemon that does not answer
  is an alert unless the host has no socket, no unit and no list. The other
  Docker monitors still run `docker info` first and can still wake a stopped
  Docker.
- **First seen is per key, not per container.** Two different containers
  that take the same name one after the other share one age. A key that was
  stopped for more than 7 days, or put on the list, starts again from the
  start of its container. Deleting the file (or a host rebuilt from scratch)
  resets every age to the container's start, which is what version 6 did.
- **First seen trusts the clock.** A clock stepped forward makes containers
  look older; one stepped back more than an hour drops the lines it cannot
  believe, and those keys start again from their containers' start.
- **The 40 seconds are for all docker commands together**, counted from the
  monitor's start. A daemon that answers, but very slowly (a few hundred
  containers on an overloaded host), can be reported as not answering.
  `DOCKER_TIMEOUT` is a constant, not an input variable.
- **It needs `timeout` from GNU coreutils** (or a BusyBox one that takes
  `-k`). Without it the check says it could not run.
- **bash 4.2 or newer.** Every expansion of a possibly empty array is guarded,
  and Tier 1 runs its main paths under GNU bash 4.2 built from source. bash 4.0
  and 4.1 have not been tried.
- **Docker only.** Podman is not handled.
- It only knows what the list says. A list created while a service was down
  never expects that service. Check the list after the first Host Maintenance
  run.
- It doesn't watch a container's health or resource use. That is the Health
  monitor's job.
- `date -d` for container age is a GNU spelling. Where it fails, the container
  counts as just started, so a key with no first-seen line can't be reported
  as unlisted until its line is old enough. That fails quiet on purpose.
- **An unreadable container cannot be listed or ignored.** Its key is made
  from its id. Fix the labels, or the image they come from.
- Under `usrUnlistedAction` Ignore, an unreadable container is still counted
  in the status, but never alerts.
- It shares five blocks of code with the other Docker components. Every
  copy of a block must stay byte-identical; CI's "Shared blocks match" check
  fails the pull request when they are not.
  - `tc-docker shared`: how a container becomes its key, and (from version 9)
    how the prune's `pending-removal` file is read. Four copies: this
    monitor, Update Expected Containers, and Host Maintenance twice (the
    component and the prune script it installs).
  - `tc-docker running`: the "is Docker running" check. Six copies: those
    four and the Health and Images monitors.
  - `tc-docker bounded` (marked from version 9): the time limit on every
    docker command. Three copies: this monitor and the Health and Images
    monitors.
  - `tc-docker result` (from version 10): the result block, the diagnostic
    and the `EXIT` trap. Three copies: the same three monitors.
  - `tc-docker state` (from version 10): the state directory and how a file
    in it is written. Four copies: the three monitors and the prune.

## Open questions

- **Should unlisted containers alert?** It starts at Warn, so the first weeks
  show how noisy each host is before anyone is paged. Revisit after rollout.
- **Telling clients.** Alerting when a client deploys something new changes
  what we watch on their servers. Tell them before turning it on there.
- **Level** is not standardised. `component.json` carries 4, as the Images
  monitor does.
