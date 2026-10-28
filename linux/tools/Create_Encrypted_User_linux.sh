#!/usr/bin/env bash
# =============================================================================
# Create_Encrypted_User_linux.sh - Create a sudo user with an eCryptfs-encrypted home
# =============================================================================
#
# SYNOPSIS:
#     Interactive technician tool: asks for a username, creates the user with
#     today's date as the initial password, adds it to the sudo group,
#     encrypts its home folder with eCryptfs and saves the recovery
#     (mount) passphrase to a text file.
#
# DESCRIPTION:
#     1. Prompts for the new username (validated, must not already exist).
#     2. Initial password = today's date as DDMMYY (e.g. 28-10-2026 -> 281026).
#     3. Installs ecryptfs-utils, rsync, lsof if missing (apt).
#     4. Creates the user (useradd -m, bash shell), sets the password,
#        adds the user to the "sudo" group.
#     5. Encrypts the (new, empty) home with ecryptfs-migrate-home, passing
#        the login password via LOGINPASS so no second prompt appears.
#     6. Verifies the setup, removes the temporary cleartext copy
#        (/home/<user>.XXXXXXXX - only the skeleton files of a new user).
#     7. Unwraps the mount passphrase and writes it to:
#            <admin home>/Documents/keys/<user>_ecryptfs_passphrase.txt
#        where <admin> is the account that ran sudo (chmod 600). It is
#        kept OUTSIDE the new user's home on purpose: a copy inside the
#        encrypted home could not help recover that home.
#     8. Optionally forces a password change at first login.
#
#     NOT an N-Sight Automation Manager task: it prompts for input, so it
#     must be run by a technician in a terminal (or over SSH / Take Control).
#
#     Ubuntu / Debian only. Fedora no longer ships ecryptfs-utils - use LUKS
#     there (see linux/tasks/Encrypt_LUKS2_In_Place.sh).
#     Vendor docs: https://manpages.ubuntu.com/manpages/noble/man1/ecryptfs-migrate-home.8.html
#                  https://manpages.ubuntu.com/manpages/noble/man1/ecryptfs-unwrap-passphrase.1.html
#
# EXIT CODES:
#     0    = Success (user created, home encrypted, passphrase saved)
#     1001 = Warning (user created and encrypted, but a post-step failed,
#            e.g. passphrase file could not be written - read the output)
#     1002 = Critical (not root, unsupported OS, invalid input, user exists,
#            package install failed, or encryption failed)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Create_Encrypted_User_linux.sh
#     Linux (repo):   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/tools/Create_Encrypted_User_linux.sh)"
#     (Use the bash -c form, not "curl | sudo bash" - the script needs the
#      keyboard for its prompts.)
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Changelog: 1.0 - Initial version.
#     Requires: Root privileges (sudo), interactive terminal
#     Platform: Ubuntu 22.04+ / Debian 12+
#     Security: the date-based password is predictable - keep "force change
#               at first login" on unless you have a reason not to.
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_VERSION="1.0"
readonly SUDO_GROUP="sudo"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

WARNINGS=()

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
    command -v apt-get >/dev/null 2>&1 || \
        die "This tool supports Ubuntu/Debian only (eCryptfs is not available on Fedora - use LUKS)."
}

install_deps() {
    local missing=()
    command -v ecryptfs-migrate-home >/dev/null 2>&1 || missing+=(ecryptfs-utils)
    command -v rsync >/dev/null 2>&1 || missing+=(rsync)
    command -v lsof  >/dev/null 2>&1 || missing+=(lsof)
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || \
            die "apt-get install ${missing[*]} failed."
    fi
    modprobe ecryptfs 2>/dev/null || die "Could not load the ecryptfs kernel module."
    ok "eCryptfs tools ready"
}

ask_username() {
    local name
    while true; do
        read -r -p "New username: " name
        name="${name,,}"   # lower-case
        if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            echo "    Invalid name. Use lower-case letters, digits, - or _ (start with a letter, max 32)."
            continue
        fi
        if id "$name" >/dev/null 2>&1; then
            echo "    User '$name' already exists. Pick another name."
            continue
        fi
        NEW_USER="$name"
        break
    done
}

ask_yes_no() {   # $1 = question, $2 = default (y/n)
    local ans def="${2:-y}" hint="[Y/n]"
    [[ "$def" == "n" ]] && hint="[y/N]"
    read -r -p "$1 $hint " ans
    ans="${ans:-$def}"
    [[ "${ans,,}" == y* ]]
}

# =============================================================================
# MAIN
# =============================================================================
check_root
check_tty
check_os

echo "=== Create encrypted user (v${SCRIPT_VERSION}) ==="
ask_username

TODAY_LONG=$(date +%d-%m-%Y)
NEW_PASS=$(date +%d%m%y)

echo ""
echo "  Username : $NEW_USER"
echo "  Password : $NEW_PASS   (today: $TODAY_LONG)"
echo "  Groups   : $SUDO_GROUP"
echo "  Home     : /home/$NEW_USER  (eCryptfs encrypted)"
echo ""
FORCE_CHANGE=0
ask_yes_no "Force a password change at first login?" y && FORCE_CHANGE=1
ask_yes_no "Continue?" y || die "Cancelled by technician."

install_deps

# --- 1. Create user -----------------------------------------------------------
useradd -m -s /bin/bash -c "$NEW_USER" "$NEW_USER" || die "useradd failed for $NEW_USER."
printf '%s:%s\n' "$NEW_USER" "$NEW_PASS" | chpasswd || { userdel -r "$NEW_USER" 2>/dev/null; die "Setting the password failed."; }
usermod -aG "$SUDO_GROUP" "$NEW_USER" || warn "Could not add $NEW_USER to $SUDO_GROUP."
ok "User $NEW_USER created and added to $SUDO_GROUP"

# --- 2. Encrypt home -----------------------------------------------------------
info "Encrypting /home/$NEW_USER ..."
MIGRATE_LOG=$(mktemp)
if ! LOGINPASS="$NEW_PASS" ecryptfs-migrate-home -u "$NEW_USER" >"$MIGRATE_LOG" 2>&1; then
    cat "$MIGRATE_LOG"; rm -f "$MIGRATE_LOG"
    die "ecryptfs-migrate-home failed. User $NEW_USER exists but the home is NOT encrypted (remove with: sudo userdel -r $NEW_USER)."
fi
rm -f "$MIGRATE_LOG"

WRAPPED="/home/.ecryptfs/${NEW_USER}/.ecryptfs/wrapped-passphrase"
[[ -f "$WRAPPED" ]] || die "Encryption ran but $WRAPPED is missing - check the system before using this account."
ok "Home folder encrypted"

if command -v ecryptfs-verify >/dev/null 2>&1; then
    ecryptfs-verify -h -u "$NEW_USER" >/dev/null 2>&1 && ok "ecryptfs-verify: OK" || warn "ecryptfs-verify reported a problem - test a login before rebooting."
fi

# Temporary cleartext copy made by the migration (new user = only skeleton files)
for d in /home/"${NEW_USER}".????????; do
    [[ -d "$d" ]] || continue
    rm -rf -- "$d" && ok "Removed temporary cleartext copy $d"
done

# --- 3. Recover and save the mount passphrase -----------------------------------
MOUNT_PASS=$(printf '%s' "$NEW_PASS" | ecryptfs-unwrap-passphrase "$WRAPPED" - 2>/dev/null)
if [[ -z "$MOUNT_PASS" ]]; then
    warn "Could not unwrap the passphrase. Run later as $NEW_USER: ecryptfs-unwrap-passphrase"
else
    KEY_OWNER="${SUDO_USER:-root}"
    OWNER_HOME=$(getent passwd "$KEY_OWNER" | cut -d: -f6)
    KEY_DIR="${OWNER_HOME}/Documents/keys"
    KEY_FILE="${KEY_DIR}/${NEW_USER}_ecryptfs_passphrase.txt"

    umask 077
    if mkdir -p "$KEY_DIR" && cat > "$KEY_FILE" <<EOF
eCryptfs recovery passphrase
----------------------------
Host      : $(hostname)
User      : ${NEW_USER}
Created   : $(date '+%Y-%m-%d %H:%M')
Mount passphrase:
${MOUNT_PASS}

Recover data (from a live USB or another admin account):
  sudo ecryptfs-recover-private /home/.ecryptfs/${NEW_USER}/.Private
EOF
    then
        chown -R "$KEY_OWNER": "$KEY_DIR" 2>/dev/null
        chmod 700 "$KEY_DIR"; chmod 600 "$KEY_FILE"
        ok "Passphrase saved to $KEY_FILE"
    else
        warn "Could not write $KEY_FILE"
    fi
fi
unset MOUNT_PASS

# --- 4. First-login password change -----------------------------------------
if [[ $FORCE_CHANGE -eq 1 ]]; then
    chage -d 0 "$NEW_USER" && ok "Password change required at first login" || warn "chage -d 0 failed."
fi

# --- Summary -------------------------------------------------------------------
echo ""
if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    echo "OK: User $NEW_USER created (sudo), home encrypted, passphrase saved."
    RC=$EXIT_SUCCESS
else
    echo "WARNING: User $NEW_USER created and encrypted, with ${#WARNINGS[@]} warning(s):"
    printf '  - %s\n' "${WARNINGS[@]}"
    RC=$EXIT_WARNING
fi
echo ""
echo "  Login     : $NEW_USER / $NEW_PASS"
echo "  NEXT STEP : log in as $NEW_USER once BEFORE rebooting and confirm the desktop loads."
echo "  Tip       : encrypt swap too (sudo ecryptfs-setup-swap) so keys never land on disk."
exit $RC
