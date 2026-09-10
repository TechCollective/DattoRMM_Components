# Component README template

Copy this into a new component folder as `README.md` and fill it in. The README
is the component's documentation and it is canonical — there is no separate
internal document restating it, so what is missing here is missing everywhere.

Drop a heading with nothing to say rather than filling it with a placeholder,
and add headings the component needs. Worked examples live under `Monitors/` —
`disk-space-free-space-below-threshold-lin` and
`docker-container-health-and-resource-usage-lin` are the fullest. Match their
depth.

Remember this repository is public. No customer names, hostnames, addresses,
keys or tuned-for-one-site values in any section.

---

# [Exact component name as saved in Datto, brackets and all]

One or two sentences: what this is and what it runs on.

> **Status: Not Validated.** [What review it has had, and dated. Never
> *Validated* in the same change that writes it — that is a second person's
> call, after it has run somewhere real.]

## What it does

Present tense. What it reads, what it changes on the endpoint, whether it makes
any network call. **Say plainly if it is read-only** — that is the first thing a
reviewer looks for.

If it replaces or supersedes another component, say which and say
`Untarget [old name] when this goes live. Do not run both.`

## Source and provenance

*Only if adopted or derived from outside. Delete this heading otherwise.*

The original's name, author, build or version, where it came from, and **its
licence**. What was changed and why. If it is a rewrite rather than a patch, say
so and say why the original could not be patched.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | |
| Description | *One sentence, under ~140 characters, present tense. Says what it does and the consequence a technician would not guess from the name.* |
| Category | **Applications / Scripts / Monitors** — permanent for Monitors, cannot be changed after the first save |
| Script type | |
| Target OS | |
| Level | *not standardised yet — decide at save time* |
| Timeout | *always set one* |
| Attachments | |
| Monitor interval | *monitors only* |

Paste the whole of `[script filename]` as the script body, then add the input
variables below.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| | String / Selection | | *the value that must not be exceeded, and what happens if it is* |

State explicitly that no customer-specific value is hardcoded. Prefer
**Selection** over String wherever the valid values are a known set, so a bad
value is unrepresentable.

Say what happens on an invalid value. Refusing to run beats silently falling
back to a default, which means monitoring against a threshold nobody chose.

## Exit behaviour

For a **monitor**, the full table. Datto monitors have exactly two states: exit
`0` healthy, exit `1` alert. There is no warning tier — that is a Nagios concept
and it does not survive the translation.

| Host state | Result |
|---|---|
| The thing being checked is not installed on this host | |
| Installed and healthy | |
| Installed, unreachable or broken | |
| A required tool is missing | |
| An input variable is invalid | |
| The script dies unexpectedly | |

The last row is the one that gets skipped and the one that matters: a script
that exits non-zero with nothing on stdout renders as **an alert with no text in
it**. Handle it and say how.

For a **script or application component**, what each exit code means.

## How to tell it worked

What correct output looks like, on the healthy path and on the alert path,
specifically enough that someone with no context can judge a run.

## Test order

Never a customer first.

1. One internal device.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

A monitor is run as a **Scripts** component first, with its raw output read
before it ever becomes a monitor.

## Known limits

What it does not cover. Platforms and configurations it has **not** been run
against. Dependencies and their versions — a GNU-only spelling, a bash version,
a tool that may be absent.

## Open questions

Anything undecided, so the next person does not have to rediscover it. Component
`Level` lives here until we standardise it.
