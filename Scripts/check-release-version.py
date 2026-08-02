#!/usr/bin/env python3

"""Check that a v* Git tag matches Packaging/Info.plist."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLIST_PATH = ROOT / "Packaging" / "Info.plist"
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")


def fail(message: str) -> None:
    print(f"release version check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    tag = sys.argv[1] if len(sys.argv) > 1 else ""
    if not PLIST_PATH.is_file():
        fail(f"missing {PLIST_PATH}")

    with PLIST_PATH.open("rb") as stream:
        plist = plistlib.load(stream)
    version = plist.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        fail(f"unsupported CFBundleShortVersionString: {version!r}")

    expected_tag = f"v{version}"
    if not tag:
        print(f"release metadata check passed: {expected_tag}")
        return
    if tag != expected_tag:
        fail(f"tag {tag or '<missing>'} must equal {expected_tag}")

    print(f"release version check passed: {expected_tag}")


if __name__ == "__main__":
    main()
