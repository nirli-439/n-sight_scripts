# N-Sight RMM Script Standards

> **Purpose**: This repository contains automation scripts for deployment via N-Sight RMM (N-able Remote Monitoring & Management) to managed Windows, Linux, and macOS endpoints.

**Before writing any new script:** Follow the requirements in this document (exit codes, no user interaction, admin checks, error handling, and—when applicable—vendor documentation alignment). If the project adds **AI_SCRIPT_AUTHORING.md** or platform compliance docs (e.g. **windows/WINDOWS_COMPLIANCE.md**), use those as well to keep standards consistent.

**All new scripts** must comply with this document.

---

## Official N-Sight Platform Limits


| Constraint          | Limit             | Notes                                 |
| ------------------- | ----------------- | ------------------------------------- |
| Script Size         | 65,535 characters | Maximum script file size              |
| Script Output       | 10,000 characters | stdout captured by N-Sight            |
| Dashboard Display   | 255 characters    | First chars shown in All Devices view |
| Timeout (Default)   | 60 seconds        | Can be increased per task             |
| Timeout (Maximum)   | 3,600 seconds     | 1 hour maximum execution time         |
| Reserved Exit Codes | 1-999             | Reserved for N-Sight system scripts   |


> **Source**: [N-able Script Writing Guidelines](https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm)

---

## Script Types in N-Sight

### 24x7 Checks (Monitoring Scripts)

- Run at configurable intervals: **5, 15, 30, 60, or 120 minutes**
- Purpose: Proactive monitoring (disk space, services, performance)
- Location: `/checks/` folders
- Naming: `Check_*.ps1` or `Check_*.sh`
- Exit codes determine dashboard status

### Automated Tasks (Remediation/Installation Scripts)

- Run on schedule or triggered by events/policies
- Purpose: Installations, remediations, maintenance
- Location: `/tasks/` folders
- Naming: `Install_*.ps1`, `Remediate_*.ps1`, `Remove_*.ps1`, etc.
- Can be chained in Automation Manager policies

### Windows policies (when used)

- **Location**: `windows/policies/` (if present). Task scripts can be mapped to policy JSONs for deployment in N-Sight (e.g. trigger→task when a check fails).
- If the repo includes **windows/policies/**, see that folder’s README for deployment and trigger→policy mapping (e.g. **index.json** for policy names).

---

## Exit Code Standards

### CRITICAL: Exit Code Requirements

**N-Sight reserves exit codes 1-999 for system use.** To ensure your script's output displays correctly in the N-Sight dashboard, use exit codes accordingly:


| Exit Code | Meaning        | Use Case                                |
| --------- | -------------- | --------------------------------------- |
| `0`       | Success        | Script completed successfully           |
| `1001`    | Warning        | Non-critical issue detected             |
| `1002`    | Critical/Error | Critical failure or missing requirement |
| `1003+`   | Custom Errors  | Specific error conditions               |


### Migration Note

If you have existing scripts using exit codes 1 and 2, they will still work (non-zero = failure), but the script output text may not display correctly in the N-Sight UI. Migrate to codes >1000 for proper text output display.

### Exit Code Examples

**PowerShell:**

```powershell
# Success
exit 0

# Warning (non-critical issue)
Write-Host "WARNING: High memory usage detected (85%)"
exit 1001

# Critical error
Write-Host "CRITICAL: Service failed to start"
exit 1002

# Specific error codes for different failures
exit 1003  # Network timeout
exit 1004  # File not found
exit 1005  # Permission denied
```

**Bash:**

```bash
# Success
echo "OK: All services healthy"
exit 0

# Warning
echo "WARNING: Disk usage above 80%"
exit 1001

# Critical
echo "CRITICAL: Service is in failed state"
exit 1002
```

---

## General Script Requirements

### All Scripts Must:

1. **Silent/Unattended Execution** - No user interaction (scripts run in Session 0)
2. **Respect Output Limits** - Keep output under 10,000 characters; summarize when needed
3. **Admin Privilege Check** - Verify elevated permissions before execution
4. **Proper Exit Codes** - Use 0 for success, >1000 for failures (see Exit Code Standards)
5. **Error Handling** - Graceful failure with informative error messages
6. **Idempotent Design** - Safe to run multiple times without adverse effects
7. **Slim output / Concise First Line** - First 255 chars shown in some views. Use status: **OK**, **PASS**, **WARNING**, **CRITICAL**, or **Wait to Task**. Prefer one main line: `[timestamp] [INFO] Task name | Suggested action | PASS`.

### Linux Distribution Support (Fedora & Ubuntu)

**All Linux scripts must be written to run on both Fedora and Ubuntu** so a single script can be deployed universally. Do not create separate scripts per distro unless a feature genuinely cannot be implemented in a unified way.


| Aspect      | Requirement                                                                              |
| ----------- | ---------------------------------------------------------------------------------------- |
| **Distros** | Fedora (dnf) and Ubuntu (apt) — detect and use the correct package manager and paths     |
| **Desktop** | Assume **GNOME** where desktop/session logic is needed; most managed endpoints use GNOME |
| **Pattern** | One script that branches on distro (e.g. `get_distro` / package manager detection)       |


When a script must behave differently per distro, use runtime detection (e.g. `/etc/os-release`, `command -v dnf`) and branch inside the same script. Document supported versions in the script header (e.g. Fedora 38+, Ubuntu 22.04+).

### Execution Context


| Platform | Context        | Session                                            |
| -------- | -------------- | -------------------------------------------------- |
| Windows  | SYSTEM account | Session 0 (no desktop)                             |
| Linux    | root           | Non-interactive (Fedora & Ubuntu, typically GNOME) |
| macOS    | root           | Non-interactive                                    |


**Important**: User/desktop interaction (dialogs, messages, prompts) is NOT possible.

- **No MessageBox, Read-Host, or GUI prompts** — Use `Write-Host` / `Write-Output` and exit codes so N-Sight can capture results when the Agent runs the script (Session 0, no desktop).

---

## Vendor and external standards (new scripts)

When a script implements a third-party product or vendor procedure (e.g. Google GCPW, Chrome Enterprise, MDM), it must:

1. **Follow N-Sight standards** — Per [N-able Script Writing Guidelines](https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm): exit codes 0/1001/1002 (codes 1–999 reserved), silent execution, no user interaction, admin check, output via stdout; script/output size within platform limits.
2. **Align with vendor documentation** — Use official install URLs, registry keys, silent switches, and required steps from the vendor’s current guide (e.g. [Google Workspace Admin Help](https://support.google.com/a/answer/9250996) for GCPW).
3. **Treat installer/process exit codes as failures** — If the vendor installer or subprocess returns a non-success exit code (e.g. MSI ≠ 0, 3010, 1641), log the code and exit with `1002` (critical) so N-Sight reports failure correctly.

Reference vendor docs in the script header (`.DESCRIPTION` / `SYNOPSIS`) so maintainers can verify alignment when updating.

---

## PowerShell Scripts (.ps1) - Windows

### Supported by N-Sight Agent

Windows Agent supports: AMP, DOS Batch, JavaScript, Perl, PHP, **PowerShell**, Python, Ruby, VBS, CMD

### Template Structure

```powershell
<#
.SYNOPSIS
    Brief description of what the script does.
    
.DESCRIPTION
    Detailed description including:
    - What the script performs
    - Prerequisites
    - Designed for N-Sight RMM deployment
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Script_Name.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Script_Name.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Script_Name.ps1")
    (Every task must document the iex GitHub command above for one-line run-from-repo.)
    
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning
    Exit 1002 = Critical/Error
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up web requests/downloads

$ScriptName = "Script_Name"
$ScriptVersion = "1.0"
# Windows tasks: log to C:\logs\<date> (yyyyMMdd) when a Windows compliance doc is used
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message, 
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Summary {
    <#
    .SYNOPSIS
        Writes a slim summary for N-Sight dashboard. Use OK, PASS, WARNING, CRITICAL, or Wait to Task.
        Keep under 255 characters (slim output format; see "General Script Requirements" above).
    #>
    param(
        [ValidateSet("OK", "PASS", "WARNING", "CRITICAL", "Wait to Task")]
        [string]$Status,
        [string]$Message
    )
    # First line is most visible in N-Sight UI (slim format)
    Write-Host ""
    Write-Host "${Status}: $Message"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User Context: $env:USERNAME"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Log File: $LogFile"

# Admin check
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    # ========================================
    # Main logic here
    # ========================================
    
    Write-Log "Script completed successfully!" -Level "SUCCESS"
    Write-Summary -Status "OK" -Message "Operation completed successfully"
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Script failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    # Cleanup temporary files if needed
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
```

### PowerShell Best Practices for N-Sight

#### Output Management (Critical for 10K limit)

```powershell
# BAD: Verbose output that can exceed limits
Get-Process | Format-Table *

# GOOD: Summarized output
$processes = Get-Process
Write-Host "Total Processes: $($processes.Count)"
Write-Host "High Memory (>500MB): $(($processes | Where-Object WS -gt 500MB).Count)"
```

#### Network Operations

```powershell
# Always set TLS 1.2 for downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Suppress progress bars (much faster)
$ProgressPreference = "SilentlyContinue"
```

#### Installation Commands

```powershell
# MSI silent install
msiexec /i "installer.msi" /qn /norestart ALLUSERS=1

# EXE with common silent switches
Start-Process -FilePath "setup.exe" -ArgumentList "/S", "/v/qn" -Wait -NoNewWindow
```

#### Registry Operations

```powershell
# Check before modify
if (Test-Path "HKLM:\SOFTWARE\MyApp") {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\MyApp" -Name "Setting" -Value "Value"
}
```

### Automation Manager Integration

When using PowerShell in Automation Manager policies, exit codes are consumed within the "Run PowerShell Script" module and are NOT passed to the Dashboard automatically.

**To generate Dashboard failures:**

1. Add an `If` Control Flow condition after your PowerShell script
2. Check the script result
3. Add `Fail Policy` module in the `Then` branch

```
Policy Structure:
├── Run PowerShell Script (Extensions)
├── If (Control Flow) [Check if script failed]
│   └── Then
│       └── Fail Policy (Control Flow)
```

---

## Bash Scripts (.sh) - Linux

### Supported Distributions & Environment

- **Distributions**: All Linux scripts must support **Fedora** (dnf) and **Ubuntu** (apt) in a single script. Prefer one universal script with distro detection over separate Fedora/Ubuntu scripts.
- **Desktop**: Assume **GNOME** when scripts touch desktop/session settings (e.g. gsettings, GNOME extensions, default apps). Most managed endpoints use GNOME.
- **N-Sight Agent**: Supports shell scripts, Perl, PHP, Python, Ruby.

### Template Structure

```bash
#!/usr/bin/env bash
# =============================================================================
# Script_Name.sh - Brief description for N-Sight RMM
# =============================================================================
#
# SYNOPSIS:
#     Brief description of what the script does.
#
# DESCRIPTION:
#     Detailed description including:
#     - What the script performs
#     - Prerequisites
#     - Designed for N-Sight RMM deployment
#
# EXIT CODES:
#     0    = Success (PASS)
#     1001 = Warning
#     1002 = Critical/Error
#
# EXECUTION:
#     Linux: sudo bash /path/to/Script_Name.sh
#     Or:     bash /path/to/Script_Name.sh   (run as root when required)
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+, Ubuntu 22.04+ (universal; GNOME assumed for desktop)
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Script Name"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/script_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    
    # Output to both stdout and log file
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        echo ""
        echo "CRITICAL: Root privileges required"
        exit $EXIT_CRITICAL
    fi
}

get_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${NAME:-Unknown} ${VERSION_ID:-}"
    else
        echo "Unknown"
    fi
}

# Summary function - keep output concise for N-Sight dashboard
write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Create log directory
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "Distro: $(get_distro)"
log "Kernel: $(uname -r)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Pre-flight checks
check_root

# ============================================
# Main logic here
# ============================================

log "Script completed successfully" "SUCCESS"
write_summary "OK" "Operation completed successfully on $(hostname)"
exit $EXIT_SUCCESS
```

### Monitoring Script Pattern (24x7 Checks)

```bash
#!/usr/bin/env bash
# Monitoring check script pattern

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Thresholds
readonly WARN_THRESHOLD=80
readonly CRIT_THRESHOLD=95

# Get metric (example: disk usage)
usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

# Evaluate and exit with appropriate code
if [[ "$usage" -ge "$CRIT_THRESHOLD" ]]; then
    echo "CRITICAL: Disk usage at ${usage}% (threshold: ${CRIT_THRESHOLD}%)"
    exit $EXIT_CRITICAL
elif [[ "$usage" -ge "$WARN_THRESHOLD" ]]; then
    echo "WARNING: Disk usage at ${usage}% (threshold: ${WARN_THRESHOLD}%)"
    exit $EXIT_WARNING
else
    echo "OK: Disk usage at ${usage}%"
    exit $EXIT_SUCCESS
fi
```

### Linux Best Practices for N-Sight

#### Universal Scripts: Fedora + Ubuntu

Always support both Fedora and Ubuntu in one script. Detect distro once and branch on package manager and any distro-specific paths or commands.

```bash
# Detect distro family (required for universal Fedora + Ubuntu support)
get_pkg_mgr() {
    if command -v dnf &>/dev/null; then
        echo "dnf"   # Fedora, RHEL 8+
    elif command -v apt-get &>/dev/null; then
        echo "apt"   # Ubuntu, Debian
    else
        echo ""
    fi
}

PKG_MGR=$(get_pkg_mgr)
case "$PKG_MGR" in
    dnf)  dnf install -y package-name ;;
    apt)  apt-get update && apt-get install -y package-name ;;
    *)    echo "CRITICAL: Unsupported distro (need Fedora or Ubuntu)"; exit $EXIT_CRITICAL ;;
esac
```

#### GNOME Assumption

When configuring desktop or session behavior (gsettings, default apps, lockscreen), assume **GNOME**. Avoid XFCE/KDE-specific logic unless the script is explicitly for those environments.

```bash
# Example: GNOME setting (runs as root; may need DBUS_SESSION_BUS_ADDRESS for user session)
# Prefer system-wide or policy defaults where possible
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.session idle-delay 300  # example
fi
```

#### Package Management (Fedora + Ubuntu)

```bash
# Detect package manager (Fedora = dnf, Ubuntu = apt)
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
else
    echo "CRITICAL: Unsupported distro (Fedora or Ubuntu required)"
    exit $EXIT_CRITICAL
fi

# Install with appropriate manager
case "$PKG_MGR" in
    dnf)      dnf install -y package-name ;;
    apt-get)  apt-get update && apt-get install -y package-name ;;
esac
```

#### Service Management

```bash
# Check service status
if systemctl is-active --quiet servicename; then
    echo "Service is running"
else
    echo "Service is not running"
fi

# Safe restart with verification
systemctl restart servicename
sleep 2
if systemctl is-active --quiet servicename; then
    echo "OK: Service restarted successfully"
    exit $EXIT_SUCCESS
else
    echo "CRITICAL: Service failed to restart"
    exit $EXIT_CRITICAL
fi
```

---

## Bash Scripts (.sh) - macOS

### macOS-Specific Commands Reference


| Check             | Command                                                            | Notes                        |
| ----------------- | ------------------------------------------------------------------ | ---------------------------- |
| macOS Version     | `sw_vers -productVersion`                                          | Get OS version               |
| SIP Status        | `csrutil status`                                                   | System Integrity Protection  |
| Gatekeeper        | `spctl --status`                                                   | App code signing enforcement |
| FileVault         | `fdesetup status`                                                  | Disk encryption status       |
| Firewall          | `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` | Application firewall         |
| Code Signing      | `codesign -v /path/to/app`                                         | Verify app signature         |
| System Extensions | `systemextensionsctl list`                                         | Modern extension system      |


### Template Structure

```bash
#!/usr/bin/env bash
# =============================================================================
# Script_Name_mac.sh - Brief description for N-Sight RMM
# =============================================================================
#
# SYNOPSIS:
#     Brief description of what the script does.
#
# DESCRIPTION:
#     Detailed description including:
#     - What the script performs
#     - Prerequisites
#     - Designed for N-Sight RMM deployment
#
# EXIT CODES:
#     0    = Success (PASS)
#     1001 = Warning
#     1002 = Critical/Error
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Script_Name_mac.sh
#     Or:             bash /path/to/Script_Name_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh" | sudo bash
#     For scripts with parameters: curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh" | sudo bash -s "parameter1" "parameter2"
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Script Name"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/script_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    
    # Output to both stdout and log file
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        echo ""
        echo "CRITICAL: Root privileges required"
        exit $EXIT_CRITICAL
    fi
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

# Summary function - keep output concise for N-Sight dashboard
write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Create log directory
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "macOS: $(get_macos_version)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Pre-flight checks
check_root

# ============================================
# Main logic here
# ============================================

log "Script completed successfully" "SUCCESS"
write_summary "OK" "Operation completed successfully on $(hostname)"
exit $EXIT_SUCCESS
```

### macOS install from DMG — canonical pattern (use for new app installers)

For **download → mount → copy to `/Applications`** installers, copy the structure from these working tasks rather than inventing a new flow:

| Reference script | Role |
| ---------------- | ---- |
| `macos/tasks/Install_Chrome_mac.sh` | DMG with fixed mount name, `find` fallback, Dock for all users |
| `macos/tasks/Install_GoogleDrive_mac.sh` | Same, plus `curl` retries / resume, optional PKG fallback, per-user `killall Dock` |

**Standard pipeline (idempotent, N-Sight–safe):**

1. **`set -o pipefail`** at the top; **`trap cleanup EXIT`** so the DMG is always unmounted and `/tmp` download removed.
2. **Constants:** official HTTPS URL, `/tmp/<VendorApp>.dmg`, expected mount point (if known), `APP_NAME`, `INSTALL_PATH="/Applications/${APP_NAME}"`, `CFBundleIdentifier` for verification.
3. **`mkdir -p /var/log/nsight`** and a timestamped log under that path; **`log`** writes to stdout and the log file (dashboard still gets structured lines via **`write_summary`**).
4. **`check_root`** (`EUID -ne 0` → first human-readable line should reflect failure; exit `1002`).
5. **Already installed:** if `/Applications/<App>.app` exists **and** bundle ID matches → log, **`write_summary "OK"`** with version, **`exit 0`**. (Google Drive script also re-runs Dock helper here; optional per product.)
6. **Download:** `curl -L -o "$DOWNLOAD_PATH" "$URL"`; Google Drive adds `--retry 5 --retry-delay 5 -C -` for flaky networks. Validate file exists and minimum size where practical.
7. **Mount:** `hdiutil attach … -nobrowse` to expected `-mountpoint` if possible; on failure, attach without forcing mountpoint and **`find /Volumes -maxdepth 2 -name "${APP_NAME}"`** to locate the `.app`.
8. **Install:** `rm -rf` existing `/Applications` copy only when replacing; **`cp -R`** source app to `/Applications/`; **`chown -R root:wheel`**, **`chmod -R 755`**, **`xattr -dr com.apple.quarantine`** on the installed bundle.
9. **Verify:** bundle exists, **`defaults read`** / PlistBuddy for version, optional **`codesign -v`** on the app.
10. **User experience (optional):** Dock plist updates under `/Users/*/Library/Preferences/com.apple.dock.plist` with correct **`chown`** back to the user; restart Dock only in a way that matches logged-in users (see Google Drive script for `sudo -u` pattern).
11. **First output line for failures:** use **`write_summary "CRITICAL"`** / **`OK`** / **`WARNING`** so the dashboard matches N-Sight conventions; exits **`0` / `1001` / `1002`** only (never 1–999).

**N-Sight pairing:** add a matching **`macos/checks/Check_<App>_Installed.sh`** and attach this task as the remediation when the check fails.

### N-Sight Monitoring Information (Required in Script Header)

All macOS installation/remediation scripts **MUST** include the following monitoring information in the script header comments for N-Sight trigger configuration:

```bash
#     N-Sight Monitoring:
#     - Process Check: <ProcessName>
#     - OSX Daemon Check: <com.vendor.daemonname>
#     - LaunchAgent Path: /Library/LaunchAgents/<plist-file>.plist
#     - LaunchDaemon Path: /Library/LaunchDaemons/<plist-file>.plist (if applicable)
```


| Field             | Description                              | Example                                        |
| ----------------- | ---------------------------------------- | ---------------------------------------------- |
| Process Check     | Process name visible in Activity Monitor | `DisplayLinkUserAgent`, `Google Chrome Helper` |
| OSX Daemon Check  | LaunchAgent/LaunchDaemon identifier      | `com.displaylink.DisplayLinkUserAgent`         |
| LaunchAgent Path  | User-level service plist location        | `/Library/LaunchAgents/com.app.agent.plist`    |
| LaunchDaemon Path | System-level service plist location      | `/Library/LaunchDaemons/com.app.daemon.plist`  |


**Finding Daemon/LaunchAgent identifiers:**

```bash
# List all LaunchAgents (user-level services)
ls /Library/LaunchAgents/
ls ~/Library/LaunchAgents/

# List all LaunchDaemons (system-level services)
ls /Library/LaunchDaemons/

# Check if a specific daemon is loaded
launchctl list | grep -i "appname"

# Get daemon info
launchctl print system/com.vendor.daemonname
launchctl print gui/$(id -u)/com.vendor.agentname
```

### macOS Best Practices

```bash
#!/usr/bin/env bash
# macOS script template

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Get macOS version
macos_version=$(sw_vers -productVersion)
macos_major=$(echo "$macos_version" | cut -d. -f1)

# Version-specific logic
if [[ "$macos_major" -ge 14 ]]; then
    # Sonoma or later
    log "Running on macOS $macos_version (Sonoma+)"
fi

# Check app installation
if [[ -d "/Applications/Google Chrome.app" ]]; then
    version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
        "/Applications/Google Chrome.app/Contents/Info.plist" 2>/dev/null)
    echo "OK: Chrome installed (v$version)"
    exit $EXIT_SUCCESS
else
    echo "CRITICAL: Chrome not installed"
    exit $EXIT_CRITICAL
fi
```

---

## Output Best Practices

### Dashboard-Friendly Output

N-Sight captures stdout for display. Structure your output for maximum visibility:

```powershell
# First line is most important (255 char limit in some views)
Write-Host "OK: Chrome v120.0.6099.130 installed on WORKSTATION-01"

# Additional details follow
Write-Host "Path: C:\Program Files\Google\Chrome\Application\chrome.exe"
Write-Host "Architecture: x64"
Write-Host "Check completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
```

### Managing Large Output

When dealing with potentially large outputs (lists, logs, etc.):

```powershell
# BAD: Can easily exceed 10,000 character limit
Get-EventLog -LogName System -Newest 1000 | Format-Table

# GOOD: Summarize and truncate
$events = Get-EventLog -LogName System -Newest 1000 -EntryType Error
Write-Host "Error Events (Last 1000): $($events.Count)"
Write-Host ""
Write-Host "Most Recent 5 Errors:"
$events | Select-Object -First 5 | ForEach-Object {
    Write-Host "  $($_.TimeGenerated): $($_.Message.Substring(0, [Math]::Min(100, $_.Message.Length)))..."
}
```

```bash
# Bash: Limit output lines
log_entries=$(journalctl -u servicename --since "1 hour ago" -n 20 --no-pager)
echo "Recent service logs (last 20 lines):"
echo "$log_entries"
```

---

## Timeout Considerations

### For Long-Running Scripts

- Default timeout: 60 seconds
- Maximum timeout: 3,600 seconds (1 hour)
- Set appropriate timeout when deploying via N-Sight dashboard

### Timeout Best Practices

```powershell
# Add timeout handling for external processes
$process = Start-Process -FilePath "setup.exe" -ArgumentList "/S" -Wait -PassThru -NoNewWindow
if ($process.ExitCode -ne 0) {
    Write-Host "CRITICAL: Installation failed with exit code $($process.ExitCode)"
    exit 1002
}

# For downloads, use timeout parameters
$webClient = New-Object System.Net.WebClient
# Note: WebClient doesn't have built-in timeout, use HttpClient for timeout control
```

```bash
# Add timeout to commands that might hang
timeout 300 apt-get update  # 5 minute timeout

if [[ $? -eq 124 ]]; then
    echo "CRITICAL: Command timed out"
    exit $EXIT_CRITICAL
fi
```

---

## Script Inventory

### Windows (.ps1)

**Deployable policies**: When used, task policies in `windows/policies/*.json` and triggers in `windows/policies/triggers/`; see that folder’s README and any Windows compliance doc if present.

**Exit codes**: Windows scripts use 0 (success), 1001 (warning), 1002 (critical) per N-Sight.

#### Checks (windows/checks/)


| Script                                | Purpose                                  | Exit Codes                                  |
| ------------------------------------- | ---------------------------------------- | ------------------------------------------- |
| `Check_Chrome_Installed.ps1`          | Chrome installation monitoring           | 0=Installed, 1002=Missing                   |
| `Check_Edge_Installed.ps1`            | Edge installation status                 | 0=Installed, 1002=Missing                   |
| `Check_Edge_Blocked.ps1`              | Edge blocking policy check               | 0=Blocked, 1002=Not blocked                 |
| `Check_GoogleDrive_Installed.ps1`     | Google Drive installation                | 0=Installed, 1002=Missing                   |
| `Check_HEVC_Installed.ps1`            | HEVC/MOV (iPhone video) playback         | 0=Available, 1002=Missing                   |
| `Check_Twingate_Installed.ps1`        | Twingate client status                   | 0=Installed, 1002=Missing                   |
| `Check_HVCI_Enabled.ps1`              | Memory Integrity (HVCI) status           | 0=Enabled, 1001/1002=Disabled/Error         |
| `Check_Office_Macros_Disabled.ps1`    | Office macro security                    | 0=Secure, 1001/1002=Insecure                |
| `Check_PowerShell_v2_Disabled.ps1`    | PowerShell v2 disabled                   | 0=Disabled, 1001=Enabled                    |
| `Check_ScreenLock_Timeout.ps1`        | Screen lock configuration                | 0=Compliant, 1001/1002=Non-compliant        |
| `Check_Uptime_Windows.ps1`            | System uptime monitoring                 | 0=OK, 1001=Warning, 1002=Reboot needed      |
| `Check_Credential_Manager_Health.ps1` | Credential Manager status                | 0=Healthy, 1002=Issues                      |
| `Check_TakeControl_Health.ps1`        | TakeControl service health               | 0=Healthy, 1002=Issues                      |
| `Check_GCPW_Registry.ps1`             | Google Credential Provider               | 0=Configured, 1002=Missing                  |
| `Check_McAfee_Installed.ps1`          | McAfee presence detection                | 0=Not found, 1001=Found, 1002=Error         |
| `Check_OneDrive_Installed.ps1`        | OneDrive presence                        | 0/1002 based on policy                      |
| `Check_Slack_Installed.ps1`           | Slack installation                       | 0=Installed, 1002=Missing                   |
| `Check_Tailscale_Installed.ps1`       | Tailscale VPN installation               | 0=Installed, 1001=Not running, 1002=Missing |
| `Check_WinRAR_Installed.ps1`          | WinRAR installation                      | 0=Installed, 1002=Missing                   |
| `Check_Brother_MFC-L5750DW.ps1`       | Printer driver check                     | 0=Installed, 1001/1002=Missing              |
| `Check_ComputerName_Inventory.ps1`    | Computer naming inventory                | 0=Compliant, 1002=Issues                    |
| `Check_Applied_Policies.ps1`          | List applied Group Policy Objects (GPOs) | 0=OK, 1002=Error                            |


#### Tasks (windows/tasks/)


| Script                              | Purpose                                   |
| ----------------------------------- | ----------------------------------------- |
| `Install_Chrome.ps1`                | Chrome Enterprise installation            |
| `Install_GoogleDrive.ps1`           | Google Drive for Desktop                  |
| `Install_Slack.ps1`                 | Slack desktop client                      |
| `Install_Tailscale.ps1`             | Tailscale VPN installation                |
| `Install_WinRAR.ps1`                | WinRAR installation                       |
| `Install_DaVinciResolve.ps1`        | DaVinci Resolve installer                 |
| `Install_Brother_MFC-L5750DW.ps1`   | Brother printer driver                    |
| `Remove_McAfee.ps1`                 | Complete McAfee removal                   |
| `Remove_TeamViewer.ps1`             | TeamViewer removal and cleanup            |
| `Remove_OneDrive.ps1`               | OneDrive removal                          |
| `Remove_Edge.ps1`                   | Microsoft Edge removal                    |
| `Block_Edge.ps1`                    | Block Edge via policy                     |
| `Unblock_Edge.ps1`                  | Remove Edge blocking                      |
| `Rename_Computer.ps1`               | Computer hostname change                  |
| `Remediate_GCPW_Registry.ps1`       | Fix GCPW configuration                    |
| `Remediate_GCPW_Token_Expiration.ps1` | Fix GCPW token expiration breaking Windows Hello |
| `Remediate_Office_Macros.ps1`       | Set macro security                        |
| `Remediate_ScreenLock_Timeout.ps1`  | Configure screen lock                     |
| `Remediate_Credential_Manager.ps1`  | Fix Credential Manager                    |
| `Remediate_TakeControl_Service.ps1` | Repair TakeControl                        |
| `Remediate_Uptime_Reboot.ps1`       | Force system reboot                       |
| `Install_HEVC_Codec.ps1`            | HEVC/MOV (iPhone video) codec and players |
| `openoffice_winget.ps1`             | OpenOffice via WinGet                     |


### Linux (.sh)

#### Checks (linux/checks/)


| Script                         | Purpose                                             | Exit Codes                           |
| ------------------------------ | --------------------------------------------------- | ------------------------------------ |
| `Check_Linux_Memory.sh`        | Memory usage monitoring                             | 0=OK, 1=Warn, 2=Critical             |
| `Check_Linux_Daemons.sh`       | Daemon health check                                 | 0=Healthy, 1=Warn, 2=Critical        |
| `Check_Desktop_Environment.sh` | Desktop environment detection (GNOME/KDE/XFCE/MATE) | 0=Detected, 1001=Unknown, 1002=Error |


#### Tasks (linux/tasks/)


| Script                                          | Purpose                                                                                      |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `Remediate_Linux_Daemons.sh`                    | Comprehensive daemon fix                                                                     |
| `Remediate_All_Daemons_Fedora.sh`               | All daemon fixes (Fedora)                                                                    |
| `Remediate_Hostname_Fedora.sh`                  | Hostname configuration                                                                       |
| `Remediate_Hostname_Ubuntu.sh`                  | Hostname rename (Ubuntu)                                                                     |
| `Remediate_Fwupd.sh`                            | fwupd service fix                                                                            |
| `Remediate_Fprintd.sh`                          | fprintd service fix                                                                          |
| `Remediate_Getty_TTY2.sh`                       | Getty TTY2 fix                                                                               |
| `Remediate_NetworkManager_Dispatcher.sh`        | NM dispatcher fix                                                                            |
| `Remediate_NetworkManager_Dispatcher_Fedora.sh` | NM dispatcher (Fedora)                                                                       |
| `Remediate_Nvidia_Persistenced.sh`              | NVIDIA service fix                                                                           |
| `Remediate_PackageKit.sh`                       | PackageKit disable                                                                           |
| `Remediate_PackageKit_Fedora.sh`                | PackageKit (Fedora)                                                                          |
| `Remediate_Realmd.sh`                           | Realmd service fix                                                                           |
| `Remediate_Virtqemud.sh`                        | QEMU daemon fix                                                                              |
| `Remediate_Disk_Performance.sh`                 | Disk I/O optimization                                                                        |
| `Remediate_DisplayLink.sh`                      | DisplayLink driver fix                                                                       |
| `Remediate_Systemd_Services.sh`                 | General systemd fixes                                                                        |
| `Remediate_SSH_And_Admin_User.sh`               | Install/enable SSH, create user with password "1111", add to sudo/wheel                      |
| `Install_N-Sight_Support_Ubuntu.sh`             | Install rsyslog, smartmontools, gnome-remote-desktop, kerneloops, cups, cron (Ubuntu)        |
| `Install_N-Sight_Support_Fedora.sh`             | Install rsyslog, smartmontools, gnome-remote-desktop, abrt-kerneloops, cups, cronie (Fedora) |


### macOS (.sh)

#### Checks (macos/checks/)


| Script                           | Purpose                | Exit Codes             |
| -------------------------------- | ---------------------- | ---------------------- |
| `Check_Chrome_Installed.sh`      | Chrome installation    | 0=Installed, 2=Missing |
| `Check_GoogleDrive_Installed.sh` | Google Drive status    | 0=Installed, 2=Missing |
| `Check_Twingate_Installed.sh`    | Twingate client        | 0=Installed, 2=Missing |
| `Check_macOS_Security.sh`        | SIP, Gatekeeper, kexts | 0=Secure, 2=Issues     |
| `Check_Mac_RMM_Agent_SelfHeal.sh` | N-sight agent up + optional self-heal (LaunchDaemon) | 0=OK, 1001=Sync/heal warn, 1002=Critical |
| `Check_Mac_RMM_Agent_Refresh.sh` | Full agent refresh (task-cancel, sync, scans) | 0=OK, 1001=Partial/restarted, 1002=Missing binary |
| `Check_Uptime_macOS.sh`          | System uptime          | 0=OK, 1=Warn, 2=Reboot |
| `Check_Handoff_Disabled_mac.sh`  | Handoff (Continuity) off per user | 0=OK, 1001=No users, 1002=Enabled |
| `Check_Homebrew_Path_mac.sh`     | Homebrew present + `/etc/paths.d/homebrew` | 0=OK, 1001=brew OK paths.d missing, 1002=brew missing/broken |


#### Tasks (macos/tasks/)


| Script                                 | Purpose                                                                          |
| -------------------------------------- | -------------------------------------------------------------------------------- |
| `Remediate_SSH_And_Admin_User_mac.sh`  | Enable Remote Login (SSH), create user with password "1111", add to admin (sudo) |
| `Create_User_mac.sh`                   | Create new user with generated password                                          |
| `Install_Chrome_mac.sh`                | Chrome installation                                                              |
| `Install_GoogleDrive_mac.sh`           | Google Drive for Desktop                                                         |
| `Install_Slack_mac.sh`                 | Slack desktop client                                                             |
| `Disable_Safari_Default_Chrome_mac.sh` | Set Chrome as default browser                                                    |
| `Rename_Hostname_mac.sh`               | Hostname change                                                                  |
| `Refresh_RMM_Agent_mac.sh`             | Wrapper → runs `../checks/Check_Mac_RMM_Agent_Refresh.sh` (legacy task URL)        |
| `Remediate_Disable_Handoff_mac.sh`     | Disable Handoff per user + verify                                                  |
| `Remediate_Homebrew_Path_mac.sh`       | Write `/etc/paths.d/homebrew` so Homebrew `bin` is on system PATH (after brew exists) |


---

## Quick Reference Card

### Execution by platform


| Platform                | Run command                                                                                                                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Windows (local)**     | `iex (Get-Content ".\ScriptName.ps1" -Raw)` or `powershell -NoProfile -ExecutionPolicy Bypass -File ".\ScriptName.ps1"`                                                                                            |
| **Windows (from repo)** | `iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/ScriptName.ps1")` — every task must include this in .EXECUTION and log to `C:\logs\<date>`                              |
| **Linux**               | `sudo bash /path/to/script.sh` or `bash /path/to/script.sh` (as root when required)                                                                                                                                |
| **macOS (local)**       | `sudo bash /path/to/script.sh` or `bash /path/to/script.sh` (as root when required)                                                                                                                                |
| **macOS (from repo)**   | `curl -fsSL "[https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh](https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh)" |


### Exit Codes

```
0     = Success
1001  = Warning  
1002  = Critical Error
1003+ = Custom errors
(1-999 reserved for N-Sight system)
```

### Output Format

```
<STATUS>: <Brief message under 255 chars>
<Additional details...>
```

### Key Limits

- Script: 65,535 chars
- Output: 10,000 chars  
- Dashboard: 255 chars (first line)
- Timeout: 60s default, 3600s max

### Execution Context

- Windows: SYSTEM account, Session 0
- Linux: root, non-interactive; **Fedora + Ubuntu**, GNOME assumed for desktop
- macOS: root, non-interactive
- No user interaction possible

---

## References

- [N-able Script Writing Guidelines](https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm)
- [Script Return Codes](https://documentation.n-able.com/remote-management/userguide/Content/script_guide_return.htm)
- [Automation Manager Guide](https://documentation.n-able.com/remote-management/userguide/Content/auto_mananger/construct_policy_using_auto_manager.htm)
- [Script FAQs](https://documentation.n-able.com/remote-management/userguide/Content/faqs3.htm)

---

*Last Updated: January 2026*