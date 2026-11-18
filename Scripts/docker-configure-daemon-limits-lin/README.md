# Docker - Configure Daemon Limits [Lin]

A Datto RMM script component for Linux Docker hosts. It adds log rotation and
build-cache limits to the Docker daemon's configuration,
`/etc/docker/daemon.json`, so that container logs and build cache stop growing
without limit. It adds only the keys that are missing, and never changes a
value that is already set.

> **Status: Not Validated.** Version 1, 2026-11-18.
>
> This is the `daemon.json` part of
> [`Docker - Configure Host Maintenance [Lin]`](../docker-configure-host-maintenance-lin/)
> version 14, moved into a component of its own. Host Maintenance version 15
> no longer has it. **The code is moved, not rewritten:** reading the daemon's
> start flags, the merge, the conflict check, `dockerd --validate`, the write
> (mode, owner and symlink kept), the sweep of leftover staging files, the
> backups and `RESTART PENDING` are the same functions, line for line. Every
> message and exit code is the same, with one exception: the last line of a
> clean run is `Docker daemon limits: done.` where Host Maintenance printed
> `Docker host maintenance: done.`
>
> **A host that Host Maintenance already configured needs nothing.** Its
> `daemon.json` has the keys, so a run of this component says `KEPT` for each
> and changes nothing. Nothing on the host has to be moved or renamed: the
> file, its backups (`daemon.json.tc-bak-*`) and their names are the same.
>
> **A Datto job that ran Host Maintenance to set these limits needs this
> component added to it**, with the job's values for `usrLogMaxSize`,
> `usrLogMaxFile`, `usrBuildCacheMax` and `usrBuildCacheReserved`. Host
> Maintenance version 15 ignores those four variables.
>
> What has run: the Tier 1 test (`test.json`: the daemon.json steps of Host
> Maintenance's test, moved here with the code, and 13 written for this
> component), against a live Docker 29 daemon in a sandbox **without
> systemd**. There Docker is restarted by hand where the test restarts
> `docker.service`, and the stopped-Docker steps ran against a stand-in for
> `systemctl` and for `docker.socket`. Every step that came from Host
> Maintenance gave the result it gave for Host Maintenance version 14 in the
> same sandbox. One step fails there for both: it starts a container under
> `--log-driver=journald`, and the sandbox has no journald. Nothing has run
> on a host with systemd, or under bash 4.2, for this version: the Tier 1
> test runs it on the CI runner, so read that result before merging. It has
> not run through a Datto agent. The history of this code, including the
> defects it has had, is in Host Maintenance's README (versions 4, 5, 8 and
> 12).

## What it does

It **changes the endpoint**: one file, `/etc/docker/daemon.json`, with a
backup of the old file beside it. In `Report` mode it changes nothing. It
makes no network call.

### 1. Reads how the daemon is really started

`daemon.json` is not the whole of Docker's configuration. The daemon can also
be given `--log-driver`, `--log-opt` and `--config-file` on its command line,
by the systemd unit, a drop-in, or an environment file such as
`/etc/default/docker`. A `daemon.json` that clashes with those flags stops
Docker at its next start. So **first it reads how the daemon is really
started:**

- **Docker running:** the running `dockerd`'s own command line
  (`/proc/<pid>/cmdline`), and the log driver the daemon reports
  (`docker info`).
- **Docker not running:** the flags are not read. The output says
  `daemon.json: could not tell which flags Docker starts with: Docker is not running, so its start flags cannot be read.`
  Log rotation is skipped, `builder.gc` is still added (the log flags do not
  affect it), and the run exits `3`. **Run the component again once Docker
  is running** and it adds log rotation then. It does not try to work the
  flags out from `docker.service`, its drop-ins and its environment files:
  only systemd knows exactly what those add up to, and a wrong guess here
  writes a `daemon.json` that stops Docker starting.

The output names what it found, for example
`Docker starts with --log-driver=journald (read from the running dockerd, pid 812).`
Only the names of `--log-opt` flags are printed, never their values, because
a logging driver's options can carry a token.

### 2. Adds the keys that are missing

It never changes a value that is already set.

- **`log-opts.max-size` and `log-opts.max-file`.** These are added only when
  all of these hold, and otherwise the output says `SKIPPED:` and why:
  - the log driver Docker will use is `json-file` (Docker's default) or
    `local`. The driver is taken from the `--log-driver` flag, else
    `daemon.json`, else what the running daemon reports. Any other driver,
    such as `journald`, does not take these options;
  - the daemon has no `--log-opt` flag. Docker refuses to start with
    `log-opts` both as a flag and in `daemon.json`;
  - its start flags could be read, which needs Docker to be running. See
    exit code `3`.
- **`builder.gc`.** This is added only if the file has no `builder.gc` at all.
  Docker 28 and later gets a policy with `reservedSpace` and `maxUsedSpace`.
  Older engines get `defaultKeepStorage`, because they would silently ignore
  the newer keys. The log flags do not affect it, so it is still added when
  log rotation is skipped.

Before it writes, it checks the merged file with `dockerd --validate` when
the engine has that option, **with the daemon's own `--log-driver` and
`--log-opt` flags**, so the check covers the combination that will actually
run. If the check fails, nothing is written. `--validate` alone does not
catch every clash (it passes a `journald` daemon with `max-size` in the file,
which then fails at a real start), which is why the driver is also checked
directly.

### 3. Writes the file so that Docker never reads half of one

Docker must never read a half-written `daemon.json`, and the file's owner,
mode and link must survive:

1. In `Apply` mode only, it builds the new file inside the directory of the
   real file (`/etc/docker/.daemon.json.tc-XXXXXX`), so the last step is a
   rename on one filesystem. The merge itself, and its `dockerd --validate`
   check, run on a scratch file under `$TMPDIR`; that is the only file
   `Report` mode makes, and nothing in `/etc/docker`. The new file is `0600`
   while it is written, is compared with the validated one, and only then
   takes the **mode, owner and group of the file it replaces**. A
   `daemon.json` that did not exist is created `0644 root:root`.
2. **A symlinked `daemon.json` stays a symlink.** The change goes to the file
   it points to, with that file's mode, owner and group. A link that points
   nowhere, at a directory or at anything else but a regular file, or loops, is
   not touched: the output says so and the run exits `3`. `Report` mode says
   the same.
3. It saves the old file as `/etc/docker/daemon.json.tc-bak-<timestamp>`, with
   `cp -p`, so the backup has the old file's mode and owner. (When
   `daemon.json` is a link, the backup is still beside the link and holds the
   target's content.) A second backup in the same second gets `-1`, `-2` added
   to its name.
4. It flushes the new file to disk (`sync <file>`, coreutils 8.24 or later;
   best effort), renames it over the old one, then runs `restorecon` on it
   when that command exists (best effort), so an SELinux host keeps the right
   label.
5. After a successful write it keeps the **newest 5** backups and removes the
   older ones. Only names of the form `daemon.json.tc-bak-<14 digits>` (with
   the optional `-n`) are counted or removed, so a backup someone saved by
   hand under another name is never touched. They are ordered by name, which
   is time order; a file's date cannot be used, because `cp -p` gives a
   backup its source's date. Backups Host Maintenance made (up to its version
   14) have the same names, so they are counted with this component's.
6. **Nothing is left behind.** The new file is removed on every way out:
   success, a failed validation, a failed backup, a failed rename, and a run
   that is stopped. At the start of an `Apply` run it also removes any
   `.daemon.json.tc-*` file an earlier run left when it crashed. (`Report`
   mode removes nothing.)

If the rename fails (an immutable file, say), the run exits `1`, says what
failed, removes the backup it had just made, and leaves the old file exactly as
it was. If the disk is full, writing the new file fails before the old file is
touched.

### When it writes nothing

- **The daemon reads a different file.** If the running `dockerd` was started
  with `--config-file` pointing anywhere other than `/etc/docker/daemon.json`,
  the output names that file and the run exits `3`. Neither file is edited.
  (With Docker stopped this cannot be seen; `builder.gc` then goes into
  `/etc/docker/daemon.json`, which such a daemon does not read, so it does
  no harm and no good.)
- **The file already stops Docker starting.** Host Maintenance version 4
  could leave a host with `max-size` or `max-file` in `daemon.json` that its
  daemon flags refuse. Docker keeps running until its next restart or reboot,
  then fails. Such a host is reported with a line starting
  `DAEMON WILL NOT START:` that names the conflict and the newest
  `daemon.json.tc-bak-*` file, and the run exits `3`. It does **not** revert
  or edit the file, and does not add `builder.gc` either: whether to restore
  that backup or remove the conflicting setting is a person's decision. Set a
  post-condition on `DAEMON WILL NOT START` to make it stand out.
- **Both limits are blank** (`usrLogMaxSize`, `usrLogMaxFile` and
  `usrBuildCacheMax` all empty): the output says
  `daemon.json: log rotation and build-cache limits both left blank; not touched.`
  and the run exits `0`.
- **The file has everything already:** `KEPT` for each key, then
  `daemon.json: already has everything this component sets; no change.`

### What it never does

**It never starts or restarts Docker.** A `daemon.json` change only takes
effect when Docker restarts or the host reboots. Log rotation then applies
only to containers created after that. The output prints `RESTART PENDING`
whenever it changed the file and Docker is running. Set a post-condition on
that string to turn the job orange.

**It does not wake a stopped Docker either.** On a package install
`docker.socket` keeps listening while `docker.service` is stopped, and any
`docker` command would start Docker again, with every `restart: always`
container. So it runs a `docker` command only once it knows a daemon is
already running. Docker's start flags are read from a `dockerd` process that
is running, and only then is `docker info` asked for the log driver. For the
`RESTART PENDING` line it asks systemd whether `docker.service` is active
before it asks Docker (the block marked `tc-docker running`, the same code
the other Docker components use; CI's "Shared blocks match" check keeps the
seven copies identical). A run against a stopped Docker changes at most
`builder.gc`, exits `3`, and leaves Docker stopped.

**It touches nothing else.** The expected-containers list, the prune, its
settings and its timer belong to
[`Docker - Configure Host Maintenance [Lin]`](../docker-configure-host-maintenance-lin/).
This component does not create, read or change any of them, and does not
need them.

If Docker is not installed, it exits 0 and changes nothing. That makes it safe
to target at every Linux device.

## Why

A container's log, with Docker's default `json-file` driver and no limit, grows
until the disk is full. So does the build cache on a host that builds images.
Two TechCollective Docker hosts filled their disks in 2026; on one of them,
build-cache limits in `daemon.json` (the values used here by default) were
what kept its build cache in check.

These limits stop growth. They do not remove images or stopped containers
nobody uses: that is the weekly prune Host Maintenance installs.

It is a component of its own, from Host Maintenance version 15, because the
two jobs have nothing in common on the host: this one edits Docker's own
configuration and needs `python3`; that one keeps a list and a timer and
never touches Docker's configuration. A host can have either without the
other.

## Related components

| Component | Role |
|---|---|
| [`Docker - Configure Host Maintenance [Lin]`](../docker-configure-host-maintenance-lin/) | The expected-containers list, and the weekly prune that removes unused images and stopped containers. Had this component's code up to its version 14 |
| [`Docker - Update Expected Containers [Lin]`](../docker-update-expected-containers-lin/) | Changes the expected list, the ignore patterns and the review state |
| [`Docker - Containers Differ From Expected [Lin]`](../../Monitors/docker-containers-differ-from-expected-lin/) | Monitor. Alerts when an expected container is stopped or gone, or a stopped container is waiting to be removed by the prune |
| [`Docker - Container Health and Resource Usage [Lin]`](../../Monitors/docker-container-health-and-resource-usage-lin/) | Monitor. Unhealthy, restarting and resource-hungry containers |
| [`Docker Images monitor [Lin]`](../../Monitors/docker-images-monitor-lin/) | Monitor. Running containers whose image has a newer version in its registry |

None of them reads `daemon.json`, and this component reads none of their
files. The one thing it shares with them is the "is Docker running" check, the
block marked `tc-docker running`.

## Installing it in Datto

Automation → Components → New Component, or import the `.cpt` from the latest
release.

| Field | Value |
|---|---|
| Name | `Docker - Configure Daemon Limits [Lin]` |
| Description | Adds missing log-rotation and build-cache limits to Docker's daemon.json; changes no existing value and never restarts Docker. |
| Category | **Scripts** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | Not standardised yet; decide at save time (`component.json` carries 5) |
| Timeout | 120 seconds |
| Attachments | none |
| Post-condition | Optional: warn when output **contains** `RESTART PENDING`; fail when it **contains** `DAEMON WILL NOT START` |

Paste the whole of `docker-configure-daemon-limits-lin.sh` as the script body,
then add the input variables below.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | **Selection** | `Apply` | `Apply` / `Report`. Report prints what it would add and changes nothing. Use it first on any host you have not looked at. |
| `usrLogMaxSize` | String | `10m` | A number plus `k`, `m` or `g`. To leave log settings alone, blank this **and** `usrLogMaxFile`: with only one of the two blank the run is refused (exit `2`). |
| `usrLogMaxFile` | String | `3` | 1–20. Worst-case log disk per container is size × files. |
| `usrBuildCacheMax` | String | `100GB` | A number plus `MB`, `GB` or `TB`. Blank leaves build-cache settings alone. Lower it on hosts with small disks. |
| `usrBuildCacheReserved` | String | `20GB` | Same format. Docker 28 and later only. Should be smaller than the max. |

These are the five variables, with the same names, defaults and checks, that
Host Maintenance had for this part up to its version 14.

No customer-specific value is hardcoded. Different hosts get different values
through the job's variables, not through edits to the script.

An invalid value makes the component refuse to run with exit `2`. It checks
every input before it changes anything.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done, or nothing needed doing. Also returned when Docker is not installed. |
| `1` | `daemon.json` could not be replaced (immutable, a full disk, a read-only filesystem). The old file is unchanged. |
| `2` | An input variable is invalid. Nothing was changed. |
| `3` | Something could not be applied safely, and was left as it was. The output says what. See the list below. |

What causes exit `3`:

- no `python3` to merge the JSON
- the existing `daemon.json` is not valid JSON
- the merged file failed `dockerd --validate`
- `daemon.json` is a symlink that does not end at a regular file (it points
  nowhere, at a directory, or loops); nothing was touched
- Docker's start flags could not be read, so log rotation was skipped
  (`builder.gc` may still have been added). That happens when:
  - **Docker is not running.** Run the component again once it is;
  - more than one root `dockerd` is running on the host, or the running
    one's command line cannot be read
- `dockerd` is started with `--config-file` pointing somewhere other than
  `/etc/docker/daemon.json`; nothing was written
- `DAEMON WILL NOT START`: `daemon.json` already holds `max-size` or
  `max-file` that this daemon's flags refuse; nothing was written
- Docker is the snap package

Log rotation skipped because the driver does not take these options
(`journald`, say) or because the daemon has a `--log-opt` flag is a normal
outcome, not exit `3`.

Any exit other than `0` ends with the line `Finished with exit code <n>.`

## How to tell it worked

A first apply on a host that had none of this looks like:

    Docker: /usr/bin/docker, engine 28.x. Mode: apply.
    daemon.json: Docker starts with no --log-driver, --log-opt or --config-file flag (read from the running dockerd, pid 812).
      daemon.json ADDED: log-opts.max-size = 10m
      daemon.json ADDED: log-opts.max-file = 3
      daemon.json ADDED: builder.gc = {"enabled":true,"policy":[...]}
    daemon.json: merged file passes dockerd --validate.
    daemon.json: written.
    RESTART PENDING: daemon.json changed. It takes effect when Docker restarts or the host reboots; this component never restarts Docker. Log rotation applies to containers created after that.
    Docker daemon limits: done.

A second run, or a first run on a host Host Maintenance configured, says
`KEPT` for each key and
`daemon.json: already has everything this component sets; no change.`

A run with Docker stopped exits `3`:

    daemon.json: could not tell which flags Docker starts with: Docker is not running, so its start flags cannot be read.
      daemon.json SKIPPED: log rotation: Docker's start flags could not be determined, so it cannot be known whether Docker would accept log-opts in daemon.json; run this component again while Docker is running
      daemon.json ADDED: builder.gc = {"enabled":true,"policy":[...]}
    daemon.json: merged file passes dockerd --validate.
    daemon.json: written.
    daemon.json changed; Docker is not running, so it applies at next start.
    Finished with exit code 3.

On the host itself:

    cat /etc/docker/daemon.json
    ls -l /etc/docker/                        # daemon.json.tc-bak-<time>: the file before each change, newest 5
    dockerd --validate --config-file /etc/docker/daemon.json
    docker info --format '{{.LoggingDriver}}'
    docker inspect -f '{{json .HostConfig.LogConfig}}' <a container created after the restart>

## Test order

Never a customer first.

1. CI's "Component tests" check on the pull request (`test.json`, Tier 1).
2. One internal Docker host. Run with `usrMode` = `Report` first, read what it
   would add, then run `Apply`.
3. One site, one device in it, with the job scoped to that device. Run Report,
   then Apply. Restart Docker in that site's maintenance window, and check a
   new container's log settings.
4. Wider, only after the first three.

## Known limits

- **Needs `python3`** to merge JSON safely. Without it, the run exits `3`
  rather than risk rewriting the file badly.
- **A running daemon is judged by its running flags.** If someone has changed
  the unit or a drop-in since Docker last started, the flags Docker will use
  at its next start can differ from the ones checked. Restart Docker after
  changing its unit, then run this.
- **A stopped Docker gets no log rotation, and the run exits `3`.** Its start
  flags are read only from a running `dockerd`. A fleet job that reaches a
  host while its Docker is stopped shows exit `3` for that host every time,
  until a run finds Docker up. Build-cache limits are still put in place.
- **With Docker stopped, a `--config-file` elsewhere is not seen.**
  `builder.gc` is then added to `/etc/docker/daemon.json`, which that daemon
  does not read. The next run with Docker running reports the other file and
  changes nothing more.
- **A host Host Maintenance version 4 already broke is reported, not
  repaired.** Fixing it needs a person: restore the named backup or remove
  the conflicting key, then restart Docker in a maintenance window.
- **Only the logging flags are checked.** Other settings set both as a flag
  and in `daemon.json` (`data-root`, say) also stop Docker starting; this
  component never adds those keys, so it does not look for them.
- **It never tightens an existing setting.** A host that already has
  `max-size: 500m` keeps it.
- **Blanking one of the two log variables is refused.** `usrLogMaxSize` blank
  with `usrLogMaxFile` set (or the other way round) is exit `2`, not "leave
  log settings alone". Blank both. (Host Maintenance behaved the same; it is
  kept, as this version moves the code without changing it.)
- **The write keeps the mode, owner, group and SELinux label of
  `daemon.json`, and nothing else about it.** A POSIX ACL or other extended
  attribute on the file is not copied to the new one. A `daemon.json` with
  more than one hard link stops being linked to the others (the rename gives
  the name a new file); a file bind-mounted into the host from somewhere else
  cannot be renamed over, so that run exits `1` and changes nothing.
- **The `restorecon` step has not been run on an SELinux host.** It is skipped
  when the command is missing and its result is ignored, so it can only do
  good, but treat label handling on SELinux as unverified until it has been
  run on one.
- **Backups are counted by name.** Only `daemon.json.tc-bak-<14 digits>` and
  `-<n>` are pruned. If the host's clock was set back, a newer backup can sort
  before an older one and be pruned first.
- **A crashed run's leftover file is removed only by the next `Apply`.** It is
  `0600` and can hold what `daemon.json` holds until then. Two runs of this
  component at once on one host are not supported: the second would remove
  the first's new file, and the first would exit `1` with nothing changed.
  The same goes for a run of Host Maintenance version 14 or older at the same
  time, which writes the same file the same way.
- **"Running" means `docker.service` is active, where systemd has that
  unit**, for the `RESTART PENDING` line. Docker's start flags are read from
  any root `dockerd` process on the host, whoever started it.
- **Snap-packaged Docker is refused** (exit `3`). Its config lives under
  `/var/snap` and snap manages it.
- **Rootless Docker** (a per-user daemon) and **Podman** are not handled.
- **The Docker 28 cutoff for `reservedSpace`/`maxUsedSpace`** comes from
  Docker's changelog, not from testing on a 27.x host.
- **Removing it** is manual: take the `log-opts` and `builder.gc` keys out of
  `/etc/docker/daemon.json` (or restore a `daemon.json.tc-bak-*` file),
  delete the backups, and restart Docker in a maintenance window.

## Open questions

- **Level** is not standardised. `component.json` carries 5, because this
  component writes daemon configuration as root.
- **Timeout** is 120 seconds, not Host Maintenance's 900: that was for the
  prune. Nothing here takes long, but `docker info` is asked without a time
  limit of its own when the file was changed, so the timeout is what ends a
  run against a daemon that hangs.
