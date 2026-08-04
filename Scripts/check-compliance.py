#!/usr/bin/env python3
"""Phase 22 source, dependency, and admission-policy check.

This check is deliberately dependency-free. It runs before SwiftPM build and
therefore remains useful when a new package or source file makes the manifest
unbuildable on a contributor's machine.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
RESOLVED = ROOT / "Package.resolved"
PACKAGES = ROOT / "Compliance" / "package-inventory.json"
SOURCES = ROOT / "Compliance" / "source-inventory.json"
NOTICES = ROOT / "NOTICES.md"

ALLOWED_SOURCE_LICENSES = {"MIT", "MIT AND Apache-2.0"}
IDENTITY_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SECRET_PATTERNS = (
    re.compile(r"-----BEGIN (?:RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY-----"),
    re.compile(r"\b(?:ghp|github_pat|xox[baprs])-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
)
# This suite intentionally exercises the redactor with provider-shaped fake
# values, including AWS's documented AKIA...EXAMPLE value. Keep the exception
# path-specific so a real credential elsewhere still fails the admission check.
SECRET_FIXTURE_ALLOWLIST = {
    "Tests/DoMoCoreTests/RedactionTests.swift",
}
PROHIBITED_PATH = re.compile(r"(^|/)(?:enterprise|polyform|proprietary)(?:/|$)", re.IGNORECASE)


class Failure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise Failure(f"cannot read {path.relative_to(ROOT)}: {error}") from error


def repository_url(url: str) -> str:
    url = url.rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def check_packages(notices: str) -> None:
    resolved = read_json(RESOLVED)
    inventory = read_json(PACKAGES)
    require(inventory.get("schemaVersion") == 1, "package inventory schemaVersion must be 1")
    pins = {pin["identity"]: pin for pin in resolved.get("pins", [])}
    records = inventory.get("packages", [])
    record_map = {record.get("identity"): record for record in records}
    require(len(record_map) == len(records), "package inventory contains duplicate identities")
    require(set(record_map) == set(pins), "package inventory and Package.resolved identities differ")

    for identity, pin in sorted(pins.items()):
        require(IDENTITY_RE.fullmatch(identity) is not None, f"invalid package identity: {identity}")
        record = record_map[identity]
        expected_url = repository_url(pin["location"])
        actual_url = repository_url(record.get("url", ""))
        require(actual_url == expected_url, f"{identity}: URL differs from Package.resolved")
        parsed = urlsplit(actual_url)
        require(parsed.scheme == "https" and parsed.netloc == "github.com", f"{identity}: URL is not public GitHub HTTPS")
        state = pin.get("state", {})
        require(record.get("version") == state.get("version"), f"{identity}: version is stale")
        require(record.get("revision") == state.get("revision"), f"{identity}: revision is stale")
        licenses = record.get("licenses", [])
        require(licenses, f"{identity}: missing license records")
        for license_record in licenses:
            require(license_record.get("name"), f"{identity}: license has no exact name")
            require(license_record.get("spdxIdentifier"), f"{identity}: license has no SPDX identifier")
            require(license_record.get("copyright"), f"{identity}: license has no copyright holder")
        usage = record.get("usage")
        require(usage in {"runtime", "test-only", "build-only"}, f"{identity}: invalid usage {usage!r}")
        marker = record.get("noticeMarker")
        require(marker and marker in notices, f"{identity}: missing NOTICES.md marker {marker!r}")


def first_lines(path: Path, count: int = 24) -> str:
    return "\n".join(path.read_text(encoding="utf-8").splitlines()[:count])


def check_sources(notices: str) -> None:
    inventory = read_json(SOURCES)
    require(inventory.get("schemaVersion") == 1, "source inventory schemaVersion must be 1")
    entries = inventory.get("files", [])
    paths = [entry.get("path") for entry in entries]
    require(len(paths) == len(set(paths)), "source inventory contains duplicate paths")
    entry_map = dict(zip(paths, entries))

    source_files = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "Sources").rglob("*.swift"))
    for relative in source_files:
        path = ROOT / relative
        header = first_lines(path)
        require("SPDX-License-Identifier:" in header, f"{relative}: missing SPDX header")
        third_party = bool(re.search(r"Mario Zechner|opencode contributors|Kilo Code|opentui|Apache-2\.0", header))
        if third_party:
            require(relative in entry_map, f"{relative}: third-party provenance is not inventoried")
        elif relative in entry_map:
            raise Failure(f"{relative}: inventory marks an original file as derived")

    for relative, entry in entry_map.items():
        path = ROOT / relative
        require(path.is_file(), f"source inventory path does not exist: {relative}")
        require(entry.get("licenseExpression") in ALLOWED_SOURCE_LICENSES, f"{relative}: disallowed source license")
        require(entry.get("spdxIdentifier"), f"{relative}: missing SPDX identifier")
        require(entry.get("copyright"), f"{relative}: missing copyright holders")
        upstreams = entry.get("upstreams", [])
        require(upstreams, f"{relative}: missing upstream provenance")
        for upstream in upstreams:
            repository = upstream.get("repository", "").rstrip("/")
            require(repository.startswith("https://github.com/"), f"{relative}: upstream is not public GitHub HTTPS")
            require(upstream.get("path"), f"{relative}: upstream path is missing")
            require(COMMIT_RE.fullmatch(upstream.get("commit", "")) is not None, f"{relative}: upstream commit is not a full SHA")
        marker = entry.get("noticeMarker")
        require(marker and marker in notices, f"{relative}: missing NOTICES.md marker {marker!r}")
        header = first_lines(path)
        require(entry["spdxIdentifier"] in header or entry["licenseExpression"] in header, f"{relative}: SPDX header disagrees with inventory")


def tracked_files() -> list[str]:
    result = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True, stdout=subprocess.PIPE)
    return [path for path in result.stdout.decode().split("\0") if path]


def check_admission(notices: str) -> None:
    files = tracked_files()
    for relative in files:
        require(not PROHIBITED_PATH.search(relative), f"prohibited source subtree: {relative}")
        path = ROOT / relative
        if path.suffix.lower() not in {".swift", ".md", ".json", ".yml", ".yaml", ".sh", ".py", ".txt"}:
            continue
        if relative in SECRET_FIXTURE_ALLOWLIST:
            continue
        try:
            contents = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for pattern in SECRET_PATTERNS:
            require(pattern.search(contents) is None, f"possible secret in {relative}: {pattern.pattern}")
    require("SPDX-License-Identifier: MIT" in notices, "NOTICES.md is missing the project MIT notice")


def main() -> int:
    try:
        notices = NOTICES.read_text(encoding="utf-8")
        check_packages(notices)
        check_sources(notices)
        check_admission(notices)
    except (Failure, OSError, subprocess.CalledProcessError) as error:
        print(f"compliance check failed: {error}", file=sys.stderr)
        return 1
    print("compliance check passed: packages, source provenance, notices, and admission policy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
