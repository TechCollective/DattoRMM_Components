# Docker - Container Health and Resource Usage [Lin]

A Datto RMM custom monitor for Linux Docker hosts. It watches running containers
for resource exhaustion, failed healthchecks, restart loops, out-of-memory kills
and non-zero exits, and reports through Datto's monitor contract.

> **Status: Not Validated.** Reviewed against our monitor contract and security
> checklist when written. Hardened 2026-11-17 (first `component.json`, version
> 1): a root-only state directory with no `/var/tmp` fallback, a result inside
> 90 seconds on every path, a stopped Docker left stopped, one PATH rule,
> OOM kills told apart from `docker stop`, a new baseline after a long gap, and
> logs named in the status. Exercised through its Tier 1 `test.json` against a
> live Docker 29 daemon in a sandbox, except the stopped-Docker steps, which
> need systemd (run in CI). Not yet run through a Datto agent. Follow the
> [test order](#test-order) before widening it.
>
> **Version 2** (2026-11-17) changes comments only: the time-limit code
> (`bounded`, `systemd_up`, `docker_unit_loaded`) is marked as a shared block,
> `tc-docker bounded`, with the other two Docker monitors, and the first line
> of the `tc-docker running` block says it is identical in every tc-docker
> component. Every line of code is the same as version 1's. Through its Tier
> 1 `test.json` in a sandbox with no systemd and no bash 4.2, every step gave
> the result it gave for version 1 there; the bash 4.2 and stopped-Docker
> steps run in CI. Not yet run through a Datto agent.
>
> **Version 3** (2026-11-17): the result and diagnostic code is now the block
> marked `tc-docker result`, shared with the other two Docker monitors: one
> `emit`, one `diag`, one `EXIT` trap, one status limit (900 characters, which
> this monitor already had). See [One result block](#one-result-block). Every
> status and every diagnostic reads as in version 2, with one exception: a run
> that dies unexpectedly now says `Check could not run: the monitor stopped
> unexpectedly (exit N)`, as the other two monitors do, where version 2 said
> `Check failed before it could measure anything (exit N)`.
> **The state file moves** from `/var/lib/tc-docker-monitor` to
> `/var/lib/tc-docker`, the directory the prune and the Containers monitor
> already use, and is written with the function they use (`tc_state_write`,
> in the shared block `tc-docker state`). The first run of version 3 reads
> the old file once, so no restart count or breach streak is lost; the old
> directory is never changed or removed, and can be deleted by hand once
> every monitor on the host is on its new version. Two things differ from
> version 2: **a symlink in the state file's place is refused**, not replaced
> (the run then has no saved state and says so), and the status says `state
> not saved (<why>)` where version 2 said `no saved state (<why>)` or `saved
> state could not be written to ...`. See [State file](#state-file).
> **The script's header comment is short** (what it is, what it changes, the
> result states) and points here; the one thing it said that this README did
> not (no code is downloaded at run time) is now under *What it does*.
> Through its Tier 1 `test.json` in a sandbox with no bash 4.2, with
> systemd's answers simulated: every step that passed for version 2 passes,
> except the ones rewritten for the new directory, which pass as rewritten;
> the bash 4.2 steps were **not** run and run in CI. Not yet run through a
> Datto agent.

## What it does

One pass over the local Docker daemon per run. Six conditions:

| Condition | Alerts when |
|---|---|
| **CPU** | A container is at or above `usrCpuThreshold` percent **of its own CPU allowance**, for `usrConsecutive` runs in a row |
| **Memory** | A container is at or above `usrMemThreshold` percent of its memory limit, same consecutive-run rule |
| **Health** | A container's Docker `HEALTHCHECK` reports `unhealthy` (`usrCheckHealth`) |
| **Restart loop** | A container's restart count rose by `usrRestartThreshold` or more **since the previous run** |
| **Out of memory** | A container was **OOM-killed** within the last `usrExitedWindowMin` minutes. Always an alert |
| **Exited** | A container exited **non-zero** within the last `usrExitedWindowMin` minutes. Exit 143 or 137 without an OOM kill follows `usrStoppedExitAction` |

**Read-only.** It runs `docker info`, `docker version`, `docker ps`,
`docker stats --no-stream`, `docker inspect` and, only if you turn it on,
`docker logs`. It makes no change to any container, image or daemon, and it
makes no network calls of any kind, so no code is downloaded at run time. The
only thing it writes is its own state
file, in `/var/lib/tc-docker` (which it creates, root-only, when it is not
there).

### Why it replaces `Docker Monitor [LIN]`

The old component wrapped `check_docker.py`, downloaded at run time from a branch
of a GitHub fork and executed as root. It produced alerts with no text in them,
for two reasons: it emitted `Alert=` in the result block where Datto's contract
requires `STATUS=`, and its diagnostic block re-emitted `Alert=` with a variable
that was empty because stderr was never captured. It also declared `CPU` and
`MEMORY` input variables and then ignored them in favour of hardcoded thresholds.

Monitors cannot take file attachments, so a runtime download was the only way to
keep `check_docker`, which is exactly why it had to go rather than be patched.

**Untarget `Docker Monitor [LIN]` when this goes live. Do not run both.**

### CPU is normalised to the container's own allowance

`docker stats` reports CPU as a percentage of **one core**. A container using two
full cores reads `200%`. A flat 90% threshold therefore alerts on any container
that keeps a single core busy on a 16-core host, the biggest source of false
positives in every off-the-shelf Docker monitor.

This component divides the raw figure by the CPUs the container is actually
allowed:

1. `HostConfig.NanoCpus` if a CPU limit is set (`--cpus`)
2. otherwise the size of `HostConfig.CpusetCpus` if one is pinned
3. otherwise the host core count

So `100%` means *saturated*, on any host, for any container size. The allowance
and the normalised percentage appear in the diagnostic.

### A resource breach must persist

`docker stats --no-stream` is a single instantaneous sample, and a single sample
is flappy: a container mid-compaction or mid-build reads 100% for two seconds.
CPU and memory breaches must therefore be seen on `usrConsecutive` runs in a row
before they alert. The streak is carried in the state file and shown per container
in the diagnostic. Health, restart, OOM and exit conditions are **not** damped.

### Restarts are a delta, against a recent baseline

`RestartCount` is cumulative since the container was created, so the component
records the count per container each run and alerts on the **increase** since
the previous run.

- First run: no baseline exists, so one is recorded and nothing alerts.
- A container recreated from scratch resets its count to 0; the negative delta is clamped to 0.
- **A previous run more than 6 hours ago is not a baseline.** A restart count
  that grew over weeks is not a loop, and a streak with hours between its runs
  is not consecutive. When the saved state is older than 6 hours (or dated in
  the future), the run takes a new baseline: no restart alert, every breach
  streak starts again, and the status says so:

      STATUS=All 3 running container(s) within thresholds; highest CPU 2.1% (web), highest memory 40.2% (db); new baseline taken (previous run 7 h ago, more than 6 h), so no restart alert and no breach streak this run

### Out-of-memory kills and deliberate stops

The exited check reads `State.OOMKilled` as well as the exit code:

| Exited container | Result |
|---|---|
| OOM-killed (any exit code, usually 137) | **Alert**: `<name>: killed for running out of memory (OOM) N minutes ago, exit code 137` |
| Exit 143 or 137, not OOM-killed | `usrStoppedExitAction`: **Warn** (default) names it in the status, exit 0; **Alert** alerts |
| Any other non-zero exit | **Alert**, as before |

`docker stop` sends TERM and, after its grace period, KILL. A process that
exits on TERM gives 143; one that ignores TERM (a shell as PID 1, for one) is
killed and gives 137. Before this change both alerted, so stopping a container on
purpose raised an alert for the next hour.

### Docker stopped, missing or not answering

Checked before anything else, in this order:

| Host state | Result |
|---|---|
| No `docker` command on PATH or in the usual system directories, and no socket or `docker.service` | Exit 0: not installed |
| No `docker` command, but `/var/run/docker.sock` is a socket or `docker.service` is loaded | **Exit 1** |
| systemd says `docker.service` is not active | Exit 0: `Docker is stopped (docker.service is inactive); nothing to check`. **No docker command is run**, because any one would start Docker again through `docker.socket` |
| A docker client, but no `docker.service` and no socket | Exit 0: no daemon on this host |
| `docker info` fails otherwise | **Exit 1**, quoting Docker's error line |
| Docker accepts the connection and never answers | **Exit 1** after 60 seconds: `Check could not run: Docker did not answer within 60 seconds` |

Every docker command of a run shares one deadline, 60 seconds after the
monitor starts. What is still running then is stopped: `timeout(1)` sends TERM
to the process group of the docker commands this run started, then KILL to
anything left in it; nothing else is signalled. The diagnostic names the command
that did not finish. The same mechanism and the same shared "is Docker running"
block as `Docker - Containers Differ From Expected [Lin]`: the time limit is
the block marked `tc-docker bounded` (three copies, one in each Docker
monitor) and the check is the block marked `tc-docker running` (seven copies,
one in every Docker component and in the prune; the seventh came with
[`Docker - Configure Daemon Limits [Lin]`](../../Scripts/docker-configure-daemon-limits-lin/),
which took over `daemon.json` from Host Maintenance version 15). From version 3 the result
code is the block `tc-docker result` (the three monitors), the state file is
written by `tc-docker state` (the three monitors and the prune) and read by
`tc-docker monitor state` (this monitor and the Images monitor).
`tools/check-shared-blocks.py` keeps the copies identical.

### State file

`/var/lib/tc-docker/monitor-state.tsv`. Four tab-separated columns: container
name, restart count, breach streak, and the run's time (seconds since 1970).

How it is written, and when it is not (the same rules, and from version 3 the
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
root, and then only its well-formed lines.

**It never fails the check.** A run that cannot save its state still checks
everything it can without one, and the status says why, for example
`; state not saved (/var/lib/tc-docker is not owned by root), so restart and
breach counts start again every run`. The next run then has no previous run to
compare with (or an older one, when an earlier file is still readable): no
restart delta, no damping.

**Moved in version 3.** Versions 1 and 2 kept this file in
`/var/lib/tc-docker-monitor`. While `/var/lib/tc-docker/monitor-state.tsv`
does not exist, the file of that name in the old directory is read instead,
under the same rule (a real directory and a regular file, both root's). That
run writes the new file, so the old one is read once. **The old directory is
never changed or removed**; delete it by hand once the Health and Images
monitors on the host are both on their new versions. This fallback is
temporary: the block marked `tc-docker monitor state` says what to remove.

## Installing it in Datto

Automation → Components → New Component, or import the `.cpt` CI builds from
`component.json`.

| Field | Value |
|---|---|
| Name | `Docker - Container Health and Resource Usage [Lin]` |
| Description | Alerts when a container is unhealthy, restart-looping, OOM-killed, exited non-zero, or over CPU/memory thresholds, or Docker does not answer. Read-only; never starts a stopped Docker. |
| Category | **Monitors**. Permanent; cannot be changed after the first save. |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | 4 in `component.json`, as the other Docker monitors. Not standardised; decide at save time |
| Timeout | **120 seconds**: every path prints its result inside 70 (60-second Docker deadline plus 5 seconds' KILL grace) |
| Attachments | none |
| Monitor interval | 15 minutes suggested |

Paste the whole of `docker-container-health-and-resource-usage-lin.sh` as the
script body, then add the input variables below.

**On the interval.** The interval and `usrConsecutive` together decide how long a
real problem takes to surface. At 15 minutes and 2 consecutive runs, a sustained
CPU or memory breach alerts after roughly 30 minutes. Health, restart, OOM and
exit conditions alert on the first run that sees them. An interval longer than 6
hours means every run takes a new baseline, so restart loops and breach streaks
are never measured.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrCpuThreshold` | String | `90` | 1–100. Percent of the container's own CPU allowance, **not** of one core. A typed `%` is tolerated. |
| `usrMemThreshold` | String | `90` | 1–100. Percent of the container's memory limit; against total host RAM when no limit is set. |
| `usrConsecutive` | String | `2` | 1–10. Runs a container must breach CPU or memory before it alerts. `1` disables damping. |
| `usrCheckHealth` | **Selection** | `Alert` | `Alert` / `Warn` (named in the status, no alert) / `Ignore`. |
| `usrRestartThreshold` | String | `3` | 1 or more. Restarts since the previous run. |
| `usrExitedWindowMin` | String | `60` | Minutes. `0` disables the exited-container and OOM checks. |
| `usrStoppedExitAction` | **Selection** | `Warn` | `Warn` / `Alert`. A container that exited 143 or 137 without being OOM-killed, usually `docker stop`. |
| `usrExclude` | String | *(empty)* | Extended regex matched against container names, e.g. `^(ci-\|tmp-)`. Applies to running and exited containers. A pattern starting with `-` is a pattern, not an option. |
| `usrIncludeLogs` | **Selection** | `No` | `Yes` tails 20 log lines from up to 3 alerting containers into the diagnostic, and the status says so. |

No client-specific value is hardcoded. An invalid value in any of these makes
the monitor refuse to run, exit 1 with `STATUS=Check could not run: ...`, rather
than quietly falling back to a default.

### `usrIncludeLogs` defaults to `No` on purpose

Diagnostic output flows into Autotask tickets, and container logs routinely carry
tokens, connection strings and customer data. Turn it on per assignment while
triaging a specific problem. When it is on and an alert fires, the status line
ends with `; last 20 log lines of N container(s) included in the diagnostic`, so
anyone reading the alert or the ticket can see logs were attached, not only
whoever looks at the assignment.

## Exit behaviour

Datto monitors have exactly two states: exit `0` is healthy, exit `1` raises an
alert. There is no warning tier; "Warn" here means named in the status, exit 0.

| Host state | Result |
|---|---|
| Docker not installed | **Exit 0**: "Docker is not installed on this host; nothing to check" |
| No `docker` command but a socket or `docker.service` | **Exit 1** |
| Docker stopped (systemd) | **Exit 0**, says so; no docker command run |
| A docker client and no daemon at all | **Exit 0**, says so |
| Docker installed, daemon unreachable | **Exit 1**, quoting the daemon's own error line |
| Docker does not answer | **Exit 1** inside 70 seconds: "Docker did not answer within 60 seconds", naming the command |
| `docker ps` fails | **Exit 1**: "Docker did not return its container list" |
| Docker installed, no containers running | **Exit 0**, says so |
| `docker stats` returns nothing | **Exit 0** for that condition; reported in the status, never alerted on |
| A container with no resource sample | Counted in the status; health, restart and exit checks still run |
| `healthcheck: starting` | Named in the status, never alerts |
| A container OOM-killed in the window | **Exit 1** |
| A container stopped (143/137) in the window | **Exit 0** named (`Warn`) or **Exit 1** (`Alert`) |
| The state file cannot be saved | The check still runs; the status says `state not saved (<why>)`. Never fails |
| Saved state older than 6 hours | New baseline; the status says so |
| A required tool (`awk`, `grep`, `sed`, `date`, `timeout` with `-k`, `stat`, `mktemp`) missing | **Exit 1** with `STATUS=Check could not run: ...` |
| An input variable is invalid | **Exit 1**, refuses loudly |
| The script dies unexpectedly | **Exit 1** via an `EXIT` trap: `Check could not run: the monitor stopped unexpectedly (exit N)` |

The `EXIT` trap matters more than it looks. An unhandled error that exits
non-zero with nothing on stdout is what Datto renders as an alert with no text,
the exact failure the old component shipped with. The trap prints a fallback
result block and exits 1.

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

- Exactly one `<-Start Result-> / <-End Result->` pair, containing exactly one `STATUS=` line with **no space after the equals sign**.
- Exit 0 on the healthy path, with a status naming the highest-CPU and highest-memory containers and their percentages.
- Exit 1 on the alert path, plus a diagnostic listing the thresholds in force, every condition met, and a per-container table of health, restart count, normalised CPU, memory percentage, memory limit and breach streak.
- No diagnostic block at all on a healthy run.
- The **second** run showing a real age on the `previous run:` line of a diagnostic. If the status says `state not saved`, it also says why.

### Troubleshooting

**An alert with no message at all.** That's the contract, not the container: the
script isn't reaching its result block, or something is emitting a second one.
Re-run it as a Script component and check for exactly one `STATUS=` line.

**Constant CPU alerts on a busy host.** Check the diagnostic for the container's
allowance. A container with no `--cpus` limit is measured against every core on
the host. Either set a CPU limit on the container or exclude it.

**Constant restart alerts from CI or orchestrated containers.** Those restart by
design during a rollout. Exclude them with `usrExclude`, or raise
`usrRestartThreshold` on those hosts.

**Memory percentages that look wrong.** A container with no memory limit is
measured against total host RAM. The diagnostic states the limit per container.

**Nothing is measured, but the monitor is green.** `docker stats` returning
nothing is reported in the status text and does not alert on its own. If it
persists across runs, the daemon is unhealthy in a way `docker info` isn't
catching.

## Test order

Never a client first.

1. **One internal Docker host, saved as a `Scripts` component.** Run it twice and read the raw job output.
2. **One site, one device, job scoped to that device**, still as a Script.
3. **Save as a Monitor and widen.**

## Known limits

- **Docker only.** Podman is not handled.
- A container with **no memory limit** is measured against total host RAM, so `usrMemThreshold` means something subtly different for limited and unlimited containers.
- `docker stats` excludes page cache from memory on modern Docker; on older cgroup v1 hosts it may not, which reads high.
- The exited-container check only sees containers still present on the host. Anything run with `--rm` is gone before the monitor can see it.
- Exit 143 or 137 is read as "stopped" whether `docker stop` or something else sent the signal; only an OOM kill is told apart.
- It does not check whether an *expected* container is missing entirely; that is `Docker - Containers Differ From Expected [Lin]`.
- "Docker is stopped" relies on systemd. Without systemd, `docker info` is asked, and on such a host a socket-activated daemon could be started by it.
- **bash 4.2+** (associative arrays, `${var,,}`; tested under GNU bash 4.2 in CI). Alpine's busybox `ash` would need bash installed.
- GNU coreutils: `timeout` with `-k`, `stat -c`, `mv -T`, and `date -u -d <RFC3339>` (on busybox the exit time conversion fails and that container is skipped).
- Runs as root, like every Datto component on Linux.

## Open questions

- **The result keyword.** Our monitor contract says the payload line is `STATUS=`; see [`Monitors/README.md`](../README.md). Confirm on the first Script-mode run.
- **Component Level** (access tier) is not standardised. Decide at save time.
- **Whether this should be two components.** It watches six conditions, and our naming standard treats a name that won't come out cleanly as the signal to split. Kept as one because they share the same `docker stats` call and the same state file. Revisit if alert volume from one drowns the other.
