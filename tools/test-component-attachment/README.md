# Component Hash and Attachment Test [Win]

A probe, not a component. It exists to settle two things this repo could not
establish by reading exports alone.

**It changes nothing on the endpoint.** It reads its own working directory and
reports what it finds. Delete it from Datto once it has answered.

## What it established

The experiment has been run. The results are recorded in full in
[`tools/README.md`](../README.md#what-a-round-trip-through-datto-changes); in
short:

**`hash` is generated server-side.** Sent empty, it came back as
`86bec201b89c606b45925784638e48bb` — an MD5-shaped value matching nothing
derivable from the archive: not the payload, the body, the icon, any
concatenation of them, the filename, or the uid. Author it empty and let Datto
fill it in.

**`uid` is not preserved.** Datto replaced the one it was sent with its own,
which is why every manifest in this repo now leaves `uid` blank, and why an
import **creates** a component rather than updating one.

**A packed attachment survives byte-for-byte.** The 161-byte payload came back
with an identical MD5, as did the icon. That is the reassurance worth having
before shipping an Applications component with a vendor MSI in it.

**Datto strips the trailing newline from `command.bat`.** `cpt.py` now does the
same, so a build here is byte-identical to Datto's own export.

## Why it is kept

As a fixture for the attachment path, which nothing else in this repo covers.
Rebuild and import it if you change how `cpt.py` handles `files/`, or if an
Applications component ever comes back with a payload that does not work on the
endpoint — it will tell you whether the packaging or the component is at fault.

## Build it

    python3 tools/cpt.py pack tools/test-component-attachment \
      -o "dist/Component Hash and Attachment Test WIN.cpt"

Built deliberately with **`<hash/>` empty** and one attachment, `payload.txt`,
of known content:

| | |
|---|---|
| Size | 161 bytes |
| MD5 | `b03e7d94cbb193a4857d71a34e82e77d` |
| SHA256 | `f800327e1910108df235e7e79b2d6a804eaff1fbaf841c15d1fd1aaa9739a61d` |

It also ships no `icon.png`, so it exercises the TechCollective logo fallback at
the same time. Expect the TC roundel in the Component Library, not a tick.

## Run the experiment

**Step 1 — import it.** If Datto *rejects* it, that is the answer on its own:
hash is required whenever an attachment is present, and `cpt.py` will need to
compute one.

**Step 2 — run it against one device** and read the output. It prints every file
in the working directory, then the attachment's size, MD5 and SHA256.

**Step 3 — export the component back out of Datto** and look at what `hash`
holds now:

    unzip -p "export.cpt" resource.xml | grep -i hash

This is the step that answers the question:

| What you see | What it means |
|---|---|
| `<hash/>` still empty | The field is optional metadata Datto never fills in. Leave it empty forever. |
| A value matching the payload MD5 the script printed | It is an MD5 of the attachment. `cpt.py` could compute it, though clearly it need not. |
| A value matching nothing printed | Server-side and opaque — but confirmed as *generated*, not authored. Leave it empty. |

## Reading the result

`AttachmentTest=Pass`, exit 0 — the attachment arrived byte-intact, and the
component imported with an empty hash despite carrying a payload.

`AttachmentTest=Missing`, exit 1 — Datto did not lay the payload down beside the
script. That would mean attachments need a different mechanism than putting them
in `files/`.

`AttachmentTest=Corrupt`, exit 1 — it arrived but was re-encoded in transit.
Most likely a text-mode conversion, which would matter enormously for a binary
payload like an MSI.

## Why this one is never released

It carries an attachment, so `cpt.py stage-release` excludes it from the
`latest` release, and `cpt.py audit` would fail the build if its `.cpt` were
ever committed. Both are correct: that is the same rule that protects the repo
from redistributing a vendor's installer. The payload here is our own harmless
text file, but the rule does not special-case that, and it should not.

Build it locally when you need it.
