# Docker - Containers Differ From Expected [Lin]

A Datto RMM custom monitor for Linux Docker hosts. It compares the containers
on a host with that host's expected-containers list. It alerts when an
expected container is stopped or gone, and reports containers that run but
aren't on the list. It also reports a host whose installed weekly prune is out
of date, because the prune is only replaced when Host Maintenance is run on
that host again.

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

## What it does

**Read-only.** It reads `docker info`, `docker ps`, `docker inspect` and four
files, and changes nothing. It makes no network calls.

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
| A running container is **not on the list**, has run at least `usrUnlistedAfterHours`, and doesn't match the ignore file | **Unlisted.** Named in the status; alerts only if `usrUnlistedAction` is Alert |
| A container, running or stopped, has **Compose labels that are not plain names** | **Unreadable.** Counted in the status (`1 with unreadable Compose labels`) whatever `usrUnlistedAction` says; alerts only if `usrUnlistedAction` is Alert, and then named by container name and short id in the diagnostic. Not age-gated and not matched against the ignore file. |
| A list line is neither key form | Counted as unreadable list lines in the status |
| The host's **prune is stale** (see below) | **Stale prune.** Named first in the status; alerts, set by `usrStalePruneAction` (default Alert). Checked **before** the "no list yet" exit, with or without a list. |
| The list has **not been reviewed** (no `/etc/tc-docker/reviewed`) | Named in the status; alerts only if `usrUnreviewedAction` is Alert. **Until review, stopped or missing containers are reported but never alert**, so onboarding a host raises one item, not one per container. |

### The prune check

[`Docker - Configure Host Maintenance [Lin]`](../../Scripts/docker-configure-host-maintenance-lin/)
installs a prune that a systemd timer runs weekly, and only replaces it when
the component is run on that host again. Nothing else reports which prune a
host has, and the earlier ones are unsafe: version 1 ran
`docker system prune --all` from the service with no list and no review;
version 2 ran it behind a required-containers check; version 3 protected
containers one by one but had no review gate; versions 4 and 5 had the review
gate but a container label could still make them delete a protected container.

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
  near the top of the script (7 now).

A host with neither file has no prune installed, which is not stale. A
leading zero in the stamp is read as decimal.

The status names what was found, for example `prune on this host is version 3,
older than 7`, `prune on this host has no version (installed before version
7)`, or `prune service on this host does not run
/usr/local/sbin/tc-docker-prune (version 1 layout)`. It goes first in the
status, because the status is cut at 400 characters. On an alert the
diagnostic says to run Docker - Configure Host Maintenance [Lin] on the host,
and that until then **the old prune's rules apply**.

The check runs before the "no list yet" exit on purpose: version 1 and 2 hosts
have no list, and they are the ones it exists to find. A host with a current
prune is reported exactly as before.

**Raising `PRUNE_MIN_VERSION`** is how a future safety fix to the prune gets
flagged across the fleet: bump the prune's stamp by shipping a new Host
Maintenance version, raise the constant to that version here, and every host
still on an older prune alerts on its next run.

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
| Description | Alerts when an expected Docker container is stopped or gone, or the host's weekly prune is out of date; reports unlisted containers. Read-only. Healthy when there is no Docker or no list yet, unless its prune is out of date. |
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
| `usrUnreviewedAction` | **Selection** | `Warn` | `Warn` / `Alert` / `Ignore`. What an unreviewed list does. Alert turns every unreviewed host into a ticket, which suits onboarding a single client, but not turning the monitor on across the whole fleet. |
| `usrUnlistedAfterHours` | String | `24` | 0–8760. A new container only counts as unlisted once it has run this long, which keeps upgrades and short tests quiet. |

No customer-specific value is hardcoded. An invalid value makes it report
`Check could not run: …` and alert, rather than fall back to a default.

## Exit behaviour

| Host state | Result |
|---|---|
| Docker not installed | **Exit 0**: "Docker is not installed on this host; nothing to check" |
| Docker installed, no list yet, prune current or not installed | **Exit 0**: says Host Maintenance creates it |
| Prune stale, `usrStalePruneAction` Alert, with or without a list | **Exit 1**, the finding first in the status, and `STALE PRUNE` in the diagnostic saying to run Host Maintenance |
| Prune stale, `usrStalePruneAction` Warn | **Exit 0**, the finding named in the status; the rest of the result is as before |
| Prune stale, `usrStalePruneAction` Ignore | **Exit 0**, not named; the check is not made |
| Daemon unreachable | **Exit 1**: "Check could not run: cannot talk to the Docker daemon", quoting Docker's error in the diagnostic |
| Daemon answers `docker info`, but `docker ps` or `docker inspect` fails 3 times | **Exit 1**: "Check could not run: Docker did not return its container list". Never read as "no containers". |
| Every expected container running, nothing unlisted | **Exit 0**: e.g. `3 expected: 3 running` |
| List not reviewed, `usrUnreviewedAction` Warn | **Exit 0**, with `list NOT REVIEWED` in the status, even when stopped containers are listed |
| List not reviewed, `usrUnreviewedAction` Alert | **Exit 1** |
| Reviewed list, expected container stopped or missing, `usrMissingAction` Alert | **Exit 1**, naming them, with a diagnostic saying what to do |
| Unlisted container, `usrUnlistedAction` Warn | **Exit 0**, naming it in the status |
| Unlisted container, `usrUnlistedAction` Alert | **Exit 1** |
| Container with unreadable Compose labels, `usrUnlistedAction` Warn or Ignore | **Exit 0**, counted in the status |
| Container with unreadable Compose labels, `usrUnlistedAction` Alert | **Exit 1**, `UNREADABLE  <name> (<short id>)` in the diagnostic |
| An input variable is invalid | **Exit 1**, `Check could not run: …` |
| A required tool is missing | **Exit 1**, `Check could not run: …` |
| The script dies unexpectedly | **Exit 1**, through an `EXIT` trap that emits a result block, so an alert is never empty |

Exactly one result block, with `STATUS=` and no space after the equals, on
every path.

## How to tell it worked

Healthy:

    STATUS=4 expected: 4 running; 1 new, under 24h; 2 ignored

Alerting:

    STATUS=4 expected: 3 running, 1 stopped (name:legacy); 1 unlisted (name:surprise)
    <-Start Diagnostic->
    STOPPED   name:legacy  - start it, or remove it from the list if it was retired
    UNLISTED  name:surprise  - add it to the list, add an ignore pattern, or remove the container
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
- The "Docker is not installed" and "cannot talk to the Docker daemon" exits
  come before the prune check. A host with no Docker has nothing for a prune to
  delete, and an unreachable daemon alerts anyway.
- `PRUNE_MIN_VERSION` is a constant in the script, not an input variable, so a
  change to it is a reviewed change to the script.
- **Docker only.** Podman is not handled.
- It only knows what the list says. A list created while a service was down
  never expects that service. Check the list after the first Host Maintenance
  run.
- It doesn't watch a container's health or resource use. That is the Health
  monitor's job.
- `date -d` for container age is a GNU spelling. Where it fails, the container
  counts as just started, so it can't be reported as unlisted. That fails
  quiet on purpose.
- **An unreadable container cannot be listed or ignored.** Its key is made
  from its id. Fix the labels, or the image they come from.
- Under `usrUnlistedAction` Ignore, an unreadable container is still counted
  in the status, but never alerts.
- It shares its container-identity code with the two script components, in a
  block marked `tc-docker shared`. All four copies (Host Maintenance carries
  two: the component and the prune script it installs) must stay
  byte-identical; CI's "Shared blocks match" check fails the pull request
  when they are not.

## Open questions

- **Should unlisted containers alert?** It starts at Warn, so the first weeks
  show how noisy each host is before anyone is paged. Revisit after rollout.
- **Telling clients.** Alerting when a client deploys something new changes
  what we watch on their servers. Tell them before turning it on there.
- **Level** is not standardised. `component.json` carries 4, as the Images
  monitor does.
