# Docker - Update Expected Containers [Lin]

A Datto RMM script component for Linux Docker hosts. It shows, or changes, a
host's **expected-containers list** and its **ignore patterns**. It is the one
supported way to change either of them.

> **Status: Not Validated.** Written 2026-11-09. Every action, and refusal of
> bad input, passed the repo's Linux Tier 1 harness against a live Docker 29
> daemon in a sandbox. It has not yet run through a Datto agent.

## What it does

Two files on the host drive the Docker components:

| File | What it holds | Who reads it |
|---|---|---|
| `/etc/tc-docker/expected-containers` | The containers this host is expected to run, one key per line | The weekly prune, which never removes a stopped container on the list. The monitor, which alerts when one is stopped or gone. |
| `/etc/tc-docker/ignore` | Extended regular expressions matched against a container's key | The monitor, which never reports a match as unlisted |

[`Docker - Configure Host Maintenance [Lin]`](../docker-configure-host-maintenance-lin/)
creates both files once, from what is running at the time, and never changes
them again. This component changes them, so every change is a Datto job, with
its time, its author and its output on record.

A key identifies a container:

| Key | Used for |
|---|---|
| `compose:<project>/<service>` | A Docker Compose service. Survives the container being recreated or scaled. |
| `name:<container name>` | Any other container |

It **changes no container**. It writes only the two files above. When it
changes one, the previous version is kept as `<file>.prev`.

### Actions (`usrAction`)

| Action | What it does |
|---|---|
| **Show** (default) | Prints both lists, and compares them with the host now. Each expected entry is shown as `running`, `STOPPED` or `MISSING`. Each running container not on the list is shown as `UNLISTED`, or `ignored` if it matches a pattern. Changes nothing. |
| **Accept current** | Replaces the list with the containers running now. Containers matching an ignore pattern, Compose one-offs and `--rm` containers are left out. Use it after a deliberate change, when the host's current state is correct. |
| **Add** | Adds the entries in `usrItems`. A bare container name becomes that container's key: `compose:…` if it is a Compose service, otherwise `name:…`. |
| **Remove** | Removes the entries in `usrItems`, for a container that was retired on purpose. |
| **Add ignore** / **Remove ignore** | The same, for patterns in the ignore file. For example, `^name:runner-` keeps GitLab CI job containers out of the monitor. |

Every action except Show ends by running Show, so the output always says
where the host now stands.

### Typical uses

| Situation | Run |
|---|---|
| The monitor says `unlisted (name:newapp)` and the app is meant to be there | Add, `usrItems` = `newapp` |
| The monitor says `missing (compose:shop/worker)` and that service was retired | Remove, `usrItems` = `compose:shop/worker` |
| A host was rebuilt or redeployed, and what runs now is right | Show first, then Accept current |
| A CI host keeps reporting job containers | Add ignore, `usrItems` = `^name:runner-` |

## Installing it in Datto

Automation → Components → New Component, or import the `.cpt` from the latest
release.

| Field | Value |
|---|---|
| Name | `Docker - Update Expected Containers [Lin]` |
| Description | Shows or changes this host's Docker expected-containers list and ignore patterns; keeps the previous file as .prev. Changes no container. |
| Category | **Scripts** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | Not standardised yet; decide at save time (`component.json` carries 5) |
| Timeout | 120 seconds |
| Attachments | none |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrAction` | **Selection** | `Show` | Show, Accept current, Add, Remove, Add ignore, Remove ignore |
| `usrItems` | String | *(empty)* | **Add and Remove:** container names, `name:<name>` or `compose:<project>/<service>`, separated by spaces or commas. Names must be valid Docker names. **The ignore actions:** extended regular expressions, separated by spaces only, because a regex may contain a comma. Each is checked before anything is written. |

No customer-specific value is hardcoded. An invalid value makes it refuse with
exit `2` and change nothing.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done. Also returned when Docker is not installed. |
| `1` | Unexpected failure, such as a write failing. |
| `2` | An input variable is invalid. Nothing was changed. |
| `3` | Accept current needs the Docker daemon, and it is not reachable. Nothing was changed. |

## How to tell it worked

    /etc/tc-docker/expected-containers: written (4 entries; previous version kept as /etc/tc-docker/expected-containers.prev).
      added:   name:newapp

    Expected list (/etc/tc-docker/expected-containers):
      compose:shop/web
      ...
    Compared with this host now:
      running  compose:shop/web
      STOPPED  name:legacy
      UNLISTED name:surprise
    Done.

## Test order

Never a customer first.

1. CI's "Component tests" check on the pull request (`test.json`, Tier 1).
2. Show on one internal Docker host, then one change.
3. Show on one client host, then one change.

## Known limits

- **A rewrite drops hand-written comments.** The component writes a fresh
  header each time. Comments added over SSH are lost on the next change; the
  previous version survives in `.prev`.
- **Only one `.prev` is kept.**
- **It doesn't check that a name you add exists.** Adding a container that
  isn't deployed yet is allowed on purpose. The monitor reports it as missing
  until it runs.
- It shares its container-identity code with Host Maintenance and the monitor,
  in a block marked `tc-docker shared`. It must stay identical in all three.

## Open questions

- **Level** is not standardised. `component.json` carries 5, because it writes
  files as root that decide what the weekly prune keeps.
