# Java - Uninstall All Versions [Mac]

A macOS script component that removes Java installed for the whole Mac, from
any vendor, and never touches Java an application carries inside itself. A
Report mode lists the same things and changes nothing.

> **Status: Not Validated.** Written 2026-11-18. The script passes `bash -n` and
> ShellCheck. A simulation on a fake `/Library` covered the decision logic:
> - Report changes nothing.
> - The keep list keeps.
> - Symlinked, app-bundled and per-user Java are left alone.
> - Oracle's leftovers only go when nothing is kept.
> - Receipts are forgotten only for bundles that are gone.
>
> It has **not yet run on a Mac**. The Tier 1 test installs a real Temurin JRE
> on a GitHub macOS runner and proves removal there. The UDF reaching the
> device page needs one internal Mac with the Datto agent.

## What it does

**Removed:**

- Every JDK or JRE bundle in `/Library/Java/JavaVirtualMachines` that is a real folder, from any vendor: Oracle, Temurin/AdoptOpenJDK, Corretto, Zulu, Microsoft, Liberica, Semeru, SapMachine.
- Oracle's Java 8 browser plug-in, `/Library/Internet Plug-Ins/JavaAppletPlugin.plugin`.
- Oracle's leftovers, but only when nothing Java is kept. That means the Java Control Panel, the updater's launchd jobs (unloaded first), its privileged helper, and `/Library/Application Support/Oracle/Java`.
- Package receipts from those vendors (`pkgutil --forget`), but only when every file in the receipt was inside a Java bundle that no longer exists. A receipt for a kept JDK, or one that owns anything else, is left.

**Never touched:**

- **Java bundled inside an app.** It never looks inside `/Applications`, so an app shipping its own runtime keeps working.
- **Apple's own Java stubs in `/System` and `/usr/bin/java`.** Old macOS versions show "Java Web Start" and "Jar Launcher" in the Datto audit; those are part of macOS.
- **A symlink in `/Library/Java/JavaVirtualMachines`.** Homebrew and similar tools link their JDK there. Both the link and its target are left alone and listed as `[leave]`.
- **JDKs in home folders.** That covers IDE downloads, SDKMAN and `~/Library/Java`. They are listed so you can see them.
- **Homebrew itself**, in `/opt/homebrew` and `/usr/local`.

**It never stops a running program.** Anything already running on a removed Java keeps running until it quits, and those processes are listed.

It makes no network calls and needs no Python. It runs on Bash 3.2, so it works
on every macOS from 10.14 Mojave on.

The UDF is written with JavaScript for Automation (`osascript`), which edits the
agent's `values.xml` through Apple's XML parser. The file stays valid XML,
including when a value contains `&` or `<`. This is the first Mac component in
the repo that writes a UDF.

## Source and provenance

Written here, as the Mac counterpart of
[Java - Uninstall All Versions [Win]](../java-uninstall-all-versions-win). No
outside code.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Java - Uninstall All Versions [Mac]` |
| Description | Removes system-wide Java from any vendor and Oracle's plug-in; never touches Java bundled inside apps. Report mode changes nothing. |
| Category | **Scripts** |
| Script type | Bash (Unix) |
| Target OS | macOS |
| Level | 2 |
| Timeout | 900 seconds |
| Attachments | none |

Paste the whole of `java-uninstall-all-versions-mac.sh` as the script body,
then add the input variables below. Or import the `.cpt` that CI builds on the
pull request.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | Selection | Remove | `Remove` or `Report`, case-insensitive. Anything else is refused with exit 1. |
| `usrKeep` | String | blank | Comma-separated text matched, case-insensitively, against each bundle's folder name, product name, vendor and version, e.g. `corretto-17`. The Oracle plug-in matches as `Oracle Java Plug-in [version]`. Each term must be at least 3 characters, or the run is refused. |
| `usrUdfNumber` | String | 13 | UDF 13 is "Java Status" in the Datto RMM - UDFs list (Setup → Account Settings → User-Defined Fields). 1 to 300, or blank for no UDF. Anything else is refused. It never overwrites a UDF value that doesn't start with `Java: `. |

## Exit behaviour

| Exit | Status | Meaning |
|---|---|---|
| 0 | `CLEAN` | Nothing removable. Nothing changed. |
| 0 | `FOUND` | Report mode found removable Java. Nothing changed. |
| 0 | `REMOVED` | The re-check found nothing removable left. |
| 1 | `REFUSED` | An input variable is invalid. Nothing changed. |
| 3 | `REMOVE_INCOMPLETE` | Something removable is still there. Each item is listed. |
| 5 | `ERROR` | Not running as root, or PlistBuddy is missing. |

## How to tell it worked

A Remove run lists each bundle as `[remove]`, `[keep]` or `[leave]` and shows
an `[ok] deleted` line for each removal. It ends with `STATUS=REMOVED`, and the
UDF reads like `Java: REMOVED 2 | Kept 0 | 2026-11-18 14:02`.

Report gives `Java: FOUND 1 | temurin-21.jdk | [date]`, which makes the UDF a
fleet-wide filter for Macs that still have Java.

Datto's own Mac software audit cannot show this. It lists `.app` bundles, and
JDKs are `.jdk` bundles.

## Test order

Never a customer first.

1. One internal Mac.
2. One site, one Mac in it.
3. Wider, only after the first two.

Run Report across a site before running Remove there.

## Known limits

- **It removes system-wide Java that an app relies on rather than bundling.** Some older apps use the system JDK. Use `usrKeep` for those.
- **It doesn't remove Java in home folders, Homebrew or SDKMAN.** Those belong to the person or tool that installed them.
- **A UDF write reaches Datto on the agent's next check-in,** not instantly.
- **Oracle's updater may keep running until the next login.** When no one is logged in, its per-user launchd job can't be unloaded. Its files are deleted all the same, so it can't start again.

## Open questions

- Level 2 was chosen to match the Windows version. Component Level is not standardised yet.
