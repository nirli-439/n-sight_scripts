#!/bin/bash
# Check_Disk_Encryption.sh - LUKS presence check for N-sight RMM
#
# SYNOPSIS:
#     Report whether detected disks and partitions are LUKS-encrypted.
#
# DESCRIPTION:
#     Uses lsblk FSTYPE and, when present, cryptsetup isLuks. Does not modify disks.
#
#     Optional --show-keys: also prints the .txt files in any
#     /home/*/Documents/keys folder (where Create_Encrypted_User_linux.sh
#     saves the eCryptfs recovery passphrases, in the home of whichever
#     admin ran it) so they are escrowed in N-Sight.
#     WARNING: the passphrases then appear in the N-Sight check output and
#     history - anyone with dashboard access can read them.
#
#     Exit Codes:
#     - 0 = OK (every detected disk/partition is LUKS, OR no LUKS but
#               eCryptfs-encrypted user homes are present)
#     - 1001 = WARNING (mixed encrypted and plaintext)
#     - 1002 = CRITICAL (lsblk missing, or no encryption of any kind found)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Disk_Encryption.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Disk_Encryption.sh" | sudo bash
#     With keys:      curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Disk_Encryption.sh" | sudo bash -s -- --show-keys
#     N-Sight:        add  --show-keys  in the script's Parameters field.
#
# NOTES:
#     Author: IT Admin
#     Version: 1.2
#     Changelog: 1.2 - Count eCryptfs-encrypted homes as encrypted when no
#                      LUKS exists (fleet uses home-folder encryption only).
#     Changelog: 1.1 - Add --show-keys to print /home/*/Documents/keys/*.txt.
#     Platform: Linux (Ubuntu/Fedora)

ENCRYPTED_DEVICES=0
UNENCRYPTED_DEVICES=0
OUTPUT=""

# --show-keys: print recovery-key text files from any admin's keys folder
readonly KEYS_GLOB="/home/*/Documents/keys"
readonly KEYS_MAX_CHARS=6000      # keep total output under N-Sight's 10,000 limit
SHOW_KEYS=false
for arg in "$@"; do
    case "$arg" in
        --show-keys|-k) SHOW_KEYS=true ;;
    esac
done

print_keys() {
    echo ""
    echo "--- Recovery keys (${KEYS_GLOB}) ---"
    local f found=0 out=""
    while IFS= read -r -d '' f; do
        found=$((found + 1))
        out+="### ${f} ($(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null))"$'\n'
        out+="$(tr -d '\r' < "$f" 2>/dev/null || echo '(unreadable)')"$'\n\n'
    done < <(find $KEYS_GLOB -maxdepth 1 -type f -iname '*.txt' -print0 2>/dev/null | sort -z)
    if [[ $found -eq 0 ]]; then
        echo "No .txt files found (or the keys folder is in an encrypted, locked home)."
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

if ! command -v lsblk &>/dev/null; then
    echo "CRITICAL: lsblk not found. Cannot determine encryption status."
    exit 1002
fi

CRYPTSETUP_AVAILABLE=false
if command -v cryptsetup &>/dev/null; then
    CRYPTSETUP_AVAILABLE=true
fi

DEVICES=$(lsblk -rno NAME,TYPE | awk '$2 == "part" || $2 == "disk" {print $1}')

for DEV in $DEVICES; do
    DEV_PATH="/dev/$DEV"
    FSTYPE=$(lsblk -rno FSTYPE "$DEV_PATH" 2>/dev/null)

    if echo "$FSTYPE" | grep -qi "crypto_LUKS"; then
        OUTPUT+="ENCRYPTED (LUKS): $DEV_PATH\n"
        ENCRYPTED_DEVICES=$((ENCRYPTED_DEVICES + 1))
    else
        if $CRYPTSETUP_AVAILABLE; then
            if cryptsetup isLuks "$DEV_PATH" 2>/dev/null; then
                OUTPUT+="ENCRYPTED (LUKS): $DEV_PATH\n"
                ENCRYPTED_DEVICES=$((ENCRYPTED_DEVICES + 1))
            else
                OUTPUT+="NOT ENCRYPTED: $DEV_PATH\n"
                UNENCRYPTED_DEVICES=$((UNENCRYPTED_DEVICES + 1))
            fi
        else
            OUTPUT+="NOT ENCRYPTED (cryptsetup unavailable for deep check): $DEV_PATH\n"
            UNENCRYPTED_DEVICES=$((UNENCRYPTED_DEVICES + 1))
        fi
    fi
done

echo "--- Disk Encryption Status ---"
echo -e "$OUTPUT"
echo "Encrypted devices: $ENCRYPTED_DEVICES"
echo "Unencrypted devices: $UNENCRYPTED_DEVICES"

# eCryptfs home encryption (this fleet's method): active mounts or locked .Private dirs
ECRYPTFS_HOMES=$(( $(mount | grep -c " type ecryptfs") + $(ls -d /home/.ecryptfs/*/.Private 2>/dev/null | wc -l) ))

if [ "$ENCRYPTED_DEVICES" -gt 0 ] && [ "$UNENCRYPTED_DEVICES" -eq 0 ]; then
    echo "OK: All detected devices are encrypted."
    RC=0
elif [ "$ENCRYPTED_DEVICES" -gt 0 ] && [ "$UNENCRYPTED_DEVICES" -gt 0 ]; then
    echo "WARNING: Mixed encryption; some devices are not encrypted."
    RC=1001
elif [ "$ECRYPTFS_HOMES" -gt 0 ]; then
    echo "OK: No LUKS, but $ECRYPTFS_HOMES eCryptfs-encrypted home(s) present."
    RC=0
else
    echo "CRITICAL: No encryption detected (no LUKS devices, no eCryptfs homes)."
    RC=1002
fi
$SHOW_KEYS && print_keys
exit $RC
