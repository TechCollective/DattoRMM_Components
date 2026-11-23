# Unattended Upgrades - Not Running [Lin]

A Datto RMM custom monitor for Debian-family Linux (Debian, Ubuntu, Linux
Mint). Confirms that `unattended-upgrades` is actually running, by the age of
its last run. On any other Linux it reports OK and checks nothing.

> **Status: Not Validated.** Imported from the Datto Component Library on
> 2026-09-10 as part of the initial repository organisation. It has not been
> reviewed against our monitor contract or security checklist. Its Debian
> branch now has a Tier 1 test, which found and fixed three bugs (see
> [Contents](#contents)).
> Treat the defects in [Known limits](#known-limits) as unfixed.

> **The alert text is currently unusable.** Every alert reads `Status=CRITICAL`
> or `Status=WARNING` with no explanation — the human-readable message is
> computed and then discarded. See [Known limits](#known-limits).

> **Named `Update Monitor [LIN]` in the file it arrived as.** The heading above
> is the name to save it under. Also note this component supersedes an earlier
> Debian-only implementation adapted from
> [Josef-Friedrich/check_unattended_upgrades](https://github.com/Josef-Friedrich/check_unattended_upgrades),
> which was deleted in the same commit that created this folder — recover it
> from git history if you need it.

---

## Contents

| Path | What it is |
|---|---|
| `unattended-upgrades-not-running-lin.sh` | The component body. This file is the source of truth — paste it into Datto, don't edit it there. |
| `README.md` | This file. |
| `component.json` | Its metadata, from which CI builds an importable `.cpt`. The `uid` is empty until it is saved into Datto. |
| `test.json`, `tests/` | Its Tier 1 test (Debian branch, on the Ubuntu runner): a real dry run is healthy, a last run 30 hours ago warns, 3 days ago is critical, and just after rotation the newest rotated log is read. |

Not yet saved into Datto, so `component.json` has no uid. Import the `.cpt` CI
builds from it, then record the uid.

**Fixed with the Tier 1 test** (they were in the imported script):

- A healthy Debian host printed `Status=OK` but exited `1` — so it always
  alerted. `_out` ended in `[[ -n $detail ]] && …`, which returns 1 when there
  is no diagnostic, and `set -e` exited on it.
- An empty current log (just after rotation) killed the script with no result
  block: the `grep` that found no timestamp failed the pipeline under
  `pipefail`.
- The rotated-log fallback read the *oldest* rotation (highest number) instead
  of the newest (`.1.gz`), so after rotation it alerted on a month-old run.

**Fixed since:** it ran under `set -euo pipefail` with no `EXIT` trap, so any
unexpected death printed no result block. An `EXIT` trap now prints a fallback
`Status=UNKNOWN` block (exit `3`) when nothing else did; the test sends it TERM
mid-run to prove it.

---

## What it does

Detects the distribution family from `/etc/os-release` (`ID` and `ID_LIKE`).

**Debian, Ubuntu, Linux Mint.** Requires the `unattended-upgrade` binary. Finds
the most recent timestamp in `/var/log/unattended-upgrades/unattended-upgrades.log`,
falling back to the newest rotated `.gz` if the current log is empty (it will be,
just after rotation), and falling back again to the log file's mtime if neither
yields a timestamp. Alerts on the age of that run.

**Anything else** — RHEL, Fedora, SUSE, Arch, Alpine, or no `/etc/os-release`
at all — reports `Status=OK: not a Debian-based system (<name>); nothing to
check` and exits `0`. `unattended-upgrades` is a Debian tool, so there is
nothing to check there, and a device that is wrongly targeted should not alert.
An earlier version had an RHEL branch (`dnf-automatic` / `yum-cron`); it was
removed because this monitor is only meant for Debian-family hosts.

**It is read-only.** It reads `/etc/os-release` and the unattended-upgrades log.
It installs nothing, upgrades nothing, and makes no network call.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Unattended Upgrades - Not Running [Lin]` |
| Description | Alerts when a Debian-family Linux host's unattended-upgrades has not run recently. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Shell (Unix, macOS) |
| Target OS | Linux, Debian family (Debian, Ubuntu, Mint); any other Linux reports OK |
| Level | *not standardised yet — decide at save time* |
| Timeout | Always set one |
| Attachments | None |
| Monitor interval | The Debian thresholds are 26 h and 52 h, so anything under a few hours is wasted work |

Paste the whole of `unattended-upgrades-not-running-lin.sh` as the script body.
There are no input variables to add.

**It needs root** to read `/var/log/unattended-upgrades/`, which is mode 0750.
Datto runs components as root; a by-hand test as an ordinary user will report
CRITICAL for the wrong reason.

## Input variables

**None, and that is a defect.** The two age thresholds are hardcoded in
`check_debian`:

| Constant | Value | Meaning |
|---|---|---|
| `warn_sec` | `93600` (26 h) | Last run older than this → WARNING |
| `crit_sec` | `187200` (52 h) | Last run older than this → CRITICAL |

26 hours is chosen to clear a daily timer plus `APT::Periodic::RandomSleep`.
Both should become input variables with those numbers as their defaults, per
[`CONTRIBUTING.md`](../../CONTRIBUTING.md) — every threshold is an input
variable. No customer-specific value is hardcoded, so this is a portability
problem rather than a disclosure one.

## Exit behaviour

Datto monitors have exactly two states: exit `0` healthy, exit `1` alert. This
script emits four Nagios states across exit codes `0`–`3`.

**That distinction does not survive.** Datto reads only zero versus non-zero, so
WARNING, CRITICAL and UNKNOWN are one and the same alert. There is no warning
tier in Datto — it is a Nagios concept, and this script is a Nagios plugin that
was ported without collapsing its state model.

| Host state | Reported | Exit | Datto sees |
|---|---|---|---|
| Debian: last run under 26 h ago | `Status=OK` | `0` | healthy |
| Debian: last run 26–52 h ago | `Status=WARNING` | `1` | **alert** |
| Debian: last run over 52 h ago | `Status=CRITICAL` | `2` | **alert** |
| Debian: `unattended-upgrade` binary missing | `Status=UNKNOWN` | `3` | **alert** |
| Debian: log unreadable — including when not run as root | `Status=CRITICAL` | `2` | **alert** |
| Not a Debian-family system | `Status=OK: not a Debian-based system (…); nothing to check` | `0` | healthy |
| The script dies unexpectedly | `Status=UNKNOWN: check failed before it could decide (…)` | `3` (`143` on TERM) | **alert** |

## How to tell it worked

Run it as a **Scripts** component first and read the raw job output. On a healthy
Debian host, expect exactly:

```
<-Start Result->
Status=OK
<-End Result->
```

Note what is *not* there. The `_out` helper accepts a human-readable message —
`"OK: last run 3600s ago"` — as its second argument and never prints it. Only the
bare state word reaches the result block. On the alert path the diagnostic block
carries the detail, so read that:

```
<-Start Result->
Status=CRITICAL
<-End Result->
<-Start Diagnostic->
- unattended-upgrades last ran at 2026-09-07 03:14:02 (age 191488s).
<-End Diagnostic->
```

Also note the payload key is `Status=`, in mixed case — not the `STATUS=` used
by the newer monitors in this repository, nor the `Alert=` used by the older
ones.

To exercise the Debian alert path without waiting two days, temporarily point
`log_file` at a stale file on a lab machine, or `touch -d '3 days ago'` a copy.
Do not backdate the real log — you will hide a genuine failure.

## Test order

Never a customer first.

1. One internal Debian or Ubuntu device, run as a **Scripts** component, raw
   output read.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

Read as unfixed defects, in rough order of how much they matter.

- **The alert text is the state word and nothing else.** `_out` takes a `short`
  message argument and never uses it, so every alert reads `Status=CRITICAL`
  with no indication of which host state produced it. A technician has to open
  the diagnostic block to learn anything.
- **Thresholds are hardcoded.** See [Input variables](#input-variables).
- **Four exit codes where Datto has two.** Everything non-zero is one alert.
- **The mtime fallback overstates freshness.** If no timestamp line is found,
  the script uses the log file's mtime — which `logrotate` updates when it
  compresses, making a long-dead service look like it ran at rotation time.
- **No timeout on any external call.** `zgrep` across large rotated logs is the
  realistic hazard.
- **A non-Debian host reports healthy.** That is deliberate, but it means the
  monitor proves nothing there: target it only at Debian-family devices, and
  watch other distributions' updates some other way.

## Open questions

- **Licence and provenance.** This file carries no attribution. The
  implementation it replaced was adapted from
  [Josef-Friedrich/check_unattended_upgrades](https://github.com/Josef-Friedrich/check_unattended_upgrades)
  (GPL-3.0). This repository is public and GPL-3.0, so that is compatible — but
  confirm whether any code was carried across from it into this version before
  treating this as an in-house work, and record the answer here either way.
- **The result keyword.** This script emits `Status=`, the newer monitors emit
  `STATUS=`, the older ones emit `Alert=`. Establish which Datto actually parses
  and make all of them agree.
- **Component `Level`** (access tier) is not standardised. Ask before saving.
