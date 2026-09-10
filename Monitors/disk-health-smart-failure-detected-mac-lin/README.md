# Disk Health - SMART Failure Detected [Mac][Lin]

A Datto RMM custom monitor for Linux and macOS. Reads each physical disk's SMART
data and alerts on a failed self-assessment, a failing attribute, or a threshold
breach in wear, temperature, reallocated sectors or interface errors.

> **Status: Not Validated.** Written 2026-09-09 as a replacement for the Datto
> Labs ComStore monitor named below. Not yet run outside a test environment, and
> not yet reviewed against our monitor contract by a second person. The defects
> in [Known limits](#known-limits) are unfixed.

> **The script header still calls this `Disk Health (SMART) Monitor [Mac][Lin]`.**
> The heading above is the name to save it under — `[Subject] - [Condition
> watched]`, per [`CONTRIBUTING.md`](../../CONTRIBUTING.md). Bring the header
> comment into line at the next edit to the script.

---

## Contents

| Path | What it is |
|---|---|
| `disk-health-smart-failure-detected-mac-lin.sh` | The component body. This file is the source of truth — paste it into Datto, don't edit it there. |
| `README.md` | This file. |

No `.cpt` export yet — this component has not been saved into Datto. Export one
once it has, so its nine input variables can be restored without retyping.

---

## What it does

Enumerates physical disks, reads SMART data from each, and judges it.

**Linux.** Uses `smartctl --scan-open`, which reports the `-d` type each device
needs (`sat`, `nvme`, `megaraid`), falling back to `lsblk` if the scan returns
nothing. One `smartctl -H -A` call per healthy disk. Then, per device family:

- **ATA** — judges the `WHEN_FAILED` column: `FAILING_NOW` alerts,
  `In_the_past` is reported but does not alert unless `failOnPastTrip` is set.
  Reads raw values for reallocated sectors (5), pending (197), offline
  uncorrectable (198), interface CRC (199) and temperature (194, then 190).
- **NVMe** — critical warning flag, `Percentage Used`, `Available Spare`, media
  and data integrity errors, temperature.
- **SCSI/SAS** — grown defect list, current drive temperature.

**macOS.** Uses `diskutil list physical` and reads each disk's `SMART Status`.
`Verified` is healthy; `Not Supported` or empty is counted healthy and noted;
anything else alerts.

**Windows.** The script carries a `cmd.exe` stub that prints a "not supported"
status and exits 0, so the component is inert rather than broken if it lands on
a Windows device. Use a separate Windows SMART monitor.

**It is read-only.** `smartctl -H -A`, and on a failing disk `smartctl -l error
-l selftest`; `diskutil list` and `diskutil info` on macOS. It changes nothing,
starts no self-test, and makes no network call of any kind.

### The "I could not tell" policy

Deliberate, and the reason this component exists in the shape it does:

- **`smartmontools` missing, or no disk at all readable** → exit 1. An
  unmonitored disk is not a healthy disk.
- **Individual unreadable disks** — USB bridges that come and go, an enclosure
  that does not pass SMART through — are named in the status line but do not
  alert, unless `failOnUnreadable` is set.
- **A disk that reports no SMART support** is counted healthy and noted.

## Source and provenance

Replaces the Datto Labs ComStore component **"Unified Disk SMART Monitor"**
(build 25, authored by seagull), which alerted on every healthy ATA drive.

That component read the `TYPE` column of the SMART attribute table and treated
`Pre-fail` as a failure. `Pre-fail` is a class label present on every healthy
drive — it means "this attribute predicts failure", not "this attribute is
failing". The correct column is `WHEN_FAILED`. This script reads that one.

This is a **rewrite, not a patch.** ComStore components cannot be edited in
place, and the fix touches the central judgement of the script rather than one
line of it. No code was carried over, so no third-party licence attaches.

`Untarget "Unified Disk SMART Monitor" when this goes live. Do not run both.`

Secondary improvements over the original: one `smartctl` call per healthy disk
instead of four; NVMe and SCSI handled rather than assumed ATA; per-disk
diagnostics accumulated instead of overwritten; `--scan-open` used so RAID
controllers and virtio disks are found.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Disk Health - SMART Failure Detected [Mac][Lin]` |
| Description | Reads SMART data on every physical disk and alerts on a failed self-assessment, failing attribute or threshold breach. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Shell (Unix, macOS) |
| Target OS | Linux and macOS. The Windows stub reports "not supported" and exits 0 |
| Level | *not standardised yet — decide at save time* |
| Timeout | Set one. Nine disks at the default `smartctlTimeout` of 20 s is a 180 s floor before diagnostics |
| Attachments | None |
| Monitor interval | SMART data changes slowly; hourly is generous |

Paste the whole of `disk-health-smart-failure-detected-mac-lin.sh` as the script
body, then add the input variables below.

**It needs root** to read SMART data. Datto runs components as root, but this is
the thing that will differ when you test it by hand.

## Input variables

All optional — every one has a default, so the component works with none of them
set. All arrive as strings; a non-numeric value silently falls back to the
default (see [Known limits](#known-limits)).

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `reallocMax` | String | `0` | Max reallocated sectors, ATA attribute 5; also the grown-defect-list cap on SCSI. `0` is the right default — a drive that has reallocated anything is a drive to plan around. Raise only for a specific known-good drive. |
| `pendingMax` | String | `0` | Max pending (197) *and* offline uncorrectable (198) sectors. Keep at `0`; pending sectors are unread data. |
| `crcMax` | String | `10` | Max interface CRC errors (199). These are cable and connector faults, not disk faults — the alert text says to check the cable. The count never resets, so a drive with an old, fixed cable problem will sit above a low threshold forever. |
| `tempMax` | String | `55` | Max drive temperature in °C, from attribute 194 or 190. 55 suits spinning disks; NVMe routinely runs hotter and may want its own component instance. |
| `nvmeWearMax` | String | `90` | Max NVMe `Percentage Used`. Warranty life, not remaining life — 100 is the endurance rating, not a cliff. |
| `nvmeSpareMin` | String | `10` | Min NVMe `Available Spare` percent. Most drives set their own threshold near 10. |
| `failOnPastTrip` | Selection | `false` | `true` alerts on attributes showing `In_the_past`. Default reports them without alerting: a trip during a hot afternoon two years ago is not today's problem. |
| `failOnUnreadable` | Selection | `false` | `true` alerts when any one disk's SMART data cannot be read. Default reports it. Set `true` only on hosts with fixed internal disks and no removable media. |
| `smartctlTimeout` | String | `20` | Seconds per `smartctl` call. Used only where `timeout(1)` exists. A sleeping disk can take 10 s to answer. |

No customer-specific value is hardcoded. Every threshold is an input variable.

**`failOnPastTrip` and `failOnUnreadable` should be Selection type, not String** —
the valid values are exactly `true` and `false`, and anything else is read as
false.

## Exit behaviour

Datto monitors have exactly two states: exit `0` healthy, exit `1` alert.

| Host state | Result | Exit |
|---|---|---|
| All disks pass | `STATUS=All N disks healthy: SMART self-assessment passes, no failed attributes` plus max temperature | `0` |
| A disk fails self-assessment, has a failing attribute, or breaches a threshold | `STATUS=<per-disk reasons> (M of N disks healthy)`, plus a diagnostic block holding `smartctl -H -A` and the error and self-test logs for the failing disks only | `1` |
| Some disks unreadable, the rest healthy | `STATUS=M of N disks healthy`, unreadable ones named | `0` unless `failOnUnreadable` |
| **Every** disk unreadable | `STATUS=Check could not run: SMART data unreadable on all N disks` | `1` |
| A disk reports no SMART support | Counted healthy, named in the status | `0` |
| `smartctl` missing (Linux) | `STATUS=Check could not run: smartmontools is not installed` | `1` |
| No disks found | `STATUS=Check could not run: no disks found to check` | `1` |
| Windows | `STATUS=This monitor does not support Windows...` | `0` |
| An input variable is invalid | Silently replaced with its default | as above |
| The script dies unexpectedly | **No result block is emitted.** Datto renders this as an alert with no text in it | non-zero |

The last two rows are defects, not design. See [Known limits](#known-limits).

## How to tell it worked

Run it as a **Scripts** component first and read the raw job output. Expect:

- Exactly one `<-Start Result-> / <-End Result->` pair containing one `STATUS=`
  line with no space after the equals sign.
- Healthy: exit 0, a disk count, and `max temp NC`. **No diagnostic block** —
  healthy runs emit nothing beyond the result.
- Alert: exit 1, one phrase per failing disk (`/dev/sda: 8 reallocated sectors
  (max 0); 61C (max 55C)`), then a `<-Start Diagnostic->` block with the full
  `smartctl` output and the error and self-test logs for the failing disks only.

To exercise the alert path without a failing disk, set `tempMax=1`. Every disk
will breach, which confirms the per-disk phrasing, the count and the diagnostic
accumulation in one run.

## Test order

Never a customer first.

1. One internal Linux device, run as a **Scripts** component, raw output read.
   Then one macOS device — the two code paths share nothing but the output
   helpers. Then a host with an NVMe disk, since that branch is the one least
   like the original.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

- **No result block on unexpected death.** There is no `EXIT` trap, and the
  script does not run under `set -u`. A shell error or a signal exits non-zero
  with nothing on stdout, which Datto renders as an alert with no text. The
  Linux disk space monitor in this repository solves this with a trap; this one
  should adopt the same shape.
- **An invalid input variable is silently replaced with its default.** `num()`
  falls back on anything non-numeric, so `tempMax=fifty` monitors at 55 and says
  nothing. That means monitoring against a threshold nobody chose. Every other
  monitor here refuses to run instead.
- **`failOnPastTrip` and `failOnUnreadable` read anything unrecognised as
  false** — including `TRUE `with a trailing space, or a typo. Failing open.
- **No overall time budget for the diagnostic.** Individual `smartctl` calls are
  capped by `smartctlTimeout`, but the number of failing disks is not, and each
  one adds a second `smartctl -l error -l selftest`. On a JBOD with many failing
  disks this can exceed Datto's 60-second post-alert window.
- **`timeout(1)` is used when present and skipped when absent** — on macOS it is
  usually absent, so `smartctlTimeout` does nothing there.
- **A sleeping disk is woken.** `smartctl -H -A` spins up a standby drive. On a
  short monitor interval this defeats drive power management.
- **Temperature is judged against one threshold for every device family.** An
  NVMe at 60°C is normal; a spinning disk at 60°C is not.
- **Requires root**, and `smartmontools` on Linux. macOS needs neither — it uses
  `diskutil`, which reports far less: a pass/fail verdict with no attributes, no
  temperature and no wear.
- **Never run against:** a hardware RAID controller that does not pass SMART
  through, an NVMe disk behind a USB enclosure, macOS versions before whatever
  it was written on, or Alpine or any other busybox userland.

## Open questions

- **The result keyword.** This script emits `STATUS=`; the older monitors here
  emit `Alert=`. Confirm on the first script-mode run which one Datto's parser
  actually accepts, and correct this document either way.
- **Whether NVMe wants its own component instance** with a higher `tempMax`,
  rather than one threshold covering both device families.
- **Whether `failOnUnreadable` should default to `true` on servers** and `false`
  on laptops, i.e. two targeted instances rather than one.
- **Component `Level`** (access tier) is not standardised. Ask before saving.
