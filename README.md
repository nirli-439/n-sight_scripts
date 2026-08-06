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
| Windows  | 19     | 23    | 42    |
| macOS    | 9      | 11    | 20    |
| Linux    | 4      | 11    | 15    |
| **Total**| **32** | **45**| **77** |

---

## Core Standards (Summary)

- **Exit codes**: `0` = Success, `1001` = Warning, `1002` = Critical (N-Sight dashboard compliant; codes 1–999 reserved).
- **Silent**: Scripts run in Session 0 (SYSTEM/root) with no user interaction.
- **Output**: Keep under N-Sight limits (e.g. script size, stdout length); first line concise for dashboard (OK / WARNING / CRITICAL, etc.).
- **Linux**: Ubuntu/GNOME focus; use universal `systemd` patterns where possible for portability.

When adding or changing scripts, follow **N-SIGHT_SCRIPT_STANDARDS.md** so behavior and conventions stay consistent.

---

## N-Sight RMM Deployment

1. **Automation Manager**: Create policies that run **Tasks** when **Checks** fail (or on schedule).
2. **Execution context**: Windows (SYSTEM), Linux/macOS (root).
3. **Self-healing**: Map each Check to a Task so failing checks trigger the right remediation or install.

---

*Last updated: March 2025*
