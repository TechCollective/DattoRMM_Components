#!/usr/bin/env python3
"""Work out which components the Tier 1 test workflow should test.

Prints a GitHub Actions matrix (JSON) on stdout and writes `matrix=`,
`count=` and `harness=` to $GITHUB_OUTPUT when it is set. `harness=true` means
the harness itself should be tested (its self-test), because it changed or
everything is being tested. Warnings go to stderr as workflow
annotations.

  discover.py --base <sha>      components touched since <sha>
  discover.py --all             every component that has a test.json
  discover.py --only <folder>   just that one

A change to the harness itself, or to the workflow, tests everything - the
harness is what every result depends on.

A touched component without a test.json fails discovery, unless it is listed
in untested-components.txt (today's untested components, a list to shrink),
which only warns.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

CATEGORIES = ("Applications", "Scripts", "Monitors")
RETEST_ALL = ("tools/test-harness/", ".github/workflows/test-components.yml")
EXEMPT_LIST = "tools/test-harness/untested-components.txt"

# platform in test.json -> GitHub-hosted runner. Windows runs
# Invoke-ComponentTest.ps1; macOS and Linux run invoke-component-test.sh.
RUNNERS = {"windows": "windows-latest", "macos": "macos-latest", "linux": "ubuntu-latest"}


def warn(msg):
    print(f"::warning::{msg}", file=sys.stderr)


def all_components(root):
    for cat in CATEGORIES:
        base = root / cat
        if base.is_dir():
            yield from sorted(p for p in base.iterdir() if p.is_dir())


def changed_components(root, base):
    """The component folders this change touched, and whether it retests everything."""
    out = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    dirs = sorted({Path(*Path(f).parts[:2]) for f in out
                   if Path(f).parts[0] in CATEGORIES and len(Path(f).parts) > 2})
    return [root / d for d in dirs if (root / d).is_dir()], any(f.startswith(RETEST_ALL) for f in out)


def read_exempt(root):
    path = root / EXEMPT_LIST
    if not path.is_file():
        return set()
    return {l.strip().rstrip("/") for l in path.read_text().splitlines() if l.strip() and not l.startswith("#")}


def check_touched(root, touched):
    """Fails a touched component that has no test.json, unless it is exempt."""
    exempt = read_exempt(root)
    missing = False
    for d in touched:
        rel = d.relative_to(root).as_posix()
        has_spec = (d / "test.json").is_file()
        if not has_spec and rel in exempt:
            warn(f"{rel} has no test.json, so it was not tested. It is on the legacy list in "
                 f"{EXEMPT_LIST}; giving it one is how that list shrinks.")
        elif not has_spec:
            print(f"::error file={rel}::{rel} has no test.json. Every new component ships one; "
                  "see tools/test-harness/README.md.", file=sys.stderr)
            missing = True
        elif rel in exempt:
            warn(f"{rel} now has a test.json: remove it from {EXEMPT_LIST}.")
    if missing:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--base")
    g.add_argument("--all", action="store_true")
    g.add_argument("--only")
    args = ap.parse_args()
    root = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                               check=True, capture_output=True, text=True).stdout.strip())

    everything = False
    if args.all:
        dirs, everything = list(all_components(root)), True
    elif args.only:
        dirs = [root / args.only.strip("/")]
    else:
        touched, everything = changed_components(root, args.base)
        check_touched(root, touched)
        dirs = list(all_components(root)) if everything else touched

    matrix = []
    for d in dirs:
        rel = d.relative_to(root).as_posix()
        spec_file = d / "test.json"
        if not spec_file.is_file():
            continue   # check_touched has already passed judgement on it
        try:
            spec = json.loads(spec_file.read_text())
        except json.JSONDecodeError as e:
            print(f"::error file={rel}/test.json::Not valid JSON: {e}", file=sys.stderr)
            sys.exit(1)
        # "platforms": ["macos", "linux"] for a component that runs on
        # several; "platform": "windows" is the same thing for one.
        plats = spec.get("platforms")
        if plats is None:
            plats = [spec["platform"]] if "platform" in spec else []
        plats = [str(p).lower() for p in (plats if isinstance(plats, list) else [plats])]
        bad = [p for p in plats if p not in RUNNERS]
        if not plats or bad:
            print(f"::error file={rel}/test.json::platforms must be a list drawn from "
                  f"{sorted(RUNNERS)}, got {plats}.", file=sys.stderr)
            sys.exit(1)
        manifest = d / "component.json"
        if not manifest.is_file():
            print(f"::error file={rel}/test.json::A tested component needs a component.json beside it.", file=sys.stderr)
            sys.exit(1)
        name = json.loads(manifest.read_text()).get("general", {}).get("name", rel)
        runs_on = spec.get("runsOn", {})
        for p in plats:
            # runsOn: a runner label for every platform, or {"macos": "macos-15"}.
            runner = runs_on.get(p, RUNNERS[p]) if isinstance(runs_on, dict) else runs_on
            matrix.append({"component": rel, "platform": p, "runner": runner,
                           "name": name if len(plats) == 1 else f"{name} ({p})"})

    text = json.dumps(matrix)
    print(text)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"matrix={text}\ncount={len(matrix)}\nharness={str(everything).lower()}\n")


if __name__ == "__main__":
    main()
