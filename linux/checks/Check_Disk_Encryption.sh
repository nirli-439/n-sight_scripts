#!/bin/bash
# Check_Disk_Encryption.sh - LUKS presence check for N-sight RMM
#
# SYNOPSIS:
#     Report whether detected disks and partitions are LUKS-encrypted.
#
# DESCRIPTION:
#     Uses lsblk FSTYPE and, when present, cryptsetup isLuks. Does not modify disks.
#
#     Exit Codes:
#     - 0 = OK (every detected disk/partition is LUKS)
#     - 1001 = WARNING (mixed encrypted and plaintext)
#     - 1002 = CRITICAL (lsblk missing, or no encrypted device found)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Disk_Encryption.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Disk_Encryption.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Platform: Linux (Ubuntu/Fedora)

ENCRYPTED_DEVICES=0
UNENCRYPTED_DEVICES=0
OUTPUT=""

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

if [ "$ENCRYPTED_DEVICES" -gt 0 ] && [ "$UNENCRYPTED_DEVICES" -eq 0 ]; then
    echo "OK: All detected devices are encrypted."
    exit 0
elif [ "$ENCRYPTED_DEVICES" -gt 0 ] && [ "$UNENCRYPTED_DEVICES" -gt 0 ]; then
    echo "WARNING: Mixed encryption; some devices are not encrypted."
    exit 1001
else
    echo "CRITICAL: No encrypted devices detected."
    exit 1002
fi
