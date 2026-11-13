# WireGuard - Restart Unhealthy Tunnel [Lin]

A Datto RMM script component for Linux. It restarts a wg-quick WireGuard tunnel
**only when that is warranted**, then checks that a peer handshakes
afterwards. It's the remediation partner of the
`Connection Health - Ping Targets Not Responding [Lin]` monitor's WireGuard
check, and uses the same health test.

> **Status: Not Validated.** Written 2026-11-12. Reviewed against the security
> checklist the same day. Input validation, the config lint and the
> not-installed path were run locally; the restart paths are covered by its
> Tier 1 test, which builds a real WireGuard tunnel on the CI runner. Not yet
> run on a real gateway.

## What it does

**It changes the endpoint:** it can take a WireGuard interface down and bring
it back up. Everything else it does is read-only, except for one small state
file.

It only restarts when **all** of these hold, and says which one stopped it
otherwise:

1. **The tunnel is unhealthy.** The interface is missing or administratively
   down, or no peer has completed a handshake within `usrHandshakeMaxAgeSec`.
   That's the same test the Connection Health monitor applies.
   `usrMode = Always` skips this gate.
2. **The tunnel is meant to be running.** The interface exists now, or
   `wg-quick@<iface>` is enabled. A tunnel that's down and not enabled was
   taken down on purpose or never set to start, so it stays down.
3. **It's managed by wg-quick.** The tunnel must be either the
   `wg-quick@<iface>` systemd unit, or brought up by hand from
   `/etc/wireguard/<iface>.conf`. Interfaces owned by systemd-networkd,
   NetworkManager or anything else are reported, not touched.
4. **Its config parses.** The config is checked with `wg-quick strip`, and what
   remains is checked against the keys `wg` accepts. A broken config is caught
   *before* the tunnel is taken down, not halfway through bringing it back.
5. **It wasn't restarted by this component within `usrCooldownMin`.** That
   stops a monitor's automatic response from restarting the tunnel in a loop
   when the real fault is elsewhere. `usrMode = Always` skips this gate.

**How it restarts:**
- `systemctl restart wg-quick@<iface>` when that unit is enabled or active;
- otherwise `wg-quick down <iface>` and then `wg-quick up <iface>`.

**How it verifies:** it waits up to `usrVerifySec` for any peer to handshake
*after* the restart. To prompt one, it pings `usrPingTarget`, or else the
first address of each peer's first IPv4 `AllowedIPs` range. WireGuard starts a
handshake for any packet routed into the tunnel, whether or not the target
answers. A `0.0.0.0/0` range is skipped.

**What it reads:** WireGuard state only through `wg show <iface>
latest-handshakes` and `allowed-ips`. It never prints keys, and the config
check never echoes config text.

**What it writes:** one file, `/var/lib/tc-wireguard/restart-<iface>.last`,
holding the time of its last restart, for the cooldown.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `WireGuard - Restart Unhealthy Tunnel [Lin]` |
| Description | Restarts a wg-quick WireGuard tunnel only if it is unhealthy and meant to be running, then confirms a peer handshakes. |
| Category | Scripts |
| Script type | Bash (Unix) |
| Target OS | Linux |
| Level | *not standardised yet — decide at save time.* The manifest carries `4`. This one takes a tunnel down, so consider who should be able to run it. |
| Timeout | 300 seconds |
| Attachments | None |

Paste the whole of `wireguard-restart-unhealthy-tunnel-lin.sh` as the script
body, then add the input variables below. The `.cpt` that CI builds can be
imported, but its sibling monitor's import was refused by Datto, probably
because of how much shell-like text it contains. If this one is refused too,
paste it.

### Using it as a monitor response

In the monitoring policy, the WireGuard monitor can run this component as its
response when it alerts. Leave `usrMode` at **If unhealthy** and keep a
cooldown. Each response run then re-checks health first, does nothing if the
tunnel has recovered, and won't restart more than once per cooldown.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrWgInterface` | String | *(empty)* | **Required.** The WireGuard interface, such as `wg0`. Up to 15 characters: letters, digits, `_ . = + -`, not starting with `-`. |
| `usrMode` | Selection | `If unhealthy` | **If unhealthy:** all five gates apply. **Always:** restart even when healthy, ignoring the cooldown. It still won't start a tunnel that isn't meant to run, touch one wg-quick doesn't manage, or take down one whose config doesn't parse. |
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
| 1 | `STILL_UNHEALTHY` | Restarted, but no peer handshaked within `usrVerifySec`. The far side, the path to it, or the lack of traffic is the problem, not this host's tunnel. | Yes |
| 1 | `FAILED` | A restart step failed (the output says which, and whether **the tunnel is down**). Also: the config doesn't parse (not touched), `wg show` failed, the unit is enabled but its config is missing, or the script died. | Maybe; read the message |
| 2 | `REFUSED` | An input is invalid, or the interface isn't a WireGuard interface. | No |
| 3 | `NOT_ACTIVE` | Not running and `wg-quick@<iface>` not enabled: down on purpose. The message gives the command to bring it up for good. | No |
| 3 | `UNMANAGED` | Not managed by wg-quick. | No |
| 3 | `NO_PEERS` | No peers configured; a restart can't help. | No |
| 3 | `COOLDOWN` | Restarted by this component less than `usrCooldownMin` ago. Repeated restarts aren't fixing it; look elsewhere. | No |
| 3 | `NOT_INSTALLED` | wireguard-tools isn't installed. | No |

Exit 3 means "it decided not to act, and a person should look", so the job
shows as failed in Datto on purpose.

## How to tell it worked

A healthy tunnel:

    Before: 1 of 1 peer(s) handshaked within 300s (peer 1 41s ago).
    wg0 is healthy; nothing to do.
    STATUS=HEALTHY

A tunnel that had stopped:

    Before: interface wg0 does not exist.
    Restarting wg-quick@wg0.service...
    Waiting up to 30s for a handshake (prompting with ping to 10.x.x.1)...
    After: 1 of 1 peer(s) handshaked since the restart (peer 1 1s ago).
    wg0 restarted (systemd) and a peer handshaked 2s later.
    STATUS=RESTARTED

## Test order

Never a customer first.

1. An internal gateway. Run it while healthy, expecting `HEALTHY`.
2. `wg-quick down wg0` with the unit enabled: expect `RESTARTED`.
3. `systemctl disable --now wg-quick@wg0`: expect `NOT_ACTIVE`, and the tunnel
   stays down. Re-enable it afterwards.
4. Only then attach it to a monitor as a response, on one site.

## Test coverage completed

**Tier 1 (CI, every PR):** on an Ubuntu runner it installs wireguard-tools and
builds a real tunnel, `tctest0`, to a peer in its own network namespace. It
then checks:

- every invalid input is refused before anything is touched;
- down and not enabled gives `NOT_ACTIVE`, and the tunnel stays down;
- enabled but down: it's started and a handshake is confirmed;
- healthy is left alone, twice;
- with the peer unreachable, a restart reports `STILL_UNHEALTHY`;
- the cooldown stamp is written, and the next run is `COOLDOWN`;
- `Always` restarts inside the cooldown;
- a hand-made WireGuard interface is `UNMANAGED` and left in place;
- an interface with no peers is `NO_PEERS`;
- `lo` is refused as not WireGuard;
- a config with an unknown key is caught before the tunnel is touched.

**Local:** every input check, the not-installed path, and the config lint on
valid, unusually cased, PostUp-keyed, unknown-key, missing-section and
malformed configs. The lint was also checked to never echo a bare key line.

**Not verified:** a real gateway; distributions other than Ubuntu; userspace
`wireguard-go`; a host without systemd (the `wg-quick down`/`up` path is
covered only for an interface brought up by hand).

## Known limits

- **It can't tell whose fault it is.** `STILL_UNHEALTHY` after a restart
  usually means the far side, the ISP path or a firewall is the problem.
  Restarting this end again won't help; the cooldown exists for that reason.
- **The verify nudge needs a route.** If the peer's allowed IPs are
  `0.0.0.0/0` and `usrPingTarget` is empty, nothing prompts a handshake. Unless
  `PersistentKeepalive` is set, the result is then `STILL_UNHEALTHY` even when
  the tunnel is fine.
- **A restart drops the tunnel for a moment.** Sessions over it are
  interrupted. If this host's own management traffic runs through the tunnel,
  a failed `wg-quick up` would cut it off. The config check makes that
  unlikely, but it checks the syntax, not the values in it.
- `wg-quick strip` needs wireguard-tools from 2019 or later.
- `bash` 4+, `ip` or `/sys`, `systemctl` when present, `timeout`, `awk`.

## Open questions

- **Level** (access tier) isn't standardised. Decide at save time; this
  component changes network state.
- **systemd-networkd / NetworkManager tunnels** could be supported with
  `networkctl reconfigure` or `nmcli connection up`, if we ever run them.
