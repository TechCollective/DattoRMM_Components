#!/usr/bin/env python3
"""Fail when the copies of a shared code block differ.

Some components carry the same block of code, because Datto runs each
component as one self-contained script. Each copy is marked

    # >>> <block name>: <anything>
    ...
    # <<< <block name>

and every copy of a block, in every component (including one inside a heredoc),
must be byte-identical. This finds them all and compares them.

    python3 tools/check-shared-blocks.py

Exit 0 when every block's copies match; 1 when they differ, a block is not
closed, or a block appears only once (a copy was lost).
"""
import hashlib
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATEGORIES = ("Applications", "Scripts", "Monitors")
START = re.compile(r"^# >>> ([^:]+?)\s*(:.*)?$")

blocks = {}   # name -> [(file, line, text)]
errors = []
for cat in CATEGORIES:
    for path in sorted((ROOT / cat).rglob("*")):
        if not path.is_file() or path.suffix not in (".sh", ".ps1", ".py", ".bat"):
            continue
        rel = path.relative_to(ROOT)
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
        i = 0
        while i < len(lines):
            m = START.match(lines[i].rstrip("\n"))
            if not m:
                i += 1
                continue
            name, first = m.group(1), i
            end = f"# <<< {name}"
            j = i + 1
            while j < len(lines) and lines[j].rstrip("\n") != end:
                j += 1
            if j == len(lines):
                errors.append(f"{rel}:{first + 1}: '{name}' is never closed with '{end}'")
                break
            blocks.setdefault(name, []).append((rel, first + 1, "".join(lines[first:j + 1])))
            i = j + 1

for name, copies in sorted(blocks.items()):
    digests = {}
    for rel, line, text in copies:
        digests.setdefault(hashlib.sha256(text.encode()).hexdigest()[:12], []).append(f"{rel}:{line}")
    print(f"{name}: {len(copies)} copies, {len(digests)} distinct")
    for digest, where in digests.items():
        for w in where:
            print(f"  {digest}  {w}")
    if len(copies) < 2:
        errors.append(f"'{name}' appears only once; a shared block with one copy has lost the others")
    if len(digests) > 1:
        errors.append(f"'{name}': the copies differ - change every copy together")

for e in errors:
    print(f"::error::{e}" if "GITHUB_ACTIONS" in os.environ else f"ERROR: {e}")
if not blocks:
    print("No shared blocks found.")
sys.exit(1 if errors else 0)
