# Docker - Update Expected Containers [Lin]

A Datto RMM script component for Linux Docker hosts. It shows, or changes, a
host's **expected-containers list**, its **ignore patterns** and its **review
state**. It is the one supported way to change any of them.

> **Status: Not Validated.** Written 2026-11-09; version 2 adds Confirm
> reviewed on 2026-11-10. Every action, and refusal of bad input, passed the
> repo's Linux Tier 1 harness against a live Docker 29 daemon in a sandbox.
> Version 1 ran through a Datto agent.

## What it does

Two files on the host drive the Docker components:

| File | What it holds | Who reads it |
|---|---|---|
| `/etc/tc-docker/expected-containers` | The containers this host is expected to run, one key per line | The weekly prune, which never removes a stopped container on the list. The monitor, which alerts when one is stopped or gone. |
| `/etc/tc-docker/ignore` | Extended regular expressions matched against a container's key | The monitor, which never reports a match as unlisted |
| `/etc/tc-docker/reviewed` | When the list was confirmed, and an optional note | The weekly prune, which removes no containers or images until this file exists. The monitor, which reports a host without it. |

[`Docker - Configure Host Maintenance [Lin]`](../docker-configure-host-maintenance-lin/)
creates both files once, from what is running at the time, and never changes
them again. This component changes them, so every change is a Datto job, with
its time, its author and its output on record.

A key identifies a container:

| Key | Used for |
|---|---|
| `compose:<project>/<service>` | A Docker Compose service. Survives the container being recreated or scaled. |
| `name:<container name>` | Any other container |

It **changes no container**. It writes only the three files above. When it
changes one, the previous version is kept as `<file>.prev`.

### Actions (`usrAction`)

| Action | What it does |
|---|---|
| **Show** (default) | Changes nothing. Prints both lists and the review state, then compares them with the host now. See the Show details below. |
| **Confirm reviewed** | Records that a person has checked the list, with the date and an optional note from `usrItems`. **The weekly prune removes no containers and no images on a host until this has been run once.** It refuses, with exit 3, if the host has no list yet. |
| **Accept current** | Replaces the list with every container present now, running or stopped. Containers matching an ignore pattern, Compose one-offs and `--rm` containers are left out. Use it after a deliberate change, when the host's current state is correct. |
| **Add** | Adds the entries in `usrItems`. A bare container name becomes that container's key: `compose:…` if it is a Compose service, otherwise `name:…`. |
| **Remove** | Removes the entries in `usrItems`, for a container that was retired on purpose. |
| **Add ignore** / **Remove ignore** | The same, for patterns in the ignore file. For example, `^name:runner-` keeps GitLab CI job containers out of the monitor. |

Every action except Show ends by running Show, so the output always says
where the host now stands.

### Show details

| Shown as | Meaning |
|---|---|
| `running` | An expected entry with a running container |
| `STOPPED` | An expected entry whose container exists but isn't running |
| `MISSING` | An expected entry with no container at all |
| `UNLISTED` | A running container not on the list |
| `ignored` | A running container matching an ignore pattern |
| `STOPPED, UNLISTED` | A stopped container the list doesn't protect. The prune will remove it once the list is reviewed. |

### Reviewing a new host

When Host Maintenance first reaches a server, it creates the list from every
container there, running or stopped, and marks it not reviewed. To review it:

1. Run **Show**.
2. **Remove** anything retired. A stopped container left on the list is kept
   for good.
3. **Add** anything missing, or **Add ignore** for containers that churn.
4. Run **Confirm reviewed**, with a note such as your name and the ticket
   number.

### Typical uses

| Situation | Run |
|---|---|
| The monitor says `unlisted (name:newapp)` and the app is meant to be there | Add, `usrItems` = `newapp` |
| The monitor says `missing (compose:shop/worker)` and that service was retired | Remove, `usrItems` = `compose:shop/worker` |
| A host was rebuilt or redeployed, and what runs now is right | Show first, then Accept current |
| A CI host keeps reporting job containers | Add ignore, `usrItems` = `^name:runner-` |
| The monitor says the list is not reviewed | Show, fix the list, then Confirm reviewed with `usrItems` = `your name, ticket number` |

## Installing it in Datto

Automation → Components → New Component, or import the `.cpt` from the latest
release.

| Field | Value |
|---|---|
| Name | `Docker - Update Expected Containers [Lin]` |
| Description | Shows or changes this host's Docker expected-containers list, ignore patterns and review state; changes no container. |
| Category | **Scripts** |
| Script type | Shell (Unix) |
| Target OS | Linux |
| Level | Not standardised yet; decide at save time (`component.json` carries 5) |
| Timeout | 120 seconds |
| Attachments | none |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrAction` | **Selection** | `Show` | Show, Confirm reviewed, Accept current, Add, Remove, Add ignore, Remove ignore |
| `usrItems` | String | *(empty)* | **Add and Remove:** container names, `name:<name>` or `compose:<project>/<service>`, separated by spaces or commas. Names must be valid Docker names. **The ignore actions:** extended regular expressions, separated by spaces only, because a regex may contain a comma. Each is checked before anything is written. **Confirm reviewed:** an optional note, up to 120 printable characters. |

No customer-specific value is hardcoded. An invalid value makes it refuse with
exit `2` and change nothing.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done. Also returned when Docker is not installed. |
| `1` | Unexpected failure, such as a write failing. |
| `2` | An input variable is invalid. Nothing was changed. |
| `3` | Accept current needs the Docker daemon and it's not reachable, or Confirm reviewed was run on a host with no list yet. Nothing was changed. |

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
- **A review stays in force after later changes.** Changes made with this
  component are deliberate, so they don't reset the review. To withdraw a
  review, delete `/etc/tc-docker/reviewed` on the host.
- **It doesn't check that a name you add exists.** Adding a container that
  isn't deployed yet is allowed on purpose. The monitor reports it as missing
  until it runs.
- It shares its container-identity code with Host Maintenance and the monitor,
  in a block marked `tc-docker shared`. It must stay identical in all three.

## Open questions

- **Level** is not standardised. `component.json` carries 5, because it writes
  files as root that decide what the weekly prune keeps.
