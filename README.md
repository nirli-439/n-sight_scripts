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
| Windows  | 31     | 52    | 83    |
| macOS    | 15     | 22    | 37    |
| Linux    | 7      | 24    | 31    |
| **Total**| **53** | **98** | **151** |

Counts cover tracked checks/tasks only; interactive tools, tests and profiles are excluded.

---

## Core Standards (Summary)

- **Exit codes**: `0` = Success, `1001` = Warning, `1002` = Critical (N-Sight dashboard compliant; codes 1–999 reserved).
- **Silent**: Scripts run in Session 0 (SYSTEM/root) with no user interaction.
- **Output**: Keep under N-Sight limits (e.g. script size, stdout length); first line concise for dashboard (OK / WARNING / CRITICAL, etc.).
- **Linux**: Ubuntu/GNOME focus; use universal `systemd` patterns where possible for portability.

When adding or changing scripts, follow **N-SIGHT_SCRIPT_STANDARDS.md** so behavior and conventions stay consistent.

---

## Interactive Windows onboarding (PowerShell)

1. Download the N-sight **Windows** agent from the dashboard (Download Agent > Windows) into
   `Downloads` - links expire, so nothing is baked in.
2. In any PowerShell window (it asks for UAC by itself), or double-click
   `windows/tools/Onboarding_Menu_windows.cmd`:

```powershell
irm https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tools/Onboarding_Menu_windows.ps1 | iex
```

Plain numbered menu (works in every console): type numbers to toggle (`13 18`, `2-4`),
`a` all, `n` none, **Enter** runs, `q` quits. Order: N-sight agent, remove McAfee,
remove consumer bloat, remove OneDrive, Bitdefender, Chrome, Chrome default browser,
Google Drive, Slack, Twingate, GCPW, Claude Desktop, Claude Code + AI CLIs (optional),
speed & focus tweaks, hibernate/lid, screen lock, pin desktop apps, OpenSSH (optional).

Every selected task is downloaded fresh (cache-busted) and syntax-checked **before** anything
runs, then run one at a time with a per-task timeout (a hung installer is killed and the menu
moves on). At the end Chrome, Slack and Claude are opened as the signed-in user (not as
admin) and one summary popup is shown. Logs: `C:\logs\<yyyyMMdd>\`.

- `windows/tasks/Install_NSight_Agent.ps1` - newest `*AGENT*.exe/.msi/.zip` in any
  `C:\Users\*\Downloads` (or `-Path`, `NSIGHT_AGENT_PATH`, `NSIGHT_AGENT_URL`); EXE `/S`,
  MSI `/qn`; verifies the `Advanced Monitoring Agent` service.
- `windows/tasks/Optimize_Windows_AI_Workstation.ps1` (+ `Check_Windows_Optimized.ps1`) -
  winutil-style safe tweaks for a Claude/Chrome laptop: restore point first; telemetry,
  ads, suggestions, widgets, Copilot, Recall, Bing-in-Start, Game DVR off; best-performance
  power mode on AC; lighter animations; taskbar cleanup; Chrome Memory Saver, no background
  mode, "Work" bookmarks (Claude, Gmail, Calendar, Drive); temp cleanup. Never touches
  updates, Defender/Bitdefender, sign-in, hibernate or screen lock. Undo = the restore point.

---

## Interactive macOS onboarding (Terminal)

Macs are not imaged: onboarding runs on the Mac as delivered, from one line in
Terminal, **as the signed-in user, not with `sudo`**:

```bash
curl -fsSL is.gd/helfymac | bash
```

No menu, run the defaults: `curl -fsSL is.gd/helfymac | bash -s -- --auto --name IA-123`

`is.gd/helfymac` is a public shortlink (cannot be edited or deleted) that redirects to
`https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/onboard.sh`.
Use the full URL if is.gd is unreachable or the repo path ever changes.

`macos/onboard.sh` (the entry point) waits up to 5 min for internet (Wi-Fi / captive
portal), fixes a wrong clock (TLS fails otherwise), pins the run to **one commit** and
downloads the whole repo as one tarball from codeload (no raw-CDN lag, never a mix of old
and new scripts; per-file raw download is the fallback). The file is one function called
on its last line, so a cut-off download never runs half a script.

N-sight agent: downloaded automatically from the `agents-nsight` Drive folder; a newer
`OSX_AGENT_*_RW.ZIP` in `~/Downloads` (any letter case, or the folder Safari unzips) wins.

The menu (Up/Down + Space, 1-9, `t` type numbers like `14 21` or `2-5`, `a` all, `n` none,
Enter runs, `q` quits) asks **every question up front** - asset key, agent ZIP, `ADMIN`,
`REMOVE` - then one sudo password (kept alive) and the rest runs unattended: every task is
staged and syntax-checked first, runs one at a time with a **timeout** (a hung installer is
killed and the queue moves on), the Mac is kept awake (`caffeinate`), all output goes to
`~/Library/Logs/Helfy/onboarding-*.log` (except the interactive admin tool).

Order (same rules as the Windows USB: name before agent, Bitdefender after agent):

| # | Item | Default | Notes |
|---|---|---|---|
| 1 | Create admin mac | on | interactive; predictable date password + passwordless sudo, needs `ADMIN` |
| 2 | Computer name (IA-xxx) | on | Jira Assets key; serial shown to look it up; Enter keeps an existing IA name |
| 3 | N-sight agent | on | newest `OSX_AGENT*RW*.ZIP` in Downloads |
| 4 | Bitdefender | on | after the agent |
| 5-8 | Chrome, Chrome default browser, Google Drive, Slack | on | default browser: macOS asks the user to click "Use Google Chrome" |
| 9-10 | Twingate, Homebrew | on | Twingate = pinned, hash-checked vendor pkg |
| 11-13 | Claude, ChatGPT, Gemini Desktop | on | Homebrew casks, signature + Gatekeeper checked; skipped if already installed |
| 14-16 | Claude Code (CLI), Git setup, 1Password | off | Claude Code = official `claude.ai/install.sh` as the user |
| 17 | NirTab | on | |
| 18 | Mac settings | on | `Configure_Mac_Defaults_mac.sh`: network time (+Asia/Jerusalem only if still UTC), Hebrew keyboard, file extensions, no recent apps in Dock, battery %, Handoff off |
| 19 | Power on charger | on | `Remediate_Power_mac.sh`: on AC never system-sleep, display 15 min, wake for network |
| 20 | Screen lock 15 min | on | existing `Remediate_ScreenLock_Timeout_mac.sh` |
| 21 | Pin apps to Dock | off | as the user (never root), plist backed up, existing pins kept |
| 22 | Remove N-sight agent | off | never in "all", needs `REMOVE`, keeps Take Control |

At the end: successfully installed GUI apps are opened as the technician, then **final
checks** (IA name, agent running, Bitdefender running, FileVault, selected apps present)
and one summary dialog. Not covered on Mac (no equivalent): GCPW, McAfee/OneDrive/bloat
removal. Sign-ins, system/network extension approvals and Full Disk Access stay manual/MDM.

### Company profiles (pushed by the MDM)

`macos/profiles/Helfy_*.mobileconfig` - upload each one in N-sight > Device Management for Apple > Profiles >
Upload profile (scope Customer = Israel(Helfy)) and deploy it to all Macs; the MDM installs them silently on enrollment. Rebuild after an
edit with `python3 -I macos/profiles/build_helfy_profiles.py` (fixed UUIDs, so a re-upload
replaces the installed profile instead of adding a second one).

| Profile | What it does |
|---|---|
| `Helfy_Activation_Lock` | Find My Mac off, so a personal Apple ID can never Activation-Lock the Mac; Handoff off |
| `Helfy_Security_Baseline` | screen lock 15 min + password at once, firewall + stealth, automatic security updates (no forced macOS upgrades), guest off |
| `Helfy_Chrome` | same Chrome policies as Windows: Memory Saver, no background mode/promo tabs, "Work" bookmarks |
| `Helfy_FileVault` | FileVault on at the user's next log-in, cannot be turned off; the recovery key is shown to the user (no escrow) - IT must save it |
| `Helfy_System_Extensions` | Bitdefender (`GUNFMW623Y`) and Twingate (`6GX8KVTR9H`) system extensions load without a user click |

Also in the MDM: Macs added through Apple Business Manager should have "Allow Activation
Lock" off in the enrollment/prestage settings. Full Disk Access for Bitdefender: use the
profile GravityZone provides for Mac; for N-sight: `build_nsight_ppcc_mobileconfig.sh`.
The onboarding final checks report MDM enrollment, how many of the 5 Helfy profiles
arrived, and Activation Lock status.

### MDM enrollment (N-sight Device Management for Apple + Apple Business Manager)

- ABM server token **ISR_OCT_2026** uploaded to Device Management for Apple > Auto-enrollment,
  customer Israel(Helfy). **Expires 25 Nov 2027 - renew before** (ABM > Preferences > MDM server
  > Download token, upload to the same place), or auto-enrollment stops.
- In ABM, assign every Mac to that server (Devices > Edit MDM Server); set it as the default for
  Mac so new purchases go there automatically.
- Enrollment profile "DMA Default ABM Setup Config": Supervised Yes, MDM payload locked Yes.
  Recommended: Await device configuration **Yes** (profiles land before the desktop) and Allow
  Activation Lock **off** (Advanced setup).
- New or erased Macs enroll in Setup Assistant by themselves. For an already set-up Mac the
  onboarding runs `sudo profiles renew -type enrollment` before the queue; the user approves
  "Device Enrollment" in System Settings > General > Device Management. If the Mac is not
  assigned in ABM it says so and continues.
- N-sight agent ZIP: Drive folder `agents-nsight` (link-shared). The menu downloads it when no
  `OSX_AGENT*` file is in Downloads. Update it with Drive > Manage versions (keeps the file ID).

The old way still works (menu alone, fetches each task from raw):
`curl -fSL .../macos/tools/Onboarding_Menu_mac.sh -o ~/Downloads/m.sh && bash ~/Downloads/m.sh`

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
sequentially. Options 1-12 and 14 are selected by default. **Offboarding is never selected
by default or by the "all" shortcut.** Use arrows to reach options 11-14:

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
14. Enable SSH (OpenSSH server enabled at boot; existing authentication/host keys/firewall preserved)

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

SSH installs OpenSSH Server if needed, validates the current configuration, enables
and starts `ssh.service`, and verifies listeners on configured ports (including
custom ports). It does not enable root/password login, replace keys/configuration,
or change firewall rules. Remote reachability still depends on existing network/
firewall policy. A running systemd host is required.

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
python3 linux/tools/test_enable_ssh.py
```

---

## N-Sight RMM Deployment

1. **Automation Manager**: Create policies that run **Tasks** when **Checks** fail (or on schedule).
2. **Execution context**: Windows (SYSTEM), Linux/macOS (root).
3. **Self-healing**: Map each Check to a Task so failing checks trigger the right remediation or install.

---

*Last updated: September 2026*
