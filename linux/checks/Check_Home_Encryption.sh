#!/usr/bin/env bash
# =============================================================================
# Check_Home_Encryption.sh - Home folder encryption check for N-sight RMM
# =============================================================================
#
# SYNOPSIS:
#     Report whether interactive users' home directories are encrypted.
#
# DESCRIPTION:
#     Checks two independent home-folder encryption methods and treats a
#     user as protected if either applies:
#       1. eCryptfs per-user home encryption - Ubuntu's classic "Encrypt my
#          home folder" installer option (ecryptfs-utils). Detected via an
#          active ecryptfs mount at the user's home path.
#       2. LUKS whole-volume encryption that happens to back /home - common
#          on Fedora, or Ubuntu installs that used full-disk/LVM encryption
#          at install time. Detected by walking the block device backing
#          the /home mountpoint up through its LVM/mapper parents and
#          checking FSTYPE / cryptsetup isLuks for crypto_LUKS.
#     Only interactive users (UID 1000-59999, with a real shell and an
#     existing home directory) are evaluated; system/service accounts are
#     skipped. The shared local account "user" (EXCLUDED_USERS) is skipped
#     too - every OTHER user must be encrypted.
#     An eCryptfs home counts as encrypted whether it is mounted (user
#     logged in) or locked (user logged out). Does not modify disks,
#     mounts, or user accounts.
#
#     Optional --show-keys: also prints the .txt files in
#     /home/user/Documents/keys (where Create_Encrypted_User_linux.sh saves
#     the eCryptfs recovery passphrases) so they are escrowed in N-Sight.
#     WARNING: the passphrases then appear in the N-Sight check output and
#     history - anyone with dashboard access can read them.
#
#     Companion script: Check_Disk_Encryption.sh checks whole-disk LUKS
#     status generally; this script is specifically about whether each
#     user's HOME directory is covered.
#
# EXIT CODES:
#     0    = OK (at least one user other than "user" exists, and ALL of
#              them have an encrypted home - eCryptfs or LUKS-backed /home)
#     1002 = CRITICAL (no users other than "user" found, OR any of them has
#              an unencrypted home, OR required tools such as lsblk are
#              missing)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Home_Encryption.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Home_Encryption.sh" | sudo bash
#     With keys:      curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Home_Encryption.sh" | sudo bash -s -- --show-keys
#     N-Sight:        add  --show-keys  in the script's Parameters field.
#
# NOTES:
#     Author: IT Admin
#     Version: 1.2
#     Changelog: 1.2 - Add --show-keys to print /home/user/Documents/keys/*.txt.
#     Changelog: 1.1 - Skip the "user" account; FAIL when no other users exist
#                      or any is unencrypted (no more WARNING); treat a locked
#                      (logged-out) eCryptfs home as encrypted; status first line.
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+, Ubuntu 22.04+ (universal; eCryptfs detection is
#               primarily relevant on Ubuntu, LUKS detection applies to both)
#
# =============================================================================

set -o pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_CRITICAL=1002

# Accounts that are NOT checked (shared local login)
readonly EXCLUDED_USERS=("user")

# --show-keys: print recovery-key text files from this folder
readonly KEYS_DIR="/home/user/Documents/keys"
readonly KEYS_MAX_CHARS=6000      # keep total output under N-Sight's 10,000 limit
SHOW_KEYS=false
for arg in "$@"; do
    case "$arg" in
        --show-keys|-k) SHOW_KEYS=true ;;
    esac
done

print_keys() {
    echo ""
    echo "--- Recovery keys (${KEYS_DIR}) ---"
    if [[ ! -d "$KEYS_DIR" ]]; then
        echo "Folder not found (or /home/user is encrypted and locked)."
        return
    fi
    local f found=0 out=""
    while IFS= read -r -d '' f; do
        found=$((found + 1))
        out+="### $(basename "$f") ($(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null))"$'\n'
        out+="$(tr -d '\r' < "$f" 2>/dev/null || echo '(unreadable)')"$'\n\n'
    done < <(find "$KEYS_DIR" -maxdepth 1 -type f -iname '*.txt' -print0 2>/dev/null | sort -z)
    if [[ $found -eq 0 ]]; then
        echo "No .txt files found."
        return
    fi
    echo "Files: $found"
    if [[ ${#out} -gt $KEYS_MAX_CHARS ]]; then
        printf '%s\n' "${out:0:$KEYS_MAX_CHARS}"
        echo "... (truncated at ${KEYS_MAX_CHARS} chars - read the rest on the device)"
    else
        printf '%s' "$out"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "CRITICAL: Root privileges required (sudo) to read mount/LUKS metadata reliably."
        exit $EXIT_CRITICAL
    fi
}

get_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "${NAME:-Unknown} ${VERSION_ID:-}"
    else
        echo "Unknown"
    fi
}

get_pkg_mgr() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    else
        echo ""
    fi
}

check_root

PKG_MGR=$(get_pkg_mgr)
if [[ -z "$PKG_MGR" ]]; then
    echo "CRITICAL: Unsupported distro (need Fedora or Ubuntu)."
    exit $EXIT_CRITICAL
fi

if ! command -v lsblk &>/dev/null; then
    echo "CRITICAL: lsblk not found. Cannot determine encryption status."
    exit $EXIT_CRITICAL
fi

CRYPTSETUP_AVAILABLE=false
command -v cryptsetup &>/dev/null && CRYPTSETUP_AVAILABLE=true

# ---------------------------------------------------------------------------
# Method 1: is /home itself backed by a LUKS-encrypted block device?
# Walks LVM/mapper devices up to their physical parent(s) looking for LUKS.
# ---------------------------------------------------------------------------
home_is_luks() {
    local mnt_target src pk fstype seen=""

    mnt_target=$(df --output=target /home 2>/dev/null | tail -1)
    [[ -z "$mnt_target" ]] && mnt_target="/"

    if command -v findmnt &>/dev/null; then
        src=$(findmnt -no SOURCE --target "$mnt_target" 2>/dev/null)
    else
        src=$(df --output=source "$mnt_target" 2>/dev/null | tail -1)
    fi
    [[ -z "$src" ]] && return 1

    while [[ -n "$src" ]]; do
        # guard against any pathological parent loop
        case " $seen " in *" $src "*) break ;; esac
        seen+=" $src"

        fstype=$(lsblk -rno FSTYPE "$src" 2>/dev/null | head -1)
        if echo "$fstype" | grep -qi "crypto_LUKS"; then
            return 0
        fi
        if $CRYPTSETUP_AVAILABLE && cryptsetup isLuks "$src" 2>/dev/null; then
            return 0
        fi

        pk=$(lsblk -rno PKNAME "$src" 2>/dev/null | head -1)
        [[ -z "$pk" ]] && break
        src="/dev/$pk"
    done
    return 1
}

HOME_LUKS=false
if home_is_luks; then
    HOME_LUKS=true
fi

# ---------------------------------------------------------------------------
# Method 2: per-user eCryptfs-encrypted home (Ubuntu "Encrypt my home folder")
# Only evaluated per-user when /home is not already LUKS-covered as a whole.
# ---------------------------------------------------------------------------
ENCRYPTED_USERS=0
UNENCRYPTED_USERS=0
TOTAL_USERS=0
OUTPUT=""
SKIPPED=""
UNENCRYPTED_NAMES=""

is_excluded() {
    local u
    for u in "${EXCLUDED_USERS[@]}"; do
        [[ "$1" == "$u" ]] && return 0
    done
    return 1
}

while IFS=: read -r uname _ uid _ _ uhome ushell; do
    [[ "$uid" -lt 1000 || "$uid" -ge 60000 ]] && continue
    [[ "$ushell" == */nologin || "$ushell" == */false || -z "$ushell" ]] && continue
    [[ ! -d "$uhome" ]] && continue
    if is_excluded "$uname"; then
        SKIPPED+="${uname} "
        continue
    fi

    TOTAL_USERS=$((TOTAL_USERS + 1))

    if $HOME_LUKS; then
        OUTPUT+="ENCRYPTED (LUKS, whole /home): ${uname} (${uhome})\n"
        ENCRYPTED_USERS=$((ENCRYPTED_USERS + 1))
        continue
    fi

    if mount | grep -qE "on ${uhome} type ecryptfs"; then
        OUTPUT+="ENCRYPTED (eCryptfs, mounted): ${uname} (${uhome})\n"
        ENCRYPTED_USERS=$((ENCRYPTED_USERS + 1))
    elif [[ -d "/home/.ecryptfs/${uname}/.Private" && -f "/home/.ecryptfs/${uname}/.ecryptfs/wrapped-passphrase" ]]; then
        # Logged out: eCryptfs is set up, data sits encrypted in .Private
        OUTPUT+="ENCRYPTED (eCryptfs, locked): ${uname} (${uhome})\n"
        ENCRYPTED_USERS=$((ENCRYPTED_USERS + 1))
    else
        OUTPUT+="NOT ENCRYPTED: ${uname} (${uhome})\n"
        UNENCRYPTED_USERS=$((UNENCRYPTED_USERS + 1))
        UNENCRYPTED_NAMES+="${uname} "
    fi
done < /etc/passwd

if [[ "$TOTAL_USERS" -eq 0 ]]; then
    STATUS="CRITICAL: No users found other than \"${EXCLUDED_USERS[*]}\" - nothing to verify."
    RC=$EXIT_CRITICAL
elif [[ "$UNENCRYPTED_USERS" -gt 0 ]]; then
    STATUS="CRITICAL: ${UNENCRYPTED_USERS}/${TOTAL_USERS} user home(s) NOT encrypted: ${UNENCRYPTED_NAMES% }"
    RC=$EXIT_CRITICAL
else
    STATUS="OK: All ${TOTAL_USERS} user home(s) encrypted."
    RC=$EXIT_SUCCESS
fi

echo "$STATUS"
echo "--- Home Folder Encryption Status ($(get_distro)) ---"
echo -e "$OUTPUT"
if $HOME_LUKS; then
    echo "Method: LUKS (whole /home volume)"
else
    echo "Method: per-user eCryptfs"
fi
echo "Skipped (excluded): ${SKIPPED% }"
echo "Users checked: $TOTAL_USERS | Encrypted: $ENCRYPTED_USERS | Not encrypted: $UNENCRYPTED_USERS"
$SHOW_KEYS && print_keys
exit $RC
