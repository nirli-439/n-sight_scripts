#!/usr/bin/env bash
# =============================================================================
# Remediate_Homebrew_Path_mac.sh - Add Homebrew bin to system PATH (paths.d)
# =============================================================================
#
# SYNOPSIS:
#     Writes /etc/paths.d/homebrew so path_helper includes Homebrew for all
#     users and typical root/non-interactive sessions.
#
# DESCRIPTION:
#     Idempotent: if the file already contains the correct bin directory line,
#     exits OK without changes. Does not install Homebrew; install via
#     https://brew.sh first (or ensure brew exists under a standard prefix).
#
# EXIT CODES:
#     0    = OK (paths.d correct or updated successfully)
#     1001 = WARNING (brew not found; nothing to configure)
#     1002 = CRITICAL (not root, or write/verify failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Remediate_Homebrew_Path_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Remediate_Homebrew_Path_mac.sh" | sudo bash
#
# NOTES:
#     Requires root. Pair with macos/checks/Check_Homebrew_Path_mac.sh.
#
# REFERENCES:
#     N-able Script Writing Guidelines:
#     https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Remediate Homebrew Path"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/RemediateHomebrewPath_$(date +%Y%m%d_%H%M%S).log"
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "Root required" "ERROR"
        write_summary "CRITICAL" "Run as root (sudo)"
        exit $EXIT_CRITICAL
    fi
}

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
check_root

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "Hostname: $(hostname)"
log "=========================================="

brew_exe=""
if ! brew_exe=$(resolve_brew_executable); then
    log "brew not found; cannot create paths.d entry" "WARNING"
    write_summary "WARNING" "Homebrew not installed at /opt/homebrew or /usr/local; install first (https://brew.sh)"
    exit $EXIT_WARNING
fi

brew_bin_dir=$(dirname "$brew_exe")
log "Using brew: $brew_exe -> bin dir $brew_bin_dir"

if paths_d_lists_bin "$brew_bin_dir"; then
    write_summary "OK" "Already configured: ${PATHS_D_FILE} contains ${brew_bin_dir}"
    exit $EXIT_SUCCESS
fi

if ! printf '%s\n' "$brew_bin_dir" >"$PATHS_D_FILE.tmp.$$"; then
    log "Failed to write temp file" "ERROR"
    write_summary "CRITICAL" "Could not write temp paths.d file"
    exit $EXIT_CRITICAL
fi

if ! mv "$PATHS_D_FILE.tmp.$$" "$PATHS_D_FILE"; then
    log "Failed to move into ${PATHS_D_FILE}" "ERROR"
    rm -f "$PATHS_D_FILE.tmp.$$" 2>/dev/null || true
    write_summary "CRITICAL" "Could not update ${PATHS_D_FILE}"
    exit $EXIT_CRITICAL
fi

chmod 644 "$PATHS_D_FILE" 2>/dev/null || true
chown root:wheel "$PATHS_D_FILE" 2>/dev/null || true

if ! paths_d_lists_bin "$brew_bin_dir"; then
    write_summary "CRITICAL" "Updated file but verification failed"
    exit $EXIT_CRITICAL
fi

if ! "$brew_exe" --version >/dev/null 2>&1; then
    log "brew --version failed after paths.d update" "ERROR"
    write_summary "CRITICAL" "paths.d updated but brew --version failed"
    exit $EXIT_CRITICAL
fi

write_summary "OK" "Wrote ${PATHS_D_FILE} with ${brew_bin_dir}"
log "New sessions inherit PATH via path_helper; re-run check to confirm."
exit $EXIT_SUCCESS
