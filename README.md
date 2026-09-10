# DattoRMM_Components

Custom components for [Datto RMM](https://rmm.datto.com/) — deployment
components, scripts and monitors — written and maintained by
[TechCollective](https://techcollective.com).

**Why this repo exists:** Datto RMM is not version controlled. The Component
Library holds one mutable copy of each script body, with no history, no diff and
no review. A component runs as SYSTEM or root on every machine it is aimed at,
so "what did this say yesterday" needs an answer. This repo is that answer.

| | |
|---|---|
| **Datto RMM** | Authoritative for what is **deployed**. What is actually running on endpoints right now. |
| **This repo** | Authoritative for what the script **is** — its body, its inputs, its documentation and its history. |

A change is made here first, reviewed, merged, and then pasted over the
component body in Datto. Not the other way round.

## Layout

Top-level folders are the Datto component categories, spelled the way Datto
spells them:

    Applications/    deployment components
    Scripts/         script components
    Monitors/        monitor components

One folder per component, directly under its category, named for the component
in lowercase with hyphens and the OS tag as a trailing token:

    Monitors/disk-space-free-space-below-threshold-lin/
      disk-space-free-space-below-threshold-lin.sh    the component body
      README.md                                       what it is, how to install it, its inputs
      disk-space-free-space-below-threshold-lin.cpt   optional Datto export

The component's real name — `Disk Space - Free Space Below Threshold [Lin]`,
brackets and casing intact — lives in its README and in Datto. Only the path is
slugified, because `[Lin]` percent-encodes to `%5BLin%5D` in every GitHub URL
and two folders differing only in case collide on a macOS or Windows checkout.

**The README is the component's documentation, and it is canonical.** There is
no separate internal document restating it. See
[`COMPONENT-README-TEMPLATE.md`](COMPONENT-README-TEMPLATE.md) for the required
sections, and the component READMEs under `Monitors/` for worked examples —
`disk-space-free-space-below-threshold-lin` and
`docker-container-health-and-resource-usage-lin` are the fullest.

## This is a partial mirror

Components land here from the day the rule took effect, going forward. There is
no backfill of the existing Component Library, and **an empty category folder
does not mean we have no components of that kind** — it means none has been
created or changed since. Datto remains authoritative for what exists and what
is deployed.

Nothing verifies that this repo matches Datto. There is no component API to
check against. The mirror holds because people follow
[`CONTRIBUTING.md`](CONTRIBUTING.md), or it does not hold.

## This repository is public

Anyone can read it, forever, including anything a force-push later removes.

**Never commit:** client or site names, hostnames, IP ranges, subnets, AD domain
names, tenant ids, API keys, tokens, licence keys, account numbers, thresholds
or paths tuned for one customer, or output captured from a real device.

Every value that varies by customer is a Datto **input variable** with a neutral
default, set at assignment time. A component that cannot be written without a
customer-specific value is not ready to be written.

## Contributing

Branch, commit, pull request, merge. Never push to `main` — see
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the steps, the review checklist and the
naming rules.

## Licence

[GPL-3.0](LICENSE). Note that this applies to what we publish here: adopting a
component from the Datto Community ComStore, a forum or another repository and
pushing it to this one is a redistribution decision. Check the source's licence
and record it in the component's README.

## Using these components

They are written for our environment and published in case they are useful.
They are provided as-is under the licence above, with no warranty and no
support. Read a script before you run it — that is the same standard we apply to
anything we adopt from someone else.
