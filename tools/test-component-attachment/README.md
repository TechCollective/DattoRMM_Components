# Component Hash and Attachment Test [Win]

A probe, not a component. It exists to settle two things this repo could not
establish by reading exports alone.

**It changes nothing on the endpoint.** It reads its own working directory and
reports what it finds. Delete it from Datto once it has answered.

## The questions

### 1. What is `<hash>`?

Of the three real exports studied, two have `<hash/>` empty and one carries
`baea7e9d07601880a587eef94d6ce863`. The one with a value is the only one with an
attachment, which suggests hash is tied to the payload — but it is **not** a
plain MD5 of it. That was tested against the MSI alone, the MSI concatenated
with the body, all four files in order, and the filename; none matched.

So hash is server-side, and what it actually digests is unknown.

### 2. Does a packed attachment reach the endpoint intact?

`cpt.py` puts anything in `files/` at the archive root. Nothing has confirmed
Datto lays it down beside the script at run time, or that it survives byte-for-
byte.

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
