# The `.cpt` format, and the tool that builds one

A Datto RMM component export (`.cpt`) is a **flat ZIP archive**. Nothing more
exotic than that — `unzip -l` opens one. This document records what is actually
inside, established by unpacking three real exports (an application, a script
and a monitor) pulled out of our Datto tenant.

## Archive layout

    command.bat     the component body
    resource.xml    metadata and input variables
    icon.png        48x48 RGBA PNG, the Component Library thumbnail
    <payload>       zero or more extra files, at the archive root

Observed in every export:

* No directory entries. Every path is a bare filename at the archive root.
* Entries are written in the order `command.bat`, `resource.xml`, `icon.png`,
  then payload.
* Deflate compression throughout.
* Datto's own exporter streams the entries (general-purpose flag `0x808`, so
  sizes live in a trailing data descriptor). A normally-written ZIP is fine;
  this is an artefact of the Java library Datto exports with, not a requirement.

### `command.bat` is a lie

The body is **always** called `command.bat` no matter what language it is. Our
Linux bash monitor and both Windows PowerShell components all ship as
`command.bat`. The real language comes from `<installType>`, and the shebang on
a `unix` component is honoured.

The body is stored with **LF line endings**, including for PowerShell. `cpt.py`
normalises CRLF to LF on the way in.

### `icon.png`

48x48, 8-bit RGBA, non-interlaced. Chosen in the Datto UI, so each component has
its own. Datto's stock icons bleed to the frame edge and use the alpha channel
for whatever the mark's shape leaves over, so there is no required margin.

**Icon resolution order when packing:**

1. `icon.png` in the component directory, if there is one.
2. Otherwise [`tools/default-icon.png`](default-icon.png) — the TechCollective
   logo — so a component never reaches the Component Library with a blank or
   broken thumbnail.

The default was generated from [`techcollective-logo.jpeg`](techcollective-logo.jpeg)
(200x200, white background) by scaling the mark to 46px inside a 48px frame and
masking it to a circle, which drops the white corners and keeps the
anti-aliased edge off the frame boundary:

```python
from PIL import Image, ImageDraw
src, SS, content = Image.open("tools/techcollective-logo.jpeg").convert("RGB"), 384, 46
s = int(SS * content / 48)
logo = src.resize((s, s), Image.LANCZOS).convert("RGBA")
mask = Image.new("L", (s, s), 0)
ImageDraw.Draw(mask).ellipse([0, 0, s - 1, s - 1], fill=255)
logo.putalpha(mask)
frame = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
frame.paste(logo, ((SS - s) // 2,) * 2, logo)
frame.resize((48, 48), Image.LANCZOS).save("tools/default-icon.png", "PNG", optimize=True)
```

To give a component its own icon, drop a 48x48 RGBA `icon.png` beside its
`component.json`.

## `resource.xml`

    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <component info="CentraStage Component">
        <general>...</general>
        <variable idx="0">...</variable>
        ...
    </component>

Four-space indent, double-quoted attributes, empty elements self-closed
(`<hash/>`, `<defaultVal/>`), and **no trailing newline** after `</component>`.
`cpt.py verify` reproduces all three sample exports byte for byte, so the shape
above is exact rather than approximate.

### `<general>`, in document order

| Element | Notes |
|---|---|
| `name` | The display name, brackets and casing intact — `Disk Space Monitor (TC Version) [LIN]` |
| `category` | `applications`, `scripts` or `monitors` |
| `description` | Free text, may contain newlines. We use it for the repo URL or a rollback note. |
| `uid` | A UUID. **This is the component's identity** — see below. |
| `hash` | Empty in two of three real exports. Server-side; not reproducible from file contents. Leave empty. |
| `version` | Integer, bumped by Datto on each save |
| `timeout` | Seconds. `60` and `3600` both seen. |
| `securityLevel` | Integer. `1` and `5` both seen. |
| `installType` | `powershell` or `unix`. Drives the body language. |
| `uninstallType` | Applications only, and empty in our sample. Omitted entirely for scripts and monitors. |

### `<variable>`

Zero or more, `idx` counting from 0, in the order they appear in the UI. Child
order is `name`, then any `selectionKeyValue` blocks, then `type`, `direction`,
`description`, `defaultVal`. Note that **the options come before `<type>`**,
which is the one ordering that is easy to get wrong.

Types seen in real exports: `string`, `boolean`, `map`.

* `boolean` reaches the script as the literal text `true` or `false`.
* `map` renders a drop-down. Each `selectionKeyValue` has a `name` (shown in the
  UI) and a `value` (**what the script receives**). `defaultVal` holds the
  *name*, not the value.
* Every variable arrives at the script as an environment variable of the same
  name, always as text.

### About `uid` — leave it blank

Datto **replaces a uid it does not recognise with one of its own** on import —
measured, not assumed; see
[What a round trip through Datto changes](#what-a-round-trip-through-datto-changes).
A uid authored here therefore never becomes the component's identity in Datto.

So `uid` is optional, and every manifest in this repo leaves it empty. Chasing
one down was a step a component builder had to take for no benefit.

The consequence to remember: an import **creates** a component. It does not
update an existing one. Import, then delete whatever it supersedes.

## The component directory

`cpt.py` builds a `.cpt` from a directory:

    Monitors/disk-space-free-space-below-threshold-lin/
      component.json     metadata -> resource.xml
      <slug>.sh|.ps1     body     -> command.bat
      icon.png           optional -> icon.png, else the TC logo
      files/             optional -> extra payload at the archive root
      README.md          documentation, never packaged

`component.json` mirrors `resource.xml` one-for-one, so there is nothing to
learn twice:

```json
{
  "general": { "name": "...", "category": "monitors", "uid": "...", "...": "..." },
  "body": "disk-space-free-space-below-threshold-lin.sh",
  "variables": [
    { "name": "usrThreshold", "type": "string", "direction": "false",
      "description": "1-99. Percent used.", "defaultVal": "90" },
    { "name": "usrUnknownFs", "type": "map", "direction": "false",
      "description": "...", "defaultVal": "Warn",
      "options": [ { "name": "Warn", "value": "warn" },
                   { "name": "Alert", "value": "alert" } ] }
  ]
}
```

`body` is optional when the directory holds exactly one `.sh`/`.ps1`/`.bat`/`.py`
file; it is required when there is more than one.

## Using the tool

    # start a new component: folder, component.json, README, test.json, stub body
    python3 tools/cpt.py new "Disk Space - Free Space Below Threshold [Lin]" monitors

    # build an importable .cpt
    python3 tools/cpt.py pack Monitors/disk-space-free-space-below-threshold-lin

    # bring an existing Datto export into the repo layout
    python3 tools/cpt.py unpack "export.cpt" -o Monitors/new-component

    # prove the tool reproduces a real export exactly
    python3 tools/cpt.py verify tools/fixtures/*.cpt

`pack` validates before it writes, and refuses on a missing `uid`, a bad
`category`, a non-integer `timeout`, a duplicate variable name, or a `map`
variable with no options.

`new` gives a component that passes the lint, naming and discovery checks,
and its own Tier 1 test, before anyone has written a line of it:
- the folder is named as the slug of the display name;
- the body is `.ps1` for `[Win]` and `.sh` for `[Mac]` and `[Lin]`;
- the timeout is 120 seconds for a monitor and 600 otherwise;
- the uid is empty;
- the `test.json` runs on the platforms the OS tags name.

A monitor's stub takes a `usrThreshold` input, prints its result block, and
refuses bad input. Its `test.json` holds a healthy run, a bad-input run and a
second run. `new` refuses a name without OS tags, with a version number, or
with both `[Win]` and `[Mac]`/`[Lin]` (one body can't run on both), and a
folder that already exists.

The packer's tests (`tools/test_cpt.py`) run in CI before the build:

    python3 -m unittest discover -s tools -p 'test_*.py'

Builds are deterministic: ZIP timestamps are pinned, so rebuilding an unchanged
component produces an identical file and CI raises no spurious diff.

## Payload files

An application component bundles its installer. Our UniFi sample carries a 58 MB
MSI as a fourth archive entry, referenced from the body by filename. Put such
files in `files/` and they land at the archive root.

**They are not committed to this repo** — it is public, and `samples/` is in
`.gitignore` for exactly that reason. A build pipeline for application
components has to source the installer from somewhere other than git.

## What a round trip through Datto changes

Established by importing a component built here, then exporting it straight back
out and diffing. The probe that did it is
[`tools/test-component-attachment`](test-component-attachment/).

**Preserved exactly:** `name`, `category`, `description`, `timeout`,
`installType`. The icon and any attachment come back **byte-identical** — a
161-byte text payload survived untouched, which is the reassurance that matters
for a binary like an MSI.

**Changed by Datto:**

| Field | Sent | Returned | What it means |
|---|---|---|---|
| `uid` | `b10dea05-…` | `026f0de7-…` | **Datto assigned its own.** The uid in an imported file is not honoured. |
| `hash` | empty | `86bec201…` | Generated server-side on import. |

**Changed by hand during the test, not by Datto:** `securityLevel` went `1` → `5`
because the component was locked down in the UI while it sat in the Component
Library. So securityLevel is authored here and respected, not overridden.

`version` likewise read `4` on the way back out having been sent as `1`, and the
component was edited in the UI between the two. That is consistent with version
being carried across on import and then incremented on each save, rather than
reset by the import — but the edits were not counted, and only one import has
been measured, so it is the likely reading rather than a settled one.

`hash` is an MD5-shaped value that matches nothing derivable from the archive —
not the payload, the body, the icon, any concatenation of them, the filename or
the uid. It is opaque. **Author it empty and let Datto fill it in.**

### The uid does not survive an import

This is the one with consequences. A `.cpt` carrying a uid Datto has not seen
gets a fresh uid assigned, so **importing creates a new component**.

**Datto does not honour a uid it already knows, either** (measured 2026-11-04).
`Hardware - Estimate Model Year to UDF [Win]` was re-imported carrying the uid
Datto had assigned on the first import (`796681e0-…`, recorded in its
`component.json` by PR). The import created a second component with a new uid
(`998ddf3f-…`) beside the first, rather than updating it in place.

So **every import creates a component**. After importing an update:

1. Delete the component it supersedes from the Component Library.
2. Re-point anything that targeted the old one — policies, scheduled jobs, the
   new-device audit — because they reference the deleted component, not the name.
3. Record the new uid in `component.json` by PR, so the repo still says which
   Datto component it is.

### Datto strips the trailing newline from the body

A component exported after import has `command.bat` one byte shorter than what
was sent: the final `\n` is gone. `normalise_body` in `cpt.py` does the same, so
a `.cpt` built here is byte-identical to Datto's own export, and `audit` does
not report a false mismatch against a repo script whose editor left a newline on
it. `verify` checks the body as well as the metadata, which is what would catch
a regression in this.

## What is still not established

* What `hash` actually digests.
* Variable types beyond `string`, `boolean` and `map`. Datto's UI offers more;
  no export we have exercises them. `cpt.py` passes any `type` through
  unchanged, so an unknown type is not blocked, just unverified.
* Whether entry order in the ZIP matters. `cpt.py` matches Datto's order anyway.

## In CI

[`.github/workflows/build-components.yml`](../.github/workflows/build-components.yml)
runs on every pull request, whatever it touches (it is a required check), and
does four things:

1. **The packer's tests** (`tools/test_cpt.py`).
2. **`cpt.py audit`** — fails the build if any `.cpt` is committed under a
   category folder. Exports are built, not stored.
3. **`cpt.py verify`** — reproduces the reference export in
   [`tools/fixtures/`](fixtures/) byte for byte, so a change to the packer that
   breaks the format is caught here.
4. **`cpt.py pack-all`** — builds every component that has a `component.json`
   and uploads them as the **component-exports** artifact.

On a push to `main` a second job publishes the same exports to the rolling
**`latest`** release, so each has a permanent URL rather than expiring with the
artifact:

    https://github.com/TechCollective/DattoRMM_Components/releases/latest

### The reference export

`tools/fixtures/disk-space-monitor-lin.cpt` is the one export committed to the
repo: a real Datto export of the disk space monitor, with no attachment. It
exercises string variables, an empty default and a `map` drop-down. It was
reviewed byte by byte before it was committed: its body is already in this
repo's history, its icon is a Datto stock icon, and its `resource.xml` holds
only the GitHub URL, Datto's uid for it and its input variables. No client
names, hostnames, IPs or secrets. `samples/` stays gitignored; anything added
to `tools/fixtures/` gets the same review, and never carries an attachment.

**Nothing else is ever committed.** Built exports are artifacts and release assets,
never files in git: an Applications export bundles the vendor's installer and
this repo is public, and a zip in the tree goes stale in silence because no diff
shows it drifting from the script beside it. `audit` enforces it.

Artifacts are named for the component as Datto displays it — `Domain Trust.cpt`,
not `active-directory-domain-trust-secure-channel-win.cpt` — so a reviewer
downloading one recognises what they are about to import.

### What is never published

`cpt.py stage-release` drops any export carrying an attachment before the
release is cut, for two independent reasons:

- A release asset on a public repo is a permanent, unauthenticated download
  link. Publishing a vendor's installer through one is the redistribution
  `CONTRIBUTING.md` forbids.
- Payload files live in `files/` and are not in git, so an Applications export
  built in CI would not contain its installer anyway. Publishing it would hand
  someone a component that imports cleanly and then fails on the endpoint.

Excluded components are listed in the release notes, saying what was dropped
and why. Export those from Datto directly.

### The release is only republished when it would differ

`stage-release` writes a `SHA256SUMS` fingerprint covering the exports and the
release notes, and publishes it as an asset. The next run compares against it
and skips publishing when nothing has changed.

That matters because republishing recreates the release and its tag, which
resets download counts. Without the check, a merge that only touched a README
would churn the release for no reason. Builds are deterministic, so the
comparison is exact — and it holds for any no-op change, including a refactor of
`cpt.py` that does not alter its output.

The notes are in the fingerprint because they can change while no `.cpt` does:
adding a component that gets excluded rewrites them and nothing else.

### Releases are distribution, not an archive

The `latest` tag moves with `main`, so it is a pointer at the current state, not
a history. Nothing is lost by that: builds are deterministic, so any commit
rebuilds its exports byte for byte. Git is the archive; the release is the
convenient way to hand someone a file.

### Re-checking the format

[`tools/test-component`](test-component/) is a self-test component kept as a
regression fixture. It changes nothing on an endpoint: it reads its own input
variables back out of the environment and reports whether each arrived as
declared, exercising the part of the format most likely to break — a string
default, an empty default, a boolean, and a `map` drop-down's name/value split.

Rebuild it, import it, and run it whenever you want to know the format still
holds:

    python3 tools/cpt.py pack tools/test-component -o "dist/Component Packaging Self-Test WIN.cpt"

Worth doing after a change to `cpt.py`, or when a Datto update makes an import
behave oddly. Delete the component from Datto once it has told you what you
needed — it should not sit in the Component Library where it can be scheduled.

It last passed on 2026-09-10: imported clean, all four variables intact.

### Adding a manifest to an existing component

A component folder is only built once it has a `component.json`. Three of the
monitors in this repo predate the manifest and are reported as `skip` until one
is written.

Write one by hand — `name`, `category`, `installType`, `timeout`,
`securityLevel`, and the input variables. Leave `uid` and `hash` blank. Nothing
needs looking up in Datto.

If you happen to have an export already, `unpack` writes the manifest rather
than you typing it:

    python3 tools/cpt.py unpack "Some Component.cpt" -o Monitors/some-component

Check the body it extracted matches the one already committed, delete the
duplicate body it writes, and point `"body"` at the committed file.

## Linting every component

[`lint-components.ps1`](lint-components.ps1) parses and lints every script
under `Applications/`, `Scripts/` and `Monitors/`, including any test scripts
kept in a component's folder. It covers every component, whether or not it
has a `test.json`. The
[Lint components](../.github/workflows/lint-components.yml) workflow runs it
on every pull request.

| Language | Checks | Fails on |
|---|---|---|
| Shell (`.sh`) | `bash -n`, then shellcheck 0.10.0 | A parse error, or anything shellcheck rates warning or above. Notes and style hints are not shown. |
| PowerShell (`.ps1`) | The PowerShell parser, then PSScriptAnalyzer 1.23.0 | A parse error, an Error-severity rule, or a warning not in [`lint-baseline.txt`](lint-baseline.txt). |

The baseline holds the PowerShell warnings that predate it, keyed on file,
rule and message rather than line, so editing elsewhere in a file does not
disturb it. It only shrinks: after fixing warnings, rewrite it with

    pwsh tools/lint-components.ps1 -UpdateBaseline

A new warning is fixed, or suppressed in the script with its reason, never
added to the baseline.

A deliberate exception is suppressed in the script itself, with the reason
beside it, so a reviewer sees it in the diff:

    # shellcheck disable=SC2154  # the input variables arrive from Datto as environment variables

It also checks each component folder against the conventions in
[CONTRIBUTING.md](../CONTRIBUTING.md#naming). The display name is
`component.json`'s `general.name`, or the README's `#` title when there is no
manifest. When both exist, they must match.

| Rule | Fails when |
|---|---|
| OS tags | The name doesn't end with its OS tags (`[Win]`, `[Mac]`, `[Lin]`), each once, space-separated, in that order. |
| Folder | The folder isn't the slug of the name: lowercase, with every run of other characters turned into one hyphen. |
| Platforms | A `test.json` runs on platforms other than exactly the ones the OS tags name. |
| README | The README has no `## What it does` or `## How to tell it worked` section, the two every component needs. |

Each failure names the folder and what is wrong.

Run it locally with shellcheck and PSScriptAnalyzer installed:

    pwsh tools/lint-components.ps1

or let [`check.sh`](check.sh) run it in a container with the pinned versions.

## Running the checks locally

    tools/check.sh              # everything that runs on Linux; needs Docker
    tools/check.sh --no-docker  # the Python checks only

It runs the packer and discovery tests, the audit, a build of every component
and the shared-blocks check, then the lint job and the Linux harness self-test
in a throwaway container. The Windows harness and the per-component tests run
only in CI. When a workflow gains a step that can run on Linux, add it here
too.

To wait for a pull request's CI without leaving a watcher running:

    tools/wait-ci.sh <pr number or branch> [minutes, default 45]

It prints the checks that did not pass and exits 0, 1, or 124 at the
deadline.

## Later: reading this out of Datto

Everything in `component.json` beyond the script — the inputs, the timeout, the
security level — is retyped from what Datto already knows. A function that
pulled it from Datto's API would remove that step, and would also let something
finally check this repo against the live Component Library.

Worth checking before planning around it: this repo's own README states there is
no component API to check against. If that holds, the manifest stays
hand-written, and `unpack` on an existing export is the only shortcut there is.
