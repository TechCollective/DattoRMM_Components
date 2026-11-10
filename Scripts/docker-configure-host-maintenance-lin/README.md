# Docker - Configure Host Maintenance [Lin]

A Datto RMM script component for Linux Docker hosts. It stops a Docker host's
disk filling up over time:

- It adds log rotation and build-cache limits to the Docker daemon's
  configuration.
- It records which containers the host is expected to run.
- It installs a weekly prune that removes what is unused and leaves those
  expected containers, and their images, alone.

**Nothing of a host's is deleted until a person has reviewed its list.**
Until then, the prune only clears build cache and unused networks.

> **Status: Not Validated.** Written 2026-11-09. Version 3 ran through a Datto
> agent on one internal Docker host.
>
> - **Version 3** added per-container protection and the expected-containers
>   list.
> - **Version 4** creates the list from every container, running or stopped,
>   and holds back all container and image removal until the list has been
>   reviewed.
>
> Version 4 was exercised against a live Docker 29 daemon in a sandbox,
> including the onboarding case it exists for: a stopped container started by
> hand, and a locally built image. The Tier 1 test covers both phases on a
> GitHub runner.

## What it does

It **changes the endpoint**. One run does up to four things.

### 1. Merges limits into `/etc/docker/daemon.json`

It adds only keys that are missing, and never changes a value that is already
set:

- **`log-opts.max-size` and `log-opts.max-file`.** These are added only when
  the log driver is `json-file` (Docker's default) or `local`. Any other
  driver, such as `journald`, is left alone and the output says so.
- **`builder.gc`.** This is added only if the file has no `builder.gc` at all.
  Docker 28 and later gets a policy with `reservedSpace` and `maxUsedSpace`.
  Older engines get `defaultKeepStorage`, because they would silently ignore
  the newer keys.

Before it writes, it checks the merged file with `dockerd --validate` when
the engine has that option. If the check fails, nothing is written. The
previous file is kept as `daemon.json.tc-bak-<timestamp>`.

### 2. Creates the expected-containers list, once

If `/etc/tc-docker/expected-containers` does not exist, it is created from
**every container present now, running or stopped**. A container that exists
when we take a server on is assumed to be wanted until a person says
otherwise. It also creates `/etc/tc-docker/ignore`, holding a commented
example.

**A new list is not reviewed.** Until a person runs
`Docker - Update Expected Containers [Lin]` with **Confirm reviewed**, which
writes `/etc/tc-docker/reviewed`, the weekly prune removes **no containers and
no images** on this host. It still clears unused networks and build cache.

This is the onboarding safeguard. Without it, a new client's server could
lose, at its first Sunday prune, a container that happened to be stopped when
the weekly job first reached it. That might be a container started by hand,
whose run command nobody wrote down, or a locally built image with no copy
anywhere else.

**After that, this component never changes the list.** A list that rewrote
itself on every run would accept whatever turned up and stop meaning
anything. Changes go through
[`Docker - Update Expected Containers [Lin]`](../docker-update-expected-containers-lin/),
whose job history records who changed what. Editing the file over SSH also
works; nothing overwrites it.

Each entry is a key that identifies a container, not just its current name:

| Key | Used for |
|---|---|
| `compose:<project>/<service>` | A Docker Compose service. Survives the container being recreated or scaled. |
| `name:<container name>` | Any other container |

Compose one-offs (`docker compose run`) and `--rm` containers are never put
on the list.

A host that ran version 2 with `usrRequiredContainers` set has those names
carried onto the new list.

### 3. Installs the weekly prune

| File | What it is |
|---|---|
| `/usr/local/sbin/tc-docker-prune` | The prune script |
| `/etc/default/tc-docker-prune` | Its setting: the age limit |
| `/etc/systemd/system/tc-docker-prune.service` | Runs the script |
| `/etc/systemd/system/tc-docker-prune.timer` | Runs the service on `usrPruneSchedule` |

The timer is `Persistent`, so a run missed while the host was off happens at
the next boot. It also has up to 30 minutes of random delay.

The script removes, when older than `usrPruneOlderThanHours`:

**Before the list is reviewed:** only unused networks and build cache.

**After review:**

1. **Stopped containers, except protected ones.** A stopped container is kept
   if it is on the expected-containers list, has restart policy `always` or
   `unless-stopped`, or is labelled `tc.keep`. The output names every kept
   container and why it was kept.
2. **Images no container uses**, except images labelled `tc.keep`. A kept
   stopped container still counts as using its image, so **a protected
   container's image is kept too**.
3. **Unused networks and build cache.**

**Volumes are never removed.**

The prune always runs. A stopped container is protected rather than blocking
the prune, so one container stopped on purpose can't stop the disk from being
cleaned.

For images, "older than N hours" means the image was **built** that long
ago, not pulled or last used. Most pulled images are older than a week, so in
practice **almost every image no container uses is removed**. That includes
images on a CI host or an AI workstation, which are then downloaded again on
next use.

### 4. Optionally prunes once, now

With `usrPruneNow`, it runs the same script immediately and reports free disk
space before and after.

### What it never does

**It never restarts Docker.** A `daemon.json` change only takes effect when
Docker restarts or the host reboots. Log rotation then applies only to
containers created after that. The output prints `RESTART PENDING` whenever a
restart is still needed. Set a post-condition on that string to turn the job
orange.

If Docker is not installed, it exits 0 and changes nothing. That makes it safe
to target at every Linux device.

It makes no network calls of its own.

## Why

Two TechCollective Docker hosts filled their disks in 2026:

- **A GitLab server.** Build-cache limits in `daemon.json` (the same values used
  here by default) kept build cache in check. They did not stop roughly 150 GB
  of unused images from piling up, because build-cache cleanup never touches
  images.
- **An internal Docker host.** Its root filesystem reached 99%.

This component combines both fixes: limits that stop growth, and a scheduled
prune that removes what the limits don't cover.

## Related components

| Component | Role |
|---|---|
| [`Docker - Update Expected Containers [Lin]`](../docker-update-expected-containers-lin/) | The only thing that changes the expected list or the ignore patterns |
| [`Docker - Containers Differ From Expected [Lin]`](../../Monitors/docker-containers-differ-from-expected-lin/) | Monitor. Alerts when an expected container is stopped or gone, and reports unlisted ones |

All three share one block of code that turns a container into its key. It is
marked `tc-docker shared` in each script and must stay identical in all three.

## Installing it in Datto

**Updating an existing copy:** open it in Datto, paste the script over the
body, and make the variables and description match the tables below. A
re-import creates a second component; see the repo's `tools/README.md`.

**New install:** Automation → Components → New Component, or import the
`.cpt` from the latest release.

| Field | Value |
|---|---|
| Name | `Docker - Configure Host Maintenance [Lin]` |
| Description | Sets Docker log and build-cache limits, seeds the expected-containers list, and a weekly prune that deletes nothing until the list is reviewed. |
| Category | **Scripts** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | Not standardised yet; decide at save time (`component.json` carries 5) |
| Timeout | 900 seconds. A first prune on a full host can take minutes. |
| Attachments | none |
| Post-condition | Optional: warn when output **contains** `RESTART PENDING` |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | **Selection** | `Apply` | `Apply` / `Report`. Report prints what it would change, including the list it would create, and changes nothing. Use it first on any host you have not looked at. |
| `usrLogMaxSize` | String | `10m` | A number plus `k`, `m` or `g`. Blank leaves log settings alone. |
| `usrLogMaxFile` | String | `3` | 1–20. Worst-case log disk per container is size × files. |
| `usrBuildCacheMax` | String | `100GB` | A number plus `MB`, `GB` or `TB`. Blank leaves build-cache settings alone. Lower it on hosts with small disks. |
| `usrBuildCacheReserved` | String | `20GB` | Same format. Docker 28 and later only. Should be smaller than the max. |
| `usrPruneSchedule` | String | `Sun *-*-* 04:00:00` | A systemd `OnCalendar` expression in the host's local time, checked with `systemd-analyze calendar`. Blank leaves the timer alone. |
| `usrPruneOlderThanHours` | String | `168` | 24–8760. Only unused items older than this are pruned. Saved to `/etc/default/tc-docker-prune`, so the most recent run sets it for the timer. |
| `usrPruneNow` | **Selection** | `No` | `Yes` also runs the prune once, now. |

No customer-specific value is hardcoded. Different hosts get different values
through the job's variables, not through edits to the script. The
per-host list lives on the host, not in a variable, so one fleet-wide job can
target every host.

An invalid value makes the component refuse to run with exit `2`. It checks
every input before it changes anything.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done, or nothing needed doing. Also returned when Docker is not installed. |
| `1` | Unexpected failure, such as a write, `systemctl` call or prune step failing. |
| `2` | An input variable is invalid. Nothing was changed. |
| `3` | One part could not be applied safely, and was not changed. Other parts may still have run, and the output says which. See the list below. |

What causes exit `3`:

- no `python3` to merge the JSON
- the existing `daemon.json` is not valid JSON
- the merged file failed `dockerd --validate`
- the host is not running systemd
- Docker is the snap package
- the daemon was unreachable, so the list could not be created; the next run
  retries

The prune script on the host exits `0` when it pruned, and `1` on an error,
such as the daemon being unreachable or a prune step failing.

## How to tell it worked

A first apply on a host that had none of this looks like:

    Docker: /usr/bin/docker, engine 28.x. Mode: apply.
      daemon.json ADDED: log-opts.max-size = 10m
      daemon.json ADDED: log-opts.max-file = 3
      daemon.json ADDED: builder.gc = {"enabled":true,"policy":[...]}
    daemon.json: merged file passes dockerd --validate.
    daemon.json: written.
    Expected list: created /etc/tc-docker/expected-containers with 3 entries:
      compose:shop/web
      compose:shop/db
      name:gitlab-runner
    Prune timer: installed tc-docker-prune.timer (...)
    Prune timer: next run ...
    RESTART PENDING: daemon.json changed. ...
    Docker host maintenance: done.

A second run says `KEPT` for each key, `no change`,
`Expected list: ... exists ... not changed`, and
`already installed with these settings`.

A prune reports what it kept:

    Stopped containers removed: 2
    Stopped containers kept, with their images:
      shop-db-1 (on the expected list)
      legacy (restart policy unless-stopped)
    Images: 3.1GB reclaimed
    Networks: nothing to remove
    Build cache: 0B reclaimed

On the host itself:

    cat /etc/tc-docker/expected-containers
    systemctl list-timers tc-docker-prune.timer
    journalctl -u tc-docker-prune.service    # what each prune removed and kept
    sudo /usr/local/sbin/tc-docker-prune     # run the prune by hand

## Test order

Never a customer first.

1. CI's "Component tests" check on the pull request (`test.json`, Tier 1).
2. One internal Docker host. Run with `usrMode` = `Report` first, read the
   list it would create, then run `Apply`.
3. On that host, run Update Expected Containers with Show, correct the list,
   then run Confirm reviewed. Check the next prune's journal.
4. One site, one device in it, with the job scoped to that device. Run Report,
   then Apply, then review the list. Restart Docker in that site's maintenance
   window.
5. Wider, only after the first four.

## Known limits

- **An unreviewed host gets no image cleanup.** That is deliberate. Its disk
  relief waits for the review, so review a new host's list in its first
  week. The monitor reports every unreviewed host.
- **A list includes whatever existed at creation, junk included.** That's
  safe, because a listed container is kept, but stale stopped containers stay
  until someone removes them from the list during the review.
- **Upgrading a version 3 host** leaves its list in place, but marks it
  unreviewed, because no `reviewed` file exists yet. Its container and image
  removal stops until someone runs Confirm reviewed.
- **systemd only** for the timer. On a host without systemd, the timer part
  exits `3`, and the other parts still run.
- **Needs `python3`** to merge JSON safely. Without it, the `daemon.json` part
  exits `3` rather than risk rewriting the file badly.
- **Snap-packaged Docker is refused.** Its config lives under `/var/snap` and
  snap manages it.
- **Rootless Docker** (a per-user daemon) and **Podman** are not handled.
- **The Docker 28 cutoff for `reservedSpace`/`maxUsedSpace`** comes from
  Docker's changelog, not from testing on a 27.x host.
- **It never tightens an existing setting.** A host that already has
  `max-size: 500m` keeps it.
- **No alert when the timer itself fails.** The prune's result is in the
  journal and `systemctl --failed`. Disk space monitoring is the backstop.
- **Removing it** is manual: `systemctl disable --now tc-docker-prune.timer`,
  then delete the two unit files, `/usr/local/sbin/tc-docker-prune`,
  `/etc/default/tc-docker-prune` and `/etc/tc-docker/`, and run
  `systemctl daemon-reload`.

## Open questions

- **Level** is not standardised. `component.json` carries 5, because this
  component writes daemon configuration as root.
