# Connection Health - Ping Targets Not Responding [Win]

A Datto RMM custom monitor for Windows. It watches a connection that should
always be up, typically a site-to-site tunnel, in one or both of two ways:

- **Ping** — pings the hosts you give it and alerts when they stop answering.
- **WireGuard** — checks that a WireGuard for Windows tunnel is active and that
  its peers have completed a handshake recently.

The targets and the tunnel are set per monitor, so the same component can
watch any number of connections. Run it on a Windows host behind the tunnel
for the ping check, or on the Windows machine running the WireGuard tunnel for
both.

> **Status: Not Validated.** v1 written 2026-11-12 (ping only). v2, adding the
> WireGuard checks, written the same day: reviewed against the monitor contract
> and security checklist, and a 43-case sweep passing under both Windows
> PowerShell 5.1 and PowerShell 7.6 on Windows 11. **Neither version has run on
> a real tunnel yet**, and the running-tunnel path was exercised through the
> script's own functions, not against a live tunnel service.

Its Linux counterpart is `Connection Health - Ping Targets Not Responding [Lin]`,
with the same alert wording. Its WireGuard check reads a network interface
(`usrWgInterface`) instead of a tunnel service, and it also has `usrSource`.

## What it does

Pings run first, then the WireGuard check. The order matters: traffic through
the tunnel makes WireGuard re-handshake with a live peer, so the handshake age
read afterwards reflects the peer rather than an idle tunnel.

### Ping (`usrTargets`)

For each target it sends `usrPingCount` ICMP echo requests using
`System.Net.NetworkInformation.Ping`, one target after another, and records
each one as:

- **Replied** — at least one reply with status `Success`.
- **No route** — destination host or network unreachable, including a socket
  error saying the network is unreachable. Counted as down.
- **No reply** — timed out, or any other non-success status.
- **Error** — the request could not be made: the name did not resolve.

It uses .NET's `Ping` rather than `ping.exe` for two reasons. `ping.exe` output
is localised, and `ping.exe` **exits 0 when a router answers "Destination host
unreachable"**, which would report a dead tunnel as healthy. Errors are
classified by `SocketErrorCode`, which is not localised either.

### WireGuard (`usrWgTunnel`)

WireGuard for Windows runs each active tunnel as a Windows service named
`WireGuardTunnel$<tunnel name>`. Deactivating the tunnel in the WireGuard app
removes that service.

1. **Tunnel active** — the service exists and its status is `Running`. A
   missing service means the tunnel is deactivated; any other status (Stopped,
   StartPending…) counts as down.
2. **Handshake age per peer** — `wg.exe show <tunnel> latest-handshakes`. A peer
   is **current** when its last handshake is no older than
   `usrHandshakeMaxAgeSec`, and **stale** when it is older or has never
   handshaked. WireGuard re-handshakes about every two minutes while traffic
   flows, so a peer that has gone quiet for longer than that, with traffic
   offered, has stopped answering.

`wg.exe` is looked for in 64-bit Program Files first (so a 32-bit agent still
finds it), then on `PATH`. It reads WireGuard state only through
`wg.exe show <tunnel> latest-handshakes`, `transfer` and `allowed-ips`. It never
calls `dump`, `private-key` or `showconf`, which print the tunnel's private key.

### Any or all

`usrRequire` applies to each check separately. With `any` (the default), ping
is up if any target replied and WireGuard is up if any peer is current. With
`all`, every target must reply and every peer must be current.

**Read-only.** It changes nothing on the endpoint. It sends ICMP echo requests
to the configured targets only, reads one service's status and reads WireGuard
state. On the alert path it also calls `Find-NetRoute` (Windows 8 / Server 2012
and later) for the diagnostic.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Connection Health - Ping Targets Not Responding [Win]` |
| Description | Alerts when ping targets stop replying or WireGuard peers stop handshaking, e.g. across a site-to-site tunnel. Read-only. Bad input or a failed check also alerts. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | PowerShell |
| Target OS | Windows |
| Level | *not standardised yet — decide at save time* (manifest carries `4`, matching our other recent monitors) |
| Timeout | 180 seconds |
| Attachments | None (monitors cannot have them) |
| Monitor interval | Set in the monitoring policy. 5 minutes is a sensible start. |

Paste the whole of `connection-health-ping-targets-not-responding-win.ps1` as
the script body, then add the input variables below. Or import the `.cpt` that
CI builds from `component.json`.

**Updating from v1.** The component already exists in Datto (UID in
`component.json`). Open it, replace the script body with the v2 file, add the
two new input variables `usrWgTunnel` and `usrHandshakeMaxAgeSec`, and save.
That keeps the UID; an import would create a second component. Monitors
already in policies keep working unchanged: with `usrWgTunnel` empty, v2
behaves exactly like v1 and produces the same alert text. Re-push each
monitoring policy that uses it so the new body reaches devices.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrTargets` | String | *(empty)* | 1–8 IPv4/IPv6 addresses or hostnames, space- or comma-separated. Pick hosts that are always on, ideally the far gateway's LAN address. IPs beat hostnames: if DNS also crosses the tunnel, a down tunnel shows as a resolution error instead of "no reply". Empty: no ping check. |
| `usrRequire` | Selection | `Any` | `Any`: alert only when nothing replies / no peer is current. `All`: alert when any target is silent or any peer is stale. |
| `usrPingCount` | String | `3` | 1–10. Pings sent to each target. |
| `usrReplyTimeoutSec` | String | `2` | 1–5. Seconds to wait for each reply. |
| `usrWgTunnel` | String | *(empty)* | Optional. The tunnel's name as the WireGuard app shows it (its `.conf` file name without the extension). 1–32 characters: letters, digits, `_ = + . -`, not starting with `-`. Empty: no WireGuard check. |
| `usrHandshakeMaxAgeSec` | String | `300` | 150–3600. A peer whose last handshake is older than this is stale. The floor of 150 sits just above WireGuard's two-minute re-handshake interval. |

**At least one of `usrTargets` and `usrWgTunnel` must be set.** Set both to
check both.

No client-specific value is hardcoded. Each input is validated and the monitor
**refuses to run** on a bad value instead of falling back to a default. Targets
and the tunnel name are passed to .NET or to `wg.exe` as data, never to a shell,
and must match their patterns above.

Pings are sequential and a miss waits the full timeout, so the worst case is
targets × count × timeout. The monitor refuses any combination over 120
seconds; the defaults with 8 targets come to 48.

There is no `usrSource`: .NET `Ping` cannot bind a source address, and a
Windows host behind a tunnel does not need one. See Known limits.

## Health reporting

Every run prints exactly one result block with one `STATUS=` line, and exits
0 only when every configured check is healthy. The line starts with one of
four verdicts. When both checks are configured it carries both, as
`ping: … | WireGuard <tunnel>: …`, and the **worst** verdict wins, in this
order: down, degraded, could not run, up.

| Verdict | Exit | Meaning |
|---|---|---|
| `Connection up:` | 0 | Every configured check passed. |
| `Connection down:` | 1 | A check positively saw the connection down. |
| `Connection degraded:` | 1 | With `usrRequire=all`, some but not all targets replied, or some but not all peers are current. |
| `Check could not run:` | 1 | The monitor could not tell. Treated as a fault: a monitor that cannot see the tunnel is blind. |

### What each check reports

| Check | Condition | Contributes | Text in the status line |
|---|---|---|---|
| Ping | Enough targets replied (`any`: one; `all`: every one) | up | `N of M targets replied (<target> 3/3 24 ms; …)` or `all M targets replied (…)` |
| Ping | No target replied (timed out, or no route) | down | `0 of M targets replied (<target> no reply; <target> no route)` |
| Ping | `all`, some but not every target replied | degraded | `K of M targets did not reply and all are required (…)` |
| Ping | Every target failed to resolve | could not run | `ping failed on every target (<first error>)` |
| Ping | Some targets failed to resolve | — | listed as `<target> error: <reason>`; the others decide |
| WireGuard | No `WireGuardTunnel$<name>` service (tunnel deactivated, or wrong name) | down | `tunnel is not active (no tunnel service)` |
| WireGuard | Service present but not `Running` | down | `tunnel service is Stopped` (or the status it reports) |
| WireGuard | No peers configured in the tunnel | down | `no peers configured` |
| WireGuard | Enough peers current (`any`: one; `all`: every one) | up | `N of M peers handshaked within 300s (peer 1 42s ago; …)` |
| WireGuard | No peer current | down | `0 of M peers handshaked within 300s (peer 1 17m ago (stale); peer 2 never)` |
| WireGuard | `all`, some but not every peer current | degraded | `K of M peers stale and all are required (…)` |
| WireGuard | `wg.exe` not found | could not run | `wg.exe not found (WireGuard for Windows not installed in the usual place)` |
| WireGuard | `wg.exe show` failed | could not run | `wg show failed: <reason>` |
| WireGuard | `wg.exe show` output not as expected | could not run | `unexpected output from wg show latest-handshakes` |
| Either | Neither `usrTargets` nor `usrWgTunnel` set | could not run | `nothing to check; set usrTargets …, usrWgTunnel …, or both` |
| Either | An input variable is invalid, or the ping settings exceed the runtime budget | could not run | `<which input> must be … (got '…')` / `… could take Ns; keep it to 120s or less` |
| Either | The script dies unexpectedly | could not run | `the monitor stopped unexpectedly (<error>)`, via a top-level `trap` |

A mistyped tunnel name looks exactly like a deactivated tunnel (`tunnel is not
active`), because both mean the service does not exist. Check the name against
the WireGuard app the first time a new monitor alerts.

Peers are named `peer 1`, `peer 2`… in the order `wg.exe` lists them. Public
keys and endpoints stay out of the status line, which can flow on into a ticket.

### What it does not report

- **Which specific peer matters.** `all` means every peer in the tunnel. Use
  `any`, or a separate tunnel per site-to-site link, where peers come and go.
- **Throughput, latency trends or packet loss below 100%.** Ping reports
  replies and average RTT per target in the status line, but no threshold
  applies to them; a target that answers 1 of 3 pings counts as replied.
- **Endpoint changes, MTU problems, or traffic that handshakes but does not
  flow.** The diagnostic shows rx/tx bytes per peer, but nothing alerts on
  them.
- **Tunnels that are not WireGuard for Windows** (RRAS, IPsec, OpenVPN, a
  firewall appliance). Those are covered by the ping check only.

### Diagnostic block

Printed on the alert path only, after the result block:

- per ping target: replies, failure statuses, and the interface and next hop
  `Find-NetRoute` chooses for IP targets;
- for WireGuard: the tunnel service and its status, and per peer its number,
  the first 8 characters of its public key, its last handshake, its allowed IPs
  and its rx/tx byte counters (no endpoint, no private key);
- the settings in force.

## How to tell it worked

Run it as a **Scripts** component first and read the raw output. Expect exactly
one result block with one `STATUS=` line and no space after the `=`.

Healthy, ping only (identical to v1):

    <-Start Result->
    STATUS=Connection up: 2 of 2 targets replied (10.x.x.1 3/3 24 ms; 10.x.x.10 3/3 26 ms)
    <-End Result->

Healthy, both checks:

    <-Start Result->
    STATUS=Connection up: ping: 1 of 1 target replied (10.x.x.1 3/3 24 ms) | WireGuard site-b: 1 of 1 peer handshaked within 300s (peer 1 31s ago)
    <-End Result->

Alert, tunnel deactivated:

    <-Start Result->
    STATUS=Connection down: ping: 0 of 1 target replied (10.x.x.1 no reply) | WireGuard site-b: tunnel is not active (no tunnel service)
    <-End Result->
    <-Start Diagnostic->
    == 10.x.x.1 : 0/3 replies
       failures: TimedOut x3
       route: interface 'Ethernet', next hop 192.168.x.1
    == WireGuard site-b
       service: WireGuardTunnel$site-b not found
    == settings: …
    <-End Diagnostic->

Then, on an internal test tunnel:

1. Deactivate the tunnel in the WireGuard app: expect `tunnel is not active`.
2. Activate it, then stop the **far** end: within `usrHandshakeMaxAgeSec` plus
   one monitor interval, expect the peer `(stale)` and `Connection down`.

## Test coverage completed

**v2 (2026-11-12): 43-case sweep, run twice** — under Windows PowerShell 5.1
and PowerShell 7.6 on Windows 11, with WireGuard for Windows installed but no
tunnel configured. Each whole-script case asserts the exit code, exactly one
result block and the status text:

- ping regression (v1 behaviour and wording): localhost up, a TEST-NET address
  timing out, one of two with `any` and `all`, an unknown host, an option
  injection (`-f`), a `$( )` subexpression, `+3`, and the runtime budget;
- WireGuard against this machine: a tunnel service that does not exist, alone
  and alongside a live and a failing ping target, every invalid tunnel name
  (space, `;`, `$`, 33 characters, leading `-`) and threshold, and the
  diagnostic's service and settings lines;
- the real `wg.exe` against a tunnel that does not exist, under
  `ErrorActionPreference = Stop`: the error is captured and reported, not
  thrown;
- the WireGuard verdict through the script's own `Measure-WgPeers` and
  `Get-Verdict` functions with scripted `wg.exe` output: fresh, stale and
  never-handshaked peers, a custom threshold, two peers under `any` and `all`,
  no peers, malformed output, blank lines, age formatting, and every
  combination of verdicts to confirm the worst wins.

**v1:** 18 cases under PowerShell 7.4 on Linux, and 6 smoke cases on Windows 11.

**Not verified:** a live tunnel service (running or stopped), Windows
PowerShell 2.0 (written to 2.0 syntax but not executed there), a 32-bit agent
finding `wg.exe`, `Find-NetRoute` output, and IPv6 targets.

## Known limits

- **An idle tunnel looks stale.** WireGuard only handshakes when there is
  traffic to send. A WireGuard-only monitor on a tunnel with no traffic and no
  `PersistentKeepalive` will see handshakes age past the threshold and alert.
  Either set `PersistentKeepalive = 25` on the peer, or also set `usrTargets`
  to a far-side host: the pings run first and generate the traffic.
- **ICMP must be allowed** end to end for the ping check, including Windows
  Firewall on the target if the target is a Windows host. A blocked echo
  request looks exactly like a dead tunnel.
- **Ping measures reachability, not the tunnel.** Under `all`, a far-side host
  that is down for its own reasons alerts as a tunnel problem.
- **`wg.exe` has no timeout.** If it ever hung, Datto's 180-second component
  timeout would end the run without a result block. Windows PowerShell 2.0 has
  no clean way to bound a native command that keeps its output; not seen in
  testing.
- **No source binding.** If the monitor ever has to run on a Windows tunnel
  endpoint (RRAS) where the tunnel only carries LAN-sourced traffic, it needs
  `ping.exe -S`, and with it localised output parsing. Not written.
- The `Find-NetRoute` diagnostic line is skipped silently on Windows 7 /
  Server 2008 R2.

## Open questions

- **Peer selection.** If a tunnel needs some peers watched and others ignored,
  a later version could take a list of public-key prefixes. Not built until
  someone needs it.
- **The name** says "Ping Targets", but v2 also checks WireGuard. Renaming in
  Datto keeps the UID; decide whether the wider scope is worth a rename.
- **Component Level** (access tier) is not standardised. Decide at save time.
- **Result keyword.** `STATUS=` per our monitor contract; confirm on the first
  script-mode run.
