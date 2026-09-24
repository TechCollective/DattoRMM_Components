# UniFi Endpoint - Version Behind Latest [Win]

A Windows monitor that alerts when UniFi Endpoint is behind Ubiquiti's latest release. It's built to run with `UniFi Endpoint [Win]` as its auto-response.

> **Status: Not Validated.** 2026-09-24. Tested against simulated installed and latest versions only. It has not run on a Windows device or against Ubiquiti's live download link.

## What it does

This monitor alerts when the installed **UniFi Endpoint** is older than Ubiquiti's latest Windows release. It's designed to run with `UniFi Endpoint [Win]` as its **auto-response**, so devices stay current without the app's own updater. The users don't have admin rights, so that updater can't finish.

1. It reads the installed version from the registry. It checks both registry views, requires the publisher to be Ubiquiti, and never matches UniFi Identity *Enterprise*.
2. It works out the latest version **without downloading the installer**. It sends HEAD requests to Ubiquiti's "latest MSI" link and follows the redirects by hand, never reading a response body. Then it reads the version from the `.msi` file name in the `Location` or `Content-Disposition` header. If a server refuses HEAD, it retries that step with a GET and closes the connection without reading the body.
3. It caches the answer in `C:\ProgramData\_automation\UniFiEndpoint\latest.json`, so each device asks Ubiquiti at most once every `cacheHours`, however often the monitor runs. The cache also records when a new version was first seen, which drives the grace period.
4. It compares the two versions, using only as many version fields as both have. `3.7.4` counts as equal to `3.7.4.301`.

It doesn't change the product. The only file it writes is its own cache file. Its only network traffic is the HEAD requests to `download.uid.ui.com` and whichever HTTPS hosts that link redirects to.

**"Couldn't tell" is routine at first, then a fault.** If the latest version can't be found, the monitor stays healthy and uses the last good cached answer. Once `staleDays` pass without a successful lookup, it alerts `Check could not run…`. By then the vendor link has probably changed, and the monitor can't see anything.

## Installing it in Datto

**Easiest:** import `UniFi Endpoint - Version Behind Latest [Win].cpt` from this pull request's **component-exports** artifact, or from the [latest release](../../releases/latest) once merged. It comes with its variables already defined. **But run it as a Scripts component first** (see *Test order*). The export is category Monitors, and that category can't be changed after saving. For the script-mode trial, create a temporary Scripts component and paste this `.ps1` into it, then delete that component once you've read its output.

Otherwise, create it by hand with these field values:

| Field | Value |
|---|---|
| Name | `UniFi Endpoint - Version Behind Latest [Win]` |
| Description | Alerts when UniFi Endpoint is older than Ubiquiti's latest release; stays quiet when unsure, alerts after staleDays blind. |
| Category | **Monitors.** This is permanent and can't be changed after saving. |
| Script type | PowerShell |
| Target OS | Windows |
| Level | 1 |
| Timeout | 120 seconds |
| Attachments | None. Monitors can't have attachments. |
| Monitor interval | Every few hours. The cache means frequent checks don't mean frequent requests to Ubiquiti. |

**In the monitoring policy:**

| Setting | Value |
|---|---|
| Targets | A filter where installed software contains `UniFi Endpoint`, or the sites being deployed to |
| Monitor | This component, checking every few hours. The cache means frequent checks don't mean frequent requests to Ubiquiti. |
| Auto-response | `UniFi Endpoint [Win]`, with `usrMode=Install` and `usrSource=Auto` |
| Auto-resolve | On. The next check after a successful update returns healthy. |

The auto-response runs the install component with its **default** variables. That's safe because of `usrKeepExistingSettings=1`: an update keeps each device's existing domain, VPN and startup settings rather than resetting them. See that component's README.

## Input variables

All four are defined in `component.json`. No customer-specific value is hardcoded, and an out-of-range value fails the check with `Check could not run` rather than falling back to a default.

| Name | Datto type | Default | Safe range and effect |
|---|---|---|---|
| `cacheHours` | String | `12` | 1–168. How long a lookup result is reused. Lower means more requests to Ubiquiti from every device. Higher means devices notice a new release later. Outside the range, the check fails with `Check could not run`. |
| `graceDays` | String | `2` | 0–60. Days after a release is first seen before this monitor alerts on it. This keeps a same-day buggy release off the whole estate. A device's first-ever check has no grace period, so an outdated device alerts straight away. |
| `staleDays` | String | `7` | 1–60. How long the monitor tolerates not knowing the latest version before it alerts about itself. |
| `alertIfMissing` | Boolean | `false` | When `true`, a device without UniFi Endpoint installed alerts. Leave it off when the policy targets a "has UniFi Endpoint" filter. |

## Exit behaviour

| Device state | STATUS (example) | Exit |
|---|---|---|
| Installed version is current | `UniFi Endpoint 3.7.4.301 is current (latest 3.7.4.301, cached).` | 0 |
| Behind, but the release is newer than `graceDays` | `UniFi Endpoint 3.7.4.301; 3.8.0.10 released 2026-09-24, within the 2-day grace period.` | 0 |
| **Behind** | `UniFi Endpoint 3.6.0.236 is behind the latest version 3.7.4.301 (available since 2026-09-20).` | **1** |
| Not installed (`alertIfMissing=false`) | `UniFi Endpoint is not installed; nothing to check.` | 0 |
| Not installed (`alertIfMissing=true`) | `UniFi Endpoint is not installed on this device (alertIfMissing is on).` | **1** |
| Latest version unknown for up to `staleDays` | `…latest version temporarily unknown (<reason>). Alerts after 7 days.` | 0 |
| **Latest version unknown for more than `staleDays`** | `Check could not run: latest UniFi Endpoint version unknown for 9 days (<reason>)…` | **1** |
| **Bad input variable, or the script errors** | `Check could not run: <error>` | **1** |

On every alert, a diagnostic block includes the installed registrations, the redirect chain (host names and HTTP status codes only), the latest version with its source, and the error line.

## How to tell it worked

- **Healthy device:** exits 0 with `…is current (latest X, checked now)` on the first run, and `(…, cached)` on later runs.
- **Outdated device:** exits 1 with `…is behind…`. The auto-response job runs and reports `STATUS=UPDATED`. The next check exits 0 and the alert resolves.
- **On the first run, look for** a version in the diagnostic's `Latest:` line. If you get `No version in the vendor link's file name` instead, Ubiquiti's file names don't carry a version, and the lookup approach needs rethinking before this goes wider.

## Test order

1. **Run it as a script component first** on one internal device and read the raw output. Only save it as a Monitor after that. The Monitor category is permanent, and a monitor's output is only visible as an alert.
2. As a monitor with the auto-response, on one internal device that has an **older** version installed. Confirm the device alerts, updates, and the alert resolves.
3. One client site, with the policy scoped to one device.
4. Wider rollout.

## Known limits

- **The latest version comes from the installer's file name.** That relies on an unconfirmed assumption: that Ubiquiti's link redirects to a versioned file name, as third-party listings suggest (`UniFi_Endpoint-3.6.0.236.msi`). I couldn't reach the link from the authoring environment. Step 1 of the test order confirms or disproves it.
- Grace timing is per device. Each device first sees a release on its own cache refresh, so devices can differ by up to `cacheHours`.
- Lookups run as SYSTEM and use SYSTEM's proxy settings. A site with an authenticated proxy will show "temporarily unknown", then alert after `staleDays`.
- If the auto-response fails, the alert stays open until someone deals with it. Check the install component's job output and the msiexec log on the device.

## Open questions

- What the redirect chain and file name actually look like. This comes from the first script-mode run.
- Whether the policy's auto-response runs only once per alert or on every check while the alert is open. Confirm this in the policy settings. If it runs on every check, the check interval sets how often a failing device downloads the installer again.
