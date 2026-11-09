# Docker - Containers Differ From Expected [Lin]

A Datto RMM custom monitor for Linux Docker hosts. It compares the containers
on a host with that host's expected-containers list. It alerts when an
expected container is stopped or gone, and reports containers that run but
aren't on the list.

> **Status: Not Validated.** Written 2026-11-09. Every outcome below was
> exercised against a live Docker 29 daemon in a sandbox. It has not yet run
> through a Datto agent. Run it as a **Scripts** component first; see
> [Test order](#test-order).

## What it does

**Read-only.** It reads `docker info`, `docker ps`, `docker inspect` and two
files, and changes nothing. It makes no network calls.

The two files:

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
| A list line is neither key form | Counted as unreadable in the status |

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
| Description | Alerts when an expected Docker container is stopped or gone; reports unlisted ones. Read-only. Healthy when there is no Docker or no list yet. |
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
| `usrUnlistedAfterHours` | String | `24` | 0–8760. A new container only counts as unlisted once it has run this long, which keeps upgrades and short tests quiet. |

No customer-specific value is hardcoded. An invalid value makes it report
`Check could not run: …` and alert, rather than fall back to a default.

## Exit behaviour

| Host state | Result |
|---|---|
| Docker not installed | **Exit 0**: "Docker is not installed on this host; nothing to check" |
| Docker installed, no list yet | **Exit 0**: says Host Maintenance creates it |
| Daemon unreachable | **Exit 1**: "Check could not run: cannot talk to the Docker daemon", quoting Docker's error in the diagnostic |
| Every expected container running, nothing unlisted | **Exit 0**: e.g. `3 expected: 3 running` |
| Expected container stopped or missing, `usrMissingAction` Alert | **Exit 1**, naming them, with a diagnostic saying what to do |
| Unlisted container, `usrUnlistedAction` Warn | **Exit 0**, naming it in the status |
| Unlisted container, `usrUnlistedAction` Alert | **Exit 1** |
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

## Test order

1. One internal Docker host, saved as a **Scripts** component. Run it and read
   the raw output.
2. One site, one device, with the job scoped to that device.
3. Save as a Monitor and widen, starting with TechCollective's own hosts.
   Route its alerts to TI before Support sees them.

## Known limits

- **Docker only.** Podman is not handled.
- It only knows what the list says. A list created while a service was down
  never expects that service. Check the list after the first Host Maintenance
  run.
- It doesn't watch a container's health or resource use. That is the Health
  monitor's job.
- `date -d` for container age is a GNU spelling. Where it fails, the container
  counts as just started, so it can't be reported as unlisted. That fails
  quiet on purpose.
- It shares its container-identity code with the two script components, in a
  block marked `tc-docker shared`. It must stay identical in all three.

## Open questions

- **Should unlisted containers alert?** It starts at Warn, so the first weeks
  show how noisy each host is before anyone is paged. Revisit after rollout.
- **Telling clients.** Alerting when a client deploys something new changes
  what we watch on their servers. Tell them before turning it on there.
- **Level** is not standardised. `component.json` carries 4, as the Images
  monitor does.
