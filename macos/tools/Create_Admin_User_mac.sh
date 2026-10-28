#!/usr/bin/env bash
# =============================================================================
# Create_Admin_User_mac.sh - Onboarding: create an admin user ready for Claude Cowork
# =============================================================================
#
# SYNOPSIS:
#     Interactive technician tool for new Macs: asks for a username, creates
#     a local admin with today's date as the initial password, and gives it
#     the rights Claude Cowork / Claude Code need to work unattended
#     (install apps, run sudo without a prompt, use developer tools).
#
# DESCRIPTION:
#     1. Prompts for the username (validated, must not already exist) and
#        an optional full name.
#     2. Initial password = today's date as DDMMYY (e.g. 28-10-2026 -> 281026).
#     3. Creates the user with sysadminctl (-admin), builds the home folder.
#     4. Passwordless sudo: /etc/sudoers.d/<user> with NOPASSWD: ALL,
#        validated with visudo before it is kept (so Claude can run
#        installer / brew / launchctl / softwareupdate without a prompt).
#     5. Developer access: adds the user to _developer and runs
#        DevToolsSecurity -enable (no auth prompts for debuggers/compilers).
#     6. SecureToken + FileVault: asks for the technician's (current admin)
#        password and grants the new user a SecureToken, so it can unlock
#        FileVault, install system extensions and approve software updates.
#     7. Optionally forces a password change at first login.
#
#     What a script CANNOT grant (Apple requires the user or an MDM profile):
#     Accessibility, Screen Recording, Full Disk Access and the Cowork
#     virtualization prompt. Approve those on first launch of Claude, or push
#     a PPPC profile (see macos/profiles/).
#
#     NOT an N-Sight Automation Manager task: it prompts for input, so it
#     must be run by a technician in Terminal (or over Take Control / SSH).
#     Vendor docs: man sysadminctl, man dseditgroup, man DevToolsSecurity,
#                  https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web
#
# EXIT CODES:
#     0    = Success (user created with all rights)
#     1001 = Warning (user created, but a post-step failed - e.g. no
#            SecureToken or sudoers file - read the output)
#     1002 = Critical (not root, no terminal, invalid input, user exists,
#            or user creation failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Create_Admin_User_mac.sh
#     macOS (repo):   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tools/Create_Admin_User_mac.sh)"
#     (Use the bash -c form, not "curl | sudo bash" - the script needs the
#      keyboard for its prompts.)
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Changelog: 1.0 - Initial version (based on linux/tools/Create_Encrypted_User_linux.sh).
#     Requires: Root privileges (sudo), interactive terminal
#     Platform: macOS 12+ (Intel and Apple Silicon); bash 3.2 compatible
#     Security: NOPASSWD sudo = full root for this account without a
#               password, and the date-based password is predictable.
#               Keep "force change at first login" on.
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_VERSION="1.0"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

WARNINGS=()
NEW_USER=""
FULL_NAME=""

# =============================================================================
# FUNCTIONS
# =============================================================================
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; WARNINGS+=("$*"); }
die()   { echo ""; echo "CRITICAL: $*"; exit $EXIT_CRITICAL; }

check_root() {
    [[ $EUID -eq 0 ]] || die "Root privileges required. Run with: sudo bash $0"
}

check_tty() {
    [[ -t 0 ]] || die "No interactive terminal. Run with: sudo bash $0 (not via curl | bash or RMM)."
}

check_os() {
    [[ "$(uname -s)" == "Darwin" ]] || die "This tool is for macOS only."
    command -v sysadminctl >/dev/null 2>&1 || die "sysadminctl not found (macOS 10.13+ required)."
}

ask_username() {
    local name
    while true; do
        read -r -p "New username (short name): " name
        name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        if [[ ! "$name" =~ ^[a-z_][a-z0-9_.-]{0,30}$ ]]; then
            echo "    Invalid name. Use lower-case letters, digits, . - or _ (start with a letter, max 31)."
            continue
        fi
        if id "$name" >/dev/null 2>&1 || [[ -e "/Users/$name" ]]; then
            echo "    User or folder '$name' already exists. Pick another name."
            continue
        fi
        NEW_USER="$name"
        break
    done
    read -r -p "Full name [${NEW_USER}]: " FULL_NAME
    FULL_NAME="${FULL_NAME:-$NEW_USER}"
}

ask_yes_no() {   # $1 = question, $2 = default (y/n)
    local ans def="${2:-y}" hint="[Y/n]"
    [[ "$def" == "n" ]] && hint="[y/N]"
    read -r -p "$1 $hint " ans
    ans=$(printf '%s' "${ans:-$def}" | tr '[:upper:]' '[:lower:]')
    [[ "$ans" == y* ]]
}

has_token() {   # $1 = user
    sysadminctl -secureTokenStatus "$1" 2>&1 | grep -q "ENABLED"
}

# =============================================================================
# MAIN
# =============================================================================
check_root
check_tty
check_os

echo "=== Create admin user for Claude Cowork (v${SCRIPT_VERSION}) ==="
ask_username

TODAY_LONG=$(date +%d-%m-%Y)
NEW_PASS=$(date +%d%m%y)
TECH_USER="${SUDO_USER:-}"

echo ""
echo "  Username  : $NEW_USER  ($FULL_NAME)"
echo "  Password  : $NEW_PASS   (today: $TODAY_LONG)"
echo "  Groups    : admin, _developer"
echo "  Sudo      : passwordless (/etc/sudoers.d/$NEW_USER)"
echo "  Token     : SecureToken from ${TECH_USER:-<no sudo user - skipped>}"
echo ""
FORCE_CHANGE=0
ask_yes_no "Force a password change at first login?" y && FORCE_CHANGE=1
ask_yes_no "Continue?" y || die "Cancelled by technician."

# --- 1. Create user -----------------------------------------------------------
info "Creating $NEW_USER ..."
sysadminctl -addUser "$NEW_USER" -fullName "$FULL_NAME" -password "$NEW_PASS" \
    -home "/Users/$NEW_USER" -shell /bin/zsh -admin >/dev/null 2>&1
id "$NEW_USER" >/dev/null 2>&1 || die "sysadminctl -addUser failed for $NEW_USER."

[[ -d "/Users/$NEW_USER" ]] || createhomedir -c -u "$NEW_USER" >/dev/null 2>&1
[[ -d "/Users/$NEW_USER" ]] || warn "Home folder /Users/$NEW_USER was not created - it will be built at first login."

dseditgroup -o checkmember -m "$NEW_USER" admin >/dev/null 2>&1 || \
    dseditgroup -o edit -a "$NEW_USER" -t user admin >/dev/null 2>&1
if dseditgroup -o checkmember -m "$NEW_USER" admin >/dev/null 2>&1; then
    ok "User $NEW_USER created (admin)"
else
    warn "User created but NOT in the admin group."
fi

# --- 2. Passwordless sudo ------------------------------------------------------
SUDOERS_FILE="/etc/sudoers.d/$NEW_USER"
TMP_SUDO=$(mktemp)
printf '# Created by Create_Admin_User_mac.sh %s - Claude Cowork unattended sudo\n%s ALL=(ALL) NOPASSWD: ALL\n' \
    "$(date '+%Y-%m-%d')" "$NEW_USER" > "$TMP_SUDO"
if visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
    mkdir -p /etc/sudoers.d
    install -m 0440 -o root -g wheel "$TMP_SUDO" "$SUDOERS_FILE" && ok "Passwordless sudo: $SUDOERS_FILE" \
        || warn "Could not write $SUDOERS_FILE"
    # Make sure /etc/sudoers actually reads the drop-in folder
    grep -Eq '^[#@]includedir[[:space:]]+/private/etc/sudoers.d|^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers || \
        warn "/etc/sudoers has no includedir for sudoers.d - passwordless sudo will not apply."
else
    warn "Generated sudoers line failed visudo validation - skipped."
fi
rm -f "$TMP_SUDO"

# --- 3. Developer tools ---------------------------------------------------------
dseditgroup -o edit -a "$NEW_USER" -t user _developer >/dev/null 2>&1 && ok "Added to _developer" \
    || warn "Could not add $NEW_USER to _developer."
DevToolsSecurity -enable >/dev/null 2>&1 && ok "Developer mode enabled (DevToolsSecurity)" \
    || warn "DevToolsSecurity -enable failed."

# --- 4. SecureToken / FileVault --------------------------------------------------
if has_token "$NEW_USER"; then
    ok "SecureToken already enabled for $NEW_USER"
elif [[ -z "$TECH_USER" || "$TECH_USER" == "root" ]]; then
    warn "No technician account (run with sudo from an admin) - SecureToken not granted."
elif ! has_token "$TECH_USER"; then
    warn "$TECH_USER has no SecureToken, so it cannot grant one. Grant later from a token holder: sysadminctl -secureTokenOn $NEW_USER -password - -adminUser <admin> -adminPassword -"
else
    echo ""
    echo "Granting SecureToken (needed for FileVault unlock and software updates)."
    echo "Enter the password of YOUR account ($TECH_USER) when asked:"
    sysadminctl -secureTokenOn "$NEW_USER" -password "$NEW_PASS" \
        -adminUser "$TECH_USER" -adminPassword - 2>/dev/null
    if has_token "$NEW_USER"; then
        ok "SecureToken granted to $NEW_USER"
        if fdesetup isactive >/dev/null 2>&1; then
            fdesetup list 2>/dev/null | grep -q "^${NEW_USER}," && ok "$NEW_USER can unlock FileVault" \
                || warn "FileVault is on but $NEW_USER is not listed in fdesetup - check System Settings > Privacy & Security."
        fi
    else
        warn "SecureToken was NOT granted (wrong password?). Retry: sudo sysadminctl -secureTokenOn $NEW_USER -password - -adminUser $TECH_USER -adminPassword -"
    fi
fi

# --- 5. First-login password change ------------------------------------------
if [[ $FORCE_CHANGE -eq 1 ]]; then
    pwpolicy -u "$NEW_USER" -setpolicy "newPasswordRequired=1" >/dev/null 2>&1 \
        && ok "Password change required at first login" \
        || warn "Could not set newPasswordRequired."
fi

# --- 6. Verify ---------------------------------------------------------------------
if sudo -n -l -U "$NEW_USER" 2>/dev/null | grep -q "NOPASSWD: ALL"; then
    ok "Verified: $NEW_USER can run sudo without a password"
else
    warn "sudo check did not show NOPASSWD for $NEW_USER."
fi

# --- Summary -------------------------------------------------------------------
echo ""
if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    echo "OK: User $NEW_USER created (admin, NOPASSWD sudo, developer, SecureToken)."
    RC=$EXIT_SUCCESS
else
    echo "WARNING: User $NEW_USER created with ${#WARNINGS[@]} warning(s):"
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
    RC=$EXIT_WARNING
fi
echo ""
echo "  Login     : $NEW_USER / $NEW_PASS"
echo "  NEXT STEPS: 1. Log in as $NEW_USER (change the password if asked)."
echo "              2. Install Claude (macos/tasks/Install_ClaudeDesktop_mac.sh) and open Cowork."
echo "              3. Approve the macOS prompts Claude asks for (Accessibility,"
echo "                 Screen Recording, Files & Folders) - scripts cannot grant these."
exit $RC
