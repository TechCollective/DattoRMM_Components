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
| `discover.py` | Decides which components a pull request should test, and whether the harness itself changed. Fails a touched component that has no `test.json`. |
| `untested-components.txt` | The legacy list: components from before every new one had to ship a `test.json`. Touching one warns instead of failing. It only shrinks. |
| `test_discover.py` | Tests for `discover.py`, against a throwaway git repository. |
| `self-test/` | Tests the harness: fixture components whose right answer is known. See [Testing the harness](#testing-the-harness). |
| [`../../.github/workflows/test-components.yml`](../../.github/workflows/test-components.yml) | The workflow. |

The harness changes the machine it runs on — it creates a local user and
leaves whatever the component installed. It refuses to run outside GitHub
Actions unless given `-AllowLocal` (Windows) or `ALLOW_LOCAL=1` (macOS, Linux),
and then only belongs on a VM you are about to throw away.

## Writing a `test.json`

**Every component needs one.** A pull request that touches a component with
no `test.json` fails at "Find components to test", unless the component is on
the legacy list in `untested-components.txt`. That list holds the components
that were untested when the rule came in. Touching one of them only warns.
Giving one a `test.json` and deleting its line from the list, in the same pull
request, is how the list shrinks. Nothing is ever added to it.

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
| `command` | yes | yes |
| `registry`, `uninstallEntry`, `activeSetup`, `launch` | yes | — |
| `testUser` | — | yes |

A step a harness does not know fails with a message saying so, rather than
passing silently.

**`runComponent`** — run the component as SYSTEM (Windows) or root (macOS,
Linux, with a clean environment and the shebang honoured).

| Field | Default | Meaning |
|---|---|---|
| `expectExitCode` | `0` | The exit code that counts as a pass. Use a non-zero one to test that bad input is refused. |
| `outputContains` | none | Strings stdout must contain (case-insensitive). |
| `variables` | none | Overrides for this run only, over the top-level ones. |

**For a monitor, every run is also checked for exactly one result block.**
When `component.json` says the category is `monitors`, a run passes only if
its output holds one `<-Start Result->` line followed by one `<-End Result->`
line. Diagnostic blocks are not counted. A run that prints none, two, or an
unclosed one fails, and says how many start and end markers it found. This is
the review checklist's "exactly one result block, on every path" rule; nobody
needs to write it into a `test.json`, and there is no way to turn it off.

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

**`command`** on Windows — run PowerShell and check it: the way to plant
what a component reacts to before it runs (a registry key, a file, a fake
install), and to check what it left behind.

| Field | Default | Meaning |
|---|---|---|
| `run` | — | PowerShell, run by Windows PowerShell with `-EncodedCommand`, so it needs no extra quoting. |
| `script` | — | Instead of `run`: a `.ps1` in the component folder, run with `-File`. See [Test scripts](#test-scripts). |
| `as` | `system` | `system`, `testuser` (the local standard user, created on first use), or `runner` (the runner's own account, in its own session). |
| `expectExitCode` | `0` | |
| `outputContains` / `outputNotContains` | none | Case-insensitive, stdout and stderr together. |
| `timeoutSeconds` | `120` | A command still running then fails, and is stopped. |

Use reserved names in anything planted — `example.com` hosts, documentation
IP ranges — because the log of this public repo shows every command.

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
| `script` | — | Instead of `run`: a file in the component folder, its text run with `bash -c` like `run`. See [Test scripts](#test-scripts). |
| `as` | `root` | `root`, `testuser` (a login shell as the test user), or `runner`. |
| `expectExitCode` | `0` | |
| `outputContains` / `outputNotContains` | none | Case-insensitive, stdout and stderr together. |
| `timeoutSeconds` | `120` | |

A user-facing script that ends by waiting for input gets end-of-file and
exits, so a `command` can run one up to the point where it would need a
person, a browser or a real server, and check it got that far — see
[`google-cloud-iap-connect-mac-lin/test.json`](../../Applications/google-cloud-iap-connect-mac-lin/test.json).

### Test scripts

A `command` step can give `script` instead of `run`: a path relative to the
component's folder, by convention in a `tests` subfolder
(`"script": "tests/plant-rogue-client.ps1"`). Test logic longer than a line or
two belongs in one, where it shows in the diff and is linted like the body.
The harness runs it as any `as` identity (the test user need not be able to
read the checkout) with the same `as`, exit code, output and timeout checks as `run`. Giving both
`run` and `script` fails the step, and so does a path that leads outside the
component folder. The packer never puts `tests/` in an export.

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

### Killed monitors

A monitor stopped mid-run (Datto's timeout, or someone stopping the job) should
still leave a result block, or Datto shows an alert with no text.

**macOS and Linux:** a shell monitor's EXIT trap prints a fallback block when
bash gets TERM (see `CODING_STANDARDS.md`). Each monitor proves it with a
`command` step running `tests/kill.sh`: start the body as the harness would,
with a shim hanging, send TERM, and count the result blocks itself (the
harness checks blocks only on `runComponent` steps). Copy
`Monitors/disk-space-free-space-below-threshold-lin/tests/kill.sh`.

macOS runs monitors with `/bin/bash` 3.2, which holds a TERM sent to bash
alone until the command it is running returns, so a hung command delays the
fallback block indefinitely. TERM to the whole process group (bash and the hung
command) prints it at once, so a macOS kill test stops the group: see
`Monitors/disk-health-smart-failure-detected-mac-lin/tests/kill.sh`. Whether
Datto stops the group or only bash is part of the open question below.

**Windows:** nothing can print a block after a kill. `Stop-Process` (and
anything else built on `TerminateProcess`) ends `powershell.exe` at once:
no `trap`, `finally` or exit handler runs, so the `trap` fallbacks in the
Windows monitors cover errors, never a kill. The step
`Monitors/connection-health-ping-targets-not-responding-win/tests/kill.ps1`
proves it: stopped mid-ping, the monitor prints no result block at all. This
holds for every PowerShell monitor, so the other Windows monitors carry no kill
test of their own. A Windows monitor's defence is its own time limit: finish,
or give up with a block, well inside the component timeout.

**Open question, for someone with Datto access:** what Datto itself records
when it stops a Windows monitor (its timeout, or a stopped job), and whether it
stops the process this way at all; and on macOS, whether it signals the whole
process group or only bash. Confirm it on an internal device and record
the answer here.

## Testing the harness

Every result above depends on the harness being right, so the harness has its
own test. `self-test/Invoke-HarnessSelfTest.ps1` runs the harness on a fixture
monitor (`self-test/monitor-win` on Windows, `self-test/monitor-lin` on macOS
and Linux) that prints whatever result blocks a variable asks for, and checks
the harness passes what it should pass and fails what it should fail, for the
reason it should.

The workflow runs it on Windows and Linux whenever anything under
`tools/test-harness/` or the workflow changes, and the **Component tests**
check fails if it does. Locally it needs `pwsh`, and the same throwaway
machine the harness does — a container works for the Linux side:

    docker run --rm -v "$PWD":/repo:ro -w /repo mcr.microsoft.com/powershell:7.4-ubuntu-22.04 \
      bash -c 'apt-get update -qq && apt-get install -y -qq jq sudo && pwsh tools/test-harness/self-test/Invoke-HarnessSelfTest.ps1'

A new harness check gets a case there: a fixture output it must fail, and one
it must pass.

`discover.py` has its own tests, `test_discover.py`. They build a throwaway git
repository and check which components and platforms a change selects. "Find
components to test" runs them on every pull request before it discovers
anything:

    python3 -m unittest discover -s tools/test-harness -p 'test_*.py'

## Adding a check type

Add a case to the `switch ($type)` in `Invoke-ComponentTest.ps1`, and a section
above. Keep each type generic — a check that only makes sense for one product
belongs in that product's `outputContains`, not in the harness.
