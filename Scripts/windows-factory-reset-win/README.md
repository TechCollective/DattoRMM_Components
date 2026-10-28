# Windows - Factory Reset [Win]

Starts **Reset this PC** on a Windows 10 or 11 workstation from Datto RMM, after a set of safety checks, so a client's "please wipe this laptop" request no longer needs a phone call to walk someone through Settings. Runs as SYSTEM on 64-bit Windows Pro, Enterprise or Education.

> **Status: Not Validated.** 2026-10-28. Written in this repository and reviewed against Microsoft's RemoteWipe documentation. The refusal paths and the server-OS preflight run in CI. The reset itself has not yet been run on a device through Datto; the first run must be on a throwaway internal machine.

## What it does

It calls the same Windows mechanism Intune uses for a remote wipe: the `MDM_RemoteWipe` class in the `root\cimv2\mdm\dmmap` WMI namespace. No Intune or MDM enrolment is needed. The bridge only answers to SYSTEM, which is the context Datto runs a component in.

**Nothing destructive happens unless all of these hold:**

1. `usrConfirm` is exactly `ERASE`. The default is `No`.
2. `usrConfirmSerial` equals the BIOS serial number of the device the job landed on, the same serial Datto and Autotask show on the device record. This is what stops a mis-click on the wrong device. A device whose BIOS reports a blank or placeholder serial (`To Be Filled By O.E.M.`, `Default string`) can never be confirmed and is refused.
3. `usrTicketNumber` looks like an Autotask ticket number (`T20261028.0001`).
4. Every preflight check below passed.

**Preflight** runs on every job, including `usrConfirm=No`, so a `No` run is a dry run that reports what would block the reset:

| Check | Passes when | Why |
|---|---|---|
| Operating system | Workstation OS, Windows 10 or later | Refuses servers and domain controllers outright. There is no override. |
| MDM bridge | The `MDM_RemoteWipe` instance exists | Absent on Windows Home, and when not running as SYSTEM. |
| Windows RE | `reagentc /info` reports `Enabled` | The reset runs from the recovery environment. Microsoft's Intune troubleshooting says a wipe fails when Windows RE is disabled. The check fails closed if the status line cannot be read (non-English Windows). |
| BitLocker | OS volume unprotected, or protected and `usrBitLockerKeySaved=Yes` | When protected, the recovery key protector **ID** is printed so the technician can match it in the key escrow. The key itself is never printed. |
| Power | Not on battery, or `usrIgnoreBattery=true` | A laptop that dies mid-reset is a reinstall. |

It also prints the logged-on user, if any, as information. It does not refuse on that.

When the gate is satisfied it invokes one method on the bridge, chosen by `usrResetMode`:

| Mode | Method | Same as | Notes |
|---|---|---|---|
| `RemoveEverything` (default) | `doWipeMethod` | Reset this PC → Remove everything, Clean Data = No, Delete Files = Yes | If interrupted, Windows tries to roll back to the pre-reset state. |
| `KeepMyFiles` | `doWipePersistUserDataMethod` | Reset this PC → Keep my files | Keeps user accounts and files. |
| `Protected` | `doWipeProtectedMethod` | Remove everything, uninterruptible | Microsoft documents it for lost or stolen devices: it keeps retrying until done, cleans the partitions on failure, and "may leave the device unable to boot". Not for a device the client intends to keep using. |

After Windows accepts the call the device reboots into recovery on its own within a few minutes. **The Datto agent is erased with everything else, so the device goes offline and does not come back.** The Datto job may show as timed out or lost because the reboot interrupts the result upload. The device dropping offline is the confirmation.

It makes no network calls of its own, writes no files and no UDFs. The ticket number is printed in the output so the job result can be pasted into the ticket.

**Operating rule: device-level quick job only.** Never schedule it against a filter, a site or a policy. Datto cannot enforce that; the `usrConfirmSerial` requirement is the technical backstop, because a single typed serial number matches only one device.

## Installing it in Datto

**Easiest:** download the **component-exports** artifact from this pull request's checks (or, once merged, from the [latest release](../../releases/latest)) and import `Windows - Factory Reset [Win].cpt`. Every input variable comes with it.

Or create it by hand with Automation → Components → New Component:

| Field | Value |
|---|---|
| Name | `Windows - Factory Reset [Win]` |
| Description | Starts Reset this PC remotely after safety checks; the device reboots, is erased and drops out of Datto RMM. Needs the serial number and ticket typed in. |
| Category | Scripts |
| Script type | PowerShell |
| Target OS | Windows (64-bit, 10 or 11, Pro/Enterprise/Education) |
| Level | 5 (Super) — proposed, see Open questions |
| Timeout | 600 seconds |
| Attachments | None |
| Post-condition | Warning if output contains `warn `. Not carried in the export; set by hand after importing. |

Paste the whole of `windows-factory-reset-win.ps1` as the script body, then add the input variables below.

## Input variables

No customer-specific value is hardcoded. Every variable is defined in `component.json`.

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrConfirm` | Selection | `No` | `No` runs the checks and changes nothing. `ERASE` resets the device if the checks pass and the serial matches. Anything else is refused. |
| `usrConfirmSerial` | String | *(blank)* | The device's serial number as shown in Datto or Autotask, case-insensitive. Blank or mismatched is refused. Type it per job; never leave a value saved in the component. |
| `usrTicketNumber` | String | *(blank)* | Must match `T` + 8 digits + `.` + 4 digits. Anything else is refused before any check runs. |
| `usrResetMode` | Selection | `RemoveEverything` | See the mode table above. `Protected` only for a lost or stolen device. |
| `usrBitLockerKeySaved` | Selection | `No` | Only consulted when BitLocker is on. `Yes` asserts the recovery key for the printed protector ID is escrowed. Leave `No` on the first, dry run and read the ID. |

The serial and ticket number are also printed on the `TICKET=` line of a successful run, so the job output cross-references to both records.
| `usrIgnoreBattery` | Boolean | `false` | `true` lets a laptop on battery proceed. Plug it in instead. |

Invalid values refuse the job with exit 1 rather than falling back to a default.

## Exit behaviour

| Outcome | STATUS line | Exit |
|---|---|---|
| Reset accepted by Windows; device will reboot and erase | `RESET_STARTED` | 0 |
| `usrConfirm=No` and every check passed | `PREFLIGHT_ONLY` | 0 |
| Bad or missing input, `usrConfirmSerial` does not match the device, or the device has no usable serial | `REFUSED` | 1 |
| A safety check failed (server OS, no bridge, Windows RE off, BitLocker key not confirmed, on battery) | `PREFLIGHT_FAILED` | 2 |
| Windows rejected the wipe method | `FAILED` | 3 |

Every non-zero exit changes nothing on the device. Each `STATUS` line is preceded by a `DETAIL` line saying why.

## How to tell it worked

A dry run (`usrConfirm=No`) on a healthy laptop looks like this:

```
Windows - Factory Reset [Win]
Device: EXAMPLE-LAPTOP
Serial: EXAMPLESERIAL01
Ticket: T20260101.0001
Mode:   RemoveEverything
Preflight:
  ok    Workstation OS: Microsoft Windows 11 Pro (build 26100)
  info  Logged-on user: EXAMPLE-LAPTOP\someone. They lose their session when the reset starts.
  ok    MDM RemoteWipe bridge is present.
  ok    Windows RE is enabled.
  info  BitLocker is ON for C:. Recovery key protector ID(s): {00000000-0000-0000-0000-000000000000}
  FAIL  BitLocker is on and usrBitLockerKeySaved is No. Confirm the recovery key matching the ID above is escrowed, then rerun with Yes.
  ok    On mains power (battery 100%).
DETAIL=1 check(s) failed; nothing was changed. First: BitLocker is on and ...
STATUS=PREFLIGHT_FAILED
```

That is the expected first result on an encrypted device. Match the ID in the escrow, rerun with `usrBitLockerKeySaved=Yes` and `usrConfirm=No` to see `Preflight passed.` and `STATUS=PREFLIGHT_ONLY`, then rerun with `usrConfirm=ERASE` and the serial.

The real run ends with:

```
Starting reset: RemoveEverything via MDM_RemoteWipe.doWipeMethod for ticket T20260101.0001
TICKET=T20260101.0001 HOST=EXAMPLE-LAPTOP SERIAL=EXAMPLESERIAL01 MODE=RemoveEverything METHOD=doWipeMethod
The device will reboot into recovery within a few minutes and drop out of Datto RMM. That is expected.
DETAIL=Reset accepted on EXAMPLE-LAPTOP, serial EXAMPLESERIAL01 (RemoveEverything). Record this in ticket T20260101.0001.
STATUS=RESET_STARTED
```

If the job result never arrives because the reboot cut it off, the device going offline a few minutes after the job was sent is the confirmation. If the device is still online after fifteen minutes, the reset did not start: check the Windows RE status by hand.

## Test order

Never a customer first.

1. **A throwaway internal Windows 11 VM or spare laptop.** Dry run first, then `ERASE`. Confirm it reboots, resets, and reaches the out-of-box setup screen. Try it once with BitLocker on so the key ID line and the `Yes` path are seen for real.
2. One internal device with a user logged on, to see the session-loss behaviour.
3. A client device, only with the ticket in hand and only ever as a device-level quick job.

The component tests in CI run on Windows Server, so they prove the refusals and the server-OS check, never the reset.

## Known limits

- **Reprovisioning is not covered.** After the reset the device sits at the out-of-box setup screen. A JumpCloud or Autopilot-joined device enrols itself; anything else needs someone at the keyboard. The reset removes the Datto agent, so the device must be re-onboarded.
- **The Windows RE check matches the English label** `Windows RE status:`. On a non-English Windows it fails closed and the technician checks `reagentc /info` by hand.
- **The job result may be lost to the reboot.** Documented above; nothing in the component can prevent it.
- **It does not write a note to the Autotask ticket.** That needs an Autotask credential, which does not belong in a component. The ticket number is printed in the output for the technician to paste, and the Autotask integration's job-result forwarding will carry it where that is configured.
- **OEM recovery content.** Forum reports say a reset can restore OEM bundled software from `C:\Recovery` on some machines. Not handled here.
- Windows Home has no MDM bridge; the preflight reports it and refuses.
- Needs PowerShell 5.1 and 64-bit Windows. The script uses `Sysnative` so it works from Datto's 32-bit PowerShell host.
- The reset has not been run through Datto yet. The method call is Microsoft's documented example, unchanged.

## Open questions

- **Level.** Proposed at 5 (Super) so only the highest Datto access tier can run it. Component levels are not standardised in this tenant yet; confirm at save time.
- **Whether the job result reaches Datto before the reboot.** The first real run will show whether `STATUS=RESET_STARTED` arrives or the job shows as lost. Update the "How to tell it worked" section with what actually happened.
- **Writing the note back to the ticket.** If job results should land on the ticket automatically, that is an Autotask-side or reporting-side integration, not a change to this component.

## Sources

- Microsoft, [RemoteWipe CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/remotewipe-csp): node semantics, which Settings option each maps to, the `doWipeProtected` warning.
- Microsoft, [MDM_RemoteWipe class](https://learn.microsoft.com/en-us/windows/win32/dmwmibridgeprov/mdm-remotewipe): the method names and the SYSTEM-only PowerShell example this component uses.
- Microsoft Q&A, [How to ensure wipe API is executed on Windows 10](https://learn.microsoft.com/en-us/answers/questions/1186677/how-to-ensure-wipe-api-is-executed-on-windows-10): the Windows RE requirement, quoting the Intune troubleshooting article.
