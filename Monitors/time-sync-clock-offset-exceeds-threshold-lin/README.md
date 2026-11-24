# Time Sync - Clock Offset Exceeds Threshold [Lin]

A Datto RMM custom monitor for Linux. Alerts when the clock is not
synchronised, or is more than a set number of seconds off NTP time.

> **Status: Not Validated.** Rewritten 2026-11-24 from the `Time Monitor [LIN]`
> component already in our Component Library. Run against the real
> systemd-timesyncd on one Ubuntu 24.04 machine, and against stand-ins for
> chronyd and ntpd in the Tier 1 test. Not yet run on a client device.

---

## Contents

| Path | What it is |
|---|---|
| `time-sync-clock-offset-exceeds-threshold-lin.sh` | The component body. Paste it into Datto; don't edit it there. |
| `component.json` | Datto metadata and input variables; CI builds the `.cpt` from it. |
| `test.json`, `tests/` | The Tier 1 test and its shims for `chronyc`, `ntpq` and `timedatectl`. |

## What it does

Asks the time service running on the machine for its own measured offset:

| Service | Default on | Asked with |
|---|---|---|
| chronyd | RHEL, Rocky, Alma, Fedora, Ubuntu 25.10 and later | `chronyc -c tracking` (System time) |
| ntpd or ntpsec | older or hand-built machines | `ntpq -c 'rv 0 offset,leap'` |
| systemd-timesyncd | Ubuntu 24.04 and earlier, Debian 12, Arch | `timedatectl timesync-status` (Offset) |

It tries them in that order and uses the first one that answers. It then reads
the kernel's sync flag (`timedatectl show -p NTPSynchronized`) where
`timedatectl` exists, which works whichever service is keeping time.

**Read-only. No network call.** The services already measure the offset against
their own servers; this only reads what they report.

## Source and provenance

Replaces our own `Time Monitor [LIN]` (version 2 in Datto, author not
recorded). It is a rewrite, not a patch. The original:

1. Multiplied the offset by 60, though `ntpdate` already reports seconds, so it
   alerted on any drift over one second whatever the threshold said.
2. Captured its own error message as the offset when the NTP server did not
   answer, then did arithmetic on that text.
3. Needed `ntpdate` and `bc`, neither installed on a stock Ubuntu 24.04, and
   read the offset from a fixed field of `ntpdate` output, which differs
   between versions.
4. Hard-coded the server (`pool.ntp.org`) and the 60-second threshold.
5. Sent no diagnostic with the alert.

The one thing it did that this does not: it checked against an outside server,
so it could catch a time service synced to a wrong source. See Known limits.

Untarget `Time Monitor [LIN]` when this goes live. Do not run both.

## Installing it in Datto

Import the `.cpt` CI builds for the pull request, which carries the input
variable, or create it by hand:

| Field | Value |
|---|---|
| Name | `Time Sync - Clock Offset Exceeds Threshold [Lin]` |
| Description | Alerts when the clock is not synchronised, or is more than a set number of seconds off NTP time. Read-only. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Bash |
| Target OS | Linux |
| Timeout | 120 seconds |
| Attachments | None |
| Monitor interval | Hourly is plenty; a clock drifts slowly |

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrThreshold` | String | `60` | Whole seconds, 1-86400. Alerts when the offset is **more than** this. Kerberos (Active Directory logons) fails past 300 seconds, so stay well under that on domain-joined machines. |

Nothing customer-specific is hard-coded. An invalid value (not a whole number,
or out of range) is refused with an alert saying so, never replaced with the
default.

## Exit behaviour

| Host state | Result |
|---|---|
| Synced, offset at or under the threshold | Exit 0, `STATUS=OK - clock is 0.049s off NTP time (systemd-timesyncd), within 60s` |
| Synced, service has not reported an offset yet | Exit 0, `STATUS=OK - clock synchronised by …; offset not reported yet` |
| Offset over the threshold | Exit 1, `STATUS=ALERT - clock is 75.500s off NTP time (chronyd), over the 60s threshold`, raw service output as the diagnostic |
| Service reports the clock not synchronised | Exit 1, `STATUS=ALERT - clock is not synchronised (…)` |
| No service readable, but `timedatectl` says synced | Exit 0, `STATUS=OK - clock synchronised (timedatectl NTPSynchronized=yes); …` |
| No time service running | Exit 1, `STATUS=ALERT - no running time sync service found …`, which tools were present as the diagnostic |
| `awk` missing, or `usrThreshold` invalid | Exit 1, `STATUS=Check could not run: …` |
| The script dies or is killed | Exit 1 (143 on TERM), `STATUS=Check failed before it could decide (…)`, from the EXIT trap |

Each service call has a 10-second timeout where `timeout` exists, so a hung
daemon moves the check on to the next service rather than hanging the job.

## How to tell it worked

Run it as a **Scripts** component on one device first. A healthy machine prints
one `STATUS=OK - clock is …s off NTP time (<service>), within 60s` line and
exits 0. The service named should be the one you expect for that distro.

## Test order

1. One internal Linux device, as a Scripts component, raw output read.
2. One site, one device in it, as a monitor.
3. Wider, only after the first two.

## Known limits

- **It trusts the local time service.** A service synced to a wrong source
  reports a small offset and the monitor stays green. Catching that needs an
  outside server and a network call, which this deliberately does not make.
- **openntpd, busybox ntpd and containers without systemd** are not read. On
  those it reports OK if `timedatectl` says the clock is synced, without an
  offset, and otherwise alerts "no running time sync service found".
- **systemd older than 239** (CentOS 7, Ubuntu 18.04 has 237) has no
  `timesync-status`. With timesyncd there it reports OK on the kernel's sync
  flag alone, without an offset.
- Tested on Ubuntu 24.04 only. The chronyd and ntpd paths are tested against
  shims of their documented output, not the real daemons.

## Open questions

- Level: the original used security level 1; kept as-is.
