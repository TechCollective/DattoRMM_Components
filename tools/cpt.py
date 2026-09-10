#!/usr/bin/env python3
"""
Pack and unpack Datto RMM component export files (.cpt).

A .cpt is a flat ZIP archive holding, in this order:

    command.bat     the component body, whatever the language actually is
    resource.xml    the component metadata and input variables
    icon.png        48x48 RGBA icon shown in the Component Library
    <payload>       zero or more extra files (an MSI, a config, ...)

In this repo a component lives as a directory:

    Monitors/disk-space-free-space-below-threshold-lin/
      component.json                                   metadata -> resource.xml
      disk-space-free-space-below-threshold-lin.sh     body     -> command.bat
      icon.png                                         optional -> icon.png
                                                       (falls back to the TC logo)
      files/                                           optional -> extra payload
      README.md                                        documentation, not packaged

Usage:
    cpt.py pack   <component-dir> [-o out.cpt]
    cpt.py unpack <file.cpt> -o <component-dir>
    cpt.py verify <file.cpt>          round-trip a .cpt through unpack+pack
"""

import argparse
import json
import pathlib
import sys
import zipfile
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape

# Datto's exporter writes these three first, in this order. Payload follows.
CORE_FILES = ("command.bat", "resource.xml", "icon.png")

# Order of <general> children, matching a real Datto export byte for byte.
GENERAL_ORDER = (
    "name",
    "category",
    "description",
    "uid",
    "hash",
    "version",
    "timeout",
    "securityLevel",
    "installType",
    "uninstallType",
)

# Order of <variable> children. selectionKeyValue blocks sit between name and type.
VARIABLE_ORDER = ("name", "type", "direction", "description", "defaultVal")

CATEGORIES = ("applications", "scripts", "monitors")

# Fixed ZIP timestamp so a rebuild of an unchanged component is byte-identical
# and CI does not produce a diff on every run. Datto ignores these.
ZIP_DATE = (2020, 1, 1, 0, 0, 0)

# Components without their own icon.png fall back to the TechCollective logo,
# so an unbranded component never lands in the Component Library with a blank
# or broken thumbnail. 48x48 RGBA, the size Datto's own icons use.
DEFAULT_ICON = pathlib.Path(__file__).resolve().parent / "default-icon.png"


def default_icon() -> bytes:
    if not DEFAULT_ICON.is_file():
        sys.exit(f"{DEFAULT_ICON} is missing; it is committed to this repo and should be there")
    return DEFAULT_ICON.read_bytes()


# --------------------------------------------------------------------------
# resource.xml generation
# --------------------------------------------------------------------------


def _tag(name: str, value, indent: str) -> str:
    """One XML element, self-closing when empty, the way Datto writes it."""
    if value is None or value == "":
        return f"{indent}<{name}/>"
    return f"{indent}<{name}>{escape(str(value))}</{name}>"


def build_resource_xml(manifest: dict) -> bytes:
    general = manifest.get("general", {})
    lines = [
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>',
        '<component info="CentraStage Component">',
        "    <general>",
    ]

    for key in GENERAL_ORDER:
        # uninstallType only appears on application components; skip when absent.
        if key not in general and key == "uninstallType":
            continue
        lines.append(_tag(key, general.get(key, ""), " " * 8))

    lines.append("    </general>")

    for idx, var in enumerate(manifest.get("variables", [])):
        lines.append(f'    <variable idx="{idx}">')
        lines.append(_tag("name", var.get("name", ""), " " * 8))

        for opt_idx, option in enumerate(var.get("options", [])):
            lines.append(f'        <selectionKeyValue idx="{opt_idx}">')
            lines.append(_tag("name", option.get("name", ""), " " * 12))
            lines.append(_tag("value", option.get("value", ""), " " * 12))
            lines.append("        </selectionKeyValue>")

        for key in VARIABLE_ORDER[1:]:
            lines.append(_tag(key, var.get(key, ""), " " * 8))

        lines.append("    </variable>")

    lines.append("</component>")
    # Datto's export has no trailing newline after </component>.
    return "\n".join(lines).encode("utf-8")


# --------------------------------------------------------------------------
# resource.xml parsing (for unpack)
# --------------------------------------------------------------------------


def parse_resource_xml(data: bytes) -> dict:
    root = ET.fromstring(data)
    general = {}
    general_el = root.find("general")
    if general_el is not None:
        for key in GENERAL_ORDER:
            el = general_el.find(key)
            if el is not None:
                general[key] = el.text or ""

    variables = []
    for var_el in root.findall("variable"):
        var = {}
        for key in VARIABLE_ORDER:
            el = var_el.find(key)
            if el is not None:
                var[key] = el.text or ""
        options = [
            {
                "name": (o.find("name").text or "") if o.find("name") is not None else "",
                "value": (o.find("value").text or "") if o.find("value") is not None else "",
            }
            for o in var_el.findall("selectionKeyValue")
        ]
        if options:
            var["options"] = options
        variables.append(var)

    return {"general": general, "variables": variables}


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------


def validate(manifest: dict) -> list:
    problems = []
    general = manifest.get("general", {})

    for key in ("name", "category", "uid", "installType"):
        if not general.get(key):
            problems.append(f"general.{key} is required")

    category = general.get("category")
    if category and category not in CATEGORIES:
        problems.append(f"general.category {category!r} is not one of {CATEGORIES}")

    for key in ("version", "timeout", "securityLevel"):
        value = general.get(key)
        if value in (None, ""):
            problems.append(f"general.{key} is required")
        elif not str(value).isdigit():
            problems.append(f"general.{key} must be an integer, got {value!r}")

    seen = set()
    for idx, var in enumerate(manifest.get("variables", [])):
        name = var.get("name")
        if not name:
            problems.append(f"variables[{idx}].name is required")
        elif name in seen:
            problems.append(f"variables[{idx}].name {name!r} is a duplicate")
        else:
            seen.add(name)

        vtype = var.get("type")
        if not vtype:
            problems.append(f"variables[{idx}].type is required")
        elif vtype == "map" and not var.get("options"):
            problems.append(f"variables[{idx}] is type map but has no options")
        elif vtype != "map" and var.get("options"):
            problems.append(f"variables[{idx}] has options but is type {vtype!r}, not map")

    return problems


# --------------------------------------------------------------------------
# pack / unpack
# --------------------------------------------------------------------------


def find_body(directory: pathlib.Path, manifest: dict) -> pathlib.Path:
    named = manifest.get("body")
    if named:
        path = directory / named
        if not path.is_file():
            sys.exit(f"{directory}: manifest names body {named!r}, which does not exist")
        return path

    candidates = sorted(
        p for p in directory.iterdir() if p.suffix in (".sh", ".ps1", ".bat", ".py")
    )
    if not candidates:
        sys.exit(f"{directory}: no component body found (looked for .sh .ps1 .bat .py)")
    if len(candidates) > 1:
        names = ", ".join(p.name for p in candidates)
        sys.exit(f'{directory}: several possible bodies ({names}); set "body" in component.json')
    return candidates[0]


def pack(directory: pathlib.Path, out: pathlib.Path) -> pathlib.Path:
    manifest_path = directory / "component.json"
    if not manifest_path.is_file():
        sys.exit(f"{directory}: no component.json")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    problems = validate(manifest)
    if problems:
        for problem in problems:
            print(f"{manifest_path}: {problem}", file=sys.stderr)
        sys.exit(1)

    body_path = find_body(directory, manifest)
    body = normalise_body(body_path.read_bytes())

    icon_path = directory / "icon.png"
    icon = icon_path.read_bytes() if icon_path.is_file() else default_icon()

    payload = []
    files_dir = directory / "files"
    if files_dir.is_dir():
        payload = sorted(p for p in files_dir.rglob("*") if p.is_file())

    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in (
            ("command.bat", body),
            ("resource.xml", build_resource_xml(manifest)),
            ("icon.png", icon),
        ):
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)

        for path in payload:
            info = zipfile.ZipInfo(path.relative_to(files_dir).as_posix(), date_time=ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, path.read_bytes())

    return out


def unpack(archive: pathlib.Path, directory: pathlib.Path) -> None:
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        if "resource.xml" not in names:
            sys.exit(f"{archive}: no resource.xml, this is not a component export")

        manifest = parse_resource_xml(z.read("resource.xml"))
        general = manifest["general"]

        install_type = general.get("installType", "")
        suffix = {"unix": ".sh", "powershell": ".ps1", "batch": ".bat"}.get(install_type, ".txt")
        slug = directory.name
        body_name = slug + suffix
        manifest["body"] = body_name

        directory.mkdir(parents=True, exist_ok=True)
        (directory / "component.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        if "command.bat" in names:
            (directory / body_name).write_bytes(z.read("command.bat"))
        if "icon.png" in names:
            (directory / "icon.png").write_bytes(z.read("icon.png"))

        payload = [n for n in names if n not in CORE_FILES and not n.endswith("/")]
        if payload:
            files_dir = directory / "files"
            files_dir.mkdir(exist_ok=True)
            for name in payload:
                target = files_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(name))

        print(f"{archive.name} -> {directory}/")
        for name in [ "component.json", body_name] + (["icon.png"] if "icon.png" in names else []):
            print(f"  {name}")
        for name in payload:
            print(f"  files/{name}")


def verify(archive: pathlib.Path) -> int:
    """Unpack a .cpt and repack it, then compare the two resource.xml documents.

    A byte-identical resource.xml means this tool's output is indistinguishable
    from what Datto itself exported.
    """
    import tempfile

    with zipfile.ZipFile(archive) as z:
        original = z.read("resource.xml")
        original_body = z.read("command.bat") if "command.bat" in z.namelist() else None

    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / archive.stem
        unpack(archive, work)
        manifest = json.loads((work / "component.json").read_text())
        rebuilt = build_resource_xml(manifest)
        rebuilt_body = normalise_body((work / manifest["body"]).read_bytes())

    # The body is checked as well as the metadata. A Datto export strips the
    # trailing newline from command.bat, so this catches a regression in that
    # normalisation - which would otherwise only surface as a false audit
    # failure much later.
    if original_body is not None and rebuilt_body != original_body:
        print(
            f"  command.bat differs after round-trip "
            f"({len(original_body)} bytes in, {len(rebuilt_body)} out)",
            file=sys.stderr,
        )
        return 1

    if rebuilt == original:
        print(f"  resource.xml round-trips byte-identically ({len(original)} bytes)")
        if original_body is not None:
            print(f"  command.bat  round-trips byte-identically ({len(original_body)} bytes)")
        return 0

    import difflib

    print("  resource.xml differs after round-trip:", file=sys.stderr)
    diff = difflib.unified_diff(
        original.decode("utf-8").splitlines(),
        rebuilt.decode("utf-8").splitlines(),
        "datto-export",
        "cpt.py-rebuild",
        lineterm="",
    )
    for line in diff:
        print("   " + line, file=sys.stderr)
    return 1


def discover(root: pathlib.Path) -> tuple:
    """Find component directories under the category folders.

    Returns (buildable, unmanaged): directories holding a component.json, and
    directories that look like components but have no manifest yet.
    """
    buildable, unmanaged = [], []
    for category in CATEGORIES:
        category_dir = root / category.capitalize()
        if not category_dir.is_dir():
            continue
        for directory in sorted(p for p in category_dir.iterdir() if p.is_dir()):
            if (directory / "component.json").is_file():
                buildable.append(directory)
            elif any(p.suffix in (".sh", ".ps1", ".bat", ".py") for p in directory.iterdir()):
                unmanaged.append(directory)
    return buildable, unmanaged


def pack_all(root: pathlib.Path, out_dir: pathlib.Path) -> int:
    """Build every component that has a manifest. Used by CI."""
    buildable, unmanaged = discover(root)

    if not buildable and not unmanaged:
        print("no components found")
        return 0

    failures = 0
    for directory in buildable:
        manifest = json.loads((directory / "component.json").read_text(encoding="utf-8"))
        # Name the artefact after the component as Datto shows it, not the slug,
        # so a reviewer downloading it recognises what they are importing.
        display = manifest.get("general", {}).get("name", directory.name)
        safe = "".join(c for c in display if c not in '<>:"/\\|?*').strip()
        try:
            result = pack(directory, out_dir / f"{safe}.cpt")
        except SystemExit as exc:
            print(f"FAIL  {directory}: {exc}")
            failures += 1
            continue
        print(f"built {result.name}  ({result.stat().st_size:,} bytes)  <- {directory}")

    for directory in unmanaged:
        print(f"skip  {directory}: no component.json, nothing to build")

    return 1 if failures else 0


def normalise_body(data: bytes) -> bytes:
    """The body exactly as Datto stores it in command.bat.

    Datto keeps LF endings whatever the target OS, and strips the trailing
    newline - confirmed by exporting a component back out after import and
    diffing it against what was sent. Normalising here means a .cpt this tool
    builds is byte-identical to Datto's own export of the same component, and
    that audit does not report a false mismatch against a repo script whose
    editor left a trailing newline on it.
    """
    data = data.replace(b"\r\n", b"\n")
    if data.endswith(b"\n"):
        data = data[:-1]
    return data


def attachments(archive: pathlib.Path) -> list:
    """Files in a .cpt beyond the three every component has.

    For a deployment component this is the vendor's installer. It is the reason
    a built export must never be committed or published from this public repo.
    """
    with zipfile.ZipFile(archive) as z:
        return [n for n in z.namelist() if n not in CORE_FILES and not n.endswith("/")]


def audit(root: pathlib.Path) -> int:
    """Enforce the rules CONTRIBUTING.md sets for a committed .cpt.

    Both are review-checklist items that a human is currently expected to catch:
      * a committed .cpt must carry no attachment, because this repo is public
        and an Applications export bundles the vendor's installer;
      * a committed .cpt must match the script committed beside it.
    """
    problems = []

    categories = {c.capitalize() for c in CATEGORIES}
    for archive in sorted(root.glob("*/*/*.cpt")):
        # glob returns the path as given, so compare against the category
        # relative to the repo root rather than to the filesystem root.
        if archive.relative_to(root).parts[0] not in categories:
            continue
        directory = archive.parent

        with zipfile.ZipFile(archive) as z:
            names = z.namelist()
            extra = attachments(archive)
            if extra:
                problems.append(
                    f"{archive}: carries {len(extra)} attachment(s) ({', '.join(extra)}). "
                    f"This repo is public - see CONTRIBUTING.md."
                )
                continue

            if "command.bat" not in names:
                problems.append(f"{archive}: no command.bat")
                continue
            packaged = z.read("command.bat")

        bodies = [p for p in directory.iterdir() if p.suffix in (".sh", ".ps1", ".bat", ".py")]
        if len(bodies) != 1:
            problems.append(f"{archive}: cannot tell which file it should match ({len(bodies)} candidates)")
            continue

        if normalise_body(packaged) != normalise_body(bodies[0].read_bytes()):
            problems.append(
                f"{archive}: its command.bat does not match {bodies[0].name} in the same commit"
            )

    for problem in problems:
        print(f"FAIL  {problem}")
    if not problems:
        print("all committed .cpt files carry no attachment and match their script")
    return 1 if problems else 0


def stage_release(directory: pathlib.Path) -> int:
    """Drop from a build directory every export that must not be published.

    A release asset on a public repository is a permanent, unauthenticated
    download link, so an export carrying a vendor's installer cannot go into
    one - the same rule CONTRIBUTING.md sets for committing a .cpt.

    There is a second reason, independent of licensing: payload files live in
    files/ and are not in git, so an Applications export built in CI would not
    contain its installer anyway. Publishing it would hand someone a component
    that imports cleanly and then fails on the endpoint. Absent beats broken.

    Writes RELEASE_NOTES.md beside the exports. Excluding a component is normal,
    not a failure, so this returns 0 unless nothing publishable is left.
    """
    kept, dropped = [], []
    for archive in sorted(directory.glob("*.cpt")):
        extra = attachments(archive)
        if extra:
            archive.unlink()
            dropped.append((archive.name, extra))
        else:
            kept.append(archive)

    for name, extra in dropped:
        print(f"excluded {name}: carries {', '.join(extra)}")
    for archive in kept:
        print(f"publishing {archive.name}")

    rows = []
    for archive in kept:
        with zipfile.ZipFile(archive) as z:
            general = parse_resource_xml(z.read("resource.xml"))["general"]
        rows.append(
            (general.get("name", archive.stem),
             general.get("category", "?"),
             general.get("version", "?"),
             archive.name)
        )

    notes = ["Importable Datto RMM component exports, rebuilt from `main`.", ""]
    if rows:
        notes += ["| Component | Category | Version | File |", "|---|---|---|---|"]
        notes += [f"| {n} | {c} | {v} | `{f}` |" for n, c, v, f in sorted(rows)]
        notes.append("")
    notes += [
        "Download a `.cpt` and import it in Datto RMM via "
        "**Components → New Component → Import Component**.",
        "",
        "Each file keeps its component's `uid`, so importing one that already "
        "exists updates it rather than creating a duplicate.",
        "",
    ]
    if dropped:
        notes += [
            "### Not published here",
            "",
            "These carry an attachment, so they are neither committed nor released "
            "from this public repository:",
            "",
        ]
        notes += [f"- `{name}` — {', '.join(extra)}" for name, extra in dropped]
        notes += [
            "",
            "A build here would not contain the installer in any case, since payload "
            "files are not in git. Export those from Datto directly.",
            "",
        ]
    notes.append("Built by `tools/cpt.py`. Builds are deterministic: the same commit "
                 "rebuilds these byte for byte.")

    (directory / "RELEASE_NOTES.md").write_text("\n".join(notes) + "\n", encoding="utf-8")

    if not kept:
        print("nothing publishable")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pack", help="build a .cpt from a component directory")
    p.add_argument("directory", type=pathlib.Path)
    p.add_argument("-o", "--output", type=pathlib.Path)

    p = sub.add_parser("unpack", help="explode a .cpt into a component directory")
    p.add_argument("archive", type=pathlib.Path)
    p.add_argument("-o", "--output", type=pathlib.Path, required=True)

    p = sub.add_parser("verify", help="check a .cpt round-trips through this tool unchanged")
    p.add_argument("archives", type=pathlib.Path, nargs="+")

    p = sub.add_parser("pack-all", help="build every component that has a component.json")
    p.add_argument("--root", type=pathlib.Path, default=pathlib.Path("."))
    p.add_argument("-o", "--out-dir", type=pathlib.Path, default=pathlib.Path("dist"))

    p = sub.add_parser("audit", help="enforce CONTRIBUTING.md's rules for a committed .cpt")
    p.add_argument("--root", type=pathlib.Path, default=pathlib.Path("."))

    p = sub.add_parser("stage-release", help="drop exports that must not be published")
    p.add_argument("--dir", type=pathlib.Path, default=pathlib.Path("dist"))

    args = parser.parse_args()

    if args.command == "pack":
        directory = args.directory.resolve()
        out = args.output or directory / f"{directory.name}.cpt"
        result = pack(directory, out)
        size = result.stat().st_size
        print(f"{result} ({size:,} bytes)")
        return 0

    if args.command == "unpack":
        unpack(args.archive, args.output)
        return 0

    if args.command == "pack-all":
        return pack_all(args.root.resolve(), args.out_dir)

    if args.command == "audit":
        return audit(args.root.resolve())

    if args.command == "stage-release":
        return stage_release(args.dir)

    failures = 0
    for archive in args.archives:
        print(archive)
        failures += verify(archive)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
