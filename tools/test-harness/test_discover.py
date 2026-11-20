"""Tests for discover.py, run against a throwaway git repository.

    python3 -m unittest discover -s tools/test-harness -p 'test_*.py'
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DISCOVER = Path(__file__).resolve().parent / "discover.py"


def git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)


class DiscoverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "test@example.com")
        git(self.repo, "config", "user.name", "test")
        self.component("Scripts/tool-win", "Tool [Win]", ["windows"])
        self.component("Applications/app-mac-lin", "App [Mac] [Lin]", ["macos", "linux"])
        self.component("Monitors/old-monitor-lin", "Old Monitor [Lin]", None)
        self.write("tools/test-harness/untested-components.txt",
                   "# today's untested components\nMonitors/old-monitor-lin\n")
        self.write("README.md", "repo\n")
        self.base = self.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        p = self.repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def component(self, rel, name, platforms):
        self.write(f"{rel}/body.ps1", "exit 0\n")
        self.write(f"{rel}/component.json", json.dumps({"general": {"name": name}}))
        if platforms is not None:
            self.write(f"{rel}/test.json", json.dumps({"platforms": platforms, "steps": []}))

    def commit(self, msg):
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", msg)
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def discover(self, *args):
        out_file = self.repo.parent / (self.repo.name + "-out")
        env = {**os.environ, "GITHUB_OUTPUT": str(out_file)}
        r = subprocess.run([sys.executable, str(DISCOVER), *args], cwd=self.repo, env=env,
                           capture_output=True, text=True)
        outputs = dict(l.split("=", 1) for l in out_file.read_text().splitlines()) if out_file.exists() else {}
        out_file.unlink(missing_ok=True)
        matrix = json.loads(r.stdout) if r.returncode == 0 else None
        return r, matrix, outputs

    def changed(self, *files):
        for f in files:
            self.write(f, "changed\n")
        self.commit("change")
        return self.discover("--base", self.base)

    def test_a_component_change_selects_that_component_on_its_platforms(self):
        r, matrix, out = self.changed("Applications/app-mac-lin/body.ps1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted((m["component"], m["platform"], m["runner"]) for m in matrix), [
            ("Applications/app-mac-lin", "linux", "ubuntu-latest"),
            ("Applications/app-mac-lin", "macos", "macos-latest"),
        ])
        self.assertEqual(out["harness"], "false")

    def test_a_change_outside_components_selects_nothing(self):
        r, matrix, out = self.changed("README.md")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(matrix, [])
        self.assertEqual(out["count"], "0")

    def test_a_harness_change_selects_every_tested_component(self):
        for changed in ("tools/test-harness/invoke-component-test.sh",
                        ".github/workflows/test-components.yml"):
            with self.subTest(changed=changed):
                r, matrix, out = self.changed(changed)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(sorted({m["component"] for m in matrix}),
                                 ["Applications/app-mac-lin", "Scripts/tool-win"])
                self.assertEqual(out["harness"], "true")

    def test_a_new_component_without_test_json_fails(self):
        self.component("Scripts/new-thing-win", "New Thing [Win]", None)
        self.commit("add")
        r, _, _ = self.discover("--base", self.base)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Scripts/new-thing-win has no test.json", r.stderr)

    def test_a_new_component_without_test_json_fails_alongside_a_harness_change(self):
        self.component("Scripts/new-thing-win", "New Thing [Win]", None)
        r, _, _ = self.changed("tools/test-harness/discover.py")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Scripts/new-thing-win has no test.json", r.stderr)

    def test_an_exempt_component_without_test_json_warns(self):
        r, matrix, _ = self.changed("Monitors/old-monitor-lin/body.ps1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(matrix, [])
        self.assertIn("::warning::Monitors/old-monitor-lin has no test.json", r.stderr)

    def test_an_exempt_component_that_gains_a_test_json_is_tested_and_told_to_leave_the_list(self):
        self.write("Monitors/old-monitor-lin/test.json", json.dumps({"platforms": ["linux"]}))
        self.commit("test it")
        r, matrix, _ = self.discover("--base", self.base)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([m["component"] for m in matrix], ["Monitors/old-monitor-lin"])
        self.assertIn("remove it from tools/test-harness/untested-components.txt", r.stderr)

    def test_a_deleted_component_is_ignored(self):
        git(self.repo, "rm", "-q", "-r", "Scripts/tool-win")
        self.commit("delete")
        r, matrix, _ = self.discover("--base", self.base)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(matrix, [])


if __name__ == "__main__":
    unittest.main()
