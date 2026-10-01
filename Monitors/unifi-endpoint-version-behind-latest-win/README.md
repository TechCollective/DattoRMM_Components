# UniFi Endpoint - Version Behind Latest [Win]

A Windows monitor that alerts when UniFi Endpoint is behind Ubiquiti's latest release. **Alert only.** It changes nothing on the device and is not meant to have an auto-response.

> **Status: Not Validated.** 2026-10-01. Run end to end under Windows PowerShell 5.1 against Ubiquiti's live download link, with simulated installed versions. It has not yet run on a device through Datto.

## What it does

This monitor alerts when the installed **UniFi Endpoint** is older than Ubiquiti's latest Windows release. It only raises the alert in Datto RMM. Updates are delivered separately, by a scheduled `UniFi Endpoint [Win]` job (see *Pairing it with the update job*). This monitor is how you see which devices that job hasn't brought current.

1. It reads the installed version from the registry. It checks both registry views, requires the publisher to be Ubiquiti, and never matches UniFi Identity *Enterprise*.
2. It works out the latest version **without downloading the installer**. It sends HEAD requests to Ubiquiti's "latest MSI" link and follows the redirects by hand, never reading a response body. Then it reads the version from the `.msi` file name in the `Location` or `Content-Disposition` header. Where a server refuses HEAD, it retries that hop with a GET and closes the connection without reading the body. Ubiquiti's API gateway is one such server: it answers HEAD with 404.
3. It caches the answer in `C:\ProgramData\_automation\UniFiEndpoint\latest.json`, so each device asks Ubiquiti at most once every `cacheHours`, however often the monitor runs. The cache also records when a new version was first seen, which drives the grace period.
4. It compares the two versions, using only as many version fields as both have. Ubiquiti's file name carries three (`3.7.5`), so `3.7.5` counts as equal to `3.7.5.318`.

It doesn't change the product. The only file it writes is its own cache file. Its only network traffic is the header-only requests to `download.uid.ui.com` and whichever HTTPS hosts that link redirects to.

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

**In the monitoring policy:**

| Setting | Value |
|---|---|
| Targets | A filter where installed software contains `UniFi Endpoint`, or the sites being deployed to |
| Monitor | This component, checking every few hours. The cache means frequent checks don't mean frequent requests to Ubiquiti. |
| Auto-response | **None.** This monitor only raises the alert. |
| Auto-resolve | On. The first check after the device is updated returns healthy and the alert resolves. |

## Pairing it with the update job

The monitor and the updater are deliberately separate:

- **The updater:** a Datto scheduled job of `UniFi Endpoint [Win]` (`usrMode=Install`), e.g. early each morning, against the same "has UniFi Endpoint" filter. That component checks the version first and exits `UP_TO_DATE` without downloading on devices that are already current, so running it daily against every device is cheap.
- **This monitor:** alerts only where the job hasn't worked. That includes devices that were off, devices whose update failed, and sites that can't reach Ubiquiti.

Keep `graceDays` at least as long as the gap between job runs (the default `2` suits a daily job). The job installs a new release the next morning, and the monitor holds off alerting on that release until the grace period ends, so a healthy estate never alerts just because Ubiquiti shipped something yesterday. A device with an open alert has missed at least one run of the job.

## Input variables

All four are defined in `component.json`. No customer-specific value is hardcoded, and an out-of-range value fails the check with `Check could not run` rather than falling back to a default.

| Name | Datto type | Default | Safe range and effect |
|---|---|---|---|
| `cacheHours` | String | `12` | 1–168. How long a lookup result is reused. Lower means more requests to Ubiquiti from every device. Higher means devices notice a new release later. Outside the range, the check fails with `Check could not run`. |
| `graceDays` | String | `2` | 0–60. Days after a release is first seen before this monitor alerts on it. Keep it at least as long as the gap between update-job runs. A device's first-ever check has no grace period, so an outdated device alerts straight away. |
| `staleDays` | String | `7` | 1–60. How long the monitor tolerates not knowing the latest version before it alerts about itself. |
| `alertIfMissing` | Boolean | `false` | When `true`, a device without UniFi Endpoint installed alerts. Leave it off when the policy targets a "has UniFi Endpoint" filter. |

## Exit behaviour

| Device state | STATUS (example) | Exit |
|---|---|---|
| Installed version is current | `UniFi Endpoint 3.7.5.318 is current (latest 3.7.5, cached).` | 0 |
| Behind, but the release is newer than `graceDays` | `UniFi Endpoint 3.7.4.300; 3.7.5 released 2026-10-01, within the 2-day grace period.` | 0 |
| **Behind** | `UniFi Endpoint 3.7.2.296 is behind the latest version 3.7.5 (available since 2026-09-28).` | **1** |
| Not installed (`alertIfMissing=false`) | `UniFi Endpoint is not installed; nothing to check.` | 0 |
| Not installed (`alertIfMissing=true`) | `UniFi Endpoint is not installed on this device (alertIfMissing is on).` | **1** |
| Latest version unknown for up to `staleDays` | `…latest version temporarily unknown (<reason>). Alerts after 7 days.` | 0 |
| **Latest version unknown for more than `staleDays`** | `Check could not run: latest UniFi Endpoint version unknown for 9 days (<reason>)…` | **1** |
| **Bad input variable, or the script errors** | `Check could not run: <error>` | **1** |

On every alert, a diagnostic block includes the installed registrations, the redirect chain (host names and HTTP status codes only), the latest version with its source, a pointer to the update component and its logs, and the error line.

## How to tell it worked

- **Healthy device:** exits 0 with `…is current (latest X, checked now)` on the first run, and `(…, cached)` on later runs.
- **Outdated device:** exits 1 with `…is behind…`, and the diagnostic shows two hops, `301 download.uid.ui.com -> api-gw.uid.alpha.ui.com` and `302 api-gw.uid.alpha.ui.com -> fw-download.ubnt.com`. Once the update job has run (or `UniFi Endpoint [Win]` is run by hand), the next check exits 0 and the alert resolves.
- **If you get `No version in the vendor link's file name`** in the diagnostic instead, Ubiquiti has changed its link or its file names. The monitor stays quiet until `staleDays`, then alerts about itself.

## Test order

1. **Run it as a Scripts component first** on one internal device and read the raw output. Only save it as a Monitor after that. The Monitor category is permanent, and a monitor's output is only visible as an alert.
2. As a monitor, on one internal device that has an **older** version installed. Confirm the alert appears with the right text, then run `UniFi Endpoint [Win]` on that device and confirm the alert resolves on the next check.
3. One client site, with the policy scoped to one device.
4. Wider rollout.

## Known limits

- **The latest version comes from the installer's file name.** Checked 2026-10-01: Ubiquiti's link redirects to `…-windows-<major.minor.patch>-<id>.msi` on `fw-download.ubnt.com`. If Ubiquiti changes that shape, the lookup stops finding a version, and the monitor alerts about itself after `staleDays`.
- **Three version fields only.** A rebuild that changes only the fourth field (`3.7.5.318` to `3.7.5.400`) is not seen as newer. The update component compares the same way.
- Grace timing is per device. Each device first sees a release on its own cache refresh, so devices can differ by up to `cacheHours`.
- Lookups run as SYSTEM and use SYSTEM's proxy settings. A site with an authenticated proxy will show "temporarily unknown", then alert after `staleDays`.
- Nothing updates the device when this alerts. The alert stays open until the scheduled job, or someone running `UniFi Endpoint [Win]`, brings the device current.
