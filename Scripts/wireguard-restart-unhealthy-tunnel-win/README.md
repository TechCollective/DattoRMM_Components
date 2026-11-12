# WireGuard - Restart Unhealthy Tunnel [Win]

A Datto RMM script component for Windows. It restarts a WireGuard for Windows
tunnel **only when that is warranted**, then checks that a peer handshakes
afterwards. It's the remediation partner of the
`Connection Health - Ping Targets Not Responding [Win]` monitor's WireGuard
check, and uses the same health test.

> **Status: Not Validated.** Written 2026-11-12. Reviewed against the security
> checklist the same day. It ran on Windows 11 under Windows PowerShell 5.1
> and PowerShell 7.6, 29 cases each: every input check, the "tunnel not
> active" path against a real WireGuard for Windows install, and the
> handshake and verify logic through the script's own functions. **The
> restart itself has not run against a live tunnel service.**

## What it does

**It changes the endpoint:** it can stop and start a WireGuard tunnel service.
Everything else it does is read-only, except for one small state file.

WireGuard for Windows runs each active tunnel as a Windows service named
`WireGuardTunnel$<tunnel name>`. Deactivating a tunnel in the WireGuard app
removes the service.

It only restarts when **all** of these hold, and says which one stopped it
otherwise:

1. **The tunnel is unhealthy.** Its service isn't running, or no peer has
   completed a handshake within `usrHandshakeMaxAgeSec`. That's the same test
   the Connection Health monitor applies. `usrMode = Always` skips this gate.
2. **The tunnel is meant to be running.** Its service exists and isn't
   Disabled. A missing service means someone deactivated the tunnel in the
   WireGuard app, or the name is wrong. A Disabled service means someone
   turned it off on purpose. Either way it stays off, and this component never
   activates a tunnel.
3. **It wasn't restarted by this component within `usrCooldownMin`.** That
   stops a monitor's automatic response from restarting the tunnel in a loop.
   `usrMode = Always` skips this gate.

**How it restarts:** it stops the service, waits up to 30 seconds for it to
stop, then starts it and waits up to 30 seconds for it to run. Starting the
service re-reads the tunnel's stored configuration.

**How it verifies:** it waits up to `usrVerifySec` for any peer to handshake
*after* the restart. To prompt one, it pings `usrPingTarget`, or else the
first address of each peer's first IPv4 `AllowedIPs` range, skipping
`0.0.0.0/0`.

**What it reads:** WireGuard state only through `wg.exe show <tunnel>
latest-handshakes` and `allowed-ips`, looking in 64-bit Program Files first so
a 32-bit agent still finds it. It never prints keys.

**What it writes:** one file,
`%ProgramData%\TechCollective\WireGuard\restart-<tunnel>.last`, holding the
time of its last restart, for the cooldown.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `WireGuard - Restart Unhealthy Tunnel [Win]` |
| Description | Restarts a WireGuard for Windows tunnel service only if it is unhealthy and meant to be running, then confirms a peer handshakes. |
| Category | Scripts |
| Script type | PowerShell |
| Target OS | Windows |
| Level | *not standardised yet — decide at save time.* The manifest carries `4`. This one restarts a tunnel, so consider who should be able to run it. |
| Timeout | 300 seconds |
| Attachments | None |

Paste the whole of `wireguard-restart-unhealthy-tunnel-win.ps1` as the script
body and add the input variables below, or import the `.cpt` that CI builds.

### Using it as a monitor response

In the monitoring policy, the WireGuard monitor can run this component as its
response when it alerts. Leave `usrMode` at **If unhealthy** and keep a
cooldown. Each response run then re-checks health first, does nothing if the
tunnel has recovered, and won't restart more than once per cooldown.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrWgTunnel` | String | *(empty)* | **Required.** The tunnel's name as the WireGuard app shows it. 1–32 characters: letters, digits, `_ = + . -`, not starting with `-`. |
| `usrMode` | Selection | `If unhealthy` | **If unhealthy:** all three gates apply. **Always:** restart even when healthy, ignoring the cooldown. It still never starts a tunnel that's deactivated or Disabled. |
| `usrHandshakeMaxAgeSec` | String | `300` | 150–3600. Match the monitor's value, so both agree on what "unhealthy" means. |
| `usrVerifySec` | String | `30` | 10–120. How long to wait after the restart for a peer to handshake. |
| `usrCooldownMin` | String | `15` | 0–1440. `0` turns the cooldown off. |
| `usrPingTarget` | String | *(empty)* | Optional. A far-side IP or hostname to ping after the restart to prompt a handshake. Set it when the peer's allowed IPs are `0.0.0.0/0`. |

No customer-specific value is hardcoded. Each input is validated, and the
script **refuses to run** (exit 2) on a bad value rather than falling back to
a default.

## Exit behaviour

The last line of output is always `STATUS=<keyword>`. The line before it says
what happened in plain words, and a `Before:` line gives the health check that
decided it.

| Exit | STATUS | Meaning | Tunnel touched? |
|---|---|---|---|
| 0 | `HEALTHY` | Healthy; nothing to do. | No |
| 0 | `RESTARTED` | Restarted, and a peer handshaked afterwards. | Yes |
| 1 | `STILL_UNHEALTHY` | Restarted, but no peer handshaked within `usrVerifySec`. The far side, the path to it, or the lack of traffic is the problem. | Yes |
| 1 | `FAILED` | Stopping or starting the service failed; the message says which, and whether **the tunnel is down**. Also: `wg.exe` failed or wasn't found, or the script died. | Maybe; read the message |
| 2 | `REFUSED` | An input is invalid. | No |
| 3 | `NOT_ACTIVE` | No tunnel service (deactivated, or wrong name), or it's Disabled. | No |
| 3 | `NO_PEERS` | No peers configured; a restart can't help. | No |
| 3 | `COOLDOWN` | Restarted by this component less than `usrCooldownMin` ago. | No |
| 3 | `NOT_INSTALLED` | WireGuard for Windows isn't installed. | No |

Exit 3 means "it decided not to act, and a person should look", so the job
shows as failed in Datto on purpose.

## How to tell it worked

    Before: the WireGuardTunnel$site-b service is Stopped.
    Restarting the WireGuardTunnel$site-b service...
    Waiting up to 30s for a handshake (prompting with ping to 10.x.x.1)...
    After: 1 of 1 peer(s) handshaked since the restart (peer 1 1s ago).
    Tunnel 'site-b' restarted and a peer handshaked 3s later.
    STATUS=RESTARTED

## Test order

Never a customer first.

1. An internal machine running a test tunnel. Run it while healthy, expecting
   `HEALTHY`.
2. Stop the tunnel service (`Stop-Service 'WireGuardTunnel$<name>'`): expect
   `RESTARTED`.
3. Deactivate the tunnel in the WireGuard app: expect `NOT_ACTIVE`, and the
   tunnel stays off.
4. Only then attach it to a monitor as a response, on one site.

## Test coverage completed

**Local (Windows 11, WireGuard for Windows installed, no tunnel), under
Windows PowerShell 5.1 and PowerShell 7.6, 29 cases each:**

- every invalid input is refused;
- the drop-down accepted as either its value or its display name;
- a tunnel with no service gives `NOT_ACTIVE`, and nothing is written;
- the real `wg.exe` error is captured under `ErrorActionPreference = Stop`;
- through the script's own functions: fresh, stale, never-handshaked and mixed
  peers, no peers, malformed output, "handshaked since the restart" either
  way, and nudge targets from `/32`, `/24`, `/23`, `0.0.0.0/0` and IPv6
  ranges.

**Tier 1 (CI, every PR):** every invalid input is refused, and the runner
(no WireGuard) reports `NOT_INSTALLED` and writes nothing. The Windows harness
can't yet build a tunnel, so the live-tunnel cases are listed in `test.json`
as Tier 2.

**Not verified:**
- a live tunnel service: healthy, stopped, restarted, Disabled, cooldown and
  `Always`;
- Windows PowerShell 2.0;
- a 32-bit agent.

## Known limits

- **It can't tell whose fault it is.** `STILL_UNHEALTHY` after a restart
  usually means the far side, the ISP path or a firewall is the problem; the
  cooldown stops repeated restarts.
- **The verify nudge needs a route.** With allowed IPs of `0.0.0.0/0`, no
  `usrPingTarget` and no `PersistentKeepalive`, nothing prompts a handshake,
  and the result is `STILL_UNHEALTHY` even when the tunnel is fine.
- **A restart drops the tunnel for a moment.** Sessions over it are
  interrupted. If the service fails to start, the tunnel stays down. The
  message says so, and the WireGuard app's log says why.
- **It never activates a tunnel.** If a deactivated tunnel should be on,
  a person activates it in the WireGuard app. Doing that remotely means
  handling the tunnel's stored configuration, which this component
  deliberately doesn't touch.

## Open questions

- **Level** (access tier) isn't standardised. Decide at save time; this
  component changes network state.
- **A Windows harness `command` step** would let Tier 1 build a real tunnel on
  the runner (install WireGuard, `wireguard.exe /installtunnelservice`), as the
  Linux test does.
