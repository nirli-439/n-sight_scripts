#!/usr/bin/env python3
"""
Build a PPPC (com.apple.TCC.configuration-profile-policy) .mobileconfig for
N-sight RMM Mac Agent + Take Control-related apps.

Docs: https://documentation.n-able.com/remote-management/userguide/Content/install_mac_agent_access.htm
Apple schema: https://github.com/apple/device-management (com.apple.TCC.configuration-profile-policy.yaml)
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Iterable, List, Tuple


SERVICE_KEYS: Tuple[str, ...] = (
    "Accessibility",
    "SystemPolicyAllFiles",
    "ScreenCapture",
    "PostEvent",
    "ListenEvent",
)


def designated_requirement(target: Path) -> str:
    if not target.exists():
        raise FileNotFoundError(str(target))
    p = subprocess.run(
        ["codesign", "--display", "-r-", str(target)],
        check=False,
        capture_output=True,
        text=True,
    )
    text = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"designated\s*=>\s*(.+)$", text, re.MULTILINE)
    if not m:
        raise RuntimeError(f"Could not parse designated requirement for {target}:\n{text}")
    return m.group(1).strip()


def bundle_id(app: Path) -> str:
    info = app / "Contents" / "Info.plist"
    with info.open("rb") as f:
        pl = plistlib.load(f)
    bid = pl.get("CFBundleIdentifier")
    if not bid:
        raise RuntimeError(f"Missing CFBundleIdentifier in {info}")
    return str(bid)


def identity_dict(identifier: str, id_type: str, code_req: str) -> dict:
    return {
        "Identifier": identifier,
        "IdentifierType": id_type,
        "CodeRequirement": code_req,
        "Allowed": True,
    }


def services_payload(identities: Iterable[Tuple[str, str, str]]) -> dict:
    """
    identities: list of (identifier_type, identifier, code_requirement)
    identifier_type is 'path' or 'bundleID'
    """
    services: dict = {k: [] for k in SERVICE_KEYS}
    for id_type, ident, req in identities:
        entry = identity_dict(ident, id_type, req)
        for k in SERVICE_KEYS:
            services[k].append(entry)
    return {
        "PayloadType": "com.apple.TCC.configuration-profile-policy",
        "PayloadVersion": 1,
        "PayloadIdentifier": "com.helfy.nsight.rmm.tcc",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadDisplayName": "N-sight RMM / Take Control — TCC (PPPC)",
        "PayloadDescription": (
            "Accessibility, Full Disk Access (SystemPolicyAllFiles), ScreenCapture, "
            "PostEvent, ListenEvent for N-sight Mac Agent and Take Control components."
        ),
        "Services": services,
    }


def configuration_root(inner: dict) -> dict:
    return {
        "PayloadContent": [inner],
        "PayloadRemovalDisallowed": False,
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": "com.helfy.nsight.ppcc.profile",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadOrganization": "Helfy",
        "PayloadDisplayName": "N-sight RMM — Privacy (PPPC)",
        "PayloadDescription": "PPPC allowlist for N-sight Mac Agent and Take Control.",
    }


def discover_identities() -> List[Tuple[str, str, str]]:
    out: List[Tuple[str, str, str]] = []

    rmm_paths = [Path("/usr/local/rmmagent/rmmagentd"), Path("/usr/local/bin/rmmagentd")]
    rmm_bin = next((p for p in rmm_paths if p.is_file() and os.access(p, os.X_OK)), None)
    if not rmm_bin:
        raise FileNotFoundError(
            "rmmagentd not found at /usr/local/rmmagent/rmmagentd or /usr/local/bin/rmmagentd. "
            "Install the N-sight Mac agent on this machine, then re-run."
        )
    out.append(("path", str(rmm_bin), designated_requirement(rmm_bin)))

    ama_candidates = [
        Path("/Applications/Utilities/Advanced Monitoring Agent.app"),
        Path("/Applications/Advanced Monitoring Agent.app"),
    ]
    for app in ama_candidates:
        if app.is_dir():
            out.append(("bundleID", bundle_id(app), designated_requirement(app)))
            break

    msp_candidates = [
        Path("/Applications/MSP Anywhere Agent.app"),
        Path("/Applications/MSP Anywhere Agent (Advanced).app"),
    ]
    for app in msp_candidates:
        if app.is_dir():
            out.append(("bundleID", bundle_id(app), designated_requirement(app)))
            break

    tc_viewer = Path("/Applications/Take Control Viewer for RMM.app")
    if tc_viewer.is_dir():
        out.append(("bundleID", bundle_id(tc_viewer), designated_requirement(tc_viewer)))

    return out


def main() -> int:
    out_path = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else None
    identities = discover_identities()
    inner = services_payload(identities)
    root = configuration_root(inner)
    data = plistlib.dumps(root, fmt=plistlib.FMT_XML)
    if out_path:
        out_path.write_bytes(data)
        print(f"Wrote: {out_path}", file=sys.stderr)
    else:
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
