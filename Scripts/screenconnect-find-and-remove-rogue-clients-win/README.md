# ScreenConnect - Find and Remove Rogue Clients [Win]

A Windows script component that hunts for ScreenConnect clients that are not
ours and for the persistence left by the November 2026 "RelayTrap" campaign
against MSP ScreenConnect panels, and in Remove mode deletes them.

> **Status: Not Validated.** Written and reviewed 2026-11-11/12 in response to
> the campaign. Its logic has been run end to end against simulated machines
> (a clean one, an infected one, mistyped inputs) with the Windows cmdlets
> mocked; it has **not yet run on Windows**. The registry code in particular is
> first exercised by the pull request's Tier 1 run, and removal by the Tier 2
> steps on an internal VM.

## What it does

**Detect (the default) is read-only**, apart from the optional one-line UDF. It
makes no network calls. It checks:

- Every installed ScreenConnect client, found three ways (service name, service
  executable, and `ScreenConnect Client (...)` folders under both Program Files
  folders, so a client with no registered service still shows). Each is
  classified by its instance thumbprint, its relay host and its custom
  properties, and printed with the date its folder was created.
- ScreenConnect processes running from outside an installed client (a portable
  or support-session client).
- A `TrapWatch` scheduled task, or any task whose action mentions `RelayTrap`.
- `RelayTrapLiteAlert` or any `RelayTrap` value under Run and RunOnce: HKLM in
  **both** the 64-bit and 32-bit registry views, and every **loaded** user hive.
- `ProgramData\RelayTrap`, and `sckit-*` in the Windows TEMP, the SYSTEM
  profile's TEMP and every user profile's TEMP.
- The named payload files, and `sqlite3.exe`, in TEMP, ProgramData, Public,
  Downloads and the Startup folders (the kit drops `sqlite3.exe` to scrape
  browser sessions).
- Live TCP connections to the attacker IPs, and DNS cache entries for their
  domains.
- Defender path, process and extension exclusions that look like evasion
  (drive roots, TEMP, ProgramData, script hosts, executable extensions).
  Reported only, never changed.

**Remove** runs the same hunt, then, in this order:

1. Disables and stops the TrapWatch task (it reinstalls the client every 10
   seconds), stops any process whose command line runs something from
   `RelayTrap` or a `sckit-*` path, and stops every rogue client's service and
   processes.
2. Saves evidence to `ProgramData\TechCollective\SCHunt`: a findings log with
   the task XML and each removed client's service command line, and a zip of the
   payload folder, `sckit-*` items, payload files and removed client folders.
   Antivirus may quarantine the zip.
3. Deletes the task and the Run values, uninstalls the clients (MSI uninstall
   with a two-minute limit, then service delete, then the client folder), and
   deletes `ProgramData\RelayTrap`, the `sckit-*` items and the named payload
   files.
   If a client folder cannot be deleted because it denies access even to SYSTEM,
   Remove takes ownership of that one folder, resets its permissions to
   inherited and tries once more.
4. Waits 15 seconds and runs the hunt again; that re-check decides the result.

What Remove removes, and what it will not:

- **Removed:** every ScreenConnect client whose thumbprint can be read and is
  not in `usrKnownThumbprints` — including a vendor's or a previous MSP's. That
  is deliberate. Also any client or process carrying a published indicator.
- **Never removed:** a client whose thumbprint is in `usrKnownThumbprints`; a
  client on a relay in `usrKnownRelayHosts` (so a mistyped thumbprint cannot
  remove ours); `sqlite3.exe`; anything in Defender.
- **Support-session clients** are named after the session
  (`ScreenConnect Client ([guid])`), so they have no thumbprint to read and are
  judged by relay alone. On our relay they are ours: reported as `[ok] Ours`
  and left in place. On another relay they are not ours and Remove takes them
  off. If the relay cannot be read either, they are left for review.
- It only ever deletes folders that match `\ScreenConnect Client (...)`, the
  fixed `ProgramData\RelayTrap` path, `sckit-*` items or the exact payload file
  names.

It does not relaunch itself or change the execution policy. Where 64-bit and
32-bit Windows views differ it reads both explicitly, and it writes the UDF the
same way every other component here does, so the result does not depend on
which PowerShell host Datto starts it in.

The indicators are stored defanged (`[.]`) and refanged at run time. They live
in one region at the top of the script; update them there.

## Source and provenance

Written here. The approach follows two community detection scripts posted in
the r/msp thread "Active malware campaign abusing ScreenConnect"
(2026-11-11); neither stated a licence, so no code was copied. Indicators are
from Huntress's posts in that thread, with the Run value and payload names
credited there to Blackpoint.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | ScreenConnect - Find and Remove Rogue Clients [Win] |
| Description | Finds ScreenConnect clients that aren't ours plus RelayTrap persistence; Remove mode deletes them. Detect only writes the optional UDF. |
| Category | **Scripts** |
| Script type | PowerShell |
| Target OS | Windows |
| Level | *not standardised yet — decide at save time (see Open questions)* |
| Timeout | 1200 seconds |
| Attachments | None |

Paste the whole of `screenconnect-find-and-remove-rogue-clients-win.ps1` as the
script body, then add the input variables below. Or import the `.cpt` that CI
builds from `component.json`.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | Selection | Detect | Detect or Remove. |
| `usrKnownThumbprints` | String | *(blank)* | Our instance thumbprint(s), 16 hex characters each, comma-separated. Blank in Detect flags every client for review. **Required for Remove.** A published attacker thumbprint here is refused. |
| `usrKnownRelayHosts` | String | *(blank)* | Our relay host name(s): the `relay=` value a Detect run prints on the `[ok] Known:` line. **Required for Remove**, as the second lock that keeps our own client safe from a mistyped thumbprint. In Detect it also flags our thumbprint pointing at any other relay. |
| `usrUdfNumber` | String | *(blank)* | 1 to 300, or blank for no UDF. |
| `usrOverwriteForeign` | Selection | No | No leaves a UDF holding another component's value alone. |
| `usrCheckDefenderExclusions` | Selection | Yes | No skips the Defender check. |

No customer-specific value is hardcoded. Any invalid value is refused with exit
1; nothing falls back to a default.

## Exit behaviour

Any non-zero code shows the job as failed in Datto. That is on purpose: a
machine with something to look at should not be green.

| Code | Status | Means |
|---|---|---|
| 0 | `CLEAN` | Nothing found, and no ScreenConnect client other than ours. |
| 0 | `REMOVED` | Remove mode removed everything it found and the re-check found nothing left. (A DNS cache entry from before the removal does not count as left.) |
| 1 | `REFUSED` | An input variable is invalid. Nothing was checked. |
| 2 | `REVIEW` | No published indicator, but something a person should look at: a client from another instance (Detect), a client whose thumbprint cannot be read, a ScreenConnect process outside an installed client, a stray `sqlite3.exe`, a suspicious Defender exclusion, or our thumbprint on an unexpected relay. After a Remove, it means the removal finished and only such items remain. |
| 3 | `IOC_HIT` | Detect found a published indicator. Do not open a ScreenConnect session to this machine. |
| 4 | `REMOVE_INCOMPLETE` | Remove ran and something it should have removed, or a live attacker connection, is still there. |
| 5 | `ERROR` | The script stopped unexpectedly (the line before `STATUS=` says where), or PowerShell is older than 3. |

The last two lines of every run are `DETAIL=` and `STATUS=`.

## How to tell it worked

Healthy machine, Detect:

    [ok] Known: ScreenConnect client thumb=[ours] relay=[our relay] service='ScreenConnect Client ([ours])' state=Running installed=[date]
    [ok] Run values checked: HKLM 2 view(s), [n] loaded user hive(s), [n] value(s).
    UDF=WRITTEN Custom[N]: SCHunt: CLEAN | IOC 0 | Review 0 | [date time]
    STATUS=CLEAN

A machine with another instance's client:

    UDF=WRITTEN Custom[N]: SCHunt: REVIEW | IOC 0 | Review 1 | [date time] | SC [thumbprint]@[relay]
    STATUS=REVIEW

`HKLM 2 view(s)` on 64-bit Windows is the proof that both registry views were
read. A hit: `[!]` lines naming each indicator, then `STATUS=IOC_HIT`. A review
item: `[?]` lines, then `STATUS=REVIEW`. After Remove: the removal lines,
`--- Re-check after removal ---`, and `STATUS=REMOVED`, `STATUS=REVIEW` or
`STATUS=REMOVE_INCOMPLETE`.

Sort the fleet afterwards with a device filter on the UDF beginning
`SCHunt: IOC_HIT`, `SCHunt: REVIEW` or `SCHunt: REMOVE`. When something was
found, the summary ends with what it was: each ScreenConnect client that is not
ours as `SC [thumbprint]@[relay]`, and anything else by kind (`Sqlite`,
`Defender`, `ProcessKept`, `Task`, and so on). After a Remove, each client it
took off is kept there as `Removed SC [thumbprint]@[relay]`. Export the UDF column and group
on that to see which other instances are on the fleet and where. A machine where a
Remove run ever saved evidence keeps `| Evidence saved` on the end of its
summary, so a later clean Detect does not hide that it was once hit.

## Test order

Never a customer first.

1. One internal device, Detect. Read the output: our client on an `[ok] Known:`
   line, `HKLM 2 view(s)`, and the UDF showing in Datto after the next check-in.
2. One internal VM with planted indicators (an empty `C:\ProgramData\RelayTrap`
   folder, an empty `C:\Windows\Temp\sckit-test` file, a harmless scheduled task
   named `TrapWatch`, and a `RelayTrapLiteAlert` value under HKLM Run), Detect
   then Remove — the Tier 2 steps in `test.json`.
3. One site, one device, Detect. Then the fleet, Detect.
4. Remove only where Detect found something, and only after the panel itself
   has been checked and locked down.

## Known limits

- Windows only. The campaign's persistence is Windows-specific; Macs are not
  covered.
- Run values are read from HKLM and **loaded** user hives only. A profile that
  is not signed in is not checked.
- File searches go four folders deep, skip junctions and links, and stop after
  180 seconds in total (`$FileSearchSeconds`); a WARNING line says so if the
  limit was reached. A normal run prints `[ok] File search: [n] folders`.
- Written for PowerShell 5.1. It runs on 3.0 and 4.0 as well, where evidence is
  saved as a log only (no zip).
- A client with neither a readable thumbprint nor a readable relay is reported
  for review and left alone. A client that is removed but lives in a
  non-standard folder has its service deleted and its folder left and reported.
- Old support-session clients left by our own instance are not cleaned up.
- **Leftovers of a removed client** — a client folder with no service, or a
  service Windows has marked for deletion, with nothing running from it — are
  listed as `[i]` and do not change the result. ScreenConnect's logon DLL stays
  loaded until a restart, so the folder often cannot be deleted straight after
  an uninstall. Remove resets the folder's permissions, tries again, and if that
  fails asks Windows to delete it at the next restart. A leftover folder that
  carries a published attacker ID is still reported as a hit.
- If a client is running again seconds after it was uninstalled, the result is
  `REMOVE_INCOMPLETE` and `DETAIL=` says something on the machine is putting it
  back. Find that first (another management agent, a scheduled task, a policy).
- A technician's own workstation shows a review item while the ScreenConnect
  host client is open, unless `usrKnownRelayHosts` is given.
- `sqlite3.exe` is legitimately bundled by plenty of software. It is a review
  item, never a hit, and only when it is in a TEMP folder or was created on the
  disk since 2026-11-01 (`$SqliteSince` in the indicators region). Older copies
  elsewhere are listed as `[ok]` and not flagged. A copy whose creation date was
  deliberately back-dated would be missed.
- The indicators are a snapshot from 2026-11-11 and will change.
- The Tier 1 expectation of `CLEAN` on GitHub's Windows runner assumes the image
  has no `sqlite3.exe` within four levels of ProgramData or TEMP. If the first
  run reports `REVIEW` for that reason, the expectation changes to match, not
  the detection.

## Open questions

- **Level.** Not standardised. Remove deletes software fleet-wide, so a higher
  Level than read-only components is worth deciding at save time.
- Whether `usrKnownThumbprints` and `usrKnownRelayHosts` should come from Datto
  account variables rather than being typed at job time.
