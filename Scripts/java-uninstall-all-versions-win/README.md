# Java - Uninstall All Versions [Win]

A Windows script component that uninstalls every standalone Java runtime and
JDK, from any vendor, and cleans up what the uninstallers leave behind. A
Report mode lists the same things without changing anything.

> **Status: Not Validated.** Written 2026-11-18. The script parses under
> PowerShell 7 and its product-name matching was checked against real vendor
> names and lookalikes; it has **not yet run on Windows**. Uninstalling, the
> keep list and shared cleanup are first exercised by the Tier 2 steps on an
> internal VM.

## What it does

"Standalone" means Java installed as a product of its own: an entry in
Programs and Features, or a JDK/JRE folder in a vendor's own folder under
Program Files. Vendors covered: Oracle (Java 5 to current, JRE and JDK, and
the Java Auto Updater), Eclipse Temurin / Adoptium / AdoptOpenJDK, Amazon
Corretto, Azul Zulu, Microsoft Build of OpenJDK, BellSoft Liberica, IBM
Semeru, SapMachine, Red Hat OpenJDK and ojdkbuild.

It **never** touches:

- A runtime bundled inside another application's folder, such as `C:\Program Files\SomeApp\jre`.
- A JDK unpacked anywhere else, such as `C:\jdk` or a developer tool cache.
- Anything in a user profile, such as the per-user Java deployment cache.

It makes no network calls.

**Remove (the default)**, in this order:

1. Stops processes running from the Java folders it is about to remove, and
   the Oracle updater (`jusched`, `jucheck`). Prints each name and PID.
2. Uninstalls each registered Java with its own uninstaller: `msiexec /x` for
   MSI products, otherwise the vendor's registered quiet uninstall string. A
   product with neither is reported for manual removal, never guessed at. Each
   uninstall gets 10 minutes, and one retry after 60 seconds if another
   installation is running. **It never reboots**; it reports when one is needed.
3. Deletes leftover JDK/JRE folders inside the vendor folders, unless they
   belong to a version that is still registered (kept, or failed to uninstall).
   Folders are attributed to a product by its install location, or by
   `java.exe` version for Oracle, which records no install location.
4. **Only when no Java at all is still registered**, removes the shared
   leftovers:
   - `HKLM\SOFTWARE\JavaSoft`, in both registry views.
   - The Oracle `javapath` and Java Update folders.
   - The `SunJavaUpdateSched` Run value.
   - Machine PATH entries and `JAVA_HOME`, but only those pointing at what it
     deleted that no longer exist. Every other PATH entry is left as it was.
5. Scans again. That re-check decides the result.

Folders are deleted with `rd`, which removes a junction (Oracle's `latest`
link) as a link and never follows it into its target. Every delete is refused
unless the path is strictly inside one of the vendor folders or Oracle's
shared folders.

**Report** is read-only apart from the optional UDF. It lists everything with
a `[remove]` or `[keep]` tag and says what Remove would do.

Unlike the community script it was compared against, it never deletes
`HKCR\Installer\Products` keys. Removing those without uninstalling orphans
the product.

## Source and provenance

Written here. It was compared with "Uninstall All Versions of Java [WIN]" by
Dan Meddock ([evily2k/DattoRMM-Scripts](https://github.com/evily2k/DattoRMM-Scripts),
MIT, last updated 2022-03). That script was rejected for a rewrite because it:

- matched Oracle only,
- deleted MSI product registrations by name,
- ignored uninstaller exit codes,
- always exited 0.

No code was taken from it.

## Installing it in Datto

Automation → Components → New Component.

| Field | Value |
|---|---|
| Name | `Java - Uninstall All Versions [Win]` |
| Description | Uninstalls every standalone Java JRE/JDK from any vendor and cleans leftovers; Report mode lists them without changes. |
| Category | **Scripts** |
| Script type | PowerShell |
| Target OS | Windows |
| Level | 2 |
| Timeout | 3600 seconds |
| Attachments | none |

Paste the whole of `java-uninstall-all-versions-win.ps1` as the script body,
then add the input variables below. Or import the `.cpt` that CI builds on the
pull request.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrMode` | Selection | Remove | `Remove` or `Report`. Anything else is refused with exit 1. |
| `usrKeep` | String | blank | Comma-separated text matched, case-insensitively and anywhere, against product names and folder names. A match is left installed, e.g. `Java 8 Update 401` or `Corretto`. Each term must be at least 3 characters, or the run is refused. |
| `usrUdfNumber` | String | 13 | UDF 13 is Java Status in the [Datto RMM - UDFs](https://techcollective.itglue.com/3577506/docs/19691248) doc. 1 to 300, or blank for no UDF. Anything else is refused. It never overwrites a UDF value that doesn't start with `Java: `. |

No customer-specific value is hardcoded.

## Exit behaviour

| Exit | Status | Meaning |
|---|---|---|
| 0 | `CLEAN` | No removable Java. Nothing changed. |
| 0 | `FOUND` | Report mode found removable Java. Nothing changed. Add a post-condition on `STATUS=FOUND` if the job should show orange. |
| 0 | `REMOVED` | The re-check found nothing removable left. A pending reboot is reported on its own line and in the UDF. |
| 1 | `REFUSED` | An input variable is invalid. Nothing changed. |
| 3 | `REMOVE_INCOMPLETE` | Something removable is still there. Each remaining item is listed. A failed MSI uninstall leaves its log in `%ProgramData%\TechCollective\JavaRemoval`. |
| 5 | `ERROR` | The script failed, or PowerShell is older than 3. |

## How to tell it worked

A good Remove run lists each product as `[remove]` or `[keep]`, shows an
`[ok]` line per uninstall and per deleted folder, and ends with
`STATUS=REMOVED`. The UDF reads like `Java: REMOVED 3 | Kept 0 | 2026-11-18 14:02`.

A Report run ends with `STATUS=FOUND` and a UDF like
`Java: FOUND 2 | Java 8 Update 401 (64-bit); Amazon Corretto 11... | [date]`.
That makes the UDF a usable fleet-wide filter for "who still has Java".

## Test order

Never a customer first.

1. One internal device.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

Run **Report** across a site before running Remove there. Line-of-business
applications that need Java show up as products a client still uses.

## Known limits

- **It removes Java that applications installed as a public runtime.** An app
  that installed "Java 8 Update 401" as a separate product will stop working
  if it relies on it. Use `usrKeep` for those.
- **It doesn't remove JDKs unpacked outside the vendor folders, or per-user
  data.** The deployment cache under `AppData\LocalLow\Sun\Java` is left alone.
- **Version attribution can mistake one vendor for another.** If two vendors'
  JDKs share the same first three version numbers and one is kept, a leftover
  folder of the other may be left in place as the kept one's.
- **It doesn't notify running programs of PATH changes.** New sessions see the
  change; open ones keep the old PATH until they restart.
- **Windows PowerShell 3.0 or later is required.** On Windows 7 with
  PowerShell 2.0, it exits 5 without changing anything.
- **It has not been run against every vendor's uninstaller.** Tier 2 covers
  Oracle, Temurin and Corretto.

## Open questions

- A Windows `command` step in the test harness would let Tier 1 install a
  Temurin MSI and prove a real uninstall on every pull request.
- Level 2 was chosen at authoring time. Component Level is not standardised yet.
