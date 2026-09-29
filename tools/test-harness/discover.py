#!/usr/bin/env python3
"""Work out which components the Tier 1 test workflow should test.

Prints a GitHub Actions matrix (JSON) on stdout and writes `matrix=` and
`count=` to $GITHUB_OUTPUT when it is set. Warnings go to stderr as workflow
annotations.

  discover.py --base <sha>      components touched since <sha>
  discover.py --all             every component that has a test.json
  discover.py --only <folder>   just that one

A change to the harness itself, or to the workflow, tests everything - the
harness is what every result depends on.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

CATEGORIES = ("Applications", "Scripts", "Monitors")
RETEST_ALL = ("tools/test-harness/", ".github/workflows/test-components.yml")

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
    out = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout.split()
    if any(f.startswith(RETEST_ALL) for f in out):
        return list(all_components(root)), True
    dirs = sorted({Path(*Path(f).parts[:2]) for f in out
                   if Path(f).parts[0] in CATEGORIES and len(Path(f).parts) > 2})
    return [root / d for d in dirs if (root / d).is_dir()], False


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
        dirs, everything = changed_components(root, args.base)

    matrix = []
    for d in dirs:
        rel = d.relative_to(root).as_posix()
        spec_file = d / "test.json"
        if not spec_file.is_file():
            # Old components and monitors have no spec yet. Say so, but only
            # for the ones this change actually touched - not on a full sweep.
            if not everything and not rel.startswith("Monitors/"):
                warn(f"{rel} has no test.json, so it was not tested. See tools/test-harness/README.md.")
            continue
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
            f.write(f"matrix={text}\ncount={len(matrix)}\n")


if __name__ == "__main__":
    main()
