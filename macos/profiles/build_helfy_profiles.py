#!/usr/bin/env python3
"""Build Helfy company .mobileconfig profiles to upload into the MDM and push to all Macs.

    python3 -I build_helfy_profiles.py            # writes ./Helfy_*.mobileconfig

UUIDs are fixed (derived from the identifier), so a rebuilt profile REPLACES the
installed one instead of installing a second copy. No secrets in here (public repo).

Profiles:
  Helfy_Activation_Lock      Find My Mac off (= no user Activation Lock), Handoff off
  Helfy_Security_Baseline    screen lock 15 min + password at once, firewall + stealth,
                             automatic security updates, guest account off
  Helfy_Chrome               same Chrome policies as Windows Optimize_Windows_AI_Workstation
  Helfy_System_Extensions    pre-approve Bitdefender + Twingate system extensions (no user click)

Team IDs verified from the vendors' signed installers (2026-11-25):
  Bitdefender GUNFMW623Y (GravityZone SetupDownloader), Twingate 6GX8KVTR9H (Twingate.pkg).
"""
import os
import plistlib
import uuid

ORG = "Helfy"
PREFIX = "co.helfy.profile"
OUT = os.path.dirname(os.path.abspath(__file__))
NS = uuid.UUID("6b1f3c1e-8d0a-4f3e-9a51-2b7d1c0e4a10")


def uid(name):
    return str(uuid.uuid5(NS, name)).upper()


def payload(ptype, ident, display, content):
    p = {
        "PayloadType": ptype,
        "PayloadVersion": 1,
        "PayloadIdentifier": f"{PREFIX}.{ident}",
        "PayloadUUID": uid(f"{ident}.payload"),
        "PayloadDisplayName": display,
    }
    p.update(content)
    return p


def profile(ident, display, description, payloads):
    return {
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": f"{PREFIX}.{ident}",
        "PayloadUUID": uid(ident),
        "PayloadDisplayName": f"{ORG} - {display}",
        "PayloadDescription": description,
        "PayloadOrganization": ORG,
        "PayloadScope": "System",
        "PayloadRemovalDisallowed": True,
        "PayloadContent": payloads,
    }


PROFILES = {
    "Helfy_Activation_Lock": profile(
        "activation-lock", "No Activation Lock",
        "Company Mac: Find My Mac is disabled so a personal Apple ID can never Activation-Lock it. Handoff off.",
        [payload("com.apple.applicationaccess", "activation-lock.restrictions", "Restrictions", {
            "allowFindMyDevice": False,          # no Find My Mac -> no user Activation Lock
            "allowActivityContinuation": False,  # Handoff off (was a script task)
        })]),

    "Helfy_Security_Baseline": profile(
        "security-baseline", "Security baseline",
        "Screen lock 15 min with password at once, firewall on, automatic security updates, no guest account.",
        [
            payload("com.apple.screensaver", "security-baseline.screensaver", "Screen lock", {
                "idleTime": 900, "askForPassword": True, "askForPasswordDelay": 0,
            }),
            payload("com.apple.security.firewall", "security-baseline.firewall", "Firewall", {
                "EnableFirewall": True, "EnableStealthMode": True, "BlockAllIncoming": False,
            }),
            # Security/config updates install automatically; major macOS upgrades are NOT forced.
            payload("com.apple.SoftwareUpdate", "security-baseline.updates", "Software Update", {
                "AutomaticCheckEnabled": True, "AutomaticDownload": True,
                "CriticalUpdateInstall": True, "ConfigDataInstall": True,
                "AutomaticallyInstallAppUpdates": True,
            }),
            payload("com.apple.loginwindow", "security-baseline.loginwindow", "Login window", {
                "DisableGuestAccount": True,
            }),
        ]),

    "Helfy_Chrome": profile(
        "chrome", "Google Chrome",
        "Chrome Memory Saver on, no background mode or promo tabs, Work bookmarks (same as Windows).",
        [payload("com.google.Chrome", "chrome.policies", "Chrome policies", {
            "HighEfficiencyModeEnabled": True,
            "BackgroundModeEnabled": False,
            "PromotionalTabsEnabled": False,
            "BookmarkBarEnabled": True,
            "ManagedBookmarks": [
                {"toplevel_name": "Work"},
                {"name": "Claude", "url": "https://claude.ai"},
                {"name": "Gmail", "url": "https://mail.google.com"},
                {"name": "Calendar", "url": "https://calendar.google.com"},
                {"name": "Drive", "url": "https://drive.google.com"},
            ],
        })]),

    "Helfy_System_Extensions": profile(
        "system-extensions", "Approved system extensions",
        "Bitdefender and Twingate system extensions load without asking the user.",
        [payload("com.apple.system-extension-policy", "system-extensions.policy", "System extensions", {
            "AllowUserOverrides": True,
            "AllowedTeamIdentifiers": ["GUNFMW623Y", "6GX8KVTR9H"],
        })]),
}

if __name__ == "__main__":
    for name, prof in PROFILES.items():
        path = os.path.join(OUT, f"{name}.mobileconfig")
        with open(path, "wb") as f:
            plistlib.dump(prof, f, sort_keys=False)
        print(path)
