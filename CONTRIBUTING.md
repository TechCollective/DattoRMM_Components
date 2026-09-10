# Contributing

Every component is added or changed the same way: branch, commit, pull request,
merge, then paste into Datto.

**Never push to `main`.** A component runs as SYSTEM or root on every machine it
is aimed at. The pull request is the only review this code gets.

## Before you write anything

1. **Look for a component that already exists** — the Component Library first
   (that is what we already own), then the ComStore, then the Community
   ComStore, then public GitHub. A second component that does the same thing is
   how a Component Library becomes unusable.
2. **Anything from outside gets audited before it goes near a client.** Read the
   script line by line. Community ComStore components are supported by the
   community and nobody else; adopting one makes it ours, along with whatever it
   does at 2am on a domain controller.
3. **Check the licence of anything adopted.** This repo is public and GPL-3.0,
   so committing someone else's script is redistribution. If the source states
   no licence, ask before committing.

## Naming

The component name follows the same standard as our internal documentation
titles, so that someone searching the Component Library and someone searching
our docs type the same words. Every name ends with the OS tags it genuinely
supports: `[Win]`, `[Mac]`, `[Lin]` — exactly those tokens, in that order.

| Category | Pattern | Example |
|---|---|---|
| Applications | The product name, nothing else | `Adobe Acrobat Reader [Win]` |
| Scripts | `[Subject] - [Action]` | `Windows Update - Reset Update Components [Win]` |
| Monitors | `[Subject] - [Condition watched]` | `Veeam - Last Successful Backup Age [Win]` |

No verbs in an Applications name — the category already says it deploys
something. No version numbers anywhere: components are updated in place and the
name outlives the version. No customer names, ever.

The **folder** is that name slugified — lowercase, hyphens, brackets dropped:

    Monitors/veeam-last-successful-backup-age-win/
      veeam-last-successful-backup-age-win.ps1
      README.md

The script file always carries a real extension (`.sh`, `.ps1`, `.bat`, `.py`)
so GitHub highlights it and the diff is readable.

## What goes in the folder

| File | Required | Notes |
|---|---|---|
| The script | Yes | This is what gets reviewed. |
| `README.md` | Yes | Same commit as the script. See [`COMPONENT-README-TEMPLATE.md`](COMPONENT-README-TEMPLATE.md). |
| `component.json` | No | The component's metadata and input variables, in a form that diffs. When present, CI builds an importable `.cpt` for you on every pull request — see [`tools/README.md`](tools/README.md). |
| `icon.png` | No | 48x48 RGBA. Without one, a built export gets the TechCollective logo. |
| `.cpt` export | No | Datto's own export. Restores input variables without retyping them, so it is worth having for anything with more than two. It is a zip — it does not diff, and it is not the source of truth. If you commit one, it must match the script in the same commit. **Open it before you commit it** — see below. |

### Let CI build the export

If a component has a `component.json`, every pull request attaches a built
`.cpt` as the **component-exports** artifact, ready to import. That is the
easiest way to get a reviewer the actual component rather than a script body.

Once merged, the same export is published to the
[latest release](../../releases/latest), which gives it a permanent link rather
than a 30-day artifact. Exports carrying an attachment are excluded there for
the same reason they are never committed — see below.

Adding a manifest to a component that **already exists in Datto** means taking
its `uid` from a real export, not inventing one — a new uid makes the import
create a duplicate component instead of updating the original:

    python3 tools/cpt.py unpack "Some Component.cpt" -o Monitors/some-component

CI also checks every committed `.cpt` for the two things the review checklist
asks you to check by hand — that it carries no attachment, and that it matches
the script committed beside it. Both fail the build.

### Never commit a `.cpt` that carries an attachment

A `.cpt` is a zip of `command.bat`, `resource.xml`, an icon — **and every file
attached to the component**. For a deployment component that is the installer
itself. One `UniFi Endpoint [Win]` export in our own samples folder is 58 MB of
Ubiquiti's MSI.

Committing that to a public GPL-3.0 repository redistributes a vendor's
installer under a licence we have no right to apply to it, and git history is
permanent — a later `git rm` does not remove it from the clone anyone already
took.

So, before committing any `.cpt`:

    unzip -l "the-export.cpt"

If it lists anything beyond `command.bat`, `resource.xml` and `icon.png`, do not
commit it. Commit the script and record the attachment in the README instead —
its filename, its version, and the vendor URL it is downloaded from.

In practice this means **Applications components rarely have a committable
`.cpt`**, and monitors and scripts usually do.

## The steps

The commands below are written out against a real example — a Linux disk space
monitor. Copy the shape, not the words: type your own component's real name and
real paths rather than editing a placeholder out of a line.

**1. Start from a current `main`.**

    git checkout main
    git pull

**2. Branch. One component per branch.**

    git checkout -b disk-space-free-space-below-threshold-lin

**3. Add the script and its README together.**

    mkdir -p Monitors/disk-space-free-space-below-threshold-lin
    git add Monitors/disk-space-free-space-below-threshold-lin

**4. Write the commit message into a file, then commit with it.**

Do this rather than typing a multi-line `-m` string — a quoted string spanning
lines gets mangled often enough to be worth avoiding entirely.

    git commit -F .git/COMMIT_DRAFT

**5. Push the branch.**

    git push -u origin disk-space-free-space-below-threshold-lin

**6. Open the pull request.** A push does not create one. Open it on GitHub, or:

    gh pr create --fill

**7. Merge, then paste into Datto.** In that order — the merge commit is the
record of what was pasted. A component edited in Datto without a matching commit
here is invisible to everyone else, and nothing will ever catch it.

## Review checklist

Whoever reviews the pull request confirms all of it. The
[pull request template](.github/pull_request_template.md) carries the same list.

**Content — this repository is public:**

- [ ] No customer or site names, in the script, the README, the commit message or the branch name
- [ ] No hostnames, IP addresses, subnets or AD domain names
- [ ] No keys, tokens, tenant ids, licence keys or account numbers
- [ ] No thresholds, paths or exclusions tuned for one customer — those are input variables
- [ ] No output captured from a real device

**The component:**

- [ ] Named to the standard above, including the OS tags
- [ ] Filed under the category it is saved under in Datto
- [ ] README present, in the same commit, with input variables and their safe ranges
- [ ] Every threshold is an input variable with a neutral default
- [ ] Nothing secret reaches stdout — component output flows into ticket notes
- [ ] It does not always exit 0. A component that always succeeds hides its own failures
- [ ] A monitor emits exactly one result block, on every path including unexpected death
- [ ] Provenance and licence recorded, if it came from outside
- [ ] A `.cpt` committed here, if any, matches the script in this PR **and carries no attachment** — `unzip -l` shows only `command.bat`, `resource.xml` and `icon.png`

**Before it goes wide:**

- [ ] Run on one internal device first, then one scoped site, then wider. Never a customer first
- [ ] A monitor is run as a **Scripts** component first and its raw output read. A monitor's output is only visible as an alert, which is a poor debugger and a loud one

## Category is permanent for monitors

Datto will not let you change a component's category after it is saved as a
Monitor. Decide before the first save, and file it in the matching folder here.
