# Docker - Configure Host Maintenance [Lin]

A Datto RMM script component for Linux Docker hosts. It stops a Docker host's
disk filling up over time. It adds log rotation and build-cache limits to the
Docker daemon's configuration, and installs a systemd timer that prunes unused
images and build cache every week. Before each prune, a safety check makes sure
nothing that should be running is stopped.

> **Status: Not Validated.** Written 2026-11-09. Version 1 ran through a Datto
> agent on one internal Docker host. Version 2 adds the safety check. It was
> exercised against a live Docker 29 daemon in a sandbox, covering the
> `daemon.json` merge, the pre-28 engine path, report mode, input validation
> and every safety-check outcome. The Tier 1 test covers the systemd timer and
> the safety check on a GitHub runner.

## What it does

It **changes the endpoint**. One run does up to three things:

1. **Merges limits into `/etc/docker/daemon.json`.** It adds only keys that are
   missing, and never changes a value that is already set:
   - `log-opts.max-size` and `log-opts.max-file`. These are added only when the
     log driver is `json-file` (Docker's default) or `local`. Any other driver,
     such as `journald`, is left alone and the output says so.
   - `builder.gc`. This is added only if the file has no `builder.gc` at all.
     Docker 28 and later gets a policy with `reservedSpace` and `maxUsedSpace`.
     Older engines get `defaultKeepStorage`, because they would silently ignore
     the newer keys.

   Before it writes, it checks the merged file with `dockerd --validate` when
   the engine has that option. If the check fails, nothing is written. The
   previous file is kept as `daemon.json.tc-bak-<timestamp>`.

2. **Installs the weekly prune.** It writes four files:

   | File | What it is |
   |---|---|
   | `/usr/local/sbin/tc-docker-prune` | The prune script, with the safety check |
   | `/etc/default/tc-docker-prune` | Its settings: the age, and the required containers |
   | `/etc/systemd/system/tc-docker-prune.service` | Runs the script |
   | `/etc/systemd/system/tc-docker-prune.timer` | Runs the service on `usrPruneSchedule` |

   The timer is `Persistent`, so a run missed while the host was off happens at
   the next boot. It also has up to 30 minutes of random delay.

   **The safety check.** The prune deletes stopped containers, and then the
   images only they used. So before removing anything, the script checks that:

   - every container named in `usrRequiredContainers` is running, and
   - no container with restart policy `always` or `unless-stopped` is stopped.
     Those are meant to be running; one that isn't may be down for maintenance,
     or crashed.

   If either check fails, it **skips the whole prune** and lists the containers
   it found. The service then shows as failed in `systemctl --failed` and in
   the journal. The next run prunes once the containers are running again.
   Containers labelled `tc.keep` are exempt from the second check, because the
   prune never removes them anyway.

   When the check passes, the script runs:

       docker system prune --all --force --filter until=<N>h --filter label!=tc.keep

   This removes stopped containers, unused networks, unused images and build
   cache, all older than N hours, and skips anything labelled `tc.keep`.
   **Volumes are never removed.**

   For images, "older than N hours" means the image was **built** that long
   ago, not pulled or last used. Most pulled images are older than a week, so
   in practice **almost every image no container uses is removed**. That
   includes images on a CI host or an AI workstation that will be downloaded
   again on next use. Only images built within the last N hours survive.

3. **Optionally prunes once, now** (`usrPruneNow`). It runs the same script,
   safety check included, and reports free disk space before and after.

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

## Installing it in Datto

Automation → Components → New Component. Or import the `.cpt` that CI builds
for the pull request.

| Field | Value |
|---|---|
| Name | `Docker - Configure Host Maintenance [Lin]` |
| Description | Sets Docker log and build-cache limits and a weekly prune that skips if a needed container is down; never removes volumes or restarts Docker. |
| Category | **Scripts** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | not standardised yet. Decide at save time (`component.json` carries 5). |
| Timeout | 900 seconds. A first prune on a full host can take minutes. |
| Attachments | none |
| Post-condition | Optional: warn when output **contains** `RESTART PENDING` |

Paste the whole of `docker-configure-host-maintenance-lin.sh` as the script
body, then add the input variables below.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | **Selection** | `Apply` | `Apply` / `Report`. Report prints what it would change and changes nothing. Use it first on any host you have not looked at. |
| `usrLogMaxSize` | String | `10m` | A number plus `k`, `m` or `g`. Blank leaves log settings alone. |
| `usrLogMaxFile` | String | `3` | 1–20. Worst-case log disk per container is size × files. |
| `usrBuildCacheMax` | String | `100GB` | A number plus `MB`, `GB` or `TB`. Blank leaves build-cache settings alone. Lower it on hosts with small disks. |
| `usrBuildCacheReserved` | String | `20GB` | Same format. Docker 28 and later only. Should be smaller than the max. |
| `usrPruneSchedule` | String | `Sun *-*-* 04:00:00` | A systemd `OnCalendar` expression in the host's local time, checked with `systemd-analyze calendar`. Blank leaves the timer alone. |
| `usrPruneOlderThanHours` | String | `168` | 24–8760. Only unused items older than this are pruned. |
| `usrPruneNow` | **Selection** | `No` | `Yes` also runs the prune once, now. |
| `usrRequiredContainers` | String | *(empty)* | Optional. Container names, separated by spaces or commas, that must be running or the prune is skipped, e.g. `gitlab-runner`. Each must be a valid Docker name. Stopped `always` and `unless-stopped` containers block the prune whether this is set or not. |

**The last run sets the host's settings.** `usrPruneOlderThanHours` and
`usrRequiredContainers` are saved to `/etc/default/tc-docker-prune`, and the
weekly timer uses whatever the most recent run of this component wrote. A
recurring job aimed at a host that needs a required-container list has to
carry that list. Otherwise the next run clears it.

No customer-specific value is hardcoded. Different hosts get different values
through the job's variables, not through edits to the script.

An invalid value makes the component refuse to run with exit `2`. It checks
every input before it changes anything.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done, or nothing needed doing. Also returned when Docker is not installed. |
| `1` | Unexpected failure, such as a write or `systemctl` call failing. |
| `2` | An input variable is invalid. Nothing was changed. |
| `3` | One part could not be applied safely, and was not changed: no `python3` to merge the JSON, the existing `daemon.json` is not valid JSON, the merged file failed `dockerd --validate`, the host is not running systemd, or Docker is the snap package. **Also returned when a prune-now was skipped by the safety check.** Other parts may still have run, and the output says which. |

The prune script on the host exits `0` when it pruned, `3` when the safety
check skipped it, and `1` on an error, such as the daemon being unreachable.

## How to tell it worked

A first apply on a host that had none of this looks like:

    Docker: /usr/bin/docker, engine 28.x. Mode: apply.
      daemon.json ADDED: log-opts.max-size = 10m
      daemon.json ADDED: log-opts.max-file = 3
      daemon.json ADDED: builder.gc = {"enabled":true,"policy":[...]}
    daemon.json: merged file passes dockerd --validate.
    daemon.json: previous file saved as /etc/docker/daemon.json.tc-bak-...
    daemon.json: written.
    Prune timer: installed tc-docker-prune.timer (Sun *-*-* 04:00:00, ...)
    Prune timer: next run ...
    RESTART PENDING: daemon.json changed. ...
    Docker host maintenance: done.

A second run says `KEPT` for each key, `no change`, and
`already installed with these settings`.

A prune the safety check skipped looks like:

    SKIPPED: nothing was pruned. These containers should be running and are not:
      web (restart policy unless-stopped, but stopped)
    Start them, remove them, or label them tc.keep; the next run will prune.

On the host itself:

    systemctl list-timers tc-docker-prune.timer
    journalctl -u tc-docker-prune.service    # what each prune reclaimed, or why it skipped
    systemctl --failed                       # a skipped prune shows here until the next good run
    sudo /usr/local/sbin/tc-docker-prune     # run the prune by hand, safety check included

## Test order

Never a customer first.

1. CI's "Component tests" check on the pull request (`test.json`, Tier 1).
2. One internal Docker host. Run with `usrMode` = `Report` first, then `Apply`.
3. One site, one device in it, with the job scoped to that device. Run Report,
   then Apply, then restart Docker in that site's maintenance window.
4. Wider, only after the first three.

## Known limits

- **systemd only** for the timer. On a host without systemd, the timer part
  exits `3`, and the `daemon.json` part still runs.
- **Needs `python3`** to merge JSON safely. Without it, the `daemon.json` part
  exits `3` rather than risk rewriting the file badly.
- **Snap-packaged Docker is refused.** Its config lives under `/var/snap` and
  snap manages it.
- **Rootless Docker** (a per-user daemon) is not handled. Only the system daemon
  is configured.
- **Podman** is not handled.
- **The Docker 28 cutoff for `reservedSpace`/`maxUsedSpace`** comes from Docker's
  changelog, not from testing on a 27.x host. On older engines the component
  writes `defaultKeepStorage`, which every supported engine accepts.
- **It never tightens an existing setting.** A host that already has
  `max-size: 500m` keeps it. Edit that host by hand if it is wrong.
- **A deliberately stopped `unless-stopped` container blocks every prune**
  until it is started, removed or labelled `tc.keep`. That is intended: the
  skip is visible in the journal and in `systemctl --failed`. But nobody is
  alerted yet. A monitor that reads the service's last result would close
  that gap.
- **No alert when the timer fails or skips.** Disk space monitoring is the
  backstop.
- **Removing it** is manual: `systemctl disable --now tc-docker-prune.timer`,
  then delete the two unit files, `/usr/local/sbin/tc-docker-prune` and
  `/etc/default/tc-docker-prune`, and run `systemctl daemon-reload`.

## Open questions

- **Level** is not standardised. `component.json` carries 5, because this
  component writes daemon configuration as root.
- Whether this should also run as a scheduled job to re-assert the timer, or
  stay a run-once job per host. Re-running is harmless either way.
