# Windows 11 - Apply Clean UI Defaults [Win]

Applies the taskbar, Start menu, Explorer, privacy, animation and AC power
settings a technician would otherwise click through on every new Windows 11
setup. PowerShell, runs as SYSTEM, Windows 11 workstations only.

> **Status: Not Validated.** Written 2026-10-29 from the Settings toggles we
> apply by hand; not yet run on a device. Tier 1 (GitHub runner, Windows Server)
> covers input handling, the registry writes and idempotence. The visible result
> needs a Windows 11 device.

## What it does

Writes the per-user registry values that the Settings app itself writes. Every
per-user change is a **preference, not a policy** — a user can turn any of them
back on in Settings. It makes no network calls and installs nothing.

Per user, applied to every local profile (SIDs `S-1-5-21-*` with a profile
folder) and to the Default profile so later users inherit it:

- Taskbar: Search hidden, Task view off, Widgets off, Copilot button off, icons aligned left, Pen menu icon off
- Start: recommendations for tips/new apps off, account-related notifications off, "More pins" layout
- Privacy: Start/Settings/lock-screen suggestions and tips off, silently installed promo apps off, Advertising ID off, the post-setup "Get even more out of Windows" screen off
- Explorer: classic (Windows 10) right-click menu; file extensions shown
- Visual effects: the Accessibility "Animation effects" set off — menu and tooltip fades, window minimise/maximise animation, taskbar animations. Font smoothing, thumbnails and drop shadows are untouched.

Profiles that are logged on are written in place (`HKEY_USERS\<SID>` and
`<SID>_Classes`). Profiles that are not are written by loading `NTUSER.DAT` and
`AppData\Local\Microsoft\Windows\UsrClass.dat`, then unloading them. The
context-menu key lives in the Classes hive, which is why both are loaded.

Machine-wide:

- `HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience = 1`. The only policy it sets; Edge's first-run flow has no preference equivalent.
- `powercfg /change standby-timeout-ac 0` and `hibernate-timeout-ac 0` on the active plan. Display timeout and every on-battery value are left alone.

Then, by default, it restarts Explorer in every logged-on session so the
context menu and animation changes apply now. Killing `explorer.exe` from SYSTEM
does not reliably bring the shell back, so the script records which user owns
each shell, kills them, and relaunches `explorer.exe` in any session left
without one through a one-shot interactive scheduled task running as that user,
which it then deletes.

**Taskbar pins are not touched.** Unpinning Edge/Store/Copilot is left to the
technician.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Windows 11 - Apply Clean UI Defaults [Win]` |
| Description | Applies our standard Windows 11 taskbar, Start, Explorer, privacy and animation preferences to every profile and the Default profile, hides Edge first-run, sets sleep/hibernate on AC to Never, and restarts Explorer. |
| Category | **Scripts** |
| Script type | PowerShell |
| Target OS | Windows |
| Level | *not standardised yet — decide at save time; `component.json` carries 3 as a placeholder* |
| Timeout | 300 seconds |
| Attachments | none |

Paste the whole of `windows-11-apply-clean-ui-defaults-win.ps1` as the script
body, then add the input variables below.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrScope` | Selection: `All`, `DefaultOnly` | `All` | `DefaultOnly` leaves every existing user untouched. Any other value is refused (exit 1). |
| `usrNeverSleepOnAC` | Boolean | `true` | `false` skips the power change entirely. |
| `usrRestartExplorer` | Boolean | `true` | `false` = changes apply at the user's next sign-in. Use `false` if a user is mid-work. |
| `usrAllowUnsupportedOs` | Boolean | `false` | `true` runs on Windows 10 or a server. The Windows 11-only values are written and ignored there. Testing only. |

Nothing customer-specific is hardcoded. Booleans are compared as the text
`true`/`false`; anything else is refused with exit 1.

## Exit behaviour

| Code | `STATUS=` | Meaning |
|---|---|---|
| 0 | `APPLIED` | Every targeted profile and the machine-wide settings were written |
| 1 | `REFUSED` | Bad input. Nothing changed. |
| 2 | `PREFLIGHT_FAILED` | Not a Windows 11 workstation and `usrAllowUnsupportedOs` is `false`. Nothing changed. |
| 3 | `PARTIAL` | At least one profile could not be loaded/written or a machine-wide step failed. The others were written. Lines starting `ERROR:` say which. |

A Datto post-condition on `ERROR:` (found) turns a `PARTIAL` run orange even
if someone later changes the exit codes.

## How to tell it worked

Healthy output, one line per profile then the machine-wide steps:

    OS: Microsoft Windows 11 Pro build 26100 (workstation)
    Default profile: changed 28, already correct 0 (from disk)
    Profile jdoe: changed 28, already correct 0 (loaded)
    Edge first-run experience hidden (policy): changed
    Power: active plan sleep and hibernate on AC set to Never (display and battery settings untouched).
    Explorer restarted in 1 session(s) (1 relaunched by task) so the context menu and visual changes take effect.
    DETAIL=2 of 2 profile target(s) written, 28 setting(s) per profile
    STATUS=APPLIED

A second run shows `changed 0, already correct 28` for every profile. On the
device: taskbar icons left-aligned, no Search box, Widgets or Task view, and
right-click on the desktop shows the full Windows 10 menu.

## Test order

Never a customer first.

1. One internal Windows 11 device with a user signed in. Check the Tier 2 items by hand: taskbar, right-click menu, Settings → Accessibility → Visual effects shows Animation effects off, and that Explorer came back for the signed-in user.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

Intended use is a one-shot quick job during setup, after the user's profile
exists. It is idempotent, so re-running on a machine that already has the
settings is harmless.

## Known limits

- **Not run on a real device yet.** The registry value names are the ones the Windows 11 Settings app writes as of 24H2; Microsoft renames or blocks some between releases. Known risk: recent builds have been seen reverting the Widgets preference (`TaskbarDa`) — if that shows up, the fix is the `Dsh\AllowNewsAndInterests` machine policy, which greys the toggle out and is a deliberate step up from "preference".
- The classic context menu key is a documented-by-the-community override, not a supported setting. It works through 24H2; verify on each new feature update.
- Only local profiles with a folder are touched. Roaming or mandatory profiles are out of scope.
- A profile whose `NTUSER.DAT` cannot be loaded (locked by a stale session, corrupt) is reported as `ERROR:` and skipped; the run exits 3.
- Explorer relaunch uses the ScheduledTasks module (Windows 8+). If registering the task fails, the script says so and the user signs out and back in.
- Windows Server and Windows 10 are refused by default. With `usrAllowUnsupportedOs=true` the script runs but the Windows 11-only values are inert.

## Open questions

- Component `Level`: not standardised. `component.json` carries 3 as a placeholder.
- Whether to add an Emoji-panel "Never" setting and OneDrive first-run suppression. Both deliberately left out for now.
- Whether `TaskbarDa` holds on the current build (see Known limits).
