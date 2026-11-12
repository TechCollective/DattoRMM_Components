# Connection Health - Ping Targets Not Responding [Win]

A Datto RMM custom monitor for Windows. Pings the hosts you give it and alerts
when they stop answering. The targets are set per monitor, so the same
component can watch any connection that should always be up. It was written
for the far side of a site-to-site tunnel, run on a Windows server or
workstation behind the tunnel.

> **Status: Not Validated.** Written 2026-11-12. Reviewed against the monitor
> contract and security checklist the same day. 18-case regression sweep passing
> under PowerShell 7 on Linux; **not yet run on Windows or under Windows
> PowerShell 5.1/2.0.**

Its Linux counterpart is `Connection Health - Ping Targets Not Responding [Lin]`,
with the same inputs (that one also has `usrSource`) and the same alert wording.

## What it does

For each target in `usrTargets` it sends `usrPingCount` ICMP echo requests using
`System.Net.NetworkInformation.Ping`, one target after another, and records
each one as:

- **Replied** — at least one reply with status `Success`.
- **No route** — destination host or network unreachable, including a socket
  error saying the network is unreachable. Counted as down.
- **No reply** — timed out, or any other non-success status.
- **Error** — the request could not be made: the name did not resolve.

With `usrRequire=any` (the default), the connection is up if any target replied.
With `all`, every target must reply.

It uses .NET's `Ping` rather than `ping.exe` for two reasons. `ping.exe` output
is localised, and `ping.exe` **exits 0 when a router answers "Destination host
unreachable"**, which would report a dead tunnel as healthy. Errors are
classified by `SocketErrorCode`, which is not localised either.

**Read-only.** It changes nothing on the endpoint. It sends ICMP echo requests
to the configured targets only, and on the alert path calls `Find-NetRoute`
(Windows 8 / Server 2012 and later) for the diagnostic.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Connection Health - Ping Targets Not Responding [Win]` |
| Description | Alerts when hosts stop answering ping, such as the far side of a site-to-site tunnel. Read-only. Bad input or a failed check also alerts. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | PowerShell |
| Target OS | Windows |
| Level | *not standardised yet — decide at save time* (manifest carries `4`, matching our other recent monitors) |
| Timeout | 180 seconds |
| Attachments | None (monitors cannot have them) |
| Monitor interval | Set in the monitoring policy. 5 minutes is a sensible start. |

Paste the whole of `connection-health-ping-targets-not-responding-win.ps1` as the script body,
then add the input variables below. Or import the `.cpt` that CI builds from
`component.json`.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrTargets` | String | *(empty)* | **Required.** 1–8 IPv4/IPv6 addresses or hostnames, space- or comma-separated. Pick hosts that are always on, ideally the far gateway's LAN address. IPs beat hostnames: if DNS also crosses the tunnel, a down tunnel shows as a resolution error instead of "no reply". |
| `usrRequire` | Selection | `Any` | `Any`: alert only when nothing replies. `All`: alert when any target is silent. |
| `usrPingCount` | String | `3` | 1–10. Pings sent to each target. |
| `usrReplyTimeoutSec` | String | `2` | 1–5. Seconds to wait for each reply. |

No client-specific value is hardcoded. Each input is validated and the monitor
**refuses to run** on a bad value instead of falling back to a default. Targets
are passed to .NET as data, never to a shell, and must match
`^[A-Za-z0-9:][A-Za-z0-9.:-]*$`.

Pings are sequential and a miss waits the full timeout, so the worst case is
targets × count × timeout. The monitor refuses any combination over 120
seconds; the defaults with 8 targets come to 48.

There is no `usrSource`: .NET `Ping` cannot bind a source address, and a
Windows host behind a tunnel does not need one. See Known limits.

## Exit behaviour

| Host state | Result |
|---|---|
| `usrTargets` not set | exit 1, `STATUS=Check could not run: usrTargets is empty…` |
| Any target replies (`any`), or all reply (`all`) | exit 0, `STATUS=Connection up: …` with per-target replies and average RTT |
| No target replies | exit 1, `STATUS=Connection down: 0 of N targets replied (…)` |
| Some but not all reply, with `all` | exit 1, `STATUS=Connection degraded: …` |
| Every target fails to resolve | exit 1, `STATUS=Check could not run: ping failed on every target (…)` |
| An input variable is invalid, or over the runtime budget | exit 1, `STATUS=Check could not run: <which input and why>` |
| The script dies unexpectedly | exit 1, `STATUS=Check could not run: the monitor stopped unexpectedly (…)` via a top-level `trap` |

"Could not tell" is treated as a **fault**: a monitor that cannot see the tunnel
is blind.

On the alert path only, a diagnostic block lists replies and failure statuses
per target, the interface and next hop `Find-NetRoute` chooses for each IP
target, and the settings in force.

## How to tell it worked

Run it as a **Scripts** component first and read the raw output. Expect exactly
one result block with one `STATUS=` line and no space after the `=`.

Healthy:

    <-Start Result->
    STATUS=Connection up: 2 of 2 targets replied (10.x.x.1 3/3 24 ms; 10.x.x.10 3/3 26 ms)
    <-End Result->

Alert:

    <-Start Result->
    STATUS=Connection down: 0 of 2 targets replied (10.x.x.1 no reply; 10.x.x.10 no reply)
    <-End Result->
    <-Start Diagnostic->
    == 10.x.x.1 : 0/3 replies
       failures: TimedOut x3
       route: interface 'Ethernet', next hop 192.168.x.1
    …
    <-End Diagnostic->

## Test coverage completed

18 cases under PowerShell 7.4 on Linux, each asserting the exit code and the
result-block contract: healthy, one-of-two with `any` and `all`, all down, no
route, unknown host alone and alongside a live target, empty and oversized
target lists, a shell metacharacter and a `$( )` subexpression in a target,
every invalid-input path including `+3` and `False`, and the runtime budget.

**Not verified:** Windows itself. On Windows, unreachable and timed-out pings
come back as reply statuses rather than exceptions; both paths are handled, but
only the exception path was exercised here. Also not verified: Windows
PowerShell 2.0 and 5.1 (written to 2.0 syntax, but not executed there),
`Find-NetRoute` output, and IPv6 targets.

## Known limits

- **ICMP must be allowed** end to end, including Windows Firewall on the target
  if the target is a Windows host. A blocked echo request looks exactly like a
  dead tunnel.
- **It measures reachability, not the tunnel.** Under `all`, a far-side host
  that is down for its own reasons alerts as "Connection down".
- **No source binding.** If the monitor ever has to run on a Windows tunnel
  endpoint (RRAS) where the tunnel only carries LAN-sourced traffic, it needs
  `ping.exe -S`, and with it localised output parsing. Not written.
- The `Find-NetRoute` diagnostic line is skipped silently on Windows 7 /
  Server 2008 R2.

## Open questions

- **WireGuard checks (next version).** On Windows, the WireGuard client runs
  each tunnel as a service named `WireGuardTunnel$<name>`, and `wg.exe show
  <name> latest-handshakes` reports handshake age per peer. Planned: service
  running plus handshake age against a threshold. This will add input variables,
  so it is a material change: new branch, PR, README update.
- **Component Level** (access tier) is not standardised. Decide at save time.
- **Result keyword.** `STATUS=` per our monitor contract; confirm on the first
  script-mode run.
