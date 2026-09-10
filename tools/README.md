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

Two hand-built `.cpt` files already in this repo carry a 3-byte junk `icon.png`.
That is not a real PNG. Replace those when their manifests get written.

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

### About `uid`

The uid is how Datto recognises a component on import. Reusing one means
"update that component"; a fresh one means "create a new component". Generate a
uid once per component, commit it in `component.json`, and never change it.

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

    # build an importable .cpt
    python3 tools/cpt.py pack Monitors/disk-space-free-space-below-threshold-lin

    # bring an existing Datto export into the repo layout
    python3 tools/cpt.py unpack "export.cpt" -o Monitors/new-component

    # prove the tool reproduces a real export exactly
    python3 tools/cpt.py verify samples/*/*.cpt

`pack` validates before it writes, and refuses on a missing `uid`, a bad
`category`, a non-integer `timeout`, a duplicate variable name, or a `map`
variable with no options.

Builds are deterministic: ZIP timestamps are pinned, so rebuilding an unchanged
component produces an identical file and CI raises no spurious diff.

## Payload files

An application component bundles its installer. Our UniFi sample carries a 58 MB
MSI as a fourth archive entry, referenced from the body by filename. Put such
files in `files/` and they land at the archive root.

**They are not committed to this repo** — it is public, and `samples/` is in
`.gitignore` for exactly that reason. A build pipeline for application
components has to source the installer from somewhere other than git.

## What is not established

* `hash` — empty on two of three exports, and not an MD5 of any file or obvious
  concatenation. Import with it empty and see whether Datto minds.
* Variable types beyond `string`, `boolean` and `map`. Datto's UI offers more;
  we have no export that exercises them. `cpt.py` passes any `type` through
  unchanged, so an unknown type is not blocked, just unverified.
* Whether entry order in the ZIP matters. `cpt.py` matches Datto's order anyway.

## In CI

[`.github/workflows/build-components.yml`](../.github/workflows/build-components.yml)
runs on every pull request touching a category folder or `tools/`, and does three
things:

1. **`cpt.py audit`** — enforces the two review-checklist items in
   `CONTRIBUTING.md` that a human is otherwise expected to catch: a committed
   `.cpt` must carry no attachment, and must match the script committed beside
   it. Both fail the build.
2. **`cpt.py verify`** — reproduces any reference export in `samples/` byte for
   byte, so a change to the packer that breaks the format is caught here.
   `samples/` is gitignored, so on GitHub this is normally a no-op.
3. **`cpt.py pack-all`** — builds every component that has a `component.json`
   and uploads them as the **component-exports** artifact.

On a push to `main` a fourth step publishes the same exports to the rolling
**`latest`** release, so each has a permanent URL rather than expiring with the
artifact:

    https://github.com/TechCollective/DattoRMM_Components/releases/latest

**The workflow commits nothing.** Built exports are artifacts and release
assets, never files in git: an Applications export bundles the vendor's
installer and this repo is public. That is the same rule `CONTRIBUTING.md`
states for committing a `.cpt` by hand, and `audit` is what enforces it.

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

### Adopting an existing component

A component folder is only built once it has a `component.json`. Four of the
monitors in this repo predate the manifest and are reported as `skip` until one
is written.

Do **not** hand-write a manifest for a component that already exists in Datto.
The `uid` is its identity: invent a new one and importing creates a *duplicate*
component rather than updating the original. Export the real thing from Datto
and let the tool read the uid out of it:

    python3 tools/cpt.py unpack "Some Component.cpt" -o Monitors/some-component

That writes `component.json` next to the existing script. Check the body it
extracted matches the one already committed, delete the duplicate body it
writes, and point `"body"` at the committed file.
