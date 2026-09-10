# Active Directory - Domain Trust Secure Channel [Win]

A Datto RMM custom monitor for domain-joined Windows hosts. Verifies the
machine's secure channel to its Active Directory domain using two independent
checks, `nltest /sc_verify` and `Test-ComputerSecureChannel`.

> **Status: Not Validated.** Imported from the Datto Component Library on
> 2026-09-10 as part of the initial repository organisation. It has not been
> reviewed against our monitor contract or security checklist, and the review
> below is a reading of the script only — it has not been re-run. Treat the
> defects in [Known limits](#known-limits) as unfixed.

> **This monitor cannot currently alert.** Every path exits `0`. See
> [Exit behaviour](#exit-behaviour) before targeting it at anything.

> **Currently saved in Datto as `Domain Trust`** (component uid
> `32794eee-0268-4724-8b4d-c9069ee0931b`, version 4). That name carries no OS
> tag and no condition. Rename it to the heading above at the next edit; the
> script body does not change.

---

## Contents

| Path | What it is |
|---|---|
| `active-directory-domain-trust-secure-channel-win.ps1` | The component body. This file is the source of truth — paste it into Datto, don't edit it there. |
| `active-directory-domain-trust-secure-channel-win.cpt` | Datto export, taken 2025-01-08. Byte-identical to the script above. Carries no attachment. |
| `README.md` | This file. |

---

## What it does

1. Reads `Win32_ComputerSystem` via WMI to get `PartOfDomain` and `Domain`.
2. If the host is not domain-joined, reports that and stops.
3. Runs `nltest /sc_verify:<domain>` and records whether it returned 0.
4. Runs `Test-ComputerSecureChannel` and records whether it returned true.
5. Reports success only if **both** passed; otherwise reports which one failed.

**It is read-only on the endpoint.** `Test-ComputerSecureChannel` is called
without `-Repair`, so nothing is reset and no password is changed. It does make
network calls: both checks contact a domain controller, which is the point of
the check.

Running two independent checks is deliberate. `nltest /sc_verify` and
`Test-ComputerSecureChannel` fail in different ways — a DC that answers one and
not the other is itself a finding — so a disagreement between them is reported
rather than collapsed into a single verdict.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Active Directory - Domain Trust Secure Channel [Win]` |
| Description | Verifies the machine's AD secure channel with both nltest and Test-ComputerSecureChannel, and reports if either fails. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | PowerShell |
| Target OS | Windows, domain-joined |
| Level | `securityLevel 5` in the current export — not standardised yet, decide at save time |
| Timeout | 3600 s in the current export |
| Attachments | None |
| Monitor interval | Not set in the export; decide at save time |

Paste the whole of `active-directory-domain-trust-secure-channel-win.ps1` as the
script body. There are no input variables to add. Importing the `.cpt` does the
same thing.

The description currently stored in Datto is two lines of raw command names
(`Test-ComputerSecureChannel` / `nltest /sc_verify:$domain`). Replace it with the
one-line description above at the next edit — a description is what a technician
reads in the alert list.

## Input variables

None. The domain name is read from the machine itself rather than configured,
which is correct here: a hardcoded domain name would be a customer-specific
value, and this repository is public.

There is consequently nothing to tune. Every threshold-like decision in this
script is a pass/fail from a Windows API.

## Exit behaviour

Datto monitors have exactly two states: exit `0` healthy, exit `1` alert.

**This script never exits `1`.** `main` returns normally on every path and
PowerShell exits `0`. The table below is what the script *reports*; the exit
column is what Datto actually acts on.

| Host state | Reported | Exit |
|---|---|---|
| Not joined to a domain | `STATUS=Computer is not joined to a domain.` | `0` |
| Both checks pass | `STATUS=Secure channel is functioning correctly...` | `0` |
| Either or both checks fail | `STATUS=Secure channel verification failed for domain <d>` plus a `DETAILS=` line | **`0` — no alert is raised** |
| WMI unavailable or `Win32_ComputerSystem` unreadable | `$computerSystem` is null, `PartOfDomain` reads as false, reports "not joined to a domain" | `0` |
| `nltest.exe` missing | Caught, `INFO=nltest encountered an error: ...`, treated as a failed check | `0` |
| The script dies unexpectedly | **No result block is emitted.** Datto renders this as an alert with no text in it | non-zero |

So the only condition that currently produces an alert is the script crashing.
This is the first thing to fix; until it is fixed, the component is a reporting
script, not a monitor.

## How to tell it worked

Run it as a **Scripts** component first and read the raw job output. On a
healthy domain-joined host, expect the `nltest` transcript, then:

```
<-Start Result->
STATUS=Secure channel is functioning correctly. Both nltest and Test-ComputerSecureChannel passed for domain <domain>.
<-End Result->
```

On a broken secure channel, expect `INFO=` lines from the failing check, then a
result block containing both a `STATUS=` and a `DETAILS=` line.

To exercise the failure path safely, use a lab machine whose computer account has
been reset or removed in AD. Do not test this by breaking a real machine's trust
— the repair is a rejoin.

## Test order

Never a customer first.

1. One internal domain-joined device, run as a **Scripts** component, raw output
   read. Then one non-domain-joined device, to confirm that branch.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

Read as unfixed defects, in rough order of how much they matter.

- **It never alerts.** No path calls `exit 1`. See
  [Exit behaviour](#exit-behaviour).
- **"Cannot tell" is reported as "not joined".** If WMI is unavailable,
  `$computerSystem` is null and `-not ($computerSystem.PartOfDomain)` is true, so
  a host whose state could not be read is indistinguishable from a workgroup
  machine. Both report healthy.
- **No result block on unexpected death**, so a crash renders as an alert with
  no text.
- **The result block carries two lines.** The failure path emits `STATUS=` and
  `DETAILS=` inside one marker pair. Our contract is one `STATUS=` line; confirm
  what Datto's parser does with the second.
- **`INFO=` lines are written outside the result markers**, and `nltest` writes
  its own transcript to stdout unsuppressed. Both land in the ticket note ahead
  of the result block.
- **`Get-WmiObject` is deprecated** and absent from PowerShell 6 and later. Fine
  on the Windows PowerShell 5.1 that Datto uses today, but it is the line that
  breaks first if the agent ever moves to PowerShell 7.
  `Get-CimInstance -ClassName Win32_ComputerSystem` is the replacement.
- **No timeout on `nltest`.** An unreachable DC can hang the script until
  Datto's own component timeout.
- **Never run against:** a read-only domain controller, a machine in a resource
  forest or across a one-way trust, or any non-English Windows locale.

## Open questions

- **Provenance is unrecorded.** Nothing in the script or the export names an
  author or an upstream source. Confirm it was written in-house before treating
  this repository's GPL-3.0 licence as settled for it.
- **Should a non-domain-joined host alert?** If the component is only ever
  targeted at a domain-joined device group, "not joined" is a real finding and
  should probably exit `1`. If it can land on workgroup machines, it should exit
  `0` quietly. That decision determines the fix.
- **Should a disagreement between the two checks alert differently** from both
  failing? Both currently produce the same verdict.
- **Component `Level`** (access tier) is not standardised. Ask before saving.
