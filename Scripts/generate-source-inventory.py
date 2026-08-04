#!/usr/bin/env python3
"""Generate the checked-in source provenance inventory from Swift headers.

The inventory is intentionally generated from the headers rather than from a
second hand-maintained list of files. A copied file therefore has one source
of truth for its SPDX expression and its upstream URL, while the checked-in
JSON remains reviewable and CI can detect drift.
"""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Compliance" / "source-inventory.json"

PI_COMMIT = "9b3a2059171bcc74ad9d2cadeea6d186776cf2db"
OPENCODE_COMMIT = "def14d96ef897ed60fd6039e9ac96a63314642ad"
KILOCODE_COMMIT = "6ec20f23952b94517a106de366c23024a628e0b9"
ARGUMENT_PARSER_COMMIT = "6a52f3251125d74daf04fcbd5e6f08a75d074382"
OPENTUI_COMMIT = "7da92b4088aebfe27b9f691c04163a48821e49fd"

URL_RE = re.compile(r"https://github\.com/[^\s)`]+")

OVERRIDES: dict[str, list[dict[str, str]]] = {
    "Sources/DoMoTermIO/TerminalSize.swift": [
        {
            "repository": "https://github.com/apple/swift-argument-parser",
            "path": "Sources/ArgumentParser/Utilities/Platform.swift",
            "commit": ARGUMENT_PARSER_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/PermissionConfigWriter.swift": [
        {
            "repository": "https://github.com/Kilo-Org/kilocode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": KILOCODE_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/BashArity.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/permission/arity.ts",
            "commit": OPENCODE_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/PermissionConfig.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": OPENCODE_COMMIT,
        },
        {
            "repository": "https://github.com/Kilo-Org/kilocode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": KILOCODE_COMMIT,
        },
    ],
    "Sources/DoMoPermissions/PermissionPolicy.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": OPENCODE_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/Wildcard.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/util/wildcard.ts",
            "commit": OPENCODE_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/PermissionEngine.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": OPENCODE_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/PermissionRequest.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": OPENCODE_COMMIT,
        }
    ],
    "Sources/DoMoPermissions/PermissionRequestFactory.swift": [
        {
            "repository": "https://github.com/anomalyco/opencode",
            "path": "packages/opencode/src/permission/index.ts",
            "commit": OPENCODE_COMMIT,
        }
    ],
}


def canonical_repository(url: str) -> str:
    url = url.rstrip("/")
    if "/blob/" in url:
        return url.split("/blob/", 1)[0]
    if " — " in url:
        return url.split(" — ", 1)[0]
    return url


def upstream_from_url(url: str) -> dict[str, str] | None:
    url = url.rstrip(".,")
    repository = canonical_repository(url)
    if "/blob/" not in url:
        return None
    revision_and_path = url.split("/blob/", 1)[1]
    revision, path = revision_and_path.split("/", 1)
    if repository == "https://github.com/earendil-works/pi":
        revision = PI_COMMIT
    elif repository == "https://github.com/anomalyco/opencode":
        revision = OPENCODE_COMMIT
    elif repository == "https://github.com/sst/opencode":
        repository = "https://github.com/anomalyco/opencode"
        revision = OPENCODE_COMMIT
    elif repository == "https://github.com/anomalyco/opentui":
        revision = OPENTUI_COMMIT
    if revision == "dev":
        revision = OPENCODE_COMMIT
    return {"repository": repository, "path": path, "commit": revision}


def copyrights(header: str, path: str) -> list[str]:
    values: list[str] = []
    for line in header.splitlines():
        match = re.search(r"// Copyright \(c\) (.+?)(?:\. MIT license\.)?$", line)
        if match:
            values.append(match.group(1).rstrip("."))
    if path.endswith("TerminalSize.swift"):
        values.append("2020 Apple Inc. and the Swift project authors")
    if "opentui" in header and "2025 opentui" not in " ".join(values):
        values.append("2025 opentui")
    return list(dict.fromkeys(values))


def license_expression(header: str, path: str) -> str:
    if path.endswith("TerminalSize.swift"):
        return "MIT AND Apache-2.0"
    return "MIT"


def main() -> None:
    entries: list[dict[str, object]] = []
    for file in sorted((ROOT / "Sources").rglob("*.swift")):
        relative = file.relative_to(ROOT).as_posix()
        header = "\n".join(file.read_text(encoding="utf-8").splitlines()[:24])
        urls = URL_RE.findall(header)
        upstreams = list(OVERRIDES.get(relative, []))
        for url in urls:
            upstream = upstream_from_url(url)
            if upstream and upstream not in upstreams:
                upstreams.append(upstream)
        third_party_header = bool(
            re.search(r"Mario Zechner|opencode contributors|Kilo Code|opentui|Apache-2\.0", header)
        )
        if not third_party_header:
            continue
        if not upstreams:
            raise SystemExit(f"no exact upstream mapping for {relative}")
        entries.append(
            {
                "path": relative,
                "licenseExpression": license_expression(header, relative),
                "spdxIdentifier": "Apache-2.0" if relative.endswith("TerminalSize.swift") else "MIT",
                "copyright": copyrights(header, relative),
                "upstreams": upstreams,
                "noticeMarker": f"`{relative}`",
            }
        )

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "schemaVersion": 1,
        "generatedBy": "Scripts/generate-source-inventory.py",
        "auditDate": "2026-08-03",
        "allowedLicenseExpressions": ["MIT", "MIT AND Apache-2.0"],
        "files": entries,
    }
    OUTPUT.write_text(json.dumps(document, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} source provenance entries to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
