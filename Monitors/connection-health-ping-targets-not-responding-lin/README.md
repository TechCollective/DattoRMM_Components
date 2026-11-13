# Connection Health - Ping Targets Not Responding [Lin]

A Datto RMM custom monitor for Linux. It watches a connection that should
always be up, typically a site-to-site tunnel, in one or both of two ways:

- **Ping** — pings the hosts you give it and alerts when they stop answering.
- **WireGuard** — checks that a WireGuard interface exists and is up, and that
  its peers have completed a handshake recently.

The targets and the interface are set per monitor, so the same component can
watch any number of connections. Run it on the tunnel endpoint itself (a
WireGuard gateway, say) or, for the ping check, on any Linux host behind it.

> **Status: Not Validated.** v1 written 2026-11-12 (ping only). v2, adding the
> WireGuard checks, written the same day: reviewed against the monitor contract
> and security checklist, and a 55-case stub-based sweep passing. **Neither
> version has run on a real tunnel endpoint yet.**

Its Windows counterpart is `Connection Health - Ping Targets Not Responding [Win]`,
with the same alert wording. Its WireGuard check reads the Windows tunnel
service instead of a network interface; see that README.

## What it does

Pings run first, then the WireGuard check. The order matters: traffic through
the tunnel makes WireGuard re-handshake with a live peer, so the handshake age
read afterwards reflects the peer rather than an idle tunnel.

### Ping (`usrTargets`)

For each target it runs `ping -n -c <count> -w <count + wait>`, one target
after another, and decides from ping's exit code and output:

- **Replied** — at least one echo reply came back.
- **No reply** — packets went out and nothing came back.
- **No route** — the kernel refused to send, because the route is gone or a
  blackhole or unreachable route has replaced it. That is what a tunnel that has
  dropped its route looks like, so it counts as down and not as a check failure.
- **Error** — ping could not run for this target: the name did not resolve,
  `usrSource` does not exist, or ping hung past its own deadline.

### WireGuard (`usrWgInterface`)

1. **Interface present and up** — `ip -o link show dev <iface>` (or
   `/sys/class/net/<iface>/flags` where `ip` is missing). `wg-quick down`
   deletes the interface; `ip link set <iface> down` leaves it present without
   the `UP` flag. Both count as down.
2. **Handshake age per peer** — `wg show <iface> latest-handshakes`. A peer is
   **current** when its last handshake is no older than
   `usrHandshakeMaxAgeSec`, and **stale** when it is older or has never
   handshaked. WireGuard re-handshakes about every two minutes while traffic
   flows, so a peer that has gone quiet for longer than that, with traffic
   offered, has stopped answering.

It reads WireGuard state only through `wg show <iface> latest-handshakes`,
`transfer` and `allowed-ips`. It never calls `dump`, `private-key` or
`showconf`, which print the interface's private key.

### Any or all

`usrRequire` applies to each check separately. With `any` (the default), ping
is up if any target replied and WireGuard is up if any peer is current. With
`all`, every target must reply and every peer must be current.

**Read-only.** It changes nothing on the endpoint. It sends ICMP echo requests
to the configured targets only and reads interface and WireGuard state. On the
alert path it also runs `ip route get` and `getent ahosts` for the diagnostic.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Connection Health - Ping Targets Not Responding [Lin]` |
| Description | Alerts when ping targets stop replying or WireGuard peers stop handshaking, e.g. across a site-to-site tunnel. Read-only. Bad input or a failed check also alerts. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Bash (Unix) |
| Target OS | Linux |
| Level | *not standardised yet — decide at save time* (manifest carries `4`, matching our other recent monitors) |
| Timeout | 180 seconds |
| Attachments | None (monitors cannot have them) |
| Monitor interval | Set in the monitoring policy. 5 minutes is a sensible start. |

Paste the whole of `connection-health-ping-targets-not-responding-lin.sh` as
the script body, then add the input variables below.

> **Do not import the `.cpt` for this one; paste instead.** On 2026-11-12 the
> CI-built `.cpt` was refused by Datto's Import Component with "We're having
> trouble loading this data", while the `[Win]` twin imported fine. Splitting
> it showed the cause is the script body as a whole: either half imported with
> all five variables, the full body failed even with no variables, and no
> single line stood out. Pasting the same body into the Create Component form
> saved without trouble. The likely cause is a filter on Datto's import upload
> that scores shell-command-like text and blocks once the total passes a
> threshold; that is inferred, not confirmed by Datto. Re-test the import
> after any material change to the script, and update this note.

**Updating from v1.** The component already exists in Datto (UID in
`component.json`). Open it, replace the script body with the v2 file, add the
two new input variables `usrWgInterface` and `usrHandshakeMaxAgeSec`, and save.
That keeps the UID; an import would create a second component. Monitors
already in policies keep working unchanged: with `usrWgInterface` empty, v2
behaves exactly like v1 and produces the same alert text. Re-push each
monitoring policy that uses it so the new body reaches devices.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrTargets` | String | *(empty)* | 1–8 IPv4/IPv6 addresses or hostnames, space- or comma-separated. Pick hosts that are always on, ideally the far gateway's LAN address. IPs beat hostnames: if DNS also crosses the tunnel, a down tunnel shows as a resolution error instead of "no reply". Empty: no ping check. |
| `usrRequire` | Selection | `Any` | `Any`: alert only when nothing replies / no peer is current. `All`: alert when any target is silent or any peer is stale. |
| `usrPingCount` | String | `3` | 1–10. Pings sent to each target, one second apart. |
| `usrReplyTimeoutSec` | String | `2` | 1–5. Extra seconds to wait for the last reply. |
| `usrSource` | String | *(empty)* | Optional. Interface name (`wg0`) or local IP passed to `ping -I`. Needed on a gateway whose tunnel only carries traffic sourced from the LAN, such as IPsec policy-based selectors. On WireGuard, routing via `AllowedIPs` usually makes it unnecessary. |
| `usrWgInterface` | String | *(empty)* | Optional. WireGuard interface to check, such as `wg0`. Up to 15 characters: letters, digits, `_ . = + -`, not starting with `-`. Empty: no WireGuard check. |
| `usrHandshakeMaxAgeSec` | String | `300` | 150–3600. A peer whose last handshake is older than this is stale. The floor of 150 sits just above WireGuard's two-minute re-handshake interval. |

**At least one of `usrTargets` and `usrWgInterface` must be set.** Set both to
check both.

No client-specific value is hardcoded; every address and name is an input
variable. Each input is validated and the monitor **refuses to run** on a bad
value instead of falling back to a default. Target entries may not begin with
`-` and may contain only letters, digits, `.`, `:` and `-`, so nothing typed
into a field can reach ping or wg as an option or reach the shell.

Worst-case runtime is bounded by the input limits: pings 8 × (10 + 5) = 120
seconds, plus at most 3 × 10 seconds of WireGuard reads.

## Health reporting

Every run prints exactly one result block with one `STATUS=` line, and exits
0 only when every configured check is healthy. The line starts with one of
four verdicts. When both checks are configured it carries both, as
`ping: … | WireGuard <iface>: …`, and the **worst** verdict wins, in this
order: down, degraded, could not run, up.

| Verdict | Exit | Meaning |
|---|---|---|
| `Connection up:` | 0 | Every configured check passed. |
| `Connection down:` | 1 | A check positively saw the connection down. |
| `Connection degraded:` | 1 | With `usrRequire=all`, some but not all targets replied, or some but not all peers are current. |
| `Check could not run:` | 1 | The monitor could not tell. Treated as a fault: a monitor that cannot see the tunnel is blind, and silence is how a dead tunnel goes unnoticed for a week. |

### What each check reports

| Check | Condition | Contributes | Text in the status line |
|---|---|---|---|
| Ping | Enough targets replied (`any`: one; `all`: every one) | up | `N of M targets replied (<target> 3/3 24 ms; …)` or `all M targets replied (…)` |
| Ping | No target replied (no reply, or no route) | down | `0 of M targets replied (<target> no reply; <target> no route)` |
| Ping | `all`, some but not every target replied | degraded | `K of M targets did not reply and all are required (…)` |
| Ping | ping errored on **every** target (unknown host, bad `usrSource`, hung) | could not run | `ping failed on every target (<first error>)` |
| Ping | ping errored on some targets only | — | listed as `<target> error: <reason>`; the others decide |
| Ping | `ping` not installed | could not run | `the ping command is not installed` |
| WireGuard | Interface missing (`wg-quick down`, never started) | down | `interface does not exist (tunnel not started)` |
| WireGuard | Interface present without the `UP` flag | down | `interface is administratively down` |
| WireGuard | No peers configured on the interface | down | `no peers configured` |
| WireGuard | Enough peers current (`any`: one; `all`: every one) | up | `N of M peers handshaked within 300s (peer 1 42s ago; …)` |
| WireGuard | No peer current | down | `0 of M peers handshaked within 300s (peer 1 17m ago (stale); peer 2 never)` |
| WireGuard | `all`, some but not every peer current | degraded | `K of M peers stale and all are required (…)` |
| WireGuard | Interface is not WireGuard | could not run | `interface is not a WireGuard interface` |
| WireGuard | `wg` (wireguard-tools) not installed | could not run | `the wg command (wireguard-tools) is not installed` |
| WireGuard | `wg show` failed (permission, other) or hung | could not run | `wg show failed: <reason>` / `wg show hung and was stopped` |
| WireGuard | `wg show` output not as expected | could not run | `unexpected output from wg show latest-handshakes` |
| Either | Neither `usrTargets` nor `usrWgInterface` set | could not run | `nothing to check; set usrTargets …, usrWgInterface …, or both` |
| Either | An input variable is invalid | could not run | `<which input> must be … (got '…')` |
| Either | The script dies or is killed | could not run | `the monitor stopped unexpectedly (exit N)`, via an `EXIT` trap |

Peers are named `peer 1`, `peer 2`… in the order `wg` lists them. Public keys
and endpoints stay out of the status line, which can flow on into a ticket.

### What it does not report

- **Which specific peer matters.** `all` means every peer on the interface. On
  a hub with road-warrior clients that come and go, use `any`, or a dedicated
  interface per site-to-site link.
- **Throughput, latency trends or packet loss below 100%.** Ping reports
  replies and average RTT per target in the status line, but no threshold
  applies to them; a target that answers 1 of 3 pings counts as replied.
- **Endpoint changes, MTU problems, or traffic that handshakes but does not
  flow.** The diagnostic shows rx/tx bytes per peer, but nothing alerts on
  them.
- **Tunnels that are not WireGuard.** IPsec, OpenVPN and others are covered by
  the ping check only.

### Diagnostic block

Printed on the alert path only, after the result block:

- per ping target: ping's summary or error line, `ip route get` for IP
  targets (whether traffic leaves via the tunnel interface or the WAN), and
  what hostnames resolve to;
- for WireGuard: the interface flags and state, and per peer its number, the
  first 8 characters of its public key, its last handshake, its allowed IPs
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
    STATUS=Connection up: ping: 1 of 1 target replied (10.x.x.1 3/3 24 ms) | WireGuard wg0: 1 of 1 peer handshaked within 300s (peer 1 31s ago)
    <-End Result->

Alert, tunnel stopped:

    <-Start Result->
    STATUS=Connection down: ping: 0 of 1 target replied (10.x.x.1 no route) | WireGuard wg0: interface does not exist (tunnel not started)
    <-End Result->
    <-Start Diagnostic->
    == 10.x.x.1 (exit 2)
    route: …
    == WireGuard wg0
       link: Device "wg0" does not exist.
    == settings: …
    <-End Diagnostic->

Then, on an internal test pair:

1. `wg-quick down wg0` on the monitored end: expect `interface does not exist`.
2. Bring it back, then stop the **far** end: within `usrHandshakeMaxAgeSec`
   plus one monitor interval, expect the peer `(stale)` and `Connection down`.
3. `ip link set wg0 down` on the monitored end: expect `administratively down`.

## Test coverage completed

**v2 (2026-11-12): 55-case stub-based sweep** under bash 5.2, with `ping`,
`ip` and `wg` replaced by scripted stand-ins on a minimal `PATH`. Each case
asserts the exit code, exactly one result block and the status text:

- ping regression (v1 behaviour and wording): healthy, one of two with `any`
  and `all`, all down, no route, unknown host alone and alongside a live
  target, no `ping`, ping hanging past its deadline, `usrSource` shown, and
  every invalid-input path;
- WireGuard: fresh peer, interface missing, administratively down, stale peer,
  never-handshaked peer, a custom threshold, two peers under `any` and `all`,
  no peers, a non-WireGuard interface, permission denied, no `wg`, malformed
  `wg` output, a WireGuard-only host with no `ping`, and every invalid
  interface name and threshold;
- both checks together: every combination of up, down, degraded and could not
  run, to confirm the worst verdict wins;
- the diagnostic lists link state, key prefix, allowed IPs and transfer
  counters, and is absent when healthy;
- `wg` is only ever called with `latest-handshakes`, `transfer` and
  `allowed-ips`;
- SIGTERM mid-run still produces one result block.

**v1:** 19 cases in a Linux test container against real `ping`, including
`unreachable` and `blackhole` routes and `shellcheck -S warning`.

**Not verified:** a real WireGuard interface (the sweep uses stand-ins for
`ip` and `wg`; their output formats were copied from iproute2 and
wireguard-tools), the `/sys` fallback when `ip` is missing, userspace
`wireguard-go`, a real tunnel, IPv6 targets, busybox `ping`, non-Debian
distros. v2 has not been run through `shellcheck`.

## Known limits

- **An idle tunnel looks stale.** WireGuard only handshakes when there is
  traffic to send. A WireGuard-only monitor on a tunnel with no traffic and no
  `PersistentKeepalive` will see handshakes age past the threshold and alert.
  Either set `PersistentKeepalive = 25` on the peer, or also set `usrTargets`
  to a far-side host: the pings run first and generate the traffic.
- **ICMP must be allowed** end to end for the ping check. A far-side host or
  firewall that drops echo requests looks exactly like a dead tunnel. Test each
  target by hand first.
- **Ping measures reachability, not the tunnel.** A target that is down for its
  own reasons alerts as "Connection down" under `all`; use `any` with several
  targets to tell the two apart.
- **WireGuard needs root.** `wg show` needs `CAP_NET_ADMIN`. Datto runs
  components as root; run by hand without it, the check reports
  `wg show failed: … Operation not permitted`.
- `bash` 4+ is required (Debian, Ubuntu, RHEL, SUSE all qualify; Alpine needs
  it installed). `ping` from iputils or busybox; `wg` from wireguard-tools.
  `timeout`, `ip`, `getent`, `grep` and `awk` are used when present; without
  them the diagnostic is thinner but the checks still work.
- IPv6 targets use `ping6` when it exists, else `ping`. Not tested.
- Output is parsed with `LC_ALL=C`; the ping decision comes from ping's exit
  code, not its text, except for recognising "no route".

## Open questions

- **Peer selection.** If a hub needs some peers watched and others ignored, a
  later version could take a list of public-key prefixes. Not built until
  someone needs it.
- **The name** says "Ping Targets", but v2 also checks WireGuard. Renaming in
  Datto keeps the UID; decide whether the wider scope is worth a rename.
- **Component Level** (access tier) is not standardised. Decide at save time.
- **Result keyword.** `STATUS=` per our monitor contract; confirm on the first
  script-mode run, as with every monitor here.
