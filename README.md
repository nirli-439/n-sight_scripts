# N-Sight Scripts (N-Sight)

> **Purpose**: Automation scripts for deployment via **N-Sight RMM** (N-able Remote Monitoring & Management) to managed **Windows**, **macOS**, and **Linux** (Ubuntu/GNOME focus) endpoints. Used for onboarding, compliance, installs, and remediation—all silent and suitable for Session 0 / SYSTEM or root.

---

## What This Repo Is

- **RMM automation**: Scripts run by N-Sight on endpoints (checks for monitoring, tasks for install/remediate).
- **Multi-platform**: Windows (PowerShell), macOS (Bash), Linux (Bash, Ubuntu/systemd focus).
- **Check + Task pattern**: **Checks** report status (OK / Warning / Critical); **Tasks** fix or install when triggered (e.g. when a check fails).
- **Standards**: Exit codes (0 / 1001 / 1002), no user interaction, idempotent, output limits for N-Sight dashboard. See **N-SIGHT_SCRIPT_STANDARDS.md** for full rules.

---

## Repository Structure

```
Scripts_N-Sight/
├── README.md                    # This file – repo overview
├── N-SIGHT_SCRIPT_STANDARDS.md  # Script templates, exit codes, and coding standards
├── .gitignore                   # e.g. .DS_Store; GCPW installers excluded (large binaries)
│
├── windows/                     # Windows PowerShell (.ps1)
│   ├── checks/                 # Monitoring / validation scripts (Check_*.ps1)
│   ├── tasks/                  # Remediation & installation scripts (Install_*, Remediate_*, Remove_*, etc.)
│   └── gcpw/                   # Google Credential Provider for Windows – installer assets + set_gcpw_token.reg
│
├── macos/                       # macOS shell scripts (.sh)
│   ├── checks/                 # Monitoring and security checks
│   └── tasks/                  # Remediation and installation scripts
│
└── linux/                       # Linux shell scripts (.sh) – Ubuntu/systemd focus
    ├── checks/                 # Monitoring scripts
    └── tasks/                  # Remediation and universal fixes (systemd/GNOME)
```

---

## Quick Stats

| Platform | Checks | Tasks | Total |
|----------|--------|-------|-------|
| Windows  | 30     | 50    | 80    |
| macOS    | 15     | 21    | 36    |
| Linux    | 6      | 17    | 23    |
| **Total**| **51** | **88** | **139** |

Counts cover tracked checks/tasks only; interactive tools, tests and profiles are excluded.

---

## Core Standards (Summary)

- **Exit codes**: `0` = Success, `1001` = Warning, `1002` = Critical (N-Sight dashboard compliant; codes 1–999 reserved).
- **Silent**: Scripts run in Session 0 (SYSTEM/root) with no user interaction.
- **Output**: Keep under N-Sight limits (e.g. script size, stdout length); first line concise for dashboard (OK / WARNING / CRITICAL, etc.).
- **Linux**: Ubuntu/GNOME focus; use universal `systemd` patterns where possible for portability.

When adding or changing scripts, follow **N-SIGHT_SCRIPT_STANDARDS.md** so behavior and conventions stay consistent.

---

## Interactive macOS onboarding (Terminal)

Download and run as the logged-in technician, **not** with `sudo`:

```bash
curl -fSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tools/Onboarding_Menu_mac.sh -o "$HOME/Downloads/Onboarding_Menu_mac.sh" && bash "$HOME/Downloads/Onboarding_Menu_mac.sh"
```

Use **Up/Down + Space** (or **1-9** for the first nine entries) to select,
**Enter** to run, **q** to quit. Press **a** to select everything except removal.
Selected tasks run one at a time, waiting for completion, in this order:
Bitdefender, Chrome, Google Drive, Slack, Create admin mac, Homebrew, Twingate,
optional N-sight removal (8), Claude Desktop (9), ChatGPT Desktop (10),
Gemini Desktop (11), Git setup (12), and 1Password (13).
A native macOS completion/warning/failure dialog appears after each task; results remain in the menu.
N-sight removal and the new optional tools are off by default. Removal requires
typing `REMOVE` and preserves Take Control.

Claude, ChatGPT, Google's native Gemini app (`google-gemini`, **not** the unrelated
`gemini` disk cleaner), and 1Password use official vendor packages through Homebrew
casks. Homebrew is installed if needed, even when option 6 was not selected.
Gemini requires Apple Silicon and macOS 15+; Homebrew enforces each app's requirements.
Existing identical app bundles can be adopted without deleting user data; different
unmanaged copies fail safely instead of being overwritten. App signatures and
Gatekeeper approval are checked after installation. No Dock shortcuts are created.
Sign-in/licensing remains manual; 1Password vaults are never configured or removed.

Git setup installs Git through Homebrew and prompts for this Mac user's commit
name/email (Enter preserves existing values). It defaults to macOS Keychain only
when no global credential helper exists; existing credentials and signing settings
are preserved. It does not log into GitHub or generate SSH keys.

This reuses the existing admin creation tool: it uses a predictable date password
and grants passwordless sudo. The menu warns and requires typing `ADMIN` before
running it; rotate that password immediately. Account/SecureToken prompts stay in
Terminal and are not recorded in the menu's result log.

Logs: `~/Library/Logs/Helfy/`; individual installer logs remain in `/var/log/nsight/`.
Homebrew runs as the technician, not root. Twingate uses a pinned, hash-checked,
Apple-signed vendor package and does not require Homebrew. Sign-ins, system/network
extension approvals and Full Disk Access can still require manual approval/MDM.
This interactive tool is **not** an unattended RMM task.

Slack remains option 4. Its installer uses a private download/mount, validates
Slack's bundle ID, vendor signature and Gatekeeper approval before copying, and
leaves existing invalid apps untouched. It never edits the Dock or strips quarantine.

Safe checks (no installs/removal):
```bash
bash macos/tools/test_onboarding_menu.sh
bash macos/tools/test_onboarding_extras.sh
python3 macos/tools/test_slack_install.py
python3 macos/tools/test_google_drive_setup.py
```

---

## N-Sight RMM Deployment

1. **Automation Manager**: Create policies that run **Tasks** when **Checks** fail (or on schedule).
2. **Execution context**: Windows (SYSTEM), Linux/macOS (root).
3. **Self-healing**: Map each Check to a Task so failing checks trigger the right remediation or install.

---

*Last updated: September 2026*
