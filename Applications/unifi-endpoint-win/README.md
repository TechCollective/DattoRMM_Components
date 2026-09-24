# UniFi Endpoint [Win]

Deploys and updates Ubiquiti's UniFi Endpoint desktop agent on 64-bit Windows.

> **Status: Not Validated.** 2026-09-24. This revision changes the component from installing an attached MSI to installing *or updating* from Ubiquiti's signed download, and it keeps each device's settings on update. The first revision ran once on one internal device: the update succeeded but left a stale registration from Ubiquiti's `.exe` installer behind, which this revision now removes. The clean-up itself has been tested only against simulated inputs.

## What it does

This component deploys Ubiquiti's **UniFi Endpoint** desktop agent, which used to be called UniFi Identity Endpoint / Identity Standard. It runs on 64-bit Windows as SYSTEM.

- **Install** (the default mode) installs UniFi Endpoint, or updates it if it's already there:
  1. Gets the MSI. By default it downloads the latest release from Ubiquiti (`download.uid.ui.com`). If that fails, it falls back to an MSI attached to the component. `usrSource` controls this.
  2. **Refuses any MSI that isn't validly Authenticode-signed by Ubiquiti.** This check applies to the attached MSI as well as the downloaded one.
  3. Reads the MSI's `ProductVersion` and compares it with the version in the registry. If the product isn't installed, it installs it. If the installed version is older, it upgrades in place. If the installed version is the same or newer, it does nothing. It **never downgrades.**
  4. If the MSI refuses to upgrade in place (msiexec 1638), it removes the old version and then installs.
  5. After msiexec returns, it checks the registry for the installed version.
  6. **Removes the stale registration Ubiquiti's `.exe` installer leaves behind.** A device first set up from the `.exe` has a WiX Burn *bundle* registration (32-bit view, uninstaller in `C:\ProgramData\Package Cache\{GUID}\`) wrapping a hidden MSI. Our MSI upgrades that MSI but the bundle entry stays, so the device shows two versions. Once a newer MSI is verified, the component runs the bundle's own uninstaller quietly (`/uninstall /quiet /norestart`), only if it is inside the Package Cache and validly signed by Ubiquiti, and treats it as removed only when its registration is gone. If removing the bundle also removed the MSI, it installs the MSI again, keeping the device's settings. This also runs on devices that are already up to date.
- **Updates keep each device's existing settings.** When an update runs, the component reads the device's current settings from the registry and applies them again, instead of the component defaults. The settings kept are organization domain, launch at startup, Wi-Fi, VPN, auto-reconnect and the enforcement locks. Without this, an unattended update started by the version monitor would reset every device to the defaults. To force the component's own variables instead, set `usrKeepExistingSettings=0` or use Reinstall.
- **The app's own update check is switched off by default** (`CHECK_UPDATE=0`). This applies to existing installs as well, because the component always sets it and never keeps the old value. Where end users don't have admin rights, the app can't install its own updates, so updates come from this component, started by `UniFi Endpoint - Version Behind Latest [Win]`.
- **Uninstall** removes every matching MSI registration, then any Ubiquiti installer-bundle registration, and confirms nothing is left.
- **Reinstall** removes the product, then installs it with this component's variables. It does **not** keep the device's existing settings. It won't install if the removal failed.

It **never reboots.** Detection only matches registry entries whose publisher is Ubiquiti. It deliberately skips **UniFi Identity Enterprise**, which is a different product.

The only network call is the MSI download from Ubiquiti. The script sends nothing anywhere else. Logs go to `C:\ProgramData\_automation\UniFiEndpoint\`: one transcript that rotates at 5 MB, plus the ten newest msiexec logs and the ten newest installer-bundle uninstall logs (`bundle-*.log`).

**This supersedes the existing `UniFi Endpoint [Win]` in the Component Library.** That version installs whichever MSI is attached to it, and it skips devices that already have the app, so it never updates anything. When this goes live, re-point any jobs and policies that use the old component, then delete the old one. Do not run both.

## Installing it in Datto

**Easiest:** download the **component-exports** artifact from this pull request's checks (or, once merged, from the [latest release](../../releases/latest)) and import `UniFi Endpoint [Win].cpt`. It comes with every input variable already defined. Importing always creates a **new** component and never updates the existing one, so the steps are: import, re-point jobs and policies, delete the old component. The CI export has no MSI attached. That's expected, because `usrSource=Auto` downloads the MSI from Ubiquiti.

Alternatively, create the component by hand with Automation → Components → New Component, using these field values:

| Field | Value |
|---|---|
| Name | `UniFi Endpoint [Win]` |
| Description | Installs, updates, reinstalls or uninstalls UniFi Endpoint silently from Ubiquiti's signed MSI or attached MSI. |
| Category | Applications |
| Script type | PowerShell |
| Target OS | Windows (64-bit only) |
| Level | 1 |
| Timeout | 1800 seconds |
| Attachments | Optional. `UniFi Endpoint.msi` is used only when the download fails (`Auto`) or when `usrSource=Attached`. See *Known limits*. |
| Post-condition | Warning if output contains `WARNING:`. This isn't carried in the export, so set it by hand after importing. |

## Input variables

Every variable is defined in `component.json`. The variable names from the previous version are unchanged. `usrSource` and `usrKeepExistingSettings` are new. The Yes/No drop-downs show *Yes*/*No* in Datto and pass `1`/`0` to the script. No customer-specific value is hardcoded.

| Name | Datto type | Default | Valid values / safe range |
|---|---|---|---|
| `usrMode` | Selection | `Install` | `Install` (installs or updates), `Uninstall`, `Reinstall`. Any other value makes the job fail. |
| `usrSource` | Selection | `Auto` | `Auto` tries the vendor download, then the attachment. `Download` uses the vendor download only. `Attached` uses the attachment only and makes no network call. |
| `uiEndpointDomain` | String | *(blank)* | Your UniFi organization domain, passed as `ORG_DOMAIN`. Letters, digits, `.` and `-` only. Set it per site, never in the component. |
| `usrLaunchAtStartup` | Selection | Yes | Yes / No |
| `usrCheckUpdate` | Selection | No | Yes / No. The app's own update check. Leave it at No unless users are local admins: without admin rights a self-update can't finish, so updates come from this component. If users will be local admins, change it to Yes. The component applies this value on every install and update. |
| `usrConnectWiFi` | Selection | No | Yes / No |
| `usrConnectVpn` | Selection | No | Yes / No |
| `usrAutoReconnectWiFi` | Selection | No | Yes / No |
| `usrDesktopShortcut` | Selection | No | Yes / No |
| `usrEnforceConfig` | Boolean | `false` | When `true`, adds the `ENFORCE_CONFIG_*` locks so users can't change these settings locally. |
| `usrInstallerName` | String | `UniFi Endpoint.msi` | The file name of the attached MSI. Must be a bare `.msi` name with no path. |
| `usrKeepExistingSettings` | Selection | Yes | Yes keeps the device's existing domain, startup, VPN, Wi-Fi and enforcement settings when updating. No applies this component's variables. Fresh installs and Reinstall always use the variables. |
| `usrExtraMsiArgs` | String | *(blank)* | Additional `UPPERCASE_PROPERTY=value` pairs separated by spaces. Anything else, including msiexec switches, makes the job fail. |

The boolean-style variables also accept `true`/`false`/`yes`/`no`. Any other value fails the job **before** msiexec runs, rather than passing a bad value to the installer.

## Exit behaviour

| Outcome | STATUS line | Exit |
|---|---|---|
| Fresh install succeeded | `INSTALLED` | 0 |
| Older version upgraded | `UPDATED` | 0 |
| Already on the same or a newer version | `UP_TO_DATE` | 0 |
| Removed, then installed. This also covers Install mode when removing a stale installer-bundle registration took the MSI with it | `REINSTALLED` | 0 |
| A stale installer-bundle registration could not be removed | The status above, plus a `WARNING:` line | 0 (Warning via post-condition) |
| Any of the above, but Windows wants a reboot | `…_REBOOT_REQUIRED` plus a `WARNING:` line | 0 (Warning via post-condition) |
| Uninstalled and verified absent | `REMOVED` | 0 |
| Bad input, no usable or signed MSI, msiexec error, or version not updated after install | `FAILED` | 1 |

## How to tell it worked

A healthy update run looks like this:

```
Detected: UniFi Endpoint v3.6.0.236
Downloading latest MSI from Ubiquiti (download.uid.ui.com)
Signature valid: CN=Ubiquiti Inc., O=Ubiquiti Inc., ...
MSI version: 3.7.4.xxx (Download)
Updating 3.6.0.236.0 -> 3.7.4.xxx
Install exit code: 0
Verified: UniFi Endpoint v3.7.4.xxx
STATUS=UPDATED
```

A second run on the same device should report `STATUS=UP_TO_DATE`. If it doesn't, there's something wrong with how the version is detected.

On a device first set up from Ubiquiti's `.exe`, the same run also prints `Removing stale 'UniFi Endpoint' v… registration left by Ubiquiti's .exe installer`, a `Running bundle uninstaller` line, and then no `more than one UniFi Endpoint registration remains` warning.

## Test order

1. One internal device with an **older** version installed, ideally one first set up from Ubiquiti's `.exe`. This checks the upgrade path and the bundle clean-up, and the second run should report `UP_TO_DATE`.
2. One internal device with nothing installed. This checks a fresh install with `uiEndpointDomain` set.
3. One client site, with the job scoped to one device.
4. Wider rollout.

## Known limits

- **The attachment goes stale.** In `Auto` mode it's only a fallback, and it will never downgrade, so a stale attachment is harmless. Once `Download` is proven, either delete the attachment or keep it for sites with no internet.
- The download runs as SYSTEM and uses SYSTEM's proxy settings. If a site requires an authenticated proxy, use `usrSource=Attached`.
- An app that is open during an upgrade may need a reboot before the upgrade finishes (3010). The script reports this and never forces a reboot.
- Needs PowerShell 5.1 (Windows 10/11). 32-bit Windows is refused.
- Run on one internal device so far. The installer-bundle clean-up has not run on a device yet; the equivalent manual steps worked (the bundle entry went, the MSI stayed).
- Only Ubiquiti installer bundles in the Package Cache are removed automatically. Any other non-MSI registration is reported with a `WARNING:` line and left alone.

## Open questions

- **Where the settings are stored in the registry.** Ubiquiti names the values (`OrgDomain`, `LaunchAtStartup`, …) but not the key they live in. The component searches `HKLM\SOFTWARE\Ubiquiti*` / `UniFi*`, and the same under `SOFTWARE\Policies`, up to three levels deep. On the first upgrade test, confirm that the output shows `Keeping existing settings from HKLM\…`. If it prints `WARNING: Could not find the existing UniFi Endpoint settings`, find the real key on that device and add it here.
- **Enforcement-lock value names.** The component treats any value whose name starts with `Enforce` and equals `1` as "locks on". Check this on a device that was installed with locks.

- **Legacy display names.** The old script also matched `UniFi Identity*` (which would include Identity *Enterprise*) and `UI Desktop*`. This version matches only `UniFi Endpoint*`, `UniFi Identity Endpoint*` and `UniFi Identity Standard*`, and only when the publisher is Ubiquiti. If a legacy install uses a different name, add it here after checking a real device.
- **Signer name.** The script expects the MSI's certificate to have `O=Ubiquiti…`. The first run prints the actual signer subject. Confirm it.
- **Vendor URL.** `https://download.uid.ui.com/?app=DESKTOP-IDENTITY-STANDARD-WINDOWS-MSI` should always serve the latest MSI. If Ubiquiti changes it, the download fails the signature or file-header check and `Auto` falls back to the attachment.
