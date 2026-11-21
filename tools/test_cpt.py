"""Tests for cpt.py, driven through its command line.

    python3 -m unittest discover -s tools -p 'test_*.py'
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
CPT = TOOLS / "cpt.py"
DISCOVER = TOOLS / "test-harness" / "discover.py"


def run(*args, cwd=None, env=None):
    return subprocess.run([*args], cwd=cwd, env=env, capture_output=True, text=True)


class NewCommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        run("git", "init", "-q", cwd=self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def new(self, name, category):
        return run(sys.executable, str(CPT), "new", name, category, "--root", str(self.root))

    def test_every_category_on_each_body_language_scaffolds_a_component_that_packs_and_is_discovered(self):
        cases = [
            ("Veeam - Last Successful Backup Age [Win]", "monitors", ["windows"], "ps1"),
            ("Disk Space - Free Space Below Threshold [Mac] [Lin]", "monitors", ["macos", "linux"], "sh"),
            ("Windows Update - Reset Update Components [Win]", "scripts", ["windows"], "ps1"),
            ("Docker - Prune Images [Lin]", "scripts", ["linux"], "sh"),
            ("Adobe Acrobat Reader [Win]", "applications", ["windows"], "ps1"),
            ("Google Cloud SDK [Mac]", "applications", ["macos"], "sh"),
        ]
        for name, category, platforms, ext in cases:
            with self.subTest(name=name):
                r = self.new(name, category)
                self.assertEqual(r.returncode, 0, r.stderr)
                slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
                rel = f"{category.capitalize()}/{slug}"
                d = self.root / rel

                manifest = json.loads((d / "component.json").read_text())
                self.assertEqual(manifest["general"]["name"], name)
                self.assertEqual(manifest["general"]["category"], category)
                self.assertEqual(manifest["general"]["uid"], "")
                self.assertEqual(manifest["general"]["installType"], "powershell" if ext == "ps1" else "unix")
                self.assertEqual(manifest["body"], f"{slug}.{ext}")
                self.assertTrue((d / manifest["body"]).is_file())

                readme = (d / "README.md").read_text()
                self.assertTrue(readme.startswith(f"# {name}\n"), readme[:80])
                for section in ("## What it does", "## How to tell it worked"):
                    self.assertIn(f"\n{section}\n", readme)

                spec = json.loads((d / "test.json").read_text())
                self.assertEqual(spec["platforms"], platforms)
                labels = [s["label"] for s in spec["steps"]]
                if category == "monitors":
                    self.assertEqual(labels, ["Healthy with the defaults", "Bad input: check could not run",
                                              "Second run is harmless"])

                out = self.root / "out.cpt"
                r = run(sys.executable, str(CPT), "pack", str(d), "-o", str(out))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(run(sys.executable, str(CPT), "verify", str(out)).returncode, 0)

                r = run(sys.executable, str(DISCOVER), "--only", rel, cwd=self.root,
                        env={k: v for k, v in os.environ.items() if k != "GITHUB_OUTPUT"})
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(sorted(m["platform"] for m in json.loads(r.stdout)), sorted(platforms))

    def test_test_scripts_in_a_tests_folder_are_not_packed(self):
        self.new("Docker - Prune Images [Lin]", "scripts")
        d = self.root / "Scripts/docker-prune-images-lin"
        without, with_tests = self.root / "without.cpt", self.root / "with.cpt"
        self.assertEqual(run(sys.executable, str(CPT), "pack", str(d), "-o", str(without)).returncode, 0)
        (d / "tests").mkdir()
        (d / "tests/plant-state.sh").write_text("#!/usr/bin/env bash\necho planted\n")
        r = run(sys.executable, str(CPT), "pack", str(d), "-o", str(with_tests))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(with_tests.read_bytes(), without.read_bytes())

    def test_the_shell_monitor_stub_does_what_its_test_json_expects(self):
        self.new("Disk Space - Free Space Below Threshold [Lin]", "monitors")
        body = self.root / "Monitors/disk-space-free-space-below-threshold-lin/disk-space-free-space-below-threshold-lin.sh"
        self.check_monitor(["bash", str(body)])

    @unittest.skipUnless(shutil.which("pwsh"), "pwsh is not installed")
    def test_the_powershell_monitor_stub_does_what_its_test_json_expects(self):
        self.new("Veeam - Last Successful Backup Age [Win]", "monitors")
        body = self.root / "Monitors/veeam-last-successful-backup-age-win/veeam-last-successful-backup-age-win.ps1"
        self.check_monitor(["pwsh", "-NoProfile", "-File", str(body)])

    def check_monitor(self, cmd):
        for value, code, says in (("90", 0, "STATUS=TODO"), ("100", 0, "STATUS=TODO"), ("1", 0, "STATUS=TODO"), ("0", 1, "STATUS=Check could not run:"),
                                  ("abc", 1, "STATUS=Check could not run:"),
                                  ("", 1, "STATUS=Check could not run:"), ("101", 1, "STATUS=Check could not run:"),
                                  ("99999999999", 1, "STATUS=Check could not run:")):
            with self.subTest(usrThreshold=value):
                r = run(*cmd, env={**os.environ, "usrThreshold": value})
                self.assertEqual(r.returncode, code, r.stdout + r.stderr)
                self.assertIn(says, r.stdout)
                self.assertEqual(r.stdout.count("<-Start Result->"), 1)
                self.assertEqual(r.stdout.count("<-End Result->"), 1)

    def test_bad_names_are_refused_and_nothing_is_written(self):
        for name, says in [
            ("Veeam - Last Successful Backup Age", "must end with its OS tags"),
            ("Veeam - Last Successful Backup Age [WIN]", "must end with its OS tags"),
            ("Veeam - Last Successful Backup Age [Lin] [Mac]", "in the order [Win] [Mac] [Lin]"),
            ("Veeam - Last Successful Backup Age [Win] [Lin]", "cannot run on Windows and on macOS/Linux"),
            ("Adobe Acrobat Reader 2024 [Win]", "version number"),
            ("Veeam 12.1 - Backup Age [Win]", "version number"),
            ("Python v3 [Mac]", "version number"),
        ]:
            with self.subTest(name=name):
                r = self.new(name, "monitors")
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(says, r.stderr)
        self.assertFalse((self.root / "Monitors").exists())

    def test_an_existing_folder_is_refused_and_left_alone(self):
        self.assertEqual(self.new("Docker - Prune Images [Lin]", "scripts").returncode, 0)
        readme = self.root / "Scripts/docker-prune-images-lin/README.md"
        readme.write_text("ours\n")
        r = self.new("Docker - Prune Images [Lin]", "scripts")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("already exists", r.stderr)
        self.assertEqual(readme.read_text(), "ours\n")


if __name__ == "__main__":
    unittest.main()
