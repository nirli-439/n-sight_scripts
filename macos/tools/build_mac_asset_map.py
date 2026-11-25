#!/usr/bin/env python3
"""Build macos/assets/mac-asset-map.tsv (hashed serial -> Jira Assets IA key) for the public repo.

    python3 -I macos/tools/build_mac_asset_map.py ~/Downloads/mac-onboarding/asset-map.csv

Input (LOCAL ONLY, never commit): CSV `Serial,AssetKey` of the Mac laptops in Jira Assets
(IT Assets schema 2, objectType "Laptops", vendor Apple, not Disposed).
Output: `sha256("helfy-mac:" + SERIAL)<TAB>IA-xxx` - the onboarding menu hashes the Mac's
own serial the same way and looks it up, so the file never reveals serial numbers.
Refresh whenever a new Mac is added in Jira, then commit + push (the one-liner serves main).
"""
import csv
import hashlib
import os
import re
import sys

SALT = "helfy-mac:"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "mac-asset-map.tsv")


def key(serial):
    return hashlib.sha256((SALT + serial).encode()).hexdigest()


def main(path):
    rows, seen = [], {}
    with open(os.path.expanduser(path), newline="") as f:
        for r in csv.DictReader(f):
            serial = re.sub(r"[^A-Z0-9]", "", (r.get("Serial") or "").upper())
            asset = (r.get("AssetKey") or "").strip().upper()
            if not serial or not re.fullmatch(r"IA-\d+", asset):
                print(f"skip: {r}", file=sys.stderr)
                continue
            if serial in seen and seen[serial] != asset:
                sys.exit(f"duplicate serial with different keys: {seen[serial]} / {asset}")
            seen[serial] = asset
            rows.append((key(serial), asset))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("# sha256('helfy-mac:'+SERIAL)\tIA key - built by macos/tools/build_mac_asset_map.py\n")
        for h, a in sorted(set(rows), key=lambda x: x[1]):
            f.write(f"{h}\t{a}\n")
    print(f"{len(set(rows))} Macs -> {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/mac-onboarding/asset-map.csv")
