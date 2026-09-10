# Unattended Upgrades - Not Running [Lin]

A Datto RMM custom monitor for Linux. Confirms that the host's automatic
security-update mechanism is installed, enabled and actually running — on Debian
family by the age of the last `unattended-upgrades` run, on RHEL family by the
state of the `dnf-automatic` or `yum-cron` unit.

> **Status: Not Validated.** Imported from the Datto Component Library on
> 2026-09-10 as part of the initial repository organisation. It has not been
> reviewed against our monitor contract or security checklist, and the review
> below is a reading of the script only — it has not been re-run. Treat the
> defects in [Known limits](#known-limits) as unfixed.

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

No `.cpt` export yet — this component has not been saved into Datto under this
name. There are no input variables to preserve, so an export buys little beyond
the component metadata.

---

## What it does

Detects the distribution family from `/etc/os-release` (`ID` and `ID_LIKE`), then
takes one of two branches.

**Debian, Ubuntu, Linux Mint.** Requires the `unattended-upgrade` binary. Finds
the most recent timestamp in `/var/log/unattended-upgrades/unattended-upgrades.log`,
falling back to the newest rotated `.gz` if the current log is empty (it will be,
just after rotation), and falling back again to the log file's mtime if neither
yields a timestamp. Alerts on the age of that run.

**RHEL, CentOS, Fedora, Rocky, AlmaLinux, Oracle Linux.** Picks
`dnf-automatic` / `dnf-automatic-install.timer` where `dnf` exists, otherwise
`yum-cron` / `yum-cron.service`. Checks in order that the package is installed,
the unit is enabled, and the unit is active.

**Anything else** — Arch, SUSE, Alpine, Gentoo — reports UNKNOWN, which Datto
treats as an alert.

**It is read-only.** It reads `/etc/os-release`, the unattended-upgrades log,
and `rpm -q` / `systemctl is-enabled` / `systemctl is-active`. It installs
nothing, upgrades nothing, and makes no network call.

Note the two branches measure different things. The Debian branch measures
*outcome* — did it actually run recently. The RHEL branch measures
*configuration* — is the timer switched on. A RHEL host whose timer is enabled
and active but failing every run reports healthy.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Unattended Upgrades - Not Running [Lin]` |
| Description | Alerts when a Linux host's automatic security updates are not installed, not enabled, or have not run recently. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Shell (Unix, macOS) |
| Target OS | Linux, Debian and RHEL families only |
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
| RHEL: package installed, unit enabled and active | `Status=OK` | `0` | healthy |
| RHEL: `dnf-automatic` / `yum-cron` not installed | `Status=CRITICAL` | `2` | **alert** |
| RHEL: unit disabled | `Status=WARNING` | `1` | **alert** |
| RHEL: unit enabled but inactive | `Status=WARNING` | `1` | **alert** |
| Unsupported distribution | `Status=UNKNOWN` | `3` | **alert** |
| The script dies unexpectedly | **No result block is emitted.** Datto renders this as an alert with no text in it | non-zero | **alert** |

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
   output read. Then one RHEL-family device — the two branches share nothing but
   the output helper and the dispatcher.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

Read as unfixed defects, in rough order of how much they matter.

- **The alert text is the state word and nothing else.** `_out` takes a `short`
  message argument and never uses it, so every alert reads `Status=CRITICAL`
  with no indication of which host state produced it. A technician has to open
  the diagnostic block to learn anything — and the RHEL "not installed" path is
  the only one whose diagnostic names the problem clearly.
- **No result block on unexpected death.** There is no `EXIT` trap, and the
  script runs under `set -euo pipefail`, so any unset variable or failed command
  in a pipeline exits immediately with nothing on stdout. That combination makes
  a silent, textless alert *more* likely, not less.
- **`check_rhel` references `$PRETTY_NAME`**, which only exists if
  `/etc/os-release` was readable and sourced. Under `set -u` an unreadable
  `/etc/os-release` on an RPM host is an unbound-variable crash — the textless
  alert above.
- **Thresholds are hardcoded.** See [Input variables](#input-variables).
- **Four exit codes where Datto has two.** Everything non-zero is one alert.
- **The RHEL branch checks configuration, not outcome.** An enabled, active
  timer whose every run fails reports healthy. `systemctl show -p Result` on the
  service, or the timestamp of the last successful run, would be the equivalent
  of what the Debian branch measures.
- **The mtime fallback overstates freshness.** If no timestamp line is found,
  the script uses the log file's mtime — which `logrotate` updates when it
  compresses, making a long-dead service look like it ran at rotation time.
- **`\n` in the RHEL diagnostic is printed literally.** `_out` uses `echo "$detail"`
  without `-e`, so the multi-line diagnostic header arrives as one line
  containing the characters `\n`.
- **No timeout on any external call.** `zgrep` across large rotated logs is the
  realistic hazard.
- **Never run against:** SUSE, Arch, Alpine, Gentoo, or any host using a
  configuration-management tool rather than a native timer to apply updates —
  all of which report UNKNOWN and therefore alert.

## Open questions

- **Licence and provenance.** This file carries no attribution. The
  implementation it replaced was adapted from
  [Josef-Friedrich/check_unattended_upgrades](https://github.com/Josef-Friedrich/check_unattended_upgrades)
  (GPL-3.0). This repository is public and GPL-3.0, so that is compatible — but
  confirm whether any code was carried across from it into this version before
  treating this as an in-house work, and record the answer here either way.
- **Should an unsupported distribution alert?** It currently does. If the
  component is only targeted at Debian and RHEL device groups, exiting `0` with
  "not applicable" would be quieter and just as correct.
- **The result keyword.** This script emits `Status=`, the newer monitors emit
  `STATUS=`, the older ones emit `Alert=`. Establish which Datto actually parses
  and make all of them agree.
- **Component `Level`** (access tier) is not standardised. Ask before saving.
