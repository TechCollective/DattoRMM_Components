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

A UUID identifying the component. Generate one per component, commit it in
`component.json`, and never change it.

Be careful about what it does on import. Datto **replaces a uid it does not
recognise with one of its own** — measured, not assumed; see
[What a round trip through Datto changes](#what-a-round-trip-through-datto-changes).
So a uid authored here does not become the component's identity in Datto, and
importing a component Datto has not seen creates a new one.

Whether Datto honours a uid it *does* recognise, updating that component in
place, is untested. Until it is, do not rely on an import to update anything.

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
gets a fresh uid assigned, so **importing creates a new component**. Whether
Datto honours a uid it *does* recognise — updating in place rather than
duplicating — is untested, and is the next thing worth establishing, because it
decides how an existing component is updated from this repo.

Until that is known, treat an import as "creates a component" and delete the old
one by hand.

### Datto strips the trailing newline from the body

A component exported after import has `command.bat` one byte shorter than what
was sent: the final `\n` is gone. `normalise_body` in `cpt.py` does the same, so
a `.cpt` built here is byte-identical to Datto's own export, and `audit` does
not report a false mismatch against a repo script whose editor left a newline on
it. `verify` checks the body as well as the metadata, which is what would catch
a regression in this.

## What is still not established

* Whether Datto honours a uid it already knows, per above.
* What `hash` actually digests.
* Variable types beyond `string`, `boolean` and `map`. Datto's UI offers more;
  no export we have exercises them. `cpt.py` passes any `type` through
  unchanged, so an unknown type is not blocked, just unverified.
* Whether entry order in the ZIP matters. `cpt.py` matches Datto's order anyway.
