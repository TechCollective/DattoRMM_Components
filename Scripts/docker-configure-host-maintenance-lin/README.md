# Docker - Configure Host Maintenance [Lin]

A Datto RMM script component for Linux Docker hosts. It stops a Docker host's
disk filling up over time with containers and images nothing uses:

- It records which containers the host is expected to run.
- It installs a weekly prune that removes what is unused and leaves those
  expected containers, and their images, alone.

Log rotation and build-cache limits in Docker's `daemon.json`, which this
component also set up to version 14, are a component of their own:
[`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/).

**Nothing of a host's is deleted until a person has reviewed its list.**
Until then, the prune only clears build cache and unused networks. After
review, **a stopped container is never removed without warning**: the prune
first records it as waiting, and removes it only on a run at least
`usrPruneGraceHours` later. The monitor shows what is waiting.

> **Status: Not Validated.** Written 2026-11-09. Version 3 ran through a Datto
> agent on one internal Docker host.
>
> **Version 15 no longer touches `daemon.json`.** Log rotation and
> build-cache limits moved to
> [`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/).
> A job that used this component to set them must add that one. See
> *Version 15* at the end of this list.
>
> **Version 16 removes `usrPruneImages` = `All`. The prune removes untagged
> ("dangling") images only, on every host, and never a tagged image.**
> Versions up to 8 removed every image no container used; versions 9 to 15
> removed untagged ones, and with `All` also tagged ones their registry
> confirmed it still had. A host that ran with `All`, such as a CI or GitLab
> runner host whose disk fills with pulled images, **gets no cleanup of its
> tagged images from version 16**: they pile up until they are removed some
> other way. See *Version 16* at the end of this list, and *Images* below.
>
> - **Version 3** added per-container protection and the expected-containers
>   list.
> - **Version 4** creates the list from every container, running or stopped,
>   and holds back all container and image removal until the list has been
>   reviewed.
> - **Version 5** fixes a version 4 defect: on a host whose Docker daemon is
>   started with `--log-driver` or `--log-opt` flags, version 4 could add
>   `log-opts` to `daemon.json` that **stop Docker starting at its next
>   restart**, while reporting success. Version 5 reads how the daemon is
>   really started before it merges, and reports a host that version 4
>   already broke (`DAEMON WILL NOT START`).
>
> - **Version 6** reads container labels so that a hostile one cannot forge a
>   container. A label is untrusted (a container inherits it from its image),
>   and in version 5 a Compose label carrying a tab and a newline could add a
>   fake row to the prune's container list and get a protected stopped
>   container removed. Version 6 also stops when Docker does not return its
>   container list: version 5 read that as "no containers".
>
> Version 5 was exercised against a live Docker 29 daemon in a sandbox,
> restarted under each set of flags, and the Tier 1 test restarts Docker
> under each set on a GitHub runner. It has not yet run through a Datto
> agent. **Run version 5 in Report mode across the Docker hosts version 4 has
> already reached**, and look for `DAEMON WILL NOT START` before those hosts
> next reboot.
>
> Version 6 was exercised against a live Docker 29 daemon in a sandbox, its
> label handling against Docker 17.12, 18.09 and 20.10 engines, and the Tier 1
> test covers both defects. It has not yet run through a Datto agent.
>
> - **Version 7** stamps the installed prune with its version
>   (`TC_PRUNE_VERSION=7`) and prints `tc-docker-prune version 7` as the first
>   line of every run, so a host's prune can be told apart from an older one.
>   What the prune removes, the units, `daemon.json` handling and the shared
>   block are unchanged. The monitor
>   [`Docker - Containers Differ From Expected [Lin]`](../../Monitors/docker-containers-differ-from-expected-lin/)
>   version 4 reads the stamp and flags a host whose prune is older than its
>   `PRUNE_MIN_VERSION`. The Tier 1 test fails if the stamp and
>   `component.json`'s `version` differ. Version 7 was run against a live
>   Docker 29 daemon in a sandbox for the stamp and its first output line; the
>   journal check and the timer steps run on the CI runner. It has not yet run
>   through a Datto agent.
> - **Version 8** changes how `daemon.json` is written; what is merged into it
>   is unchanged. Version 7 forced the file to `0644 root:root`, so a
>   `daemon.json` that was `0600` because it held a proxy password came out
>   world-readable; it replaced a symlinked `daemon.json` with a plain file;
>   it built the new file under `/tmp`, so on a host where `/tmp` is its own
>   filesystem the final move was a copy that a crash or a full disk could
>   leave truncated (Docker will not start with one); and it kept every
>   backup for ever, each holding the same password. Version 8 builds the new
>   file beside the real one and renames it into place, keeps the old file's
>   mode, owner and group, writes through a symlink and leaves the link, and
>   keeps the newest 5 backups. It also names each backup uniquely: version 7
>   overwrote a backup made in the same second. The prune is unchanged, so
>   `TC_PRUNE_VERSION` is `8` only because it follows this version, and the
>   monitor's `PRUNE_MIN_VERSION` stays `7`. Version 8 was run against a live
>   Docker 29 daemon in a sandbox (every case below, including a restart with
>   a symlinked file, a full disk and an immutable file), and the Tier 1 test
>   covers them on the CI runner. It has not yet run through a Datto agent,
>   and the SELinux relabel has not run anywhere (see Known limits).
> - **Version 9** narrows what the prune removes after review. A stopped
>   container's age is counted from when it **stopped** (`State.FinishedAt`),
>   not from when it was created, so one that crashed five minutes before the
>   prune is no longer removed with its logs. Removal takes **two runs**: the
>   first records the container in `/var/lib/tc-docker/pending-removal`, a run
>   at least `usrPruneGraceHours` (default 144) later removes it if it is
>   still stopped and unprotected. Images are removed by reference and never
>   forced; the default, `Dangling`, removes untagged images only; `All` also
>   removes tagged images that can be pulled again, and prints the
>   `repo@sha256` of each. `TC_PRUNE_VERSION=9`; the monitor's
>   `PRUNE_MIN_VERSION` is 9, so every host still on an older prune alerts
>   until this component runs on it. Version 9 was run against a live Docker
>   29 daemon in a sandbox, on both image stores; the Tier 1 test covers it on
>   the CI runner. It has not yet run through a Datto agent.
> - **Version 10** changes one rule, for tagged images in `All` mode. Version
>   9 kept a tagged image unless it had a `RepoDigests` entry, and on the
>   containerd image store (the default on a fresh Docker 29 install) every
>   image has one, so version 9 kept every tagged image there and `All` did no
>   more than `Dangling`. Version 10 asks the image's registry instead: a
>   tagged image that passed every local check is removed only when its
>   registry confirms, at that moment, that it still has one of the image's
>   `repo@sha256` references. Anything short of a confirmed yes keeps it. The
>   rule is the same on both image stores. **`All` now makes network calls**
>   (registry lookups; version 16 removed them with `All`); `Dangling` still
>   makes none.
>   `TC_PRUNE_VERSION=10`. The monitor's `PRUNE_MIN_VERSION` stays `9`:
>   version 9 is safe, only less effective. Version 10 was run against a live
>   Docker 29 daemon in a sandbox on both image stores, with both lookup
>   tools; the Tier 1 test covers it on the CI runner. It has not yet run
>   through a Datto agent.
> - **Version 11 never starts a Docker that is stopped.** Up to version 10
>   the prune's service had `Requires=docker.service`, so the weekly timer
>   started a Docker someone had stopped on purpose (a maintenance window, a
>   move of `/var/lib/docker`), and every `restart: always` container came up
>   with it. And on a package install `docker.socket` keeps listening while
>   the service is stopped, so any `docker` command (`docker info`,
>   `docker ps`) from this component or the prune started it too. Version 11
>   writes `Requisite=docker.service` instead, asks systemd whether Docker is
>   running before any `docker` command, and leaves a stopped Docker stopped
>   (see *It never starts Docker* below). It also restarts the timer only
>   when the timer itself changed, and adds `FixedRandomDelay=true` to it, so
>   upgrading a host to version 11 restarts its timer once. What the prune
>   removes is unchanged. `TC_PRUNE_VERSION=11`; the monitor's
>   `PRUNE_MIN_VERSION` stays `9`. Version 11 was run against a live Docker 29
>   daemon under systemd 255 in a sandbox, and the Tier 1 test covers it on
>   the CI runner. It has not yet run through a Datto agent.
> - **Version 12** makes three things simpler and stricter.
>   - **The prune reads its settings file as text and no longer runs it.** Up
>     to version 11 the prune sourced `/etc/default/tc-docker-prune` as shell,
>     as root, so any line in it was a command. Now it takes
>     `OLDER_THAN_HOURS`, `GRACE_HOURS` and `PRUNE_IMAGES` from lines of the
>     form `NAME=value` and ignores every other line. **A value in quotes, or
>     with a comment after it, used to work and is now refused** (the prune
>     removes nothing that depends on it and exits 1). The component never
>     wrote the file that way, so this only matters on a host where someone
>     edited it by hand.
>   - **The prune checks `OLDER_THAN_HOURS` itself** (a whole number, 24 to
>     8760), as it already checked the other two. Version 11 used whatever
>     the file said, so `OLDER_THAN_HOURS=0` written by hand removed
>     containers and images of any age. With a value it refuses, the prune
>     now records and removes **nothing at all** and exits 1. The component
>     also refuses `usrPruneOlderThanHours` above 8760 when only Prune now is
>     used (it used to check that case for the lower limit only).
>   - **A stopped Docker's start flags are no longer worked out from
>     `docker.service`.** Up to version 11, with Docker stopped, the component
>     rebuilt the `dockerd` command line from the unit, its drop-ins and its
>     environment files. That was a second copy of systemd's own rules. Now
>     flags are read only from a running `dockerd`. **With Docker stopped,
>     log rotation is skipped and the run exits `3`**; build-cache limits are
>     still added, and the next run with Docker running adds log rotation.
>     A job that used to exit `0` on a host whose Docker is stopped now exits
>     `3` there.
>
>   What the prune removes on a host whose settings file is as the component
>   wrote it is unchanged. `TC_PRUNE_VERSION=12`. The monitor's
>   `PRUNE_MIN_VERSION` goes to **11** in its version 8 (the first prune that
>   never starts a stopped Docker), not to 12. Version 12's prune, with every
>   case above, and the daemon.json part were run against a live Docker 29
>   daemon in a sandbox **without systemd**. The steps that need systemd
>   (the timer, the units, a stopped `docker.service`) have **not** been run
>   for this version: the Tier 1 test runs them on the CI runner, so read
>   that result before merging. It has not yet run through a Datto agent.
> - **Version 13** (2026-11-17) moves code and changes no behaviour. The
>   prune's reading of `/var/lib/tc-docker/pending-removal` is now the
>   function `tc_pending_lines` in the block the Docker components share
>   (`tc-docker shared`), so the prune, the monitor and Update Expected
>   Containers read that file with one parser where there were three. The
>   first line of the "is Docker running" block (`tc-docker running`) now says
>   what has been true since the other components took a copy: it is
>   identical in every tc-docker component. What the prune records, removes,
>   prints and writes is the same as version 12's; only the stamp differs
>   (`TC_PRUNE_VERSION=13`). The monitor's `PRUNE_MIN_VERSION` stays **11**.
>   The version 12 and version 13 prunes were run side by side against the
>   same 33 pending-removal files (well formed, and malformed in each way the
>   parser checks) with a stand-in `docker`, under gawk, mawk 1.3.4, mawk
>   1.3.3 and busybox awk: output, exit code, the file written and the docker
>   commands run were identical every time. The Tier 1 test was run against
>   a live Docker 29 daemon in a sandbox **without systemd**, with the timer
>   and unit steps left out: each step gave the result it gave for version
>   12 there, and the two new steps pass. The steps that need systemd (the
>   timer, the units, a stopped `docker.service`) have **not** been run for
>   this version: the Tier 1 test runs them on the CI runner, so read that
>   result before merging. It has not yet run through a Datto agent.
> - **Version 14** (2026-11-17) changes how the prune writes
>   `/var/lib/tc-docker/pending-removal`, and one thing it does. The write is
>   now `tc_state_write`, one function in a block the prune shares with the
>   three Docker monitors (`tc-docker state`), which write their own state
>   files in the same directory the same way. The file it writes is the same,
>   byte for byte, and so is every refusal the prune already had: a directory
>   that is a symlink or not a directory, a symlink or anything but a regular
>   file in the record's place, a directory that cannot be made root-only, a
>   short write, a failed rename. Each still means **no container is removed**
>   and exit 1. **One refusal is new:** a `/var/lib/tc-docker` that is **not
>   owned by root** is not used. Versions 9 to 13 made such a directory
>   root's and went on, believing a record in it that another user could have
>   written, and removing the containers it named as due. Version 14 leaves
>   the directory as it is, removes no container, says
>   `ERROR: could not write /var/lib/tc-docker/pending-removal: /var/lib/tc-docker is not owned by root`
>   and exits 1 until a person has put its owner right. Nothing in these
>   components makes that directory anything but root's. Where a command
>   failed, the words after `could not write ...:` are different (a short
>   reason, then the command's own message in brackets); see *If it cannot be
>   written* below. `TC_PRUNE_VERSION=14`; the monitor's `PRUNE_MIN_VERSION`
>   stays **11**. The header comments of the component and of the prune it installs
>   are short (what it is, what it changes, the exit codes) and point here;
>   everything they said is in this README. Nothing else in the component
>   changed. The version 13 and version 14 prunes were run side by side, with
>   a stand-in `docker`, on 51 states of `/var/lib/tc-docker` and the record
>   in it (33 of them the files of version 13's comparison): output, exit
>   code, the file written and the docker commands run were identical except
>   in the cases named above. The Tier 1 test was run against a live Docker
>   29 daemon in a sandbox **without systemd**, with the timer and unit steps
>   left out: each step gave the result it gave for version 13 there, and the
>   new steps pass. The steps that need systemd (the timer, the units, a
>   stopped `docker.service`) have **not** been run for this version: the
>   Tier 1 test runs them on the CI runner, so read that result before
>   merging. It has not yet run through a Datto agent.
> - **Version 15** (2026-11-18) takes the `daemon.json` part out. Reading the
>   daemon's start flags, merging log rotation and build-cache limits into
>   `/etc/docker/daemon.json`, `dockerd --validate`, the write, the backups
>   and `RESTART PENDING` are now
>   [`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/)
>   version 1: the same code, moved, with its tests and its part of this
>   README. What changes here:
>   - **Four input variables are gone:** `usrLogMaxSize`, `usrLogMaxFile`,
>     `usrBuildCacheMax` and `usrBuildCacheReserved`. A Datto job that still
>     passes them runs as before; they are ignored, whatever their value
>     (version 14 refused a bad one with exit `2`). **A job that relied on
>     this component for those limits must add the new component**, with the
>     same four values.
>   - **This component no longer reads or writes `daemon.json`**, and no
>     longer needs `python3`. Its output has no `daemon.json:` lines, no
>     `RESTART PENDING` and no `DAEMON WILL NOT START`; a post-condition on
>     either string belongs on the new component now.
>   - **Exit `3` has fewer causes.** The ones that came from `daemon.json`
>     (Docker's start flags unknown, a `daemon.json` that is not valid JSON,
>     a failed `dockerd --validate`, and the rest) are the new component's.
>     So **a run against a stopped Docker is no longer always exit `3`**: it
>     is exit `0` when the list is there already and `usrPruneNow` is `No`.
>   - **Nothing on a host changes.** A `daemon.json` that version 14 or
>     earlier wrote stays as it is, with its backups; the list, the prune's
>     settings, the units and the timer are written exactly as version 14
>     wrote them. The prune script is version 14's with one line different,
>     the stamp: `TC_PRUNE_VERSION=15`, so running version 15 on a host
>     rewrites that file and reloads systemd, and does not restart the timer.
>     The monitor's `PRUNE_MIN_VERSION` stays **11**.
>
>   The Tier 1 test was split with the code. Its steps for the list, the
>   prune and the images were run against a live Docker 29 daemon in a
>   sandbox **without systemd**, with the timer and unit steps left out: each
>   gave the result it gave for version 14 there, and the new steps pass (a
>   run that still passes the four variables; `daemon.json` byte-for-byte
>   untouched after every run). The stopped-Docker and no-`docker.service`
>   steps in which the component itself runs, the two whose exit code changed
>   among them, ran there against a stand-in for `systemctl` and for
>   `docker.socket`. The steps that need a real systemd (the timer, starting
>   the prune's unit) have **not** been run for this version: the Tier 1 test
>   runs them on the CI runner, so read that result before merging. It has
>   not yet run through a Datto agent.
> - **Version 16** (2026-11-18) removes `All` mode. The prune removes
>   **untagged images only**, by the rule `Dangling` had: no container uses
>   the image, it was built more than `usrPruneOlderThanHours` ago, it is not
>   labelled `tc.keep`, it is removed without `--force`, and only once the
>   list is reviewed. **A tagged image is never removed.** What goes:
>   - **The input variable `usrPruneImages`.** A Datto job that still passes
>     it runs as before; it is ignored, whatever its value (version 15
>     refused anything but `Dangling` or `All` with exit `2`).
>   - **The `PRUNE_IMAGES` setting.** The component no longer writes it to
>     `/etc/default/tc-docker-prune`, and removes the line the next time it
>     runs on a host. A file that still has it (a hand edit, or a host where
>     the settings file could not be rewritten) is not an error: the prune
>     says once
>     `PRUNE_IMAGES in /etc/default/tc-docker-prune is no longer used (it is 'all'): ...`,
>     runs nothing from it, keeps every tagged image and goes on. Up to
>     version 15 a value other than `dangling` or `all` there was an `ERROR:`
>     and exit 1, with no image removed.
>   - **Every registry lookup, and with them the prune's only network
>     calls:** `docker buildx imagetools inspect` and
>     `docker manifest inspect`, the use of root's `docker login` and of the
>     Docker daemon's proxy, the lookup limits, and the two test-only
>     environment variables that lowered them (`TC_PRUNE_TEST_LOOKUP_MAX`,
>     `TC_PRUNE_TEST_LOOKUP_SECONDS`).
>
>   Two output lines change: `Images removed (PRUNE_IMAGES=dangling): N` is
>   now `Untagged images removed: N`, and the count of tagged images kept
>   ends `(the prune never removes a tagged image).` instead of naming the
>   mode. On a host that ran `Dangling`, which is the default, nothing else
>   changes. **On a host that ran `All`** (CI and GitLab runner hosts were why
>   it existed), the first version 16 run keeps every tagged image.
>   `TC_PRUNE_VERSION=16`. Running version 16 rewrites the prune script and
>   its settings file and reloads systemd; it does not restart the timer.
>   The monitor's `PRUNE_MIN_VERSION` stays **11**: a version 15 prune is not
>   unsafe, it only removes more.
>
>   The Tier 1 test lost its registry steps (17 of 123) and its test
>   registry with them; untagged-image removal is still tested on both image
>   stores, and a stand-in `docker` that records the prune's commands shows
>   it runs none that could reach a registry. The test was run against a live
>   Docker 29 daemon in a sandbox **without systemd**, with the timer and
>   unit steps left out, on both image stores (containerd first, then
>   classic): every step passed, as version 15's spec did there. The
>   stopped-Docker and no-`docker.service` steps in which the component
>   itself runs passed against a stand-in for `systemctl` and for
>   `docker.socket`. The new and changed steps were run against version 15's
>   script, where they fail, and against four broken copies of version 16's
>   (one removes tagged images, one does not name a `PRUNE_IMAGES` line, one
>   treats that line as an error, one whose component still writes it):
>   each was caught. The steps that need a real systemd (the timer, starting
>   the prune's unit) have **not** been run for this version: the Tier 1
>   test runs them on the CI runner, so read that result before merging. It
>   has not yet run on bash 4.2 or through a Datto agent.

## What it does

It **changes the endpoint**. One run does up to three things. It does not
read or write `/etc/docker/daemon.json`: see
[`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/)
for log rotation and build-cache limits.

### 1. Creates the expected-containers list, once

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

A container whose Compose labels are set but are not plain names (letters,
digits, `_`, `.`, `-`) has no key and is left off the list. The output names
it by container name and short id, never by the label. Labels are read
JSON-encoded, so a tab or newline in one cannot add a field or a container.

If `docker info` answers but `docker ps` or `docker inspect` fails three
times, the list is **not** created (exit `3`), and the next run tries again.
An empty list written then would later read as "this host runs nothing".
If Docker is stopped, the list is not created either (exit `3`), and Docker is
left stopped: the output says
`Expected list: Docker is not running (docker.service is inactive), so the list was not created and Docker was left stopped; the next run will try again.`

A host that ran version 2 with `usrRequiredContainers` set has those names
carried onto the new list.

### 2. Installs the weekly prune

| File | What it is |
|---|---|
| `/usr/local/sbin/tc-docker-prune` | The prune script |
| `/etc/default/tc-docker-prune` | Its settings: `OLDER_THAN_HOURS`, `GRACE_HOURS`. Read as text, never run; see *The settings file* below |
| `/var/lib/tc-docker/pending-removal` | Written by the prune: the stopped containers it has recorded and will remove. Directory `0700`, file `0600`, both root. The Docker monitors keep their state files in the same directory |
| `/etc/systemd/system/tc-docker-prune.service` | Runs the script, only while Docker is running (`Requisite=docker.service`) |
| `/etc/systemd/system/tc-docker-prune.timer` | Runs the service on `usrPruneSchedule` |

The timer is `Persistent`, so a run missed while the host was off happens at
the next boot. It also has up to 30 minutes of random delay, fixed per host
(`FixedRandomDelay=true`, systemd 247 and later; older systemd ignores the
line and draws a new delay each time it reloads), so a `daemon-reload` does
not move the next run.

The service as written on a host with a `docker.service` unit:

    [Unit]
    Description=Prune unused Docker images, stopped containers, networks and build cache (TechCollective)
    Documentation=https://github.com/TechCollective/DattoRMM_Components/tree/main/Scripts/docker-configure-host-maintenance-lin
    Requisite=docker.service
    After=docker.service

    [Service]
    Type=oneshot
    Nice=10
    IOSchedulingClass=idle
    ExecStart=/usr/local/sbin/tc-docker-prune

On a systemd host with **no `docker.service` unit** (Docker started some other
way), `Requisite=` could never be met and the prune would never run, so the
two dependency lines are left out, the output says
`Prune timer: this host has no docker.service unit, so tc-docker-prune.service is written without a dependency on it; the prune checks for itself whether Docker is running.`,
and the prune checks Docker itself when it runs. A later run on a host that
has the unit again writes them back. A host with only `/etc/init.d/docker`
still has a `docker.service`: systemd generates one from that script, so the
dependency lines are written there.

**When the timer is restarted.** A change to the prune script, its settings
or the service needs only `systemctl daemon-reload`; the next run uses it, and
the output says `Prune timer: updated the prune service, script or settings
(...). The timer was not restarted.` The timer is restarted only when the
timer unit itself changed (a new `usrPruneSchedule`, or an upgrade that
changes the unit, such as version 11 adding `FixedRandomDelay`), because
restarting a `Persistent` timer can run a missed prune at once. A timer that
is not enabled is enabled, and one that is not running is started.

#### It never starts Docker

A Docker host is sometimes stopped on purpose: a maintenance window, a move
of `/var/lib/docker`, a disk being replaced. Starting it again brings back
every `restart: always` container with it. So neither the component nor the
prune starts a stopped Docker:

- **The service** has `Requisite=docker.service` with `After=`, not
  `Requires=`. When the timer fires and Docker is not running, systemd does
  not start the service and does not start Docker; the timer stays active
  for its next run. **That week's prune is skipped, not postponed**: the
  next one is at the following scheduled time.
- **Before any `docker` command**, the component and the prune ask whether
  Docker is running without waking it. Where systemd manages
  `docker.service`, they ask systemd (`systemctl is-active docker.service`)
  and run no `docker` command unless it is active: on a package install
  `docker.socket` keeps listening while the service is stopped, and any
  `docker` command would start it. Elsewhere they ask `docker info`, as
  before. The code is one function, marked `tc-docker running`, in this
  component, in the prune it installs and in the other five Docker
  components; CI's shared-block check keeps the seven copies identical.
- **The prune, run by hand or by Prune now, with Docker stopped** prints
  `Docker is not running (docker.service is inactive): nothing was pruned, and Docker was left stopped.`
  after its version line, removes nothing and exits `0`. A Docker that
  systemd reports running but that does not answer `docker info`, or one that
  does not answer on a host where systemd does not manage it, is still an
  `ERROR:` and exit `1`.
- **The component with Docker stopped** installs the prune and the timer,
  and leaves Docker stopped. It does not create the list and does not run
  Prune now: those need Docker, and each makes the run exit `3`; run it
  again once Docker is up. A run that needs neither (the list is there
  already, and `usrPruneNow` is `No`) exits `0`. Up to version 14 every run
  against a stopped Docker was exit `3`, because of the `daemon.json` part.

**The prune is only replaced when this component runs on the host again.**
Nothing else updates it, so a host keeps whichever prune it last received. To
make that visible, the script carries a line `TC_PRUNE_VERSION=<n>` near the
top, where `<n>` is this component's version, and prints
`tc-docker-prune version <n>` as the first line of every run, so the journal
(`journalctl -u tc-docker-prune.service`) shows which prune ran. The Tier 1
test fails when the stamp and `component.json`'s `version` differ, so a
version bump cannot ship without it.

**Raising `PRUNE_MIN_VERSION` in the monitor is how a future safety fix to the
prune gets flagged fleet-wide.** The monitor's constant is the oldest prune it
accepts. When a fix to the prune ships, bump this component's version, raise
`PRUNE_MIN_VERSION` in
[`Docker - Containers Differ From Expected [Lin]`](../../Monitors/docker-containers-differ-from-expected-lin/)
to that version, and every host still on an older prune alerts on its next
check, with the fix named: run this component on it. The constant is **11**
from the monitor's version 8.

What earlier versions left on a host, which the monitor flags:

| Version | What it left | Why it is unsafe |
|---|---|---|
| 1 | No script. The service's `ExecStart` runs `docker system prune --all --force` directly | No list, no review |
| 2 | The script, running `docker system prune --all` behind a `REQUIRED_CONTAINERS` check | No expected-containers list |
| 3 | Per-container protection | No review gate |
| 4, 5 | Review gate | A container label can still make it delete a protected container |
| 6 | The current rules, without a stamp | The monitor cannot tell it from an older one |
| 7, 8 | Removes a stopped container at the first prune after it is old enough, counting from when it was **created**; removes every image no container uses | A container that crashed minutes ago is removed without warning, with its logs; an image built or loaded on the host, which exists nowhere else, is removed |
| 9, 10 | `Requires=docker.service`, and a `docker info` before it checks anything. (9 also keeps every tagged image on the containerd image store in `All` mode, which is not unsafe) | The weekly timer starts a Docker that was stopped on purpose, and every `restart: always` container with it. Flagged from the monitor's version 8 (`PRUNE_MIN_VERSION` 11) |
| 11 | Runs its settings file as shell, and does not check `OLDER_THAN_HOURS` | Only after a hand edit of `/etc/default/tc-docker-prune`: a line there is a command run as root, and `OLDER_THAN_HOURS=0` removes things of any age. **Not flagged** by the monitor (`PRUNE_MIN_VERSION` is 11); run the current version on the host to replace it |
| 12, 13 | The current rules, except that a `/var/lib/tc-docker` owned by another user is made root's and the record in it believed. Version 13's prune differs from 12's only in where its code for reading `pending-removal` lives | Only on a host where that directory is not root's, which nothing in these components causes: a record another user wrote there can get an unprotected stopped container removed without its wait. **Not flagged** by the monitor (`PRUNE_MIN_VERSION` is 11); run the current version on the host to replace it |
| 14, 15 | The current rules, plus `All` mode: with `PRUNE_IMAGES=all` in its settings file it also removes tagged images whose registry confirms it has them. Version 15's prune differs from 14's only in its stamp | Nothing unsafe. On a host whose settings say `all`, tagged images go on being removed until version 16 runs there |
| 16 | Current | |

**Before the list is reviewed:** the prune removes only unused networks and
build cache older than `usrPruneOlderThanHours`. No container and no image.
It records nothing, and clears any `pending-removal` file left from an earlier
review, so a later review starts every wait again.

**After review**, for each **stopped container**, in this order:

1. **Protected: kept**, with its image, and named with the reason: it is on
   the expected-containers list, has restart policy `always` or
   `unless-stopped`, is labelled `tc.keep`, or has Compose labels that are not
   plain names (named whatever its state, on every run).
2. **Its age**: from when it stopped (`State.FinishedAt`); a container that
   never started counts from when it was created. Read for these candidates
   only. An age that cannot be read means **kept**, and not recorded.
3. **Not stopped for `usrPruneOlderThanHours` yet: kept**, not recorded.
4. **Not in `pending-removal`** (or in it under another key or name):
   **recorded** with the time now, and **kept**. The output lists it under
   `Stopped containers recorded for removal this run`, with the time from
   which it can be removed.
5. **In `pending-removal` for less than `usrPruneGraceHours`: kept**, listed
   under `Stopped containers waiting to be removed`, with when it was
   recorded and when it can go.
6. **In it for `usrPruneGraceHours` or more: removed** (`docker rm`, no
   force), and its line dropped. Listed under `Stopped containers removed`.

Every line of `pending-removal` whose container is gone, running again, now
protected, or no longer old enough (it ran and stopped again) is dropped, so
its wait starts again if it comes back. The file is written before anything is
removed, as a new file renamed over the old one. **If it cannot be written**,
the prune removes **no container** that run, says why, and exits 1; images,
networks and build cache are still handled. There is no fallback location.

How it is written, and when it is not (the same rules for every file the
Docker components keep in that directory):

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

The error line names the reason and, in brackets, the failing command's own
message when it gave one:

| Reason | When |
|---|---|
| `/var/lib/tc-docker is not a directory` | It is a symlink, or a file |
| `/var/lib/tc-docker/pending-removal is not a regular file` | A symlink, a directory or anything else is in the record's place |
| `/var/lib/tc-docker cannot be created (mkdir: ...)` | |
| `/var/lib/tc-docker is not owned by root` | New in version 14; see the version note at the top |
| `/var/lib/tc-docker cannot be made root-only (chown: ...)` | Its group or mode is wrong and cannot be changed (a read-only filesystem) |
| `no file can be created in /var/lib/tc-docker (mktemp: ...)` | A read-only filesystem, an immutable directory |
| `writing it failed (...: No space left on device)` | A full disk; also when the file does not read back as written |
| `the new file could not be renamed into place (mv: ...)` | An immutable file |

Up to version 13 the same cases read `mkdir: ...` alone, `... cannot be made
root-only (0700): chown: ...`, `mktemp: ...` alone, and `writing it failed (is
the disk full?)`. On a read-only filesystem version 13 stopped at `chown`;
version 14 leaves a directory that is already `root:root 0700` alone, so it
stops at `mktemp`.

With the weekly timer and the defaults (168 hours, then 144), a container is
recorded at the first Sunday prune after it has been stopped a week, and
removed at the next one. The monitor
[`Docker - Containers Differ From Expected [Lin]`](../../Monitors/docker-containers-differ-from-expected-lin/)
alerts on each waiting container, with the date it goes, and says how to keep
it (Add it to the list).

#### The settings file

`/etc/default/tc-docker-prune` is written by this component:

    # Written by the Datto RMM component "Docker - Configure Host Maintenance [Lin]".
    # Re-run the component to change these; edits here are overwritten.
    OLDER_THAN_HOURS=168
    GRACE_HOURS=144

Up to version 15 it had a third line, `PRUNE_IMAGES=dangling` or
`PRUNE_IMAGES=all`; the component removes it the next time it runs.

**The prune reads it as text. Nothing in it is ever run.** (Up to version 11
the prune sourced it as shell, as root.) The rules:

- A setting is one line, `NAME=value`, for one of those two names. Spaces
  before the name and after the value are dropped.
- If a name appears more than once, the **last** line wins.
- **Every other line is ignored:** comments, blank lines, any other name
  (`REQUIRED_CONTAINERS` from version 2, say), and anything a shell would
  treat as a command. A misspelled name is one of those, so it is ignored
  and the default applies.
- A name with no line gets its default: 168, 144. A file that is missing,
  or is not a regular file root can read, means both defaults.
- **A `PRUNE_IMAGES` line** (the image mode up to version 15) is not used,
  whatever its value, and is not an error. The prune says so once, after its
  version line (unless Docker is stopped: then it prints only that it is):
  `PRUNE_IMAGES in /etc/default/tc-docker-prune is no longer used (it is 'all'): the prune removes untagged images only, and keeps every tagged image.`
  (the value is shown made printable and cut to 20 characters), and goes on.
  Nothing in the line is run.
- **It is not a shell file.** A value in quotes (`GRACE_HOURS="144"`), with a
  comment after it, or with `export` in front is not understood: the first
  two are refused as below, the third is ignored.

**Every value is checked by the prune itself**, whatever wrote it, and a value
it refuses is never used:

| Setting | Must be | If not |
|---|---|---|
| `OLDER_THAN_HOURS` | A whole number, 24–8760 | **Nothing at all** is recorded or removed (every removal goes by age): one `ERROR:` line, exit 1 |
| `GRACE_HOURS` | A whole number, 24–8760 | No container is recorded or removed; images, networks and build cache are still handled; `ERROR:`, exit 1 |

The error names the setting and shows what it found, for example
`ERROR: OLDER_THAN_HOURS in /etc/default/tc-docker-prune must be a whole number of hours, 24-8760 (it is '0'). Every removal depends on it, so nothing is recorded or removed this run. A setting is one line, NAME=value, with no quotes and nothing after the value.`

#### Images

After review, for each image, in this order:

1. **Its tags or digests are not plain references: kept**, and named by short
   id. (They are read JSON-encoded, the same careful way as container labels,
   so nothing in an image can add an image or a field to the list.)
2. **Labelled `tc.keep`: kept.**
3. **Used by any container**, running or stopped: kept. (So a protected
   container's image is kept too.)
4. **Built less than `usrPruneOlderThanHours` ago**, or its creation time
   cannot be read: kept. ("Older than" is the image's build time, not when it
   was pulled or last used.)
5. **Untagged: removed**, by its id (or by the `repo@sha256` names it still
   has), never `--force`, so Docker's own check refuses an image something
   uses. If it has a registry digest, that is printed, so it can be pulled
   again by digest.
6. **Tagged: kept.** The output counts them:
   `Images kept: 2 tagged image(s) that no container uses (the prune never removes a tagged image).`

Up to version 15, `usrPruneImages` = `All` also removed a tagged image whose
registry confirmed, at that moment, that it still had it. That mode and its
registry lookups are gone from version 16 (see the version note at the top),
and with them every network call the prune made.

**If Docker does not return its image list, or the list of which images
containers use**, no image is removed and the run exits 1.

**Unused networks and build cache** older than `usrPruneOlderThanHours` are
removed whether or not the list is reviewed.

**Volumes are never removed.**

**If Docker does not return its container list** (`docker ps` or
`docker inspect` fails three times), the prune prints `ERROR:`, removes
nothing at all that run (no container, image, network or build cache), and
exits 1.

The prune always runs. A stopped container is protected rather than blocking
the prune, so one container stopped on purpose can't stop the disk from being
cleaned.

### 3. Optionally prunes once, now

With `usrPruneNow`, it runs the same script immediately and reports free disk
space before and after. If Docker is not running, it does not run the prune,
leaves Docker stopped, says
`Prune now: Docker is not running (docker.service is inactive); not run, and Docker was left stopped.`,
and the run exits `3`. A daemon that does not answer is the same, with
`Prune now: the Docker daemon is not reachable; not run.`

### What it never does

**It never starts or restarts Docker.** See *It never starts Docker* above
for a stopped one. Nothing it does needs a restart.

**It never reads or writes `daemon.json`** (from version 15). That is
[`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/).

If Docker is not installed, it exits 0 and changes nothing. That makes it safe
to target at every Linux device.

**It never removes a tagged image** (from version 16), and never a volume.

It makes no network calls of its own, and neither does the prune. (Up to
version 15 the prune asked registries about tagged images when
`usrPruneImages` was `All`.)

## Why

Two TechCollective Docker hosts filled their disks in 2026:

- **A GitLab server.** Build-cache limits in `daemon.json` (the same values used
  here by default) kept build cache in check. They did not stop roughly 150 GB
  of unused images from piling up, because build-cache cleanup never touches
  images.
- **An internal Docker host.** Its root filesystem reached 99%.

Two fixes came out of that: limits that stop growth, and a scheduled prune
that removes what the limits don't cover. Up to version 14 this component
did both. From version 15 it is the prune, and the limits are
[`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/);
a host like those two wants both. The prune removes untagged images only
(from version 16 there is no other mode), so on a host like the GitLab
server, whose disk filled with unused tagged images, those still have to be
removed some other way.

## Related components

| Component | Role |
|---|---|
| [`Docker - Update Expected Containers [Lin]`](../docker-update-expected-containers-lin/) | The only thing that changes the expected list or the ignore patterns |
| [`Docker - Containers Differ From Expected [Lin]`](../../Monitors/docker-containers-differ-from-expected-lin/) | Monitor. Alerts when an expected container is stopped or gone, or a stopped container is waiting to be removed by the prune; reports unlisted ones |
| [`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/) | Log rotation and build-cache limits in Docker's `daemon.json`. Part of this component up to version 14; shares none of its files |
| [`Docker - Container Health and Resource Usage [Lin]`](../../Monitors/docker-container-health-and-resource-usage-lin/) | Monitor. Unhealthy, restarting and resource-hungry containers. Keeps its state file in `/var/lib/tc-docker`, beside the prune's record |
| [`Docker Images monitor [Lin]`](../../Monitors/docker-images-monitor-lin/) | Monitor. Running containers whose image has a newer version in its registry. Keeps its cache in `/var/lib/tc-docker` too |

The first two and this component share one block of code that turns a container into its key and,
from version 13, reads the prune's `pending-removal` file. It is marked
`tc-docker shared`, and there are four copies: this component, the prune
script it installs, and the other two. All four must stay byte-identical;
CI's "Shared blocks match" check fails the pull request when they are not.
The "is Docker running" check is a second shared block, `tc-docker running`,
with seven copies: these four, the Health and Images monitors, and (from
version 15) Docker - Configure Daemon Limits [Lin]. From version
14 the prune carries a third, `tc-docker state` (how a file in
`/var/lib/tc-docker` is written), with four copies: the prune and the three
Docker monitors.

## Installing it in Datto

**Updating an existing copy:** open it in Datto, paste the script over the
body, and make the variables and description match the tables below. For
version 16 that means deleting `usrPruneImages`. Coming from version 14 or
earlier, version 15's changes are needed too: deleting four variables
(`usrLogMaxSize`, `usrLogMaxFile`, `usrBuildCacheMax`,
`usrBuildCacheReserved`), changing the description, and removing a
post-condition on `RESTART PENDING` or `DAEMON WILL NOT START` if one was
set. A re-import creates a second
component; see the repo's `tools/README.md`.

**New install:** Automation → Components → New Component, or import the
`.cpt` from the latest release.

| Field | Value |
|---|---|
| Name | `Docker - Configure Host Maintenance [Lin]` |
| Description | Seeds the expected-containers list and installs a weekly prune that deletes nothing until the list is reviewed, then waits before removing a stopped container. |
| Category | **Scripts** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | Not standardised yet; decide at save time (`component.json` carries 5) |
| Timeout | 900 seconds. A first prune on a full host can take minutes. |
| Attachments | none |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | **Selection** | `Apply` | `Apply` / `Report`. Report prints what it would change, including the list it would create, and changes nothing. Use it first on any host you have not looked at. |
| `usrPruneSchedule` | String | `Sun *-*-* 04:00:00` | A systemd `OnCalendar` expression in the host's local time, checked with `systemd-analyze calendar`. Blank leaves the timer alone. |
| `usrPruneOlderThanHours` | String | `168` | 24–8760. Only unused items older than this are pruned; a stopped container counts from when it stopped. Saved to `/etc/default/tc-docker-prune` as `OLDER_THAN_HOURS`, so the most recent run sets it for the timer. The prune checks it again and removes nothing if it is out of range. |
| `usrPruneGraceHours` | String | `144` | 24–8760. How long a stopped container waits in `pending-removal` before the prune may remove it. 144 (6 days) means a weekly timer removes it at the run after the one that recorded it. Saved as `GRACE_HOURS`. |
| `usrPruneNow` | **Selection** | `No` | `Yes` also runs the prune once, now. |

No customer-specific value is hardcoded. Different hosts get different values
through the job's variables, not through edits to the script. The
per-host list lives on the host, not in a variable, so one fleet-wide job can
target every host.

An invalid value makes the component refuse to run with exit `2`. It checks
every input before it changes anything.

**Removed in version 16:** `usrPruneImages`. The prune removes untagged
images only. **If a Datto job still passes it, it is ignored:** the script
does not read it, so there is no error and no message, whatever its value,
even one version 15 refused with exit `2`, and it changes nothing the prune
removes. Delete it from the component in Datto (see *Installing it in
Datto*).

**Removed in version 15:** `usrLogMaxSize`, `usrLogMaxFile`,
`usrBuildCacheMax` and `usrBuildCacheReserved`. They belong to
[`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/)
now. **If a Datto job still passes them, they are simply ignored:** the
script does not read them, so there is no error and no message, even for a
value version 14 refused. The job still runs; it just no longer sets those
limits. Add the new component to the job to keep setting them.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done, or nothing needed doing. Also returned when Docker is not installed. |
| `1` | Unexpected failure, such as a write, `systemctl` call or prune step failing. |
| `2` | An input variable is invalid. Nothing was changed. |
| `3` | One part could not be applied safely, and was not changed. Other parts may still have run, and the output says which. See the list below. |

What causes exit `3`:

- the host is not running systemd
- Docker is the snap package
- Docker was stopped, the daemon was unreachable, or it answered but did not
  return its container list, so the list could not be created; the next run
  retries
- `usrPruneNow` = `Yes` and Docker was stopped or unreachable, so the prune
  did not run

Up to version 14 the list was longer: everything that could go wrong with
`daemon.json` was exit `3` here. Those causes are
[`Docker - Configure Daemon Limits [Lin]`](../docker-configure-daemon-limits-lin/)'s
now.

The prune script on the host exits `0` when it pruned, and also when
systemd reports Docker stopped (it prunes nothing then, and says so). It
exits `1` on an error: the daemon unreachable, its container list not coming back (nothing is
removed then), `pending-removal` not writable (no container removed), its
image list not coming back (no image removed), an `OLDER_THAN_HOURS` or
`GRACE_HOURS` it refuses (see *The settings file*), a container or image
Docker would not remove, or a network or build-cache step failing. A
`PRUNE_IMAGES` line in the settings file is not an error.

## How to tell it worked

A first apply on a host that had none of this looks like:

    Docker: /usr/bin/docker, engine 28.x. Mode: apply.
    Expected list: created /etc/tc-docker/expected-containers with 3 entries:
      compose:shop/web
      compose:shop/db
      name:gitlab-runner
    Prune timer: installed tc-docker-prune.timer (...)
    Prune timer: next run ...
    Docker host maintenance: done.

A second run says `Expected list: ... exists ... not changed` and
`already installed with these settings`.

A prune with Docker stopped (by hand; the timer does not start it then):

    tc-docker-prune version 16
    Docker is not running (docker.service is inactive): nothing was pruned, and Docker was left stopped.

A prune after review reports what it recorded, what is waiting, what it
removed and what it kept:

    tc-docker-prune version 16
    Pruning unused items older than 168h. Volumes are never removed.
    Disk before: 30G free, 29% used
    Stopped containers recorded for removal this run (removed 144h from now if still stopped and not protected):
      old-report (name:old-report), can be removed from 2026-11-28 04:12 CST
    Stopped containers waiting to be removed:
      scratch (name:scratch), recorded 2026-11-15 04:09 CST, can be removed from 2026-11-21 04:09 CST
    Stopped containers removed: 1
      tmp-build (name:tmp-build)
    Stopped containers kept, with their images:
      shop-db-1 (on the expected list)
      legacy (restart policy unless-stopped)
    Untagged images removed: 1
      untagged 3c9d2e7a41f0
    Images kept: 2 tagged image(s) that no container uses (the prune never removes a tagged image).
    Networks: nothing to remove
    Build cache: 0B reclaimed
    Disk after:  30G free, 29% used

On the host itself:

    cat /etc/tc-docker/expected-containers
    cat /var/lib/tc-docker/pending-removal   # what the prune will remove, and since when (seconds since 1970)
    systemctl list-timers tc-docker-prune.timer
    journalctl -u tc-docker-prune.service    # what each prune removed and kept; its first line is "tc-docker-prune version <n>"
    sudo /usr/local/sbin/tc-docker-prune     # run the prune by hand

## Test order

Never a customer first.

1. CI's "Component tests" check on the pull request (`test.json`, Tier 1).
2. One internal Docker host. Run with `usrMode` = `Report` first, read the
   list it would create, then run `Apply`.
3. On that host, run Update Expected Containers with Show, correct the list,
   then run Confirm reviewed. Check the next prune's journal.
4. One site, one device in it, with the job scoped to that device. Run Report,
   then Apply, then review the list.
5. Wider, only after the first four.

## Known limits

- **A host's prune is only as new as the last run of this component on it.**
  Until it runs again, the older prune's rules apply, including the unsafe
  ones in the table under *Installs the weekly prune*. The monitor flags such
  a host; it does not fix it.
- **The version stamp is what this component wrote, not a checksum.** A prune
  edited by hand on the host, with the stamp left on, still reads as current.
  Edits there are overwritten at the next run, and the script says so.
- **A stopped container takes longer to go:** at least
  `usrPruneOlderThanHours` after it stopped plus `usrPruneGraceHours`, and in
  practice until the next timer run after that (two weeks with the defaults).
  On a host whose disk fills fast, lower both, or remove the container by
  hand.
- **The wait is measured on the host's clock.** Setting the clock forward
  shortens it. A record is tied to the container's id, key and name: a
  container that is renamed, recreated or restarted and stopped again starts
  its wait again.
- **`pending-removal` is trusted as the prune wrote it.** It is root-only;
  a line that is not well formed is dropped, but a well-formed line edited by
  hand to an older time shortens that container's wait.
- **An untagged image is removed**, including one pulled by digest only.
  Those can be pulled again by their digest, which is printed.
- **A tagged image is never removed** (from version 16). On a host whose
  disk fills with pulled images, such as a CI or GitLab runner host, unused
  tagged images pile up: remove them by hand or with a cleanup made for that
  host. Disk space monitoring is the backstop.
- **An unreviewed host gets no image cleanup.** That is deliberate. Its disk
  relief waits for the review, so review a new host's list in its first
  week. The monitor reports every unreviewed host.
- **A list includes whatever existed at creation, junk included.** That's
  safe, because a listed container is kept, but stale stopped containers stay
  until someone removes them from the list during the review.
- **Upgrading a version 3 host** leaves its list in place, but marks it
  unreviewed, because no `reviewed` file exists yet. Its container and image
  removal stops until someone runs Confirm reviewed.
- **A container with unreadable Compose labels is kept for good,** with its
  image, and named on every prune. Fix its labels (or the image they come
  from), or remove it by hand.
- **Docker older than 1.13** has no `AutoRemove` field, so its container list
  cannot be read: the list is not created (exit `3`) and the prune removes
  nothing and exits 1. Checked against a Docker 1.10 engine.
- **systemd only** for the timer. On a host without systemd, the timer part
  exits `3`, and the other parts still run.
- **The settings file is not shell.** Only `NAME=value` lines for the two
  settings are read. A misspelled name, or `export NAME=value`, is ignored
  without a message, and that setting keeps its default; a value in quotes or
  with a comment after it is refused, and the prune exits 1 until it is
  fixed. Re-run this component to rewrite the file rather than editing it.
- **Snap-packaged Docker is refused** (exit `3`). Snap manages its daemon,
  under a service name of its own.
- **Rootless Docker** (a per-user daemon) and **Podman** are not handled.
- **A prune skipped because Docker was stopped is not made up.** The timer
  fired, so `Persistent` has nothing to catch up; the next prune is at the
  next scheduled time. The journal shows the skipped start
  (`journalctl -u tc-docker-prune.service`).
- **"Running" means `docker.service` is active, where systemd has that
  unit.** A `dockerd` started by hand on such a host while `docker.service`
  is inactive is treated as stopped: nothing is pruned and the list is not
  created. On a host where systemd does not manage `docker.service`, a
  stopped Docker cannot be told from a broken one: the prune says `ERROR:`
  and exits `1`, as before.
- **The check is made once, before the first `docker` command.** If Docker is
  stopped while a prune or this component is running, a later `docker`
  command in that run can start it again through `docker.socket`.
- **The monitors still wake a stopped Docker.** Their own `docker info`
  calls are unchanged in this version, so a monitor run on a host whose
  `docker.socket` is listening starts Docker. Pause the Docker monitors on a
  host while its Docker is stopped on purpose.
- **Upgrading from version 10 restarts the timer once**, because version 11
  adds `FixedRandomDelay=true` to it. If the host missed its last scheduled
  prune (it was off at the time), `Persistent` can run that prune at once.
- **No alert when the timer itself fails.** The prune's result is in the
  journal and `systemctl --failed`. Disk space monitoring is the backstop.
- **Removing it** is manual: `systemctl disable --now tc-docker-prune.timer`,
  then delete the two unit files, `/usr/local/sbin/tc-docker-prune`,
  `/etc/default/tc-docker-prune`, `/etc/tc-docker/` and `/var/lib/tc-docker/`
  (which also holds the Docker monitors' state files; they write them again
  on their next run), and run `systemctl daemon-reload`.

## Open questions

- **Tagged images on CI and GitLab runner hosts.** From version 16 nothing
  in these components removes them (`All` did, up to version 15). Whether
  such a host needs a component of its own for that is not decided.

- **Level** is not standardised. `component.json` carries 5, because this
  component installs a script that removes containers and images as root.
