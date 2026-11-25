#!/usr/bin/env python3
"""Fail when a committed file names an address or domain that could be real.

This repo and its CI logs are public. Every tracked text file is searched for

  - IPv4 addresses outside loopback (127.0.0.0/8) and the documentation
    ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24), and
  - domains outside the reserved example domains (example.com, .net, .org).
    A domain is a dotted name whose last label is a real TLD, from IANA's list
    in tools/tlds-alpha-by-domain.txt, refreshed with:
      curl -sSf https://data.iana.org/TLD/tlds-alpha-by-domain.txt -o tools/tlds-alpha-by-domain.txt

Anything else must be listed in tools/public-safety-allowlist.txt: a vendor
domain the components download from, or a known false positive. One entry per
line, `# reason` after it; a domain entry also admits its subdomains.

    python3 tools/check-public-safety.py [--root DIR]

Exit 0 when nothing is flagged; 1 when something is, printed as file:line: token.
"""
import argparse
import ipaddress
import pathlib
import re
import subprocess
import sys

DOCUMENTATION = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
EXAMPLE_DOMAINS = ("example.com", "example.net", "example.org")
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?!\.?\w)")
DOMAIN = re.compile(
    r"(?<![\w.-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z][a-z0-9-]*[a-z0-9]))"
    r"(?![\w-]|\.[\w-])",  # not "System.Net.WebClient"
    re.IGNORECASE)
TLDS = {line.strip().lower()
        for line in (pathlib.Path(__file__).resolve().parent / "tlds-alpha-by-domain.txt").read_text().splitlines()
        if line.strip() and not line.startswith("#")}
TLDS |= {"local", "lan", "internal", "corp"}  # not delegated, but used for internal AD and LAN names
# Real TLDs that are far more often something else here; a client domain on one of these passes.
TLDS -= {"md", "py", "sh", "pub", "ls"}  # file names: README.md, kill.sh, a.pub keys, tc-cfg.ls listings
TLDS -= {"name", "new", "read", "run", "open", "data", "id", "group", "host", "target", "properties",
         "directory", "ping", "discover", "email", "pid", "app", "java", "tc", "ee", "xxx"}
# ^ code: path.name, subprocess.run, $_.psobject.properties, com.oracle.java, v3.7.4.xxx placeholders


def allowed_ip(token, allow):
    try:
        ip = ipaddress.ip_address(token)
    except ValueError:
        return True  # a version number such as 3.7.4.301, not an address
    return ip.is_loopback or any(ip in n for n in DOCUMENTATION) or token in allow


def allowed_domain(token, allow):
    return any(token == d or token.endswith("." + d) for d in (*EXAMPLE_DOMAINS, *allow))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=pathlib.Path(__file__).resolve().parent.parent, type=pathlib.Path)
    root = ap.parse_args().root

    allow = set()
    for line in (root / "tools" / "public-safety-allowlist.txt").read_text().splitlines():
        entry = line.split("#", 1)[0].strip().lower()
        if entry:
            allow.add(entry)

    files = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                           capture_output=True, check=True).stdout.decode().split("\0")
    found = 0
    for rel in filter(None, files):
        path = root / rel
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue  # binary
        for n, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
            hits = [t for t in IPV4.findall(line) if not allowed_ip(t, allow)]
            hits += [d.lower() for d, tld in DOMAIN.findall(line)
                     if tld.lower() in TLDS and not allowed_domain(d.lower(), allow)]
            for token in hits:
                print(f"{rel}:{n}: {token}")
                found += 1

    if found:
        print(f"\n{found} address(es) or domain(s) that could be real. Replace each with a documentation"
              " address (192.0.2.x) or an example domain (example.com); if it is a vendor domain or a"
              " false positive, add it to tools/public-safety-allowlist.txt with the reason.")
        return 1
    print("No real-looking addresses or domains.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
