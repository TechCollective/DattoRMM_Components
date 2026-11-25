"""Tests for check-public-safety.py, driven through its command line.

    python3 -m unittest discover -s tools -p 'test_*.py'

Every address and domain planted here is built from parts, so this file does
not itself trip the check it tests.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).resolve().parent / "check-public-safety.py"
PUBLIC_IP = ".".join(["8"] * 4)
PRIVATE_IP = ".".join(["10", "1", "2", "3"])
UNLISTED_DOMAIN = "client-" + "site." + "com"
UNCOMMON_TLD_DOMAINS = ["client-" + "site." + "health", "client-" + "site." + "xyz"]


class PublicSafetyCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tools").mkdir()
        self.allow("")

    def tearDown(self):
        self.tmp.cleanup()

    def allow(self, text):
        (self.root / "tools" / "public-safety-allowlist.txt").write_text(text)

    def check(self, content):
        (self.root / "script.sh").write_text(content)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        return subprocess.run([sys.executable, str(CHECK), "--root", str(self.root)],
                              capture_output=True, text=True)

    def assertFlags(self, content, token):
        r = self.check(content)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"script.sh:1: {token}", r.stdout)

    def assertPasses(self, content):
        r = self.check(content)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_public_and_private_addresses_fail(self):
        self.assertFlags(f"ping {PUBLIC_IP}\n", PUBLIC_IP)
        self.assertFlags(f"ping {PRIVATE_IP}\n", PRIVATE_IP)

    def test_an_unlisted_domain_fails_even_in_capitals_or_an_email(self):
        self.assertFlags(f"curl https://{UNLISTED_DOMAIN}/x\n", UNLISTED_DOMAIN)
        self.assertFlags(f"mail admin@{UNLISTED_DOMAIN.upper()}\n", UNLISTED_DOMAIN)

    def test_a_domain_on_an_uncommon_tld_fails(self):
        for domain in UNCOMMON_TLD_DOMAINS:
            self.assertFlags(f"curl https://{domain}/x\n", domain)

    def test_file_names_and_code_on_a_tld_are_not_domains(self):
        self.assertPasses("tests/kill.sh test.json README.md cpt.py path.name subprocess.run\n")

    def test_loopback_documentation_addresses_and_example_domains_pass(self):
        self.assertPasses("127.0.0.1 127.8.9.10 192.0.2.7 198.51.100.200 203.0.113.1\n"
                          "relay.example.net example.com www.example.org\n")

    def test_version_numbers_and_code_identifiers_are_not_addresses_or_domains(self):
        self.assertPasses("v3.7.4.301 [System.Net.WebClient] Some.app install.sh\n")

    def test_the_allowlist_admits_a_domain_with_its_subdomains_and_an_exact_address(self):
        self.allow(f"# vendor\n{UNLISTED_DOMAIN}\n{PUBLIC_IP}  # reason\n")
        self.assertPasses(f"https://dl.{UNLISTED_DOMAIN}/x {PUBLIC_IP}\n")
        self.assertFlags(f"{PRIVATE_IP}\n", PRIVATE_IP)


if __name__ == "__main__":
    unittest.main()
