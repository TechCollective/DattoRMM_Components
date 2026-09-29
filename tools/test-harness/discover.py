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

# platform in test.json -> GitHub-hosted runner. Only Windows has a harness so
# far; the others are listed so a spec for them is reported, not ignored.
RUNNERS = {"windows": "windows-latest"}
PLANNED = {"macos", "linux"}


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
        platform = str(spec.get("platform", "")).lower()
        if platform in RUNNERS:
            name = rel
            manifest = d / "component.json"
            if manifest.is_file():
                name = json.loads(manifest.read_text()).get("general", {}).get("name", rel)
            else:
                print(f"::error file={rel}/test.json::A tested component needs a component.json beside it.", file=sys.stderr)
                sys.exit(1)
            matrix.append({"component": rel, "name": name,
                           "runner": spec.get("runsOn", RUNNERS[platform])})
        elif platform in PLANNED:
            warn(f"{rel}: there is no {platform} harness yet, so it was not tested.")
        else:
            print(f"::error file={rel}/test.json::platform must be one of "
                  f"{sorted(set(RUNNERS) | PLANNED)}, got '{platform}'.", file=sys.stderr)
            sys.exit(1)

    text = json.dumps(matrix)
    print(text)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"matrix={text}\ncount={len(matrix)}\n")


if __name__ == "__main__":
    main()
