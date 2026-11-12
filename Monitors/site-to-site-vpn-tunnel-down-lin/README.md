# Site-to-Site VPN - Tunnel Down [Lin]

A Datto RMM custom monitor for Linux. Pings hosts on the far side of a
site-to-site tunnel and alerts when they stop answering. Meant to run on the
tunnel endpoint itself (a WireGuard gateway, say) or on any Linux host behind it.

> **Status: Not Validated.** Written 2026-11-12. Reviewed against the monitor
> contract and security checklist the same day. 19-case regression sweep passing
> in a test container. Not yet run on a real tunnel endpoint.

Its Windows counterpart is `Site-to-Site VPN - Tunnel Down [Win]`, with the same
inputs (except `usrSource`) and the same alert wording.

## What it does

For each target in `usrTargets` it runs `ping -n -c <count> -w <count + wait>`,
one target after another, and decides from ping's exit code and output:

- **Replied** — at least one echo reply came back.
- **No reply** — packets went out and nothing came back.
- **No route** — the kernel refused to send, because the route is gone or a
  blackhole or unreachable route has replaced it. That is what a tunnel that has
  dropped its route looks like, so it counts as down and not as a check failure.
- **Error** — ping could not run for this target: the name did not resolve, or
  `usrSource` does not exist.

With `usrRequire=any` (the default), the tunnel is up if any target replied.
With `all`, every target must reply.

**Read-only.** It changes nothing on the endpoint. It sends ICMP echo requests
to the configured targets only, and on the alert path also runs
`ip route get` and `getent ahosts` for the diagnostic.

It knows nothing about the tunnel technology. WireGuard-specific checks are
planned for this same component; see Open questions.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Site-to-Site VPN - Tunnel Down [Lin]` |
| Description | Alerts when hosts across a site-to-site tunnel stop answering ping. Read-only. Bad input or a failed check also alerts. |
| Category | **Monitors** — permanent, cannot be changed after the first save |
| Script type | Bash (Unix) |
| Target OS | Linux |
| Level | *not standardised yet — decide at save time* (manifest carries `4`, matching our other recent monitors) |
| Timeout | 180 seconds |
| Attachments | None (monitors cannot have them) |
| Monitor interval | Set in the monitoring policy. 5 minutes is a sensible start. |

Paste the whole of `site-to-site-vpn-tunnel-down-lin.sh` as the script body,
then add the input variables below. Or import the `.cpt` that CI builds from
`component.json`.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrTargets` | String | *(empty)* | **Required.** 1–8 IPv4/IPv6 addresses or hostnames, space- or comma-separated. Pick hosts that are always on, ideally the far gateway's LAN address. IPs beat hostnames: if DNS also crosses the tunnel, a down tunnel shows as a resolution error instead of "no reply". |
| `usrRequire` | Selection | `Any` | `Any`: alert only when nothing replies. `All`: alert when any target is silent. |
| `usrPingCount` | String | `3` | 1–10. Pings sent to each target, one second apart. |
| `usrReplyTimeoutSec` | String | `2` | 1–5. Extra seconds to wait for the last reply. |
| `usrSource` | String | *(empty)* | Optional. Interface name (`wg0`) or local IP passed to `ping -I`. Needed on a gateway whose tunnel only carries traffic sourced from the LAN, such as IPsec policy-based selectors. On WireGuard, routing via `AllowedIPs` usually makes it unnecessary. |

No client-specific value is hardcoded; every address is an input variable. Each
input is validated and the monitor **refuses to run** on a bad value instead of
falling back to a default. Target entries may not begin with `-` and may contain
only letters, digits, `.`, `:` and `-`, so nothing typed into a field can reach
ping as an option or reach the shell.

Worst-case runtime is bounded by the input limits: 8 × (10 + 5) = 120 seconds.

## Exit behaviour

| Host state | Result |
|---|---|
| `usrTargets` not set | exit 1, `STATUS=Check could not run: usrTargets is empty…` |
| Any target replies (`any`), or all reply (`all`) | exit 0, `STATUS=Tunnel up: …` with per-target replies and average RTT |
| No target replies | exit 1, `STATUS=Tunnel down: 0 of N targets replied (…)` |
| Some but not all reply, with `all` | exit 1, `STATUS=Tunnel degraded: …` |
| Route to the targets has gone | Counted as down: `… no route` |
| ping errors on **every** target (bad names, bad `usrSource`) | exit 1, `STATUS=Check could not run: ping failed on every target (…)` |
| `ping` not installed | exit 1, `STATUS=Check could not run: the ping command is not installed` |
| An input variable is invalid | exit 1, `STATUS=Check could not run: <which input and why>` |
| The script dies or is killed | exit 1, `STATUS=Check could not run: the monitor stopped unexpectedly (exit N)` via an `EXIT` trap |

"Could not tell" is treated as a **fault**: a monitor that cannot see the tunnel
is blind, and silence is how a dead tunnel goes unnoticed for a week.

A diagnostic block is printed on the alert path only. It holds each target's
ping summary line, `ip route get` for IP targets (this shows at a glance whether
traffic is leaving via the tunnel interface or the WAN), what hostnames resolve
to, and the settings in force.

## How to tell it worked

Run it as a **Scripts** component first and read the raw output. Expect exactly
one result block with one `STATUS=` line and no space after the `=`.

Healthy:

    <-Start Result->
    STATUS=Tunnel up: 2 of 2 targets replied (10.x.x.1 3/3 24 ms; 10.x.x.10 3/3 26 ms)
    <-End Result->

Alert:

    <-Start Result->
    STATUS=Tunnel down: 0 of 2 targets replied (10.x.x.1 no route; 10.x.x.10 no route)
    <-End Result->
    <-Start Diagnostic->
    == 10.x.x.1 (exit 2)
    route: …
    …
    <-End Diagnostic->

Then take the tunnel down on purpose (`wg-quick down wg0` on an internal test
pair) and confirm the alert text says what happened.

## Test coverage completed

19 cases in a test container, each asserting the exit code and the result-block
contract: healthy, one-of-two with `any` and with `all`, all down, route removed
(`unreachable` and `blackhole` routes), unknown host, nonexistent `usrSource`,
`usrSource=lo`, empty and oversized target lists, an option-injection attempt
(`-f`), a shell metacharacter, every invalid-input path, no `ping` on PATH, and
SIGTERM mid-run. `shellcheck -S warning` clean.

**Not verified:** a real tunnel, IPv6 targets (the test container had no IPv6),
busybox `ping`, non-Debian distros.

## Known limits

- **ICMP must be allowed** end to end. A far-side host or firewall that drops
  echo requests looks exactly like a dead tunnel. Test each target by hand first.
- **It measures reachability, not the tunnel.** A target that is down for its
  own reasons alerts as "tunnel down" under `all`; use `any` with several
  targets to tell the two apart.
- `bash` 4+ is required (Debian, Ubuntu, RHEL, SUSE all qualify; Alpine needs
  it installed). `ping` from iputils or busybox. `timeout`, `ip`, `getent`,
  `grep` and `awk` are used when present; without them the diagnostic is
  thinner but the check still works.
- IPv6 targets use `ping6` when it exists, else `ping`. Not tested.
- Output is parsed with `LC_ALL=C`; the decision itself comes from ping's exit
  code, not its text, except for recognising "no route".

## Open questions

- **WireGuard checks (next version).** Planned additions to this component:
  interface exists and is up (`ip link show`), and the latest handshake age per
  peer from `wg show <iface> latest-handshakes` against a threshold (WireGuard
  re-handshakes every two minutes while traffic flows, so a handshake older than
  about three minutes on a tunnel with keepalive set means the peer is gone).
  This will add input variables (`usrWgInterface`, a handshake-age threshold,
  and a check-mode selection), so it is a material change: new branch, PR,
  README update. `wg show` never prints private keys, but it does print peer
  public keys and endpoints; keep those out of the result line.
- **Component Level** (access tier) is not standardised. Decide at save time.
- **Result keyword.** `STATUS=` per our monitor contract; confirm on the first
  script-mode run, as with every monitor here.
