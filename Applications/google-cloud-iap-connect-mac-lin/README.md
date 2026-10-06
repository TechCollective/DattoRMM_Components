# Google Cloud IAP Connect [Mac] [Lin]

Gives macOS and Linux users a double-click way to reach a Google Cloud Windows
VM over Remote Desktop through Identity-Aware Proxy, with no public IP on the
VM. It is the Mac/Linux counterpart of `Google IAP Desktop [Win]`: Google ships
no IAP Desktop for those platforms, so this installs the Google Cloud CLI and a
launcher script that opens the IAP tunnel, starts the RDP client against it,
and closes the tunnel when the session ends.

> **Status: Not Validated.** Written 2026-09-29. The deployment logic was
> dry-run on Linux in a sandbox with a stubbed `gcloud`; the launcher has not
> yet been run end-to-end on a real Mac or Linux desktop. See
> [Test order](#test-order).

## What it does

Runs as root. It **changes the endpoint**:

1. Validates every input (project id, instance name, zone, port, label,
   optional gcloud version) and exits 3 on anything malformed.
2. Downloads the Google Cloud CLI tarball for the platform from
   `dl.google.com` (Google's own host, HTTPS) and installs it to
   `/opt/google-cloud-sdk` with usage reporting off, symlinking
   `/usr/local/bin/gcloud`. **macOS first bootstraps a Python**: Google's
   `install.sh` is a wrapper that needs an existing Python 3.10+ to run
   `install.py`, neither Mac tarball bundles one, and macOS ships only an Xcode
   stub at `/usr/bin/python3` that pops Apple's installer dialog when called
   (seen 2026-10-06 on an Intel Mac; the `--install-python` flag lives inside
   `install.py` and cannot help). The component never calls that stub. It looks
   for a real Python 3.10+ in `/Library/Frameworks/Python.framework`, Homebrew
   or `/usr/local/bin`; if none, it downloads the official python.org
   universal2 package for `macPythonVersion`, **verifies it is signed by the
   Python Software Foundation** (`pkgutil --check-signature`) and installs it
   silently with `installer -pkg`. Google's installer then runs under that
   Python (`CLOUDSDK_PYTHON`), and its output is kept: on failure the last 15
   lines are printed and the full log is copied to
   `/var/log/techcollective/gcloud-install.log`. Skips this if the same (or, unpinned, any) version
   is already there. Supports macOS arm64/x86_64 and Linux x86_64/arm64. Linux
   needs `python3` present; the script refuses (exit 4) if it is not.
3. Writes the launcher `/usr/local/share/iap-connect/iap-connect.sh` with the
   project, instance, zone, port and label filled in.
4. Puts a shortcut on every real user's desktop: `Connect to <label>.command`
   on macOS (quarantine flag cleared), `connect-to-<label>.desktop` on Linux
   (marked trusted via `gio` where available).

**Nothing is done to the VM, and no Google account is signed in by this
component.** The first time a user runs the launcher, `gcloud auth login` opens
a browser for their own Google sign-in; the credential lives in that user's
`~/.config/gcloud`.

### What the launcher does, as the user

Checks for `gcloud` and an RDP client (macOS: Microsoft **Windows App** from
the App Store; Linux: `xfreerdp3`, `xfreerdp` or `remmina`, in that order).
Signs in on first use. Starts `gcloud compute start-iap-tunnel <vm> 3389
--local-host-port=localhost:<port>` unless something is already listening on
that port, waits for the listener, then opens the RDP client against
`localhost:<port>` (an `.rdp` file on macOS, a `.remmina` profile or an
`xfreerdp` command line on Linux). It then watches the port: once an RDP
session has been established and has been gone for five seconds, it kills the
tunnel and exits. If no session starts within 90 seconds it closes the tunnel
and exits 0. Logs to `~/.config/iap-connect/iap-connect.log`.

Network calls: the CLI download from `dl.google.com` and, on a Mac with no
Python, the installer package from `www.python.org`, both at deploy time; at
run time, the user's `gcloud` talks to Google APIs and IAP. Nothing else.

## Why a tunnel per session, not a persistent one

A persistent LaunchAgent/systemd listener would be simpler to use but leaves a
standing authenticated path to the server whenever the laptop is on. Opening
the tunnel per session keeps the exposure window to the session itself, and
the `gcloud` refresh token in the user's profile is still the thing that
matters if a laptop is lost: suspend the user in JumpCloud/Google to revoke it.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Google Cloud IAP Connect [Mac] [Lin]` |
| Description | Installs the Google Cloud CLI and a desktop launcher that tunnels Remote Desktop to one VM through IAP; users sign in with Google on first use. |
| Category | **Applications** |
| Script type | Shell (Unix, macOS) |
| Target OS | macOS and Linux desktops. The Windows stub prints a pointer to `Google IAP Desktop [Win]` and exits 0 |
| Level | *not standardised yet — decide at save time* |
| Timeout | 900 seconds (the CLI tarball is ~100 MB and `install.sh` takes a minute or two) |
| Attachments | none — the CLI is downloaded from Google |
| Post-condition (recommended) | Warning if output does **not** contain `Google Cloud IAP Connect deployed` |

Paste the whole of `google-cloud-iap-connect-mac-lin.sh` as the script body,
then add the input variables below. `component.json` carries the same
metadata; CI builds an importable `.cpt` from it.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `gcpProject` | String | *(required)* | Project id: lowercase letter first, then lowercase/digits/hyphens, ≤63 chars. Anything else exits 3. |
| `vmInstance` | String | *(required)* | Instance name, same rule as above. |
| `vmZone` | String | *(required)* | `region-zone` form like `us-central1-c`. |
| `connectionLabel` | String | `Cloud Server` | What the user sees: "Connect to Cloud Server". Letters, digits, space, `.` `_` `-`, ≤40 chars. |
| `localPort` | String | `13389` | 1024–65535. Change only if something on the client machines already uses 13389. |
| `gcloudVersion` | String | *(blank = latest)* | Pin a release such as `540.0.0`. Blank pulls Google's current tarball, so two deployments a month apart can install different versions. |
| `macPythonVersion` | String | `3.13.16` | macOS only. python.org release installed when the Mac has no Python 3.10+. Must exist at `python.org/ftp/python/<v>/python-<v>-macos11.pkg` (3.10–3.15 supported by gcloud). Ignored on Linux. |

No customer-specific value is hardcoded; every deployment is defined by the
first three variables. Every input is regex-validated before it reaches a
command line or `sed`.

## Exit behaviour

| Exit | Meaning |
|---|---|
| `0` | Deployed. Output ends `Google Cloud IAP Connect deployed: ... shortcut placed for N user(s)`. N = 0 means no user home with a Desktop folder was found — the launcher is still in place. |
| `1` | Google Cloud CLI download, extract or `install.sh` failed. A previous install, if any, is left intact. |
| `2` | Could not write the launcher. |
| `3` | An input variable failed validation. Nothing changed. |
| `4` | Unsupported OS/architecture, or Linux without `python3`. Nothing changed. |

## How to tell it worked

Healthy output (values illustrative):

```
Google Cloud CLI 540.0.0 installed at /opt/google-cloud-sdk
Google Cloud IAP Connect deployed: launcher at /usr/local/share/iap-connect/iap-connect.sh, shortcut placed for 2 user(s), target example-vm (us-central1-c) as 'Cloud Server' on localhost:13389.
```

Then, as a user: double-click the desktop shortcut. A terminal window opens,
says "Opening secure tunnel", the RDP client appears pointed at
`localhost:13389` and asks for Windows credentials. Closing the RDP window
ends with "Remote desktop session ended" and "Tunnel closed". The first run
also opens a browser for Google sign-in.

macOS: Terminal keeps the window open after a script exits by default. Set
Terminal → Settings → Profiles → Shell → "When the shell exits" to "Close if
the shell exited cleanly" so the window disappears; this is a per-user
preference the component does not change.

## Test order

Never a customer first.

1. One internal Mac and one internal Linux desktop, against an internal or
   test VM the tester has `roles/iap.tunnelResourceAccessor` and
   `roles/compute.viewer` on.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

- **Not a persistent tunnel.** Closing the terminal window kills the tunnel
  and drops the RDP session; the launcher says to close the RDP window
  instead, and users will still do it.
- The RDP client is not installed by this component. macOS users need
  Microsoft Windows App (App Store, deployable via VPP); Linux users need
  `freerdp` or `remmina` from their distro. The launcher says which is
  missing.
- Linux session detection uses `ss` (iproute2). A distro without it cannot
  detect session end and the launcher will close the tunnel after 90 s.
- The `gcloud` credential is a long-lived refresh token in the user's home.
  Google Workspace "Google Cloud session control" can force re-auth on a
  schedule; otherwise it lasts until the account is suspended.
- Users created after deployment get no desktop shortcut until the component
  is re-run; the launcher itself is shared and world-readable.
- Not tested behind an authenticating proxy, on Linux arm64, or on a Mac
  with a non-default `/Users` layout.
- A Mac with no Python gets a system-wide python.org install under
  `/Library/Frameworks/Python.framework` (plus `/usr/local/bin/python3`). It is
  left in place; removing the component does not remove it.
- The python.org package is verified by signature, not by hash, so a pinned
  `macPythonVersion` that python.org has retired fails at download rather than
  installing something else.

## Open questions

- Component `Level` — not standardised yet.
- Whether to add a matching remove script (delete `/opt/google-cloud-sdk`,
  the launcher and shortcuts) when a client moves off IAP.
- `icon.png` is expected to be the Google Cloud product icon. It is Google's
  trademark; the repo carries it only to identify the product in the Component
  Library, the same way ComStore components do. Drop a 48x48 RGBA `icon.png`
  beside `component.json`; until then CI uses the TechCollective default.
