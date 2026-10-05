#!/usr/bin/env python3
"""Check repository files without printing potentially sensitive matches.

This is a guardrail for source review, not a guarantee that arbitrary personal
information can be recognized. Full Git history secret checks use Gitleaks.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

RULES = {
    "machine-specific home path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+"),
    "literal account in command example": re.compile(r"Account:\s*[A-Za-z0-9_.-]+"),
    "private key material": re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"),
    "service token": re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{25,}|sk-[A-Za-z0-9_-]{24,}|xox[baprs]-[A-Za-z0-9-]{16,}|AKIA[A-Z0-9]{16})"),
    "credential in URL": re.compile(r"https?://[^\s/:@]+:[^\s/@]+@"),
    "private network address": re.compile(r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"),
}
FORBIDDEN_SUFFIXES = {".p12", ".pfx", ".pem", ".key", ".sqlite", ".sqlite3", ".db", ".log", ".mobileprovision"}
BINARY_ASSETS = {"assets/RemoteDictateHelper.icns", "assets/RemoteDictateHelper.png"}
EMAIL = re.compile(r"[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def findings(path, data):
    result = []
    item = Path(path)
    if item.suffix.lower() in FORBIDDEN_SUFFIXES or item.name in {".env", "settings.json", ".DS_Store"}:
        result.append((0, "local data or credential file"))
    if path in BINARY_ASSETS:
        return result
    if b"\0" in data:
        return result + [(0, "unreviewed binary file")]
    text = data.decode("utf-8", errors="replace")
    for label, pattern in RULES.items():
        for match in pattern.finditer(text):
            result.append((text.count("\n", 0, match.start()) + 1, label))
    for match in EMAIL.finditer(text):
        address = match.group()
        domain = address.rsplit("@", 1)[1].lower()
        if domain in {"example.com", "example.org", "example.net", "users.noreply.github.com"}:
            continue
        if re.fullmatch(r"icon_\d+x\d+@2x\.png", address):
            continue
        result.append((text.count("\n", 0, match.start()) + 1, "email address needs review"))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="Also inspect blobs reachable from branches, remote branches and tags")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent

    def git(*command):
        return subprocess.check_output(["git", "-C", str(root), *command])

    count = 0
    failures = 0

    def check(label, path, data):
        nonlocal count, failures
        count += 1
        for line, category in findings(path, data):
            # Only the path/location and rule name are reported, never matched data.
            print(f"{label}:{line}: {category}", file=sys.stderr)
            failures += 1

    paths = set(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().split("\0"))
    for path in sorted(paths - {""}):
        file = root / path
        if file.is_symlink():
            print(f"{path}: symlink needs review", file=sys.stderr); failures += 1
        elif file.is_file():
            check(path, path, file.read_bytes())
    if args.history:
        objects = git("rev-list", "--objects", "--branches", "--remotes", "--tags").decode().splitlines()
        for entry in objects:
            oid, _, path = entry.partition(" ")
            if git("cat-file", "-t", oid).strip() == b"blob":
                check(f"{oid[:12]}:{path}", path, git("cat-file", "blob", oid))
    print(f"Privacy scan: {count} files/blobs checked; {failures} findings.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
