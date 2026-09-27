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
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Script_Name.ps1")
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
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh" | sudo bash
#     For scripts with parameters: curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh" | sudo bash -s "parameter1" "parameter2"
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

Purpose text is each script's own synopsis. `windows/experimental/` is not a deployable check or task.

### Windows (.ps1)

**Exit codes**: 0 success, 1001 warning, 1002 critical, unless that script's header says otherwise.

#### Checks (windows/checks/)

| Script | Purpose | Exit |
| --- | --- | --- |
| `Check_AI_Stack.ps1` | Checks the Windows AI Stack installed by Install_AI_Stack.ps1. | — |
| `Check_All_Local_Users_Are_Administrators.ps1` | Checks that every local user except built-in Guest is an Administrator. | — |
| `Check_Applied_Policies.ps1` | List all Group Policy Objects (GPOs) applied to the computer. | — |
| `Check_Brother_MFC-L5750DW.ps1` | Check if Brother MFC-L5750DW printer is installed and ready. | — |
| `Check_Chrome_Default_Browser.ps1` | Check if Google Chrome is the default browser on Windows 10/11. | — |
| `Check_Chrome_Installed.ps1` | Checks whether Google Chrome is installed and runnable for all users. | — |
| `Check_ComputerName_Inventory.ps1` | Check if the computer name starts with "IA" (Inventory Asset naming convention). | — |
| `Check_Edge_Blocked.ps1` | Check if Microsoft Edge is blocked and Chrome is set as default. | — |
| `Check_Edge_Installed.ps1` | Check if Microsoft Edge is installed on the system. | — |
| `Check_GCPW_Registry.ps1` | Checks and repairs GCPW registry configuration. | — |
| `Check_GoogleDrive_Installed.ps1` | Checks whether Google Drive for desktop is installed and runnable. | — |
| `Check_HEVC_Installed.ps1` | Check if HEVC/MOV (e.g. iPhone video) playback is available on Windows. | Exit 0 = Success (HEVC/MOV playback available); Exit 1002 = Critical (no HEVC decoder or player found) |
| `Check_Hibernate_Enabled.ps1` | Checks whether hibernate is enabled on this ThinkPad (companion to Restore_Hibernate_ThinkPad.ps1). | Exit 0 = PASS (hibernate enabled); Exit 1001 = WARNING (hibernate disabled); Exit 1002 = CRITICAL (could not read state) |
| `Check_Hibernate_LidClose.ps1` | Verifies hibernate is enabled (and visible) and lid-close power actions match policy (Do Nothing on AC, Sleep on battery). | Exit 0 = PASS (hibernate enabled; lid does nothing on AC, sleeps on battery); Exit 1001 = WARNING (one or more settings have drifted from policy); Exit 1002 = CRITICAL (could not read power/registry state) |
| `Check_HP_SleepBlockers.ps1` | Check if HP/print services known to block sleep are stopped and disabled. | — |
| `Check_McAfee_Installed.ps1` | Checks if McAfee products are installed on the system. | Exit 0 = McAfee NOT installed (OK); Exit 1001 = McAfee IS installed (Warning) |
| `Check_OneDrive_Edge_Copilot_Removed.ps1` | Checks that OneDrive, Microsoft Edge, and Copilot are removed. | — |
| `Check_OpenSSH.ps1` | Check if OpenSSH Server is installed and running. | — |
| `Check_PendingReboot.ps1` | Detect whether Windows has a pending restart (updates, CBS, rename, etc.). | — |
| `Check_PowerShell_v2_Disabled.ps1` | Check if PowerShell v2 Windows feature is disabled. | — |
| `Check_ScreenLock_Timeout.ps1` | Check if screen lock timeout is set correctly (3 min battery, 8 min AC). | — |
| `Check_Slack_Installed.ps1` | Check if Slack is installed on the system. | — |
| `Check_Sofortarzt.ps1` | Checks if a specific website was visited across all major browsers. | Exit 0 = Success (Not visited); Exit 1002 = Critical/Error (Visited) |
| `Check_Tailscale_Installed.ps1` | Check if Tailscale VPN is installed and (optionally) running. | — |
| `Check_Tailscale_Not_Installed.ps1` | Check that Tailscale VPN is not installed (compliance / removal verification). | — |
| `Check_Tailscale_Performance.ps1` | Checks if network performance optimizations for Tailscale are applied. | — |
| `Check_TakeControl_Health.ps1` | Check N-sight Take Control (BASupSrvc) service health status. | — |
| `Check_Twingate_Installed.ps1` | Checks whether Twingate and .NET Desktop Runtime 8.0.29 x64 are installed. | — |
| `Check_WindowsUpdate_Bandwidth.ps1` | Check whether Windows Update (Delivery Optimization) bandwidth is capped to 1MB/s up/down. | — |

#### Tasks (windows/tasks/)

| Script | Purpose |
| --- | --- |
| `Add_All_Local_Users_To_Administrators.ps1` | Adds every local user except the built-in Guest account to Administrators. |
| `Block_Edge.ps1` | Block Microsoft Edge via policy (light) so the readiness check passes. |
| `Enforce_Chrome_Default_Browser.ps1` | Enforce Google Chrome as the default browser on Windows 10/11. |
| `Fix_AdobeCreativeCloud_Loading.ps1` | Remediates Adobe Creative Cloud installer or app stuck on infinite loading. |
| `Fix_GCPW_SignIn_Allowed.ps1` | Removes stale GCPW enrollment policy that blocks an allowed Google account. |
| `Fix_HP_SleepBlockers.ps1` | Stop and disable HP/print services that prevent the machine from sleeping. |
| `Get_Chrome_GaiaAccountEmail.ps1` | Reads Chrome Default profile Preferences and outputs the Google account email from gaia_cookie data. |
| `Install_AdobeAcrobatPro.ps1` | Install Adobe Acrobat Pro DC (Windows) via winget. |
| `Install_AdobeCreativeCloud.ps1` | Installs the Adobe Creative Cloud desktop app (the Creative Cloud “suite” hub; bootstrapper, silent). |
| `Install_AI_Code_CLIs.ps1` | Install Claude Code, OpenAI Codex, and Google Gemini CLI via winget and npm. |
| `Install_AI_Stack.ps1` | Silently installs the Windows AI Stack for N-Sight. |
| `Install_BitdefenderAgent.ps1` | Download and silently install the Bitdefender GravityZone Windows agent (setup downloader). |
| `Install_Brother_MFC-L5750DW.ps1` | Install and configure Brother MFC-L5750DW network printer. |
| `Install_Chrome.ps1` | Installs Chrome, makes it the default browser, pins it for new profiles, and blocks Edge updates. |
| `Install_ClaudeDesktop.ps1` | Install Anthropic Claude Desktop (Windows) using the full MSIX package. |
| `Install_Dropbox.ps1` | Install Dropbox desktop app for all users (enterprise MSI, silent). |
| `Install_GCPW.ps1` | Installs Google Credential Provider for Windows (GCPW). |
| `Install_GoogleDrive.ps1` | Install Google Drive for Desktop for all users. |
| `Install_HEVC_Codec.ps1` | Install HEVC (H.265) codec so Windows can play iPhone MOV / HEVC video files. |
| `Install_OpenSSH.ps1` | Install OpenSSH Server and ensure the sshd service is running. |
| `Install_Slack.ps1` | Install Slack for Desktop for all users. |
| `Install_Surfshark.ps1` | Install Surfshark VPN for Windows (silent/unattended). |
| `Install_Tailscale.ps1` | Install Tailscale VPN client (silent/unattended). |
| `Install_Twingate.ps1` | Installs Twingate and .NET Desktop Runtime 8.0.29 x64 for all users. |
| `Limit_WindowsUpdate_Bandwidth.ps1` | Cap Windows Update (Delivery Optimization) bandwidth to 1MB/s up and down. |
| `Optimize-TailscalePerformance.ps1` | Optimizes network performance for Tailscale on Windows endpoints. |
| `Pin_Onboarding_Apps.ps1` | Public desktop shortcuts and one taskbar pin list for Chrome, Slack, Drive, Twingate, Claude, and ChatGPT. |
| `Refresh_N-Sight_Agent.ps1` | Refresh N-Sight agent, TakeControl, and background checks. First and last line of defense. |
| `Register_RebootReminder.ps1` | Register (or remove) a per-user scheduled task that runs Show_RebootReminder.ps1 at logon and every 4 hours. |
| `Remediate_BitLocker.ps1` | Enable BitLocker on the system drive (C:) and ensure recovery key is backed up and printed. |
| `Remediate_Disable_BuiltIn_Administrator.ps1` | Disables the built-in local Administrator account (SID ending in -500). |
| `Remediate_GCPW_Token_Expiration_1Year.ps1` | Fixes Google Credential Provider for Windows (GCPW) token expiration issues that break Windows Hello (PIN/fingerprint) login. |
| `Remediate_Hibernate_LidClose.ps1` | Enables hibernate (visible in the Start menu power flyout) and sets lid-close behavior: do nothing on AC power, sleep on battery. |
| `Remediate_Lenovo_ThinkPad_AMD_Sleep.ps1` | Applies sleep/black-screen mitigations for Lenovo ThinkPad P14s Gen 6 AMD (Ryzen AI 350) class devices on Windows 11 Pro. |
| `Remediate_ScreenLock_Timeout.ps1` | Configure screen lock timeout to meet security policy (3 min battery, 8 min AC). |
| `Remove_Edge.ps1` | Keep Edge out of the way: remove shortcuts and prevent it from being default browser. |
| `Remove_McAfee.ps1` | Remove pre-installed McAfee from Windows (new PCs / OEM installs). |
| `Remove_OneDrive.ps1` | Remove Microsoft OneDrive from Windows 11 completely (for environments using Google Drive). |
| `Remove_OneDrive_Edge_Copilot.ps1` | Removes OneDrive, Microsoft Edge browser, and Microsoft Copilot. |
| `Remove_Tailscale.ps1` | Remove Tailscale VPN silently, including services, uninstall, and leftover folders. |
| `Remove_TeamViewer.ps1` | Remove TeamViewer from Windows and clean leftover services, tasks, folders, and registry. |
| `Remove_Twingate.ps1` | Remove the Twingate client silently, including services, tasks, folders, and registry entries. |
| `Remove_Windows_Consumer_Bloat.ps1` | Removes consumer Windows apps from a business laptop. |
| `Rename_Computer.ps1` | Rename a Windows computer to a new hostname. |
| `Restore_Hibernate_ThinkPad.ps1` | Restores proper sleep + hibernate behavior on Lenovo ThinkPad devices (reverts Remediate_Lenovo_ThinkPad_AMD_Sleep.ps1). |
| `Run_Onboarding_From_GitHub.cmd` | Elevated launcher for Run_Onboarding_Tasks.ps1 from GitHub |
| `Run_Onboarding_Tasks.ps1` | Slack, hibernate, and screen lock overlap McAfee. msiexec/winget tasks run one at a time after McAfee. |
| `Show_RebootReminder.ps1` | If a restart is pending, prompt the user to reboot or snooze reminders for 4 hours. |
| `Unblock_Edge.ps1` | Unblock Microsoft Edge (reverses Block_Edge.ps1 script). |

#### Experimental (windows/experimental/)

| Script | Purpose |
| --- | --- |
| `Test-VpnConnectivity.ps1` | Tests VPN connectivity by checking access to a specific internal/VPN-protected resource. |

### Linux (.sh)

#### Checks (linux/checks/)

| Script | Purpose | Exit |
| --- | --- | --- |
| `Check_Desktop_Environment.sh` | Detect and report the desktop environment (DE) on the system. DESCRIPTION: This monitoring script identifies the desktop environment for inventory and compli... | — |
| `Check_Disk_Encryption.sh` | Report whether detected disks and partitions are LUKS-encrypted. DESCRIPTION: Uses lsblk FSTYPE and, when present, cryptsetup isLuks. Does not modify disks.... | 0 = OK (every detected disk/partition is LUKS); 1001 = WARNING (mixed encrypted and plaintext); 1002 = CRITICAL (lsblk missing, or no encrypted device found); Linux (repo): curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Disk_Encryption.sh" / sudo bash; Version: 1.0; ENCRYPTED_DEVICES=0; UNENCRYPTED_DEVICES=0; exit 1002; DEVICES=$(lsblk -rno NAME,TYPE / awk '$2 == "part" // $2 == "disk" {print $1}'); FSTYPE=$(lsblk -rno FSTYPE "$DEV_PATH" 2>/dev/null); ENCRYPTED_DEVICES=$((ENCRYPTED_DEVICES + 1)); if cryptsetup isLuks "$DEV_PATH" 2>/dev/null; then; ENCRYPTED_DEVICES=$((ENCRYPTED_DEVICES + 1)); UNENCRYPTED_DEVICES=$((UNENCRYPTED_DEVICES + 1)); UNENCRYPTED_DEVICES=$((UNENCRYPTED_DEVICES + 1)); if [ "$ENCRYPTED_DEVICES" -gt 0 ] && [ "$UNENCRYPTED_DEVICES" -eq 0 ]; then; exit 0; elif [ "$ENCRYPTED_DEVICES" -gt 0 ] && [ "$UNENCRYPTED_DEVICES" -gt 0 ]; then; exit 1001; exit 1002 |
| `Check_Hostname_Inventory_linux.sh` | Checks for proper hostname naming convention compliance. DESCRIPTION: This monitoring script checks if the hostname follows the inventory naming convention (... | 0 = OK (Hostname starts with IA); 2 = CRITICAL (Hostname does NOT start with IA); Linux (repo): curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Hostname_Inventory_linux.sh" / sudo bash; Version: 1.0; local level="${2:-INFO}"; echo "[$timestamp] [$level] $1" / tee -a "$LOG_FILE" 2>/dev/null; HOSTNAME_SHORT=$(hostname -s 2>/dev/null // hostname); HOSTNAME_FQDN=$(hostname -f 2>/dev/null // echo "N/A"); HOSTNAME_FILE=$(cat /etc/hostname 2>/dev/null // echo "N/A"); local hostname="$1"; local prefix="$2"; return 0; return 1; DISTRO=$(cat /etc/os-release 2>/dev/null / grep "^PRETTY_NAME" / cut -d'"' -f2 // echo "Unknown"); exit 0; exit 2 |
| `Check_Linux_Daemons.sh` | Check health status of common Linux system daemons. DESCRIPTION: This monitoring script verifies the health of Linux system services: - D-Bus activated servi... | 0 = PASS (All services healthy or expected inactive); 1 = WARNING (Some services need attention); 2 = CRITICAL (Services failed or missing); Linux (repo): curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Linux_Daemons.sh" / sudo bash; Version: 1.0; Platform: Fedora 38+, RHEL 8+, CentOS Stream 8+; readonly SCRIPT_VERSION="1.0"; CRITICAL_COUNT=0; WARNING_COUNT=0; PASS_COUNT=0; local level="${2:-INFO}"; local message="[$timestamp] [$level] $1"; ERROR) echo -e "\033[31m${message}\033[0m" ;;; WARN) echo -e "\033[33m${message}\033[0m" ;;; SUCCESS) echo -e "\033[32m${message}\033[0m" ;;; echo "$message" >> "$LOG_FILE" 2>/dev/null; if [[ $EUID -ne 0 ]]; then; exit 2; exit 2; version=$(cat /etc/redhat-release / grep -oP '\d+' / head -1); local service="$1"; unit_file_state=$(systemctl list-unit-files "$service" 2>/dev/null / grep "$service" / awk '{print $2}'); active_state=$(systemctl show "$service" --property=ActiveState --value 2>/dev/null); load_state=$(systemctl show "$service" --property=LoadState --value 2>/dev/null); sub_state=$(systemctl show "$service" --property=SubState --value 2>/dev/null); local service="$1"; local service_type="$2"; return 0; return 0; return 0; return 0; return 0; return 0; return 0; return 1; local service="$1"; failures=$(journalctl --since "7 days ago" -p err -u "*.service" --no-pager 2>/dev/null / \; if [[ "$failures" -gt 0 ]]; then; log "Found $failures error log entries for monitored services in last 7 days" "WARN"; return 1; return 0; printf "%-40s %-12s %-50s\n" "SERVICE" "STATUS" "MESSAGE"; printf "%-40s %-12s %-50s\n" "-------" "------" "-------"; "PASS") status_display="\033[32m[PASS]\033[0m" ;;; "WARNING") status_display="\033[33m[WARN]\033[0m" ;;; "CRITICAL") status_display="\033[31m[FAIL]\033[0m" ;;; printf "%-40s " "$service"; printf " %-50s\n" "$message"; mkdir -p "$LOG_DIR" 2>/dev/null; if [[ $CRITICAL_COUNT -gt 0 ]]; then; echo -e "\033[31mFAIL: $CRITICAL_COUNT critical issue(s) detected\033[0m"; echo "1. Run the Remediate_Linux_Daemons.sh script"; echo "2. Check journalctl -xe for detailed error messages"; echo "3. Verify package installation with: dnf list installed / grep <package>"; exit 2; elif [[ $WARNING_COUNT -gt 0 ]]; then; echo -e "\033[33mWARNING: $WARNING_COUNT issue(s) may need attention\033[0m"; echo "1. Run remediation script to attempt automatic fixes"; echo "2. Review systemctl status <service> for details"; exit 1; echo -e "\033[32mPASS: All daemon services are healthy\033[0m"; exit 0 |
| `Check_Linux_Memory.sh` | Check system memory usage with threshold alerts. DESCRIPTION: Calculates actual memory usage (excluding buffers/cache) and reports status based on configurab... | 0 = OK (Memory usage below 90%); 1 = WARNING (Memory usage 90-94%); 2 = CRITICAL (Memory usage 95%+); Linux (repo): curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Linux_Memory.sh" / sudo bash; Version: 1.1; mem_total=$(grep MemTotal /proc/meminfo / awk '{print $2}'); mem_free=$(grep MemFree /proc/meminfo / awk '{print $2}'); buffers=$(grep Buffers /proc/meminfo / awk '{print $2}'); cached=$(grep -w Cached /proc/meminfo / awk '{print $2}'); percent=$((used * 100 / mem_total)); if [ "$percent" -ge 95 ]; then; exit 2; elif [ "$percent" -ge 90 ]; then; exit 1; exit 0 |

#### Tasks (linux/tasks/)

| Script | Purpose |
| --- | --- |
| `Install_Chrome_linux.sh` | Ensures flatpak + flathub remote, installs com.google.Chrome (system-wide). Pins .desktop + /usr/local/bin wrapper so app drawer / CLI work without re-login.... |
| `Install_Fleetd_linux.sh` | install and enroll Fleet Desktop agent |
| `Install_N-Sight_Support_Linux.sh` | Installs requirements for N-Sight RMM support (logging, disk health, SSH). DESCRIPTION: Installs and configures the following for N-Sight RMM monitoring: - r... |
| `Remediate_Core_Platform_Services.sh` | Install, repair, and add systemd self-heal (restart on failure) for common platform services: cron, cups-browsed, kernel oops reporting, rsyslog, smartmontoo... |
| `Remediate_Disk_Performance.sh` | Fix disk performance monitoring for N-sight agent. DESCRIPTION: - Installs sysstat, smartmontools, nvme-cli - Enables sysstat collection - Seeds initial perf... |
| `Remediate_DisplayLink.sh` | Optimize Ubuntu system for DisplayLink dock performance. DESCRIPTION: - Installs TLP and power management tools - Sets power profile to performance - Configu... |
| `Remediate_Fedora_Scheduled_Maintenance.sh` | Install and enable periodic maintenance on Fedora: SMART monitoring, automatic updates (equivalent to Debian unattended-upgrades), and cron. DESCRIPTION: For... |
| `Remediate_Fprintd.sh` | Fix fprintd (fingerprint daemon) service issues on Fedora. DESCRIPTION: fprintd is a D-Bus activated service for fingerprint reader support. It's NORMAL for... |
| `Remediate_Fwupd.sh` | Diagnose and fix fwupd service issues. DESCRIPTION: - Checks if fwupd is installed - Installs if missing - Restarts service if not active - Attempts reinstal... |
| `Remediate_Getty_TTY2.sh` | Diagnose and fix getty@tty2 service issues. DESCRIPTION: - Checks getty@tty2 service status - Restarts if not active - Re-enables if restart fails EXECUTION:... |
| `Remediate_Hostname_Linux.sh` | Set system hostname on Linux (systemd-based). DESCRIPTION: - Validates hostname format (letters, numbers, dots, hyphens) - Sets hostname via hostnamectl - Up... |
| `Remediate_Linux_Daemons.sh` | Automatically diagnose and fix common Linux daemon service issues. DESCRIPTION: This remediation script addresses common Linux daemon problems including: - D... |
| `Remediate_Nvidia_Persistenced.sh` | Diagnose and fix NVIDIA persistenced service and driver issues. DESCRIPTION: - Checks for NVIDIA GPU hardware - Installs missing packages - Attempts driver r... |
| `Remediate_Systemd_Services.sh` | Fix systemd core services (hostnamed, localed, timedated) on Fedora. DESCRIPTION: These are D-Bus activated services that provide: - systemd-hostnamed: hostn... |
| `Remediate_Virtqemud.sh` | Fix virtqemud (QEMU virtualization daemon) service on Fedora. DESCRIPTION: virtqemud is a socket-activated service that provides QEMU/KVM virtualization supp... |

### macOS (.sh)

#### Checks (macos/checks/)

| Script | Purpose | Exit |
| --- | --- | --- |
| `Check_AppleID_Status.sh` | Check if Apple ID is logged in and Find My is active on macOS. Designed for deployment via N-Sight RMM. DESCRIPTION: This script checks the Apple ID login st... | — |
| `Check_Chrome_Default_Browser.sh` | Checks if Google Chrome is configured as the system default browser on macOS. Verifies URL scheme handlers and file type associations. DESCRIPTION: This moni... | — |
| `Check_Chrome_Installed.sh` | Checks for Google Chrome installation on macOS and reports: - Installation status (installed/not installed) - Chrome version if installed - Installation path... | — |
| `Check_GoogleDrive_Installed.sh` | Checks for Google Drive installation on macOS and reports: - Installation status (installed/not installed) - Google Drive version and path if installed Adds... | — |
| `Check_Handoff_Disabled_mac.sh` | Confirms Handoff is off for each local user by reading com.apple.coreservices.useractivityd preferences. DESCRIPTION: Handoff uses ActivityAdvertisingAllowed... | — |
| `Check_Homebrew_Path_mac.sh` | Verifies Homebrew exists at a standard prefix and that /etc/paths.d exposes its bin directory (so root and non-login tools resolve `brew`). DESCRIPTION: N-si... | — |
| `Check_Hostname_Inventory_mac.sh` | Checks for proper hostname naming convention compliance on macOS. DESCRIPTION: This monitoring script checks if the hostname follows the inventory naming con... | — |
| `Check_Mac_RMM_Agent_Refresh.sh` | Clears stuck automated tasks, syncs with the dashboard, and queues 24x7, DSC, and asset scans — same behavior as the former task script. DESCRIPTION: Intende... | — |
| `Check_Mac_RMM_Agent_SelfHeal.sh` | 24x7-style check: verifies rmmagentd is present and running; optionally recycles the LaunchDaemon and runs a dashboard sync when unhealthy. DESCRIPTION: N-si... | — |
| `Check_macOS_Security.sh` | Checks critical macOS security settings: - System Integrity Protection (SIP) enabled - Gatekeeper enabled - No unsigned kernel extensions loaded DESCRIPTION:... | — |
| `Check_Safari_Default_Browser.sh` | Checks if Safari is set as the default browser on macOS. Designed to trigger remediation if Safari is still active/default. DESCRIPTION: This monitoring scri... | — |
| `Check_Slack_Installed.sh` | Check if Slack is installed on macOS | — |
| `Check_Slack_Upgrade_Ready.sh` | Check if Slack can be automatically upgraded on macOS. Designed for deployment via N-Sight RMM. DESCRIPTION: Verifies that Slack is installed and can be upgr... | — |
| `Check_TakeControl_Viewer_Installed.sh` | Checks for Take Control Viewer for RMM installation on macOS and reports: - Installation status (installed/not installed) - Take Control Viewer version if in... | — |
| `Check_Twingate_Installed.sh` | Checks for Twingate installation on macOS and reports: - Installation status (installed/not installed) - Twingate version if installed - Installation path an... | — |

#### Tasks (macos/tasks/)

| Script | Purpose |
| --- | --- |
| `Install_Canva_mac.sh` | Install_Canva_mac.sh — Canva.app to /Applications (official ARM64 DMG). |
| `Install_Chrome_mac.sh` | Downloads and installs Google Chrome browser on macOS for ALL USERS. DESCRIPTION: This remediation script installs Google Chrome when the check script report... |
| `Install_ClaudeDesktop_mac.sh` | Install_ClaudeDesktop_mac.sh — Claude.app to /Applications (official universal zip). |
| `Install_DisplayLink_mac.sh` | Downloads and installs DisplayLink Manager on macOS for ALL USERS. DESCRIPTION: This remediation script installs DisplayLink Manager for USB docking station... |
| `Install_Dropbox_mac.sh` | Downloads and installs Dropbox for macOS using the enterprise PKG from Dropbox Help (Install Dropbox for all team members). DESCRIPTION: Remediation script f... |
| `Install_GoogleDrive_mac.sh` | Downloads and installs Google Drive for Desktop on macOS for ALL USERS. DESCRIPTION: This remediation script installs Google Drive when the check script repo... |
| `Install_Slack_mac.sh` | Install Slack for macOS (/Applications) |
| `Install_Tailscale_mac.sh` | Downloads and installs Tailscale VPN client on macOS for ALL USERS. Specifically designed for macOS 12.x (Monterey) and later. DESCRIPTION: This remediation... |
| `Refresh_RMM_Agent_mac.sh` | Refresh_RMM_Agent_mac.sh — compatibility wrapper (logic lives in checks/) |
| `Reinstall_MSP_Anywhere_mac.sh` | Reinstalls the N-Sight MSP Anywhere agent on macOS WITHOUT breaking the current remote terminal/SSH session. Self-copies to /tmp first. DESCRIPTION: Self-rel... |
| `Remediate_Disable_Handoff_mac.sh` | Sets Handoff off for each local user, then verifies preferences. DESCRIPTION: Idempotent: if Handoff is already disabled for all users, exits OK without chan... |
| `Remediate_Homebrew_Path_mac.sh` | Writes /etc/paths.d/homebrew so path_helper includes Homebrew for all users and typical root/non-interactive sessions. DESCRIPTION: Idempotent: if the file a... |
| `Remediate_SSH_And_Admin_User_mac.sh` | Enable Remote Login (SSH), create a user with password "1111", and add the user to the admin group (sudo rights). DESCRIPTION: - Enables Remote Login (SSH) v... |
| `Rename_Hostname_mac.sh` | Rename macOS hostname to a specified name. DESCRIPTION: This script renames the macOS hostname by setting: - ComputerName: The "friendly" name shown in Finde... |
| `Restart_TakeControl_Agent_mac.sh` | Restarts the N-Sight TakeControl (MSP Anywhere) agent process on macOS WITHOUT reinstalling — preserving all existing macOS TCC permissions (Screen Recording... |
| `Run_Onboarding_Tasks_mac.sh` | Sequentially downloads and executes all essential macOS onboarding scripts straight from the repository for a smooth, single-click setup. DESCRIPTION: This i... |
| `Scalefusion_PreInstall_NSight_Israel.sh` | Writes settings.ini to /tmp before Scalefusion runs Install.pkg DESCRIPTION: Upload this as the Pre-Install Script in Scalefusion PKG deployment. Runs before... |
| `Set_Chrome_Default_Browser_mac.sh` | Sets Google Chrome as the system-wide default browser for HTTP/HTTPS URLs and HTML files on macOS. DESCRIPTION: This script sets Chrome as the default browse... |
| `Upgrade_Slack_mac.sh` | Upgrade Slack to the latest version on macOS without user interaction. Designed for deployment via N-Sight RMM. DESCRIPTION: Downloads and installs the lates... |

---
## Quick Reference Card

### Execution by platform


| Platform                | Run command                                                                                                                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Windows (local)**     | `iex (Get-Content ".\ScriptName.ps1" -Raw)` or `powershell -NoProfile -ExecutionPolicy Bypass -File ".\ScriptName.ps1"`                                                                                            |
| **Windows (from repo)** | `iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/ScriptName.ps1")` — every task must include this in .EXECUTION and log to `C:\logs\<date>`                              |
| **Linux**               | `sudo bash /path/to/script.sh` or `bash /path/to/script.sh` (as root when required)                                                                                                                                |
| **macOS (local)**       | `sudo bash /path/to/script.sh` or `bash /path/to/script.sh` (as root when required)                                                                                                                                |
| **macOS (from repo)**   | `curl -fsSL "[https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh](https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Script_Name_mac.sh)" |


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

*Last Updated: September 2026*