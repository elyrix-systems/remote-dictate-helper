#!/usr/bin/env python3
"""Extract one maintained changelog section; never infer release claims."""
from pathlib import Path
import re
import sys


def section(changelog, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected a numeric semantic version")
    match = re.search(r"^## " + re.escape(version) + r"(?:\s[^\n]*)?\n(.*?)(?=^## |\Z)", changelog, re.M | re.S)
    if not match or not match[1].strip():
        raise ValueError("Missing changelog section for release")
    return match[1].strip()


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    version = (root / "VERSION").read_text().strip()
    mode = sys.argv[1] if len(sys.argv) == 2 else "preview"
    if mode not in {"preview", "notarized"}:
        raise SystemExit("Expected preview or notarized")
    print(section((root / "CHANGELOG.md").read_text(), version))
    print("\n## Install\n\nDownload the Apple-silicon DMG (Apple silicon only, macOS 26+), drag the app to Applications, eject the image and open the installed app. Follow its setup window. Quit an existing helper normally before replacing it.")
    if mode == "preview":
        print("\n**Unnotarized preview.** This download is ad-hoc signed, not signed with an Apple Developer ID or notarized. macOS may block it. If you trust the source, Apple documents the per-app Open Anyway option in System Settings → Privacy & Security. Managed Macs may disallow it. Updates may require granting Accessibility again. Never disable Gatekeeper or install a publisher certificate to run this app.")
    else:
        print("\nDeveloper ID signed and Apple notarized. macOS still asks you to confirm opening a downloaded app and to grant Accessibility.")
    print("\nSHA-256 checksums accompany the DMG. They detect corruption; they are not independent proof of publisher identity. [Installation and troubleshooting](https://github.com/elyrix-systems/remote-dictate-helper#installation).")
