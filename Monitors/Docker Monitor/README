# Docker - Container Health and Resource Usage [Lin]

A Datto RMM custom monitor for Linux Docker hosts. Watches running containers for
resource exhaustion, failed healthchecks, restart loops and non-zero exits, and
reports through Datto's monitor contract.

> **Status: Not Validated.** Reviewed against our monitor contract and security
> checklist, but not yet run against a real Docker daemon in production. Follow
> the test order below before widening it.

Internal TechCollective component. Not for client distribution.

---

## Contents

| Path | What it is |
|---|---|
| `docker-container-health-and-resource-usage-lin.sh` | The component body. This file is the source of truth — paste it into Datto, don't edit it there. |
| `README.md` | This file. |

**Where things live.** The script is versioned here. The *deployed* copy lives in
the Datto Component Library, and Datto is not version controlled — so any change
is made here first, committed, then pasted over the component body. The
operational document (thresholds, rollout notes, open questions) is in IT Glue as
**Datto RMM - Docker Container Health and Resource Usage**.

---

## What it does

One pass over the local Docker daemon per run. Five conditions:

| Condition | Alerts when |
|---|---|
| **CPU** | A container is at or above `usrCpuThreshold` percent **of its own CPU allowance**, for `usrConsecutive` runs in a row |
| **Memory** | A container is at or above `usrMemThreshold` percent of its memory limit, same consecutive-run rule |
| **Health** | A container's Docker `HEALTHCHECK` reports `unhealthy` |
| **Restart loop** | A container's restart count rose by `usrRestartThreshold` or more **since the previous run** |
| **Exited** | A container exited **non-zero** within the last `usrExitedWindowMin` minutes |

Read-only. It calls `docker ps`, `docker stats --no-stream`, `docker inspect` and
— only if you turn it on — `docker logs`. It makes no change to any container,
image or daemon, and it makes no network calls of any kind.

### Why it replaces `Docker Monitor [LIN]`

The old component wrapped `check_docker.py`, downloaded at run time from a branch
of a GitHub fork and executed as root. It produced alerts with no text in them,
for two reasons: it emitted `Alert=` in the result block where Datto's contract
requires `STATUS=`, and its diagnostic block re-emitted `Alert=` with a variable
that was empty because stderr was never captured. It also declared `CPU` and
`MEMORY` input variables and then ignored them in favour of hardcoded thresholds.

Monitors cannot take file attachments, so a runtime download was the only way to
keep `check_docker` — which is exactly why it had to go rather than be patched.

**Untarget `Docker Monitor [LIN]` when this goes live. Do not run both.**

---

## Installing it in Datto

Automation → Components → New Component. Category **Monitors** — this is
permanent and cannot be changed after the first save.

| Field | Value |
|---|---|
| Name | `Docker - Container Health and Resource Usage [Lin]` |
| Description | Alerts when a container is unhealthy, restart-looping, exited non-zero, or over CPU/memory thresholds. Read-only; changes nothing. |
| Category | **Monitors** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | decide at save time — not standardised |
| Timeout | 180 seconds |
| Attachments | none |
| Monitor interval | 15 minutes suggested |

Paste the whole of `docker-container-health-and-resource-usage-lin.sh` as the
script body, then add the input variables below.

**On the interval.** The interval and `usrConsecutive` together decide how long a
real problem takes to surface. At 15 minutes and 2 consecutive runs, a sustained
CPU or memory breach alerts after roughly 30 minutes. Health, restart and exit
conditions alert on the first run that sees them.

---

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrCpuThreshold` | String | `90` | 1–100. Percent of the container's own CPU allowance, **not** of one core. A typed `%` is tolerated. |
| `usrMemThreshold` | String | `90` | 1–100. Percent of the container's memory limit; against total host RAM when no limit is set. |
| `usrConsecutive` | String | `2` | 1–10. Runs a container must breach CPU or memory before it alerts. `1` disables damping. |
| `usrCheckHealth` | **Selection** | `alert` | `alert` / `warn` (name it in the status, don't alert) / `ignore`. |
| `usrRestartThreshold` | String | `3` | 1 or more. Restarts since the previous run. |
| `usrExitedWindowMin` | String | `60` | Minutes. `0` disables the exited-container check. |
| `usrExclude` | String | *(empty)* | Extended regex matched against container names, e.g. `^(ci-\|tmp-)`. Applies to running and exited containers. |
| `usrIncludeLogs` | **Selection** | `no` | `yes` tails 20 log lines from up to 3 affected containers into the diagnostic. |

No client-specific value is hardcoded. Both variables with a known set of valid
values are **Selection** type, so a bad value is unrepresentable.

An invalid value in any of these makes the monitor refuse to run — exit 1 with
`STATUS=Check could not run: ...` — rather than quietly falling back to a default
and monitoring against a threshold nobody chose.

### `usrIncludeLogs` defaults to `no` on purpose

Diagnostic output flows into Autotask tickets, and container logs routinely carry
tokens, connection strings and customer data. Turn it on per-assignment while
triaging a specific problem. Don't make it the default.

---

## The three things that make this different from a naive Docker check

### CPU is normalised to the container's own allowance

`docker stats` reports CPU as a percentage of **one core**. A container using two
full cores reads `200%`. A flat 90% threshold therefore alerts on any container
that keeps a single core busy on a 16-core host — the biggest source of false
positives in every off-the-shelf Docker monitor.

This component divides the raw figure by the CPUs the container is actually
allowed:

1. `HostConfig.NanoCpus` if a CPU limit is set (`--cpus`)
2. otherwise the size of `HostConfig.CpusetCpus` if one is pinned
3. otherwise the host core count

So `100%` means *saturated*, on any host, for any container size. The raw figure,
the allowance and the normalised percentage all appear in the diagnostic.

### A resource breach must persist

`docker stats --no-stream` is a single instantaneous sample, and a single sample
is flappy — a container mid-compaction or mid-build reads 100% for two seconds.
CPU and memory breaches must therefore be seen on `usrConsecutive` runs in a row
before they alert. The streak is carried in the state file and shown per container
in the diagnostic.

Health, restart and exit conditions are **not** damped. Those are discrete events,
not samples.

### Restarts are a delta, not a total

`RestartCount` from `docker inspect` is cumulative since the container was
created, so the raw number tells you nothing about whether something is looping
*now*. The component records the count per container each run and alerts on the
**increase** since the previous run.

- First run after deployment: no baseline exists, so one is recorded and nothing alerts.
- A container recreated from scratch resets its count to 0; the resulting negative delta is clamped to 0 rather than reported as a fault.

---

## State file

`/var/lib/tc-docker-monitor/monitor-state.tsv`, falling back to
`/var/tmp/tc-docker-monitor/` if `/var/lib` isn't writable. Mode 600, directory
700 — the same directory the container-image monitor uses, deliberately.

Four tab-separated columns: container name, restart count, breach streak, epoch.
Written atomically via a `.tmp` file and `mv -f`.

If the directory can't be written the monitor still runs. It just loses the
restart delta and the consecutive-run damping, and re-baselines every run. The
diagnostic line `previous run: no previous run recorded` on a second consecutive
run is how you spot that.

---

## Exit behaviour

Datto monitors have exactly two states: exit `0` is healthy, exit `1` raises an
alert. There is no warning tier — that's a Nagios concept and it does not survive
the translation.

| Host state | Result |
|---|---|
| Docker not installed | **Exit 0** — "Docker is not installed on this host; nothing to check" |
| Docker installed, no containers running | **Exit 0** — says so |
| Docker installed, daemon unreachable | **Exit 1**, quoting the daemon's own error line |
| `docker stats` returns nothing | **Exit 0** for that condition — reported in the status, never alerted on |
| A container with no resource sample | Counted in the status; health, restart and exit checks still run |
| `healthcheck: starting` | Named in the status, never alerts |
| Required tool (`awk`, `grep`, `date`) missing | **Exit 1** with `STATUS=Check could not run: ...` |
| An input variable is invalid | **Exit 1**, refuses loudly |
| The script dies unexpectedly | **Exit 1** via an `EXIT` trap |

The first two rows are what make this safe to assign to every Linux device rather
than only to known Docker hosts.

The `EXIT` trap matters more than it looks. An unhandled error that exits
non-zero with nothing on stdout is what Datto renders as an alert with no text —
the exact failure the old component shipped with. The trap emits a fallback
result block and upgrades a would-be exit 0 to exit 1, so an unexpected death can
never report success and can never be silent.

---

## Test order

Never a client first.

1. **One internal Docker host, saved as a `Scripts` component.** Run it twice and read the raw job output. A monitor's output is only visible as an alert, which is a poor debugger and a loud one.
2. **One site, one device, job scoped to that device**, still as a Script.
3. **Save as a Monitor and widen.**

What to expect in step 1:

- Exactly one `<-Start Result-> / <-End Result->` pair, containing exactly one `STATUS=` line with **no space after the equals sign**.
- Exit 0 on the healthy path, with a status naming the highest-CPU and highest-memory containers and their percentages.
- Exit 1 on the alert path, plus a diagnostic listing the thresholds in force, every condition met, and a per-container table of health, restart count, normalised CPU, memory percentage, memory limit and breach streak.
- No diagnostic block at all on a healthy run.
- The **second** run showing a real age on the `previous run:` line. If it still says `no previous run recorded`, the state directory isn't writable.

---

## Troubleshooting

**An alert with no message at all.** That's the contract, not the container — the
script isn't reaching its result block, or something is emitting a second one.
Re-run it as a Script component and check for exactly one `STATUS=` line with no
space after the equals.

**Constant CPU alerts on a busy host.** Check the diagnostic for the container's
allowance. A container with no `--cpus` limit is measured against every core on
the host, so a genuinely busy single-threaded container on a 2-core box will read
high and be right. Either set a CPU limit on the container or exclude it.

**Constant restart alerts from CI or Kubernetes-managed containers.** Those
restart by design during a rollout. Exclude them with `usrExclude`, or raise
`usrRestartThreshold` on those hosts.

**Memory percentages that look wrong.** A container with no memory limit is
measured against total host RAM. The diagnostic states the limit per container,
including `limit none (measured against host RAM)`.

**Nothing is measured, but the monitor is green.** `docker stats` returning
nothing is reported in the status text and does not alert on its own — deliberate,
because it's usually a race between listing containers and sampling them. If it
persists across runs, the daemon is unhealthy in a way `docker info` isn't
catching.

---

## Requirements

- **bash 4.0+** — uses associative arrays and `${var,,}`. Fine on Debian, Ubuntu, RHEL and SUSE. Alpine's busybox `ash` would need bash installed.
- `awk`, `grep` and `date` are hard requirements, checked explicitly before anything else runs.
- `timeout` is used when present and skipped when not.
- `date -u -d <RFC3339>` for the exited-container check is a GNU spelling. On busybox the conversion fails and that container is skipped rather than breaking the run.
- Runs as root, like every Datto component on Linux.

---

## Known limits

- **Docker only.** Podman is not handled.
- A container with **no memory limit** is measured against total host RAM, so `usrMemThreshold` means something subtly different for limited and unlimited containers.
- `docker stats` excludes page cache from memory on modern Docker; on older cgroup v1 hosts it may not, which reads high.
- The exited-container check only sees containers still present on the host. Anything run with `--rm` is gone before the monitor can see it.
- Kubernetes-managed containers will restart-loop by design during a rollout.
- It does not check whether an *expected* container is missing entirely. That needs a per-site list of expected names and is a separate component if we want it.

---

## Open questions

- **The result keyword.** Our monitor contract says the payload line is `STATUS=`. The ComStore component behind our disk space monitor emits `X=STATUS: ...`, and the component this replaces used `Alert=`. Confirm on the first Script-mode run which one Datto's parser actually accepts, and correct the IT Glue doc either way. Two components are now waiting on this answer.
- **Component Level** (access tier) is not standardised. Decide at save time.
- **Whether this should be two components.** It watches five conditions, and our naming standard treats a name that won't come out cleanly as the signal to split. "Container health" and "container resource usage" would both name well. Kept as one because they share the same `docker stats` call and the same state file. Revisit if alert volume from one drowns the other.
