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
| macOS    | 15     | 22    | 37    |
| Linux    | 7      | 23    | 30    |
| **Total**| **52** | **95** | **147** |

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
Gemini Desktop (11), Git setup (12), 1Password (13), and NirTab (14).
One native macOS summary dialog appears only after the entire selected run finishes,
including warnings, failures and cancellations. Individual tasks update Terminal
and the menu without completion popups (including N-sight removal).
After all installations finish, the tool opens only successfully selected GUI apps
as the technician: Bitdefender UI, Chrome, Drive, Slack, Twingate, Claude, ChatGPT,
Gemini, 1Password and NirTab. Command-line/admin tasks are not launched. Launch
requests/failures appear in the final summary; an accepted request does not prove
first-run setup is complete. macOS may still ask for sign-in or permission approval.
Claude, ChatGPT, Gemini and NirTab are selected by default, alongside options 1-7.
N-sight removal, Git setup and 1Password remain optional/off by default. Removal
requires typing `REMOVE` and preserves Take Control.

Claude, ChatGPT, Google's native Gemini app (`google-gemini`, **not** the unrelated
`gemini` disk cleaner), and 1Password use official vendor packages through Homebrew
casks. Homebrew is installed if needed, even when option 6 was not selected.
Gemini requires Apple Silicon and macOS 15+; Homebrew enforces each app's requirements.
Existing identical app bundles can be adopted without deleting user data; different
unmanaged copies fail safely instead of being overwritten. App signatures and
Gatekeeper approval are checked after installation. No Dock shortcuts are created.
Sign-in/licensing remains manual; 1Password vaults are never configured or removed.

Git setup installs Git through Homebrew without identity prompts. Missing Git name
uses the Mac's hostname; missing email uses `local-user@hostname` (`.local` is added
for a hostname without a domain). This is a local machine identity, **not** a verified
GitHub/company email. Existing name/email, credentials and signing settings are
preserved; macOS Keychain is the default only if no global credential helper exists.
It does not log into GitHub or generate SSH keys.

NirTab installs the pinned v0.15 universal release from
[`nirli-439/NirTab`](https://github.com/nirli-439/NirTab), verifies its SHA-256,
bundle ID, executable and signature. Reruns repair app-bundle read/traverse
permissions on an existing valid install without replacing it. New app directories
are explicitly world-readable/traversable even under a restrictive `umask 077`
(the same fix applies to Slack); private downloads/logs stay private. Requires
macOS 14+. NirTab is a **menu-bar app**, not a normal Dock application. It is
launched at the end when selected and installed successfully. The release is
self-signed, not notarized: Gatekeeper and Accessibility/Screen Recording approval
may require manual action through NirTab's Setup Checklist; the tool does not
bypass Gatekeeper, re-sign NirTab or change the Dock.

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
bash macos/tools/test_onboarding_launch.sh
python3 macos/tools/test_slack_install.py
python3 macos/tools/test_google_drive_setup.py
python3 macos/tools/test_nirtab_install.py
```

---

## Interactive Ubuntu onboarding (Terminal)

Run as the logged-in desktop user, **not** with sudo:

```bash
curl -fSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/tools/Onboarding_Menu_linux.sh -o "$HOME/Onboarding_Menu_linux.sh" && bash "$HOME/Onboarding_Menu_linux.sh"
```

Ubuntu **22.04+**; the screen-lock policy requires **GNOME**. Chrome and Slack
use system Flatpak/Flathub (their availability depends on CPU architecture).
Use Up/Down + Space (1-9/0 also toggle options 1-10); Enter runs selections
sequentially. Options 1-12 are selected by default. **Offboarding is never selected
by default or by the "all" shortcut.** Use arrows to reach options 11-13:

1. Google Chrome
2. Bitdefender GravityZone (organization package)
3. GNOME screen lock after 15 minutes (locked policy; new login required)
4. Git (machine-derived identity; existing identity/credentials stay unchanged)
5. Slack
6. Claude Code
7. Codex CLI
8. Google Antigravity desktop app
9. Docker Engine + current Compose plugin
10. Twingate client
11. MySQL Workbench GUI client (Oracle-signed 26.10.0 generic Linux build; Intel/ARM64, no MySQL Server or database changes)
12. APT update/upgrade + available firmware updates
13. Offboard selected inactive local users (**optional/destructive account change**)

Installers finish before Chrome, Slack, Antigravity and Workbench launch as the user in an
existing graphical session. CLI agents are installed/version-checked, not started
in an interactive login session. Sign-ins remain manual. There is one final
summary dialog with existing Zenity, otherwise a desktop notification if available,
with Terminal always showing the results. Logs: `~/.local/state/helfy-onboarding/`
(or beneath `$XDG_STATE_HOME`).

Docker data is preserved and the user is **not** silently added to the root-equivalent
`docker` group; use `sudo docker` unless access was already configured. Conflicting
container packages are not removed automatically. Twingate installs without changing
network/credentials; configure it afterward with `sudo twingate setup`.

Downloads are staged before execution. System tasks run elevated with a readable
system-file umask, while menu logs/work files stay private. Claude Code, Codex and
Antigravity install as the user, not root. Antigravity's GTK/NSS/audio runtimes and
Python are installed through Ubuntu packages first; the app itself remains user-scoped.
These interactive onboarding tools are
separate from unattended N-sight tasks.

System maintenance upgrades packages without automatic package removal or reboot,
preserves existing configuration, and reports held-back updates/reboot requirements.
Firmware availability depends on vendor/LVFS support and power state. Actual flashing
requires a separate exact typed confirmation; it is never forced on battery or done
without a usable confirmation terminal. A reboot may be needed before new firmware
or a kernel becomes active, so a pending reboot is not reported as fully up to date.

Offboarding protects system/service accounts, the technician passed by the menu,
and accounts with active processes. It lists eligible **local** users, requires an
explicit numbered selection and typing `REMOVE alice bob` for exactly those names,
and rechecks account identity/activity before each removal. It calls `userdel`
**without** `-r`/`--remove`/`--force`: home folders, mail and their original ownership
stay in place, as requested. This is **not a factory reset** or disk wipe. Preserve
encryption recovery keys before removing accounts; kept homes are not a backup, and
UID reuse can grant access to retained files. SSO/SaaS revocation is separate.
Read-only preview: `sudo python3 linux/tools/Offboard_Users_linux.py --keep "$USER" --list`.

Safe regression checks:
```bash
bash linux/tools/test_onboarding_menu.sh
python3 linux/tools/test_desktop_setup.py
python3 linux/tools/test_bitdefender_existing.py
python3 linux/tools/test_docker_twingate_install.py
python3 linux/tools/test_ai_tool_install.py
python3 linux/tools/test_mysql_workbench_install.py
python3 linux/tools/test_system_firmware_update.py
python3 linux/tools/test_offboard_users.py
```

---

## N-Sight RMM Deployment

1. **Automation Manager**: Create policies that run **Tasks** when **Checks** fail (or on schedule).
2. **Execution context**: Windows (SYSTEM), Linux/macOS (root).
3. **Self-healing**: Map each Check to a Task so failing checks trigger the right remediation or install.

---

*Last updated: September 2026*
