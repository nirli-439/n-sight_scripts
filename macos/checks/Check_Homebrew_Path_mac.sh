#!/usr/bin/env bash
# =============================================================================
# Check_Homebrew_Path_mac.sh - Homebrew install + system PATH (paths.d)
# =============================================================================
#
# SYNOPSIS:
#     Verifies Homebrew exists at a standard prefix and that /etc/paths.d
#     exposes its bin directory (so root and non-login tools resolve `brew`).
#
# DESCRIPTION:
#     N-sight scripts often run as root with a minimal PATH. Homebrew defaults
#     to /opt/homebrew (Apple Silicon) or /usr/local (Intel). Without an entry
#     in /etc/paths.d, `brew` may be missing in automated sessions even when
#     installed for interactive shells.
#
# EXIT CODES:
#     0    = OK (brew found and paths.d lists its bin directory)
#     1001 = WARNING (brew found but paths.d missing or wrong line)
#     1002 = CRITICAL (brew missing or brew --version failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Homebrew_Path_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Homebrew_Path_mac.sh" | sudo bash
#
# NOTES:
#     Pair with macos/tasks/Remediate_Homebrew_Path_mac.sh for remediation.
#
# REFERENCES:
#     N-able Script Writing Guidelines:
#     https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Check Homebrew Path"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/CheckHomebrewPath_$(date +%Y%m%d_%H%M%S).log"
readonly PATHS_D_FILE="/etc/paths.d/homebrew"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

write_summary() {
    echo ""
    echo "${1}: ${2}"
}

# Prints absolute path to brew executable, or nothing
resolve_brew_executable() {
    local c
    if [[ -n "${HOMEBREW_PREFIX:-}" && -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
        echo "${HOMEBREW_PREFIX}/bin/brew"
        return 0
    fi
    for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Returns 0 if paths.d file contains exact bin directory line
paths_d_lists_bin() {
    local bin_dir="$1"
    [[ -f "$PATHS_D_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ "$line" == "$bin_dir" ]] && return 0
    done <"$PATHS_D_FILE"
    return 1
}

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "Hostname: $(hostname)"
log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
log "Architecture: $(uname -m)"
log "=========================================="

brew_exe=""
if ! brew_exe=$(resolve_brew_executable); then
    log "Homebrew brew executable not found in standard locations" "WARNING"
    write_summary "CRITICAL" "Homebrew not found (expected /opt/homebrew/bin/brew or /usr/local/bin/brew)"
    echo "Install from https://brew.sh or set HOMEBREW_PREFIX if using a custom prefix."
    echo "Remediation: Remediate_Homebrew_Path_mac.sh only adds PATH after brew exists."
    exit $EXIT_CRITICAL
fi

brew_bin_dir=$(dirname "$brew_exe")
log "Resolved brew: $brew_exe"
log "Bin directory: $brew_bin_dir"

ver_out=""
if ! ver_out=$("$brew_exe" --version 2>&1); then
    log "brew --version failed: $ver_out" "ERROR"
    write_summary "CRITICAL" "brew exists but --version failed (permissions or broken install)"
    echo "$ver_out"
    exit $EXIT_CRITICAL
fi

log "brew --version: $(echo "$ver_out" | head -1)"

if paths_d_lists_bin "$brew_bin_dir"; then
    write_summary "OK" "Homebrew OK; ${PATHS_D_FILE} includes ${brew_bin_dir}"
    echo "brew: $brew_exe"
    echo "$(echo "$ver_out" | head -3)"
    exit $EXIT_SUCCESS
fi

log "${PATHS_D_FILE} missing or does not include ${brew_bin_dir}" "WARNING"
write_summary "WARNING" "Homebrew present but system PATH entry missing; run Remediate_Homebrew_Path_mac.sh"
echo "brew: $brew_exe"
echo "Expected a line '${brew_bin_dir}' in ${PATHS_D_FILE} (used by path_helper for login shells and many tools)."
echo "$(echo "$ver_out" | head -3)"
exit $EXIT_WARNING
