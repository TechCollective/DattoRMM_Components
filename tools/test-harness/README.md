# Component tests (Tier 1)

Every pull request that touches a component with a `test.json` runs that
component on a disposable GitHub-hosted runner, the way Datto would, and checks
that it did what its `test.json` says. The result shows on the pull request as
a pass or a fail, with a step-by-step table in the run summary.

**Tier 1 tests the script, not Datto.** It runs the component as SYSTEM with its
input variables as environment variables and its attachments in the working
directory, which is the shape Datto gives it. It does not use a Datto agent,
and the runner is Windows Server with a lot of developer tooling installed, not
a clean Windows 11 desktop. It catches wrong URLs, wrong silent switches, wrong
exit codes and the wrong install scope. It does not replace running the
component on one internal device before it goes wide — see the checklist in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md).

Only Windows has a harness so far. A `test.json` for `macos` or `linux` is
reported as untested rather than silently ignored.

## Files

| File | What it is |
|---|---|
| `Invoke-ComponentTest.ps1` | The Windows harness. Reads `component.json` and `test.json` and runs the steps. |
| `Invoke-Job.ps1` | Runs one command inside a scheduled task, so a step can run as SYSTEM or as the test user. |
| `discover.py` | Decides which components a pull request should test. |
| [`../../.github/workflows/test-components.yml`](../../.github/workflows/test-components.yml) | The workflow. |

The harness changes the machine it runs on — it creates a local user and
leaves whatever the component installed. It refuses to run outside GitHub
Actions unless given `-AllowLocal`, and then only belongs on a VM you are about
to throw away.

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
Any step may carry a `label`, which is what the results table shows.

### Top level

| Field | Required | Meaning |
|---|---|---|
| `platform` | Yes | `windows`. (`macos` and `linux` are reserved.) |
| `description` | No | What the test proves, for the reviewer. |
| `variables` | No | Input variable values for every run, over the defaults in `component.json`. Values are strings, as Datto passes them. |
| `runsOn` | No | Override the runner, e.g. `windows-2025`. Default `windows-latest`. |
| `steps` | Yes | The list below. |

### Step types

**`runComponent`** — run the component as SYSTEM.

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
| `as` | `system` | `testuser` resolves `%LOCALAPPDATA%`, `%APPDATA%`, `%USERPROFILE%` and `%TEMP%` against the test user's profile. |
| `exists` | `true` | `false` to check something was removed. |
| `minVersion` | none | The file's version must be at least this. |

**`registry`** — a machine-wide key or value (`HKLM:` paths).

| Field | Meaning |
|---|---|
| `path` | e.g. `HKLM:\\SOFTWARE\\Vendor\\App` |
| `name` | The value to read. `(Default)` for the default value. Omit to check only that the key exists. |
| `equals` / `matches` | Compare as a string, or against a regex. Omit both to check only that the value exists. |

**`activeSetup`** — stand in for a user's next logon. Runs the `StubPath`
the component registered under `HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\<key>`
as a local standard user the harness creates. It proves the stub works as a
standard user; it cannot prove Windows fires it at a real logon, which needs an
interactive session.

| Field | Meaning |
|---|---|
| `key` | The Active Setup GUID, braces included. |
| `log` | Optional. A file to print if the stub fails, e.g. an `msiexec /l*v` log. Expanded as the test user. |
| `timeoutSeconds` | Default `600`. |

**`launch`** — start the app and pass if it is still running after
`aliveSeconds` (default `15`). There is no desktop in a CI session, so this
proves "starts and does not crash", not "shows a window". Takes `path` and `as`
the same way `file` does.

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
