# Component tests (Tier 1)

Every pull request that touches a component with a `test.json` runs that
component on a disposable GitHub-hosted runner for each platform its
`test.json` lists — Windows, macOS, Linux — the way Datto would, and checks
that it did what its `test.json` says. The result shows on the pull request as
a pass or a fail, with a step-by-step table in the run summary.

**Tier 1 tests the script, not Datto.** It runs the component as SYSTEM
(Windows) or root (macOS, Linux) with its input variables as environment
variables and its attachments in the working directory, which is the shape
Datto gives it. It does not use a Datto agent, and the runners are not clean
client machines: Windows Server rather than Windows 11, Ubuntu rather than
whatever distribution a client runs, and all three carry a lot of developer
tooling. It catches wrong URLs, wrong silent switches, wrong
exit codes and the wrong install scope. It does not replace running the
component on one internal device before it goes wide — see the checklist in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Files

| File | What it is |
|---|---|
| `Invoke-ComponentTest.ps1` | The Windows harness. Reads `component.json` and `test.json` and runs the steps. |
| `invoke-component-test.sh` | The macOS and Linux harness. Same `test.json` format, bash + `jq`. |
| `Invoke-Job.ps1` | Runs one command inside a scheduled task, so a step can run as SYSTEM or as the test user. |
| `discover.py` | Decides which components a pull request should test. |
| [`../../.github/workflows/test-components.yml`](../../.github/workflows/test-components.yml) | The workflow. |

The harness changes the machine it runs on — it creates a local user and
leaves whatever the component installed. It refuses to run outside GitHub
Actions unless given `-AllowLocal` (Windows) or `ALLOW_LOCAL=1` (macOS, Linux),
and then only belongs on a VM you are about to throw away.

## Writing a `test.json`

It sits beside `component.json`, which a tested component must have. The
harness reads the body, the timeout and the input variables' defaults from
`component.json`, so `test.json` only says what to run and what to check.

```json
{
  "platform": "windows",
  "description": "One sentence: what this test proves.",
  "variables": { "someInput": "value used for every run" },
  "steps": [
    { "type": "runComponent", "expectExitCode": 0, "outputContains": ["Installed"] },
    { "type": "file", "path": "%ProgramFiles%\\Vendor\\App\\app.exe", "minVersion": "4.2" },
    { "type": "launch", "path": "%ProgramFiles%\\Vendor\\App\\app.exe", "aliveSeconds": 15 }
  ]
}
```

Steps run in order. If a `runComponent` step fails, the rest are skipped —
checking the files of an install that did not happen tells you nothing new.
Any step may carry a `label`, which is what the results table shows, and
`"platforms": ["linux"]` to run only on some of the component's platforms —
for a path or a message that differs between them.

Any step may also carry `"tier": 2`: something a CI runner cannot do honestly,
usually because it needs a real interactive logon. The harness reports it as
**SKIP** instead of running it. It stays in the spec so the spec is the whole
description of what "working" means, and so Tier 2 has a list to pick up.

### Top level

| Field | Required | Meaning |
|---|---|---|
| `platforms` | Yes | Which runners to test on: any of `windows`, `macos`, `linux`, e.g. `["macos", "linux"]`. Each gets its own job and its own pass/fail. (`"platform": "windows"` is the same as a one-item list.) |
| `description` | No | What the test proves, for the reviewer. |
| `variables` | No | Input variable values for every run, over the defaults in `component.json`. Values are strings, as Datto passes them. |
| `runsOn` | No | Override the runner: `{"macos": "macos-15"}`, or one label for every platform. Defaults `windows-latest`, `macos-latest`, `ubuntu-latest`. |
| `steps` | Yes | The list below. |

### Step types

Not every step type exists on every harness yet:

| Step | Windows | macOS / Linux |
|---|---|---|
| `runComponent` | yes | yes |
| `file` | yes | yes |
| `registry`, `uninstallEntry`, `activeSetup`, `launch` | yes | — |
| `testUser`, `command` | — | yes |

A step a harness does not know fails with a message saying so, rather than
passing silently.

**`runComponent`** — run the component as SYSTEM (Windows) or root (macOS,
Linux, with a clean environment and the shebang honoured).

| Field | Default | Meaning |
|---|---|---|
| `expectExitCode` | `0` | The exit code that counts as a pass. Use a non-zero one to test that bad input is refused. |
| `outputContains` | none | Strings stdout must contain (case-insensitive). |
| `variables` | none | Overrides for this run only, over the top-level ones. |

Run it twice in a row to prove a second run is harmless — most components get
re-run, and "already installed" must not be an error.

**`file`** — a file exists (or does not).

| Field | Default | Meaning |
|---|---|---|
| `path` | — | `%VARIABLES%` are expanded. |
| `as` | `system` | `testuser` resolves `%LOCALAPPDATA%`, `%APPDATA%`, `%USERPROFILE%` and `%TEMP%` against the test user's profile. `runner` (or `system`) resolves them for the runner's own account. |
| `exists` | `true` | `false` to check something was removed. |
| `minVersion` | none | The file's version must be at least this. |

When a file is not where the spec expects, the result lists anywhere under
Program Files or the user's AppData that has a file of the same name — so a
wrong expected path in the spec, or in the component's own reporting, shows
the right one.

**`uninstallEntry`** — the product is registered in Programs and Features.

| Field | Meaning |
|---|---|
| `displayName` | A regex matched against each entry's DisplayName. |
| `scope` | Optional. `machine` (HKLM) or `user` (the runner account's HKCU). Omit to accept either; the result says which it found. |

**`registry`** — a machine-wide key or value (`HKLM:` paths).

| Field | Meaning |
|---|---|
| `path` | e.g. `HKLM:\\SOFTWARE\\Vendor\\App` |
| `name` | The value to read. `(Default)` for the default value. Omit to check only that the key exists. |
| `equals` / `matches` | Compare as a string, or against a regex. Omit both to check only that the value exists. |

**`activeSetup`** — stand in for a user's next logon. With `"as": "runner"`
it runs the `StubPath` directly as the runner's own account, in its own
session — the closest a CI runner gets to "a user logs on and the stub runs".
That account is an administrator, so it proves the stub, the installer and a
silent install work, but not that a standard user could do it. Without `as`,
it runs the `StubPath`
the component registered under `HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\<key>`
as a local standard user the harness creates. It proves the stub works as a
standard user; it cannot prove Windows fires it at a real logon, which needs an
interactive session.

| Field | Meaning |
|---|---|
| `key` | The Active Setup GUID, braces included. |
| `as` | `runner` for the runner's own account (Tier 1). Default: the standard test user. |
| `log` | Optional. A file to print if the stub fails, e.g. an `msiexec /l*v` log. Expanded as the test user. |
| `timeoutSeconds` | Default `600`. |

**On GitHub's runners this step cannot run a per-user MSI.** The stub runs
from a scheduled task, which logs the user on as a batch job, and the Windows
Installer service refuses a standard user's `msiexec` from a batch logon
(`Failed to connect to server. Error: 0x80070005`, exit 1601). Running it
elevated instead is no substitute: an elevated per-user MSI can install
per-machine, which is not what a user at a real logon gets. So for an
installer, mark this step and the checks that depend on it `"tier": 2`. The
step still works for stubs that do not call `msiexec`.

**`launch`** — start the app and pass if it is still running after
`aliveSeconds` (default `15`). There is no desktop in a CI session, so this
proves "starts and does not crash", not "shows a window". Takes `path` and `as`
the same way `file` does, including `as: runner`.

### macOS and Linux only

**`testUser`** — create the local standard user `tctest` *before* the
component runs, for components that act on the users already on the machine
(a shortcut on every Desktop, say). `"desktop": true` (the default) also
creates `~/Desktop`. Paths in later steps can use `{testuser_home}` and
`{testuser}`.

**`file`** on macOS/Linux takes `path`, `exists`, and:

| Field | Meaning |
|---|---|
| `executable` | `true`: must have the execute bit. |
| `owner` | A user name, or `testuser`. |
| `contains` / `notContains` | Lists of strings the file must / must not contain — the right client values filled in, no template placeholders left behind. |

When the file is missing, the result lists what its folder does hold.

**`command`** — run a shell command and check it. The way to prove the
installed thing works for the person who will use it, not just that files
landed.

| Field | Default | Meaning |
|---|---|---|
| `run` | — | The command, run with `bash -c`, stdin closed. |
| `as` | `root` | `root`, `testuser` (a login shell as the test user), or `runner`. |
| `expectExitCode` | `0` | |
| `outputContains` / `outputNotContains` | none | Case-insensitive, stdout and stderr together. |
| `timeoutSeconds` | `120` | |

A user-facing script that ends by waiting for input gets end-of-file and
exits, so a `command` can run one up to the point where it would need a
person, a browser or a real server, and check it got that far — see
[`google-cloud-iap-connect-mac-lin/test.json`](../../Applications/google-cloud-iap-connect-mac-lin/test.json).

### Which checks to write

Write the checks that would have caught the ways this component could quietly
not work:

- **Where it lands.** A component runs as SYSTEM. A per-user installer run as
  SYSTEM installs into SYSTEM's profile and "succeeds". If the product installs
  per user, check the file `as: testuser`.
- **That it runs.** `launch`, for anything with an executable.
- **A second run.** Another `runComponent`.
- **Bad input is refused.** A `runComponent` with a broken variable and the
  exit code the script documents for it.
- **What it registers.** Uninstall keys, Active Setup keys, services.

Nothing a test prints may identify a customer — the logs of this public repo
are public.

## Adding a check type

Add a case to the `switch ($type)` in `Invoke-ComponentTest.ps1`, and a section
above. Keep each type generic — a check that only makes sense for one product
belongs in that product's `outputContains`, not in the harness.
