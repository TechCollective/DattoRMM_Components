# APT - Update Available for Package [Lin]

A Datto RMM custom monitor for Debian-family Linux hosts. Refreshes the APT
package lists and alerts when a single named package has an upgrade waiting.

> **Status: Not Validated.** Imported from the Datto Component Library on
> 2026-09-10 as part of the initial repository organisation. It has not been
> reviewed against our monitor contract or security checklist, and the review
> below is a reading of the script only — it has not been re-run. Treat the
> defects in [Known limits](#known-limits) as unfixed.

> **Currently saved in Datto as `APT update availble for PACKAGE [LIN]`**
> (component uid `cb643aad-7534-44b9-9f7f-49e7ac09bdc9`, version 5). That name
> carries a spelling error and the wrong OS-tag casing. Rename it to the heading
> above at the next edit; the script body does not change.

---

## Contents

| Path | What it is |
|---|---|
| `apt-update-available-for-package-lin.sh` | The component body. This file is the source of truth — paste it into Datto, don't edit it there. |
| `apt-update-available-for-package-lin.cpt` | Datto export, taken 2024-07-29. Byte-identical to the script above. Carries no attachment. |
| `README.md` | This file. |

---

## What it does

1. Refuses to run if the `PACKAGE` input variable is empty.
2. Runs `sudo apt-get update -y` to refresh the package lists.
3. Runs `apt list --upgradable` and matches `PACKAGE` against the output with
   `grep -w`.
4. Alerts if a match is found.

**It is not read-only.** Step 2 rewrites the APT package list caches under
`/var/lib/apt/lists/` and touches `/var/cache/apt/`. It installs nothing and
upgrades nothing, but it is a write, and it makes network calls to every
repository configured on the host. Budget for that on a monitor interval.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `APT - Update Available for Package [Lin]` |
| Description | Refreshes APT package lists, then alerts if one named package has an upgrade available. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Shell (Unix, macOS) |
| Target OS | Linux, Debian family only |
| Level | `securityLevel 5` in the current export — not standardised yet, decide at save time |
| Timeout | 3600 s in the current export |
| Attachments | None |
| Monitor interval | Set deliberately — see [Known limits](#known-limits); every run hits the repositories |

Paste the whole of `apt-update-available-for-package-lin.sh` as the script body,
then add the input variable below. Importing the `.cpt` does all of this and
restores the variable without retyping it.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `PACKAGE` | String | *(empty)* | One binary package name as APT spells it, e.g. `openssh-server`. Exactly one — the script does not split on whitespace, so a list is treated as a single package name and will never match. |

No customer-specific value is hardcoded. There is only one input and it has no
default, which is deliberate: the script refuses to run rather than monitoring
some arbitrary package nobody chose.

**Prefer a Selection over a String** here if the set of packages you monitor is
known, so a typo is unrepresentable. As a String, a misspelled package name
matches nothing and the monitor reports healthy forever.

## Exit behaviour

Datto monitors have exactly two states: exit `0` healthy, exit `1` alert.

| Host state | Result | Exit |
|---|---|---|
| `PACKAGE` is empty | `Alert=Unhealthy: No package specified`, plus a diagnostic block | `1` |
| `apt-get update` fails (no network, broken repo, no `sudo`) | `Alert=Unhealthy: Failed to update package list`, plus a diagnostic block | `1` |
| An upgrade is available for `PACKAGE` | `Alert=Update available for <package>`, plus a diagnostic block | `1` |
| No upgrade available, or the package is not installed | `Alert=No updates available for <package>` | `0` |
| Not a Debian-family host (`apt-get` absent) | Falls into the `apt-get update` failure path above | `1` |
| The script dies unexpectedly | **No result block is emitted.** Datto renders this as an alert with no text in it | non-zero |

That last row is a defect, not a design. See [Known limits](#known-limits).

## How to tell it worked

Run it as a **Scripts** component first and read the raw job output.

Healthy path — the full `apt-get update` transcript, then:

```
<-Start Result->
Alert=No updates available for openssh-server
<-End Result->
```

Alert path — the same transcript, then:

```
<-Start Result->
Alert=Update available for openssh-server
<-End Result->
<-Start Diagnostic->
There is an update available for the package openssh-server.
<-End Diagnostic->
```

Note the payload key is `Alert=`, not the `STATUS=` used by the other monitors
in this repository. Confirm which one Datto's parser actually accepts before
relying on the alert text.

## Test order

Never a customer first.

1. One internal Debian or Ubuntu device, run as a **Scripts** component, raw
   output read. Test both branches: point `PACKAGE` at something with a pending
   upgrade, then at something already current.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

Read as unfixed defects, in rough order of how much they matter.

- **No result block on unexpected death.** There is no `EXIT` trap. A shell
  error, a signal, or a timeout exits non-zero with nothing on stdout, which
  Datto renders as an alert with no text.
- **`grep -w` over-matches.** The match runs against the whole `apt list` line,
  and `-w` treats `-` as a word boundary, so `PACKAGE=nginx` also matches an
  upgrade for `nginx-common` or `nginx-core`. False alerts naming a package that
  is not the one being watched.
- **It cannot distinguish "up to date" from "not installed".** A package that
  was never installed, or whose name is misspelled, produces no `apt list` line
  and reports healthy. A monitor that reports healthy for a host it is not
  actually watching is the failure mode worth caring about here.
- **Hardcoded, unsuppressed `apt-get update`.** Its full transcript goes to
  stdout and lands in the ticket note ahead of the result block. It also runs on
  every interval — on a short interval that is repository load and, on a metered
  link, transfer.
- **`sudo` is called explicitly** even though Datto already runs components as
  root. On a host with no `sudo` package the update step fails and the monitor
  alerts with "Failed to update package list", which is misleading.
- **No timeout on any external call.** An unreachable repository can hang the
  script until Datto's own 3600 s component timeout.
- **`apt list --upgradable` has no stable CLI interface** — APT prints a warning
  saying so, which the script discards. The output format can change across APT
  releases.
- **Never run against:** Debian and Ubuntu releases other than whatever it was
  written on, Linux Mint, any Raspberry Pi OS, or any non-Debian distribution.

## Open questions

- **Provenance is unrecorded.** Nothing in the script or the export names an
  author or an upstream source. Confirm it was written in-house before treating
  this repository's GPL-3.0 licence as settled for it.
- **The result keyword.** This script emits `Alert=`; the newer monitors here
  emit `STATUS=`. Establish which Datto actually parses and make them agree.
- **Whether one component per package is the right shape at all.** Monitoring
  five packages means five component instances, five schedules and five alerts.
  A single monitor taking a package list would be one target and one alert.
- **Component `Level`** (access tier) is not standardised. Ask before saving.
