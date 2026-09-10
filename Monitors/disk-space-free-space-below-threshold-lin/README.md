# Disk Space - Free Space Below Threshold [Lin]

A Datto RMM custom monitor for Linux. Checks every measurable filesystem against
a percent-used threshold and an optional free-GB floor, and understands btrfs
metadata exhaustion and LVM thin pool exhaustion, which `df` alone cannot see.

> **Status: Not Validated.** Created 2026-09-09. Reviewed against the monitor
> contract and security checklist the same day; nine findings fixed. Not yet run
> outside a test container.

---

## Contents

| Path | What it is |
|---|---|
| `disk-space-free-space-below-threshold-lin.sh` | The component body. This file is the source of truth — paste it into Datto, don't edit it there. |
| `README.md` | This file. |

No `.cpt` export yet — this component has not been saved into Datto. Export one
once it has, so its six input variables can be restored without retyping.

---

## Source and provenance

Derived from the Datto ComStore component **"Unified Disk Space Monitor"**
(build 55, authored by seagull / Datto Labs, December 2024). That component is a
single script carrying three independent branches — Windows batch, macOS bash,
Linux bash — behind a `goto WindowsScript` trick.

This is a **Linux-only replacement for the Linux branch**. It is not a patch to
the ComStore component; ComStore components cannot be edited in place, so this is
a new Component Library entry and the ComStore one should be untargeted from
Linux devices when this goes live.

Reason for the split, per our naming standard: the three branches share nothing
but a name, and the Windows branch is dead on Windows 11 / Server 2025 and newer
because it depends on WMIC, which Microsoft removed. Datto's own script prints a
notice telling you to use native Windows disk monitoring instead. Windows and
macOS should be handled separately.

## What it does

Reads `/proc/mounts`, classifies every mount by filesystem type, and checks the
ones where free space is both measurable and actionable. For each it takes
`df -Pk`'s own `Use%` and available space, and raises an alert when a filesystem
is at or above the percentage threshold **and** (optionally) below a minimum free
GB floor.

It makes no changes to the endpoint. It reads mount tables, runs `df`, and
optionally `btrfs filesystem usage`, `dmsetup status` and a depth-1 `du`.
Read-only. No network access of any kind.

### Beyond a plain percentage check

- **Free-space floor** (`usrMinFreeGB`) — a multi-TB volume at 91% can have more headroom than a system disk has capacity. Both conditions must be true to alert.
- **Btrfs** — additionally reads `btrfs filesystem usage`. Btrfs can refuse writes with `ENOSPC` while `df` still shows free space, when metadata chunks are near full and no unallocated space remains to carve new ones from. Alerts on that combination.
- **LVM thin pools** — `df` reports the thin *volume's* virtual size; the pool underneath can be full while the volume looks half empty, and pool exhaustion means a read-only filesystem or corruption. Checked separately via `dmsetup status --target thin-pool` (data and metadata).
- **Filesystems it cannot measure** — ZFS, NFS, CIFS, fuse and unrecognised types are named in the status text rather than silently dropped. The original filtered on `grep /dev/`, which dropped all of these before the loop, so a ZFS or NFS host reported healthy forever.
- **Local filesystems mounted read-only** — named in the status text. ext4 and xfs remount themselves read-only after I/O errors, so a silent skip would mute the monitor exactly when something is wrong. Reported, not alerted; silence a deliberately read-only mount with `usrExclude`.
- **Pseudo-filesystems** are skipped silently: a full tmpfs or squashfs is not something a technician can act on.

## Defects in the original this fixes

1. **Used-percentage formula.** The original computed `1 - (avail/size)` instead of `used/(used+avail)`. Wherever available space is decoupled from raw size — ext4 root reserve, filesystem quotas, btrfs allocation profiles — this overstates usage. Measured on a quota-backed ext4 volume: `df` reported 29% used, the original's formula produced 88%.
2. **`usrDisks` accepted only one disk on Linux.** `arrDisks=(${arrDisks[@]} "$usrDisks")` quoted the whole string into a single array element, so `/dev/sda1 /dev/sdb1` became one bogus path and `df` failed. The macOS branch used `read -r -a` and was correct.
3. **No exclude mechanism**, so backup targets could not be carved out.
4. **Result payload was not `STATUS=`.** The original emitted `X=STATUS: ...`. Verify on the first test run — see Open questions.
5. **Malformed result on the invalid-threshold path** — it printed a bare sentence with no `STATUS=` prefix, which produces an alert with no text.
6. **Diagnostic block on every run**, including healthy ones. Noise in every ticket.
7. **`df` output parsed without `-P`.** Long device names wrap onto a second line in default `df` output and break `awk` field parsing.
8. **`--output=` requires GNU coreutils 8.21+**, absent on older distros and on busybox. Replaced with POSIX `df -Pk`.
9. **Threshold comparison inconsistent across branches** — Linux and macOS used `-gt` (alerts above the value), Windows used `geq` (alerts at the value). This uses `>=` and says so in the alert text.
10. **Whole classes of filesystem silently unmonitored** — see above.

## Review findings on our own version (all fixed 2026-09-09)

Held to the same bar as anything adopted from outside.

**Contract violations:**

- **No result block on unexpected death.** A shell error or signal exited non-zero with nothing on stdout, which Datto renders as an alert with no text — the defect `monitor-contract.md` names first. Fixed with an `EXIT` trap that emits a fallback result and never reports success. Verified against `SIGTERM`, an unbound variable under `set -u`, and total tool absence.
- **Diagnostic could exceed the 60-second post-alert window.** `du` was capped per mount but the number of mounts was unbounded, as was the per-filesystem btrfs detail loop. Fixed: a 30-second overall budget checked between sections, per-call caps of 5–10s, `du` limited to two mounts and btrfs detail to three filesystems. Measured at 15s worst case with every external command stubbed to hang.
- **Result payload could become multi-line.** `/proc/mounts` octal-escapes a newline in a path as `\012` and `printf '%b'` turns it back into a real newline; `usrDisks` was also echoed verbatim into the no-match message. Fixed by flattening whitespace in `emit_result`.

**Other findings:**

- `emit_result` sanitised with `tr`, so a missing `tr` produced an empty message — the code reporting a missing binary depended on one. Now pure parameter expansion.
- Dependency checks ran *after* the `tr`-based input normalisation, so a missing `df` was reported as "usrThreshold must be a whole number". Checks moved first.
- `usrPoolThreshold` and `usrUnknownFs` silently coerced bad values to defaults, i.e. monitored against a threshold nobody chose. Now refuse loudly, consistent with `usrThreshold`.
- A local filesystem mounted read-only was skipped silently (see above).
- `dmsetup` present but failing — it needs root, and script-mode testing often is not — was indistinguishable from "this host has no thin pools". Now reported as not verified.
- De-duplication used glob matching where it meant string equality, so a device name containing a glob metacharacter could suppress an unrelated filesystem. Now exact comparison.

**Checklist sections with nothing to report:** no code pulled in at run time (no
network access at all), no embedded secrets or hardcoded client values, no
phoning home, no obfuscation, no defence evasion, no third-party or attached
binaries. Blast radius: read-only, stateless, no reboot, no temp files; worst
realistic outcome is added I/O from the capped `du` on an already-busy volume,
plus a false alert.

## Input variables

| Variable | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrThreshold` | String | `90` | 1–99. Percent used. Refuses to run on a bad value; tolerates a typed `%`. |
| `usrMinFreeGB` | String | `0` | Whole GB. `0` disables the floor and gives legacy percent-only behaviour. **Set to 50 on rollout.** |
| `usrDisks` | String | `ALL` | `ALL`, or a space-separated list of mount points or devices. Globs allowed. |
| `usrExclude` | String | *(empty)* | Space-separated glob patterns, matched against both mount point and device. Only applies when `usrDisks=ALL`. Also the way to silence a deliberately read-only mount. |
| `usrUnknownFs` | Selection | `warn` | `warn` (name them in the status, do not alert) / `alert` / `ignore`. |
| `usrPoolThreshold` | String | `85` | 1–99. Percent for btrfs metadata and LVM thin pool data/metadata. |

No client-specific value is hardcoded. Every threshold is an input variable.

## What "could not tell" means here

Deliberate, because it matters for triage:

- **Cannot read the mount table, a required binary is missing, an input variable is invalid, or `df` failed on every filesystem** → exit 1 with `STATUS=Check could not run: <reason>`. Not knowing whether a disk is full is dangerous.
- **The script dies unexpectedly** → exit 1 with `STATUS=Check failed before it could measure anything`. Never green.
- **A filesystem type it cannot measure** (ZFS/NFS/fuse) → named in the status text, exit governed by `usrUnknownFs`, default `warn` (no alert). Alerting by default would flood any ZFS estate; hiding it is what the original did wrong. `warn` makes it visible without paging.
- **A local filesystem mounted read-only** → named in the status text on both paths, does not alert.
- **Btrfs present but `btrfs-progs` missing**, or **`dmsetup` failing** → named in the status text on both paths, does not itself alert.
- **A single mount that cannot be measured while others can** → counted and named as "unreadable" in the status, does not alert. Usually a race between reading `/proc/mounts` and running `df`, so alerting would be flappy.

## How to tell it worked

Run it as a **Scripts** component first and read the raw job output. Expect:

- Exactly one `<-Start Result-> / <-End Result->` pair containing one `STATUS=` line with no space after the equals sign.
- Exit 0 on the healthy path, and a status line naming the fullest filesystem with its percentage and free GB.
- Exit 1 on the alert path, plus a `<-Start Diagnostic->` block: thresholds in force, filesystems checked, anything read-only or not measured, btrfs detail, `df -PhT`, `btrfs filesystem usage`, thin pool status, and a depth-1 `du` of up to two breaching mounts.
- Healthy runs emit no diagnostic block.

Diagnostic sections are ordered cheapest-and-most-certain first, so if the budget
runs out you lose the `du` output rather than the threshold list.

Measured runtime: 50 ms healthy, 660 ms on the alert path with the full
diagnostic, 15 s worst case with every external command hanging.

## Test coverage completed

17-case regression sweep, all passing, each asserting exit code plus the result
block contract (exactly one `STATUS=` line, no space after the equals, one marker
pair): healthy and alerting paths, floor suppression, all three `usrUnknownFs`
modes, read-only silencing via `usrExclude`, single and multi-element `usrDisks`,
`usrDisks` matching nothing, excluding everything, four invalid-input cases, a
typed `%`, and mixed-case input.

Verified against real filesystems (loop-mounted ext4, bind mounts, a fuse mount,
read-only ext4) and with stubbed `btrfs-progs` and `dmsetup` for the paths this
container cannot host: btrfs metadata exhaustion, btrfs healthy, btrfs tooling
absent, btrfs subvolume de-duplication, and a thin pool at 92%. Fault injection
for the exit trap and the diagnostic budget.

**Not yet verified on real hardware:** actual btrfs and ZFS volumes, a real LVM
thin pool, and any non-Debian distro.

## Known environment requirements

- **`bash`, not POSIX sh** — uses arrays and herestrings. Fine on Debian, Ubuntu, RHEL and SUSE. Alpine ships busybox `ash` and would need bash installed.
- `df`, `awk` and `tr` are hard requirements and are checked explicitly.
- `sort -rh` and `du --max-depth` are GNU spellings. On busybox they fail into an empty diagnostic section rather than breaking the alert.
- `timeout(1)` is used when present and skipped when not.

## Open questions

- **The result keyword.** Our `monitor-contract.md` says the payload line is `STATUS=`. The ComStore original emits `X=STATUS: ...`, which is a widespread community convention. This script uses `STATUS=`. Confirm on the first script-mode test run which one Datto's parser actually accepts, and correct this document either way.
- **Component Level** (access tier) is not standardised. Ask before saving.
- **A "filesystem remounted read-only" monitor** is the right home for alerting on the read-only condition this one only reports. Not written.
