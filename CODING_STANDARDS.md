# Coding standards

Read at review time. The component rules live in CONTRIBUTING.md's
[review checklist](CONTRIBUTING.md#review-checklist): apply every item to the
diff. Anything mechanical is enforced by `tools/check.sh` and CI, so it is not
repeated here. These are the judgement calls no check can make.

## Read the file, not only the diff

Before reporting a bug in a changed line, read the code around it that decides
whether it is one: the shell options and traps set at the top of the script,
the function's callers, the harness step that runs it. A finding that holds
only for the diff in isolation is not a finding.

## Shell: a monitor survives its own errors

A monitor must print exactly one result block on every path, including
unexpected death, so a shell monitor uses `set -u` (with `pipefail` where it
pipes) and handles errors explicitly, never `set -e` on its own. The pattern is
an EXIT trap that prints the fallback result block (see
`Monitors/disk-space-free-space-below-threshold-lin`). `set -e` is acceptable
only with that trap in place.

The test harness (`tools/test-harness/invoke-component-test.sh`) uses
`set -uo pipefail` without `-e` on purpose: a failing check must be recorded
as a FAIL and the run must carry on to the next step.

## A new check proves it can fail

A new harness check, lint rule or discovery rule comes with a case that fails
without it: a self-test case in `tools/test-harness/self-test/`, a test in
`tools/test_*.py` or `tools/test-harness/test_*.py`. A check that has only been
seen passing is unproven.

## Suppressions carry their reason

A `# shellcheck disable=` or `SuppressMessageAttribute` is a judgement call:
the reason on the same line must say why this case is an exception, not
restate the rule. Prefer fixing the warning; new PowerShell warnings fail lint,
and `tools/lint-baseline.txt` only shrinks.
