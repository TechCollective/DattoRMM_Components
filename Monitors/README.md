# Monitors

Datto RMM **monitor** components — components that report a condition rather
than doing something and finishing.

Named `[Subject] - [Condition watched]`, the condition a noun phrase describing
what is wrong when it alerts: `Veeam - Last Successful Backup Age [Win]`. Every
name ends with the OS tags it genuinely supports.

A Datto monitor has exactly two states: exit `0` healthy, exit `1` alert. There
is no warning tier — that is a Nagios concept and it does not survive the
translation. A monitor emits exactly one result block on every path, including
unexpected death; a script that exits non-zero with nothing on stdout renders as
an alert with no text in it.

**Category is permanent.** Datto will not let you change a component's category
after it is saved as a Monitor. Decide before the first save.

One folder per component. See [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

## What is here

| Component | Folder | Status |
|---|---|---|
| `APT - Update Available for Package [Lin]` | [`apt-update-available-for-package-lin`](apt-update-available-for-package-lin) | Not validated — imported, unreviewed |
| `Active Directory - Domain Trust Secure Channel [Win]` | [`active-directory-domain-trust-secure-channel-win`](active-directory-domain-trust-secure-channel-win) | Not validated — imported, unreviewed. **Cannot currently alert** |
| `Disk Health - SMART Failure Detected [Mac][Lin]` | [`disk-health-smart-failure-detected-mac-lin`](disk-health-smart-failure-detected-mac-lin) | Not validated — written, not yet run for real |
| `Disk Space - Free Space Below Threshold [Lin]` | [`disk-space-free-space-below-threshold-lin`](disk-space-free-space-below-threshold-lin) | Not validated — written and reviewed, not yet run for real |
| `Docker - Container Health and Resource Usage [Lin]` | [`docker-container-health-and-resource-usage-lin`](docker-container-health-and-resource-usage-lin) | Not validated — written and reviewed, not yet run for real |
| `Unattended Upgrades - Not Running [Lin]` | [`unattended-upgrades-not-running-lin`](unattended-upgrades-not-running-lin) | Not validated — imported, unreviewed. **Alert text is unusable** |

Nothing here is validated. *Validated* is a second person's call, after the
component has run somewhere real — never set in the same change that writes it.

Read a component's README before targeting it at anything. Each one carries a
`Known limits` section listing its unfixed defects.

Empty categories elsewhere in this repository mean nothing has been created or
changed there since the rule took effect — not that we have no components of
that kind. Datto is authoritative for what exists.

## Where the three result keywords come from

These components disagree about the result payload key: the imported ones emit
`Alert=` or `Status=`, the newer ones emit `STATUS=`. Our monitor contract says
`STATUS=`. Which one Datto's parser actually accepts is an open question on
every README here, and it is the first thing to settle on the next script-mode
test run.
