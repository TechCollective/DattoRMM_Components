# IAP Desktop [Win]

Deploys [Google IAP Desktop](https://googlecloudplatform.github.io/iap-desktop/),
Google's Remote Desktop / SSH client that connects to Google Cloud VMs through
Identity-Aware Proxy, to Windows 10 and 11 workstations. Because the vendor's
MSI is **per-user**, this component does not install the app itself: it stages
the installer and registers an Active Setup entry, and Windows installs it for
each user at their next sign-in.

> **Status: Not Validated.** Written 2026-09-29 for a client remote-access
> project; reviewed by the author only. Not yet run on any device. See
> [Test order](#test-order).

## What it does

Runs as SYSTEM. It **changes the endpoint**:

1. Downloads `IapDesktop.msi` over HTTPS from `msiUrl` (default: the vendor's
   `releases/latest` link on GitHub) to `C:\ProgramData\TechCollective\IapDesktop\`.
   Refuses a non-HTTPS URL and a download under 1 MB.
2. Reads `ProductVersion` from the MSI (Windows Installer COM). Falls back to a
   date stamp if that fails.
3. Writes a two-line `Install-IapDesktop-User.cmd` beside the MSI that runs
   `msiexec /i IapDesktop.msi /qn /norestart`, logging to the user's
   `%LOCALAPPDATA%\IapDesktop-install.log`.
4. Registers `HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{6f1c2b8e-4a4d-4b0e-9c2a-5d1e7f3a9b01}`
   with `StubPath` pointing at that `.cmd` and `Version` set to the product
   version. Windows runs the stub **once per user profile, as that user, at
   logon**, whenever the recorded per-user version is older than this one.
5. Prints which existing profiles on the device already have IAP Desktop.

**Nothing is installed when the job runs.** Each user gets the app the next time
they sign in (or reboot). Re-running the component with a newer release bumps
the version, so every user upgrades at their next logon. Re-running with the
same release does nothing per-user unless `reinstallExisting` is `true`.

Why per-user and not machine-wide: Google documents IAP Desktop as a per-user
install and deploys it via user-scoped GPO/Intune. Per-user also means the
app's built-in update check works for non-admin users, so this component only
needs re-running to force a specific version.

Network calls: one HTTPS download from `msiUrl`. Nothing else leaves the device.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `IAP Desktop [Win]` |
| Description | Stages Google IAP Desktop so each user installs it at their next logon via Active Setup; nothing is installed when the job runs. |
| Category | **Applications** |
| Script type | PowerShell |
| Target OS | Windows (10 / 11 workstations) |
| Level | *not standardised yet — decide at save time* |
| Timeout | 600 seconds |
| Attachments | none — the installer is downloaded, not bundled |
| Post-condition (recommended) | Warning if output does **not** contain `IAP Desktop staged` |

Paste the whole of `iap-desktop-win.ps1` as the script body, then add the input
variables below. `component.json` carries the same metadata; CI builds an
importable `.cpt` from it on every pull request.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `msiUrl` | String | *(blank → Google's latest GitHub release)* | Must start with `https://`; anything else exits 3 without changing the device. Set to a specific release asset URL (`https://github.com/GoogleCloudPlatform/iap-desktop/releases/download/<tag>/IapDesktop.msi`) to pin a version. |
| `reinstallExisting` | Boolean | `false` | `true` appends a timestamp to the Active Setup version so every user re-runs the install at next logon. Harmless (same-product msiexec finishes in seconds) but unnecessary for a normal upgrade. |

No customer-specific value is hardcoded. The stage folder and the Active Setup
GUID are fixed by design so re-runs update rather than duplicate.

## Exit behaviour

| Exit | Meaning |
|---|---|
| `0` | Staged. Output ends with `IAP Desktop staged: <version> ...` and a per-profile list. |
| `1` | Download failed or the file was too small to be an installer. Nothing changed on the device. Output starts with `ERROR:`. |
| `2` | Could not write the stub or the Active Setup key. The MSI is on disk but no user will install it. Output starts with `ERROR:`. |
| `3` | `msiUrl` is not an `https://` URL. Nothing changed. |

It never exits 0 without having staged the installer.

## How to tell it worked

Healthy run:

```
Downloading IapDesktop.msi from https://github.com/GoogleCloudPlatform/iap-desktop/releases/latest/download/IapDesktop.msi
Downloaded 28.4 MB
IAP Desktop staged: 2.46.1737 (Active Setup version 2,46,1737). Each user installs it at their next sign-in.
Existing profiles on this device:
  jdoe                     not yet - installs at next logon
```

The version numbers above are illustrative. After that user signs out and back
in, `IAP Desktop` appears in their Start Menu and a second run of the component
lists their profile with the installed version instead of `not yet`. If it does
not, read `%LOCALAPPDATA%\IapDesktop-install.log` in that user's profile.

## Test order

Never a customer first.

1. One internal device. Run it, sign out and in as a standard user, confirm the
   Start Menu entry and that the app launches to its sign-in screen.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

- **Windows workstations only.** Windows Server enforces `DisableUserInstalls`,
  so the per-user MSI fails there; that is the vendor's documented behaviour, and
  a server is not where this client belongs anyway.
- Any policy that disables Windows Installer for non-admins (`DisableUserInstalls`
  on a workstation, or AppLocker/WDAC blocking `msiexec` for users) makes the
  per-user install fail silently at logon. The user's install log is the only
  evidence.
- Active Setup runs at interactive logon only. A user who never signs out keeps
  not having it until they do.
- Uses `Invoke-WebRequest` and `-notcontains`, so PowerShell 3.0+ (every
  supported Windows 10/11 build). Not PowerShell 2.0-compatible.
- Does not uninstall. To stop deploying, delete the Active Setup key above;
  existing per-user installs remain and can be removed by the user from
  Apps & Features.
- Not tested with a proxy that requires authentication for SYSTEM.

## Open questions

- Component `Level` — not standardised yet.
- Whether to add a matching uninstall script component if a client ever moves
  off IAP.
