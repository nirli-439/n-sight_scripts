#!/bin/bash
# Encrypt_LUKS2_In_Place.sh - N-Sight Linux automated task
#
# Usage:
#   encrypt: TARGET=/dev/nvme0n1p3 MODE=encrypt
#   keyslot: TARGET=/dev/nvme0n1p3 MODE=add-key CURRENT_KEY_FILE=/root/current-luks-key
#
# encrypt requires an unmounted target and 32 MiB unused at its end.
# add-key requires an existing LUKS device and a root-readable file containing
# an existing passphrase. N-Sight output intentionally contains the new key.

set -euo pipefail

SUCCESS=1001
FAILURE=1002
TARGET=${TARGET:-${1:-}}
MODE=${MODE:-encrypt}
CURRENT_KEY_FILE=${CURRENT_KEY_FILE:-}
HOST=$(hostname -s)
NEW_KEY_FILE=

fail() { echo "CRITICAL: $*"; exit "$FAILURE"; }
cleanup() { [ -z "$NEW_KEY_FILE" ] || rm -f "$NEW_KEY_FILE"; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || fail "Run as root."
[ -n "$TARGET" ] || fail "Set TARGET to the partition to encrypt."
[ -b "$TARGET" ] || fail "$TARGET is not a block device."
command -v cryptsetup >/dev/null 2>&1 || fail "cryptsetup is not installed."
command -v openssl >/dev/null 2>&1 || fail "openssl is not installed."

is_luks=0
cryptsetup isLuks "$TARGET" >/dev/null 2>&1 && is_luks=1

case "$MODE" in
  encrypt)
    [ "$is_luks" -eq 0 ] || { echo "OK: $TARGET is already LUKS-encrypted; skipped."; exit "$SUCCESS"; }
    findmnt -rn -S "$TARGET" >/dev/null 2>&1 && fail "$TARGET is mounted; offline conversion is required."
    while read -r child; do
      [ "$child" = "$TARGET" ] && continue
      findmnt -rn -S "$child" >/dev/null 2>&1 && fail "$child is mounted; offline conversion is required."
    done < <(lsblk -nrpo NAME "$TARGET")
    ;;
  add-key)
    [ "$is_luks" -eq 1 ] || fail "$TARGET is not LUKS-encrypted; use MODE=encrypt."
    [ -r "$CURRENT_KEY_FILE" ] || fail "Set CURRENT_KEY_FILE to a root-readable existing LUKS passphrase file."
    ;;
  *) fail "MODE must be encrypt or add-key." ;;
esac

NEW_KEY_FILE=$(mktemp /run/luks-recovery.XXXXXX)
chmod 600 "$NEW_KEY_FILE"
openssl rand -base64 48 > "$NEW_KEY_FILE"

if [ "$MODE" = encrypt ]; then
  cryptsetup reencrypt --encrypt --type luks2 --batch-mode \
    --reduce-device-size 32M --key-file "$NEW_KEY_FILE" "$TARGET" || fail "Encryption failed."
else
  cryptsetup luksAddKey "$TARGET" "$NEW_KEY_FILE" \
    --key-file "$CURRENT_KEY_FILE" --batch-mode || fail "Adding the key slot failed."
fi

echo "RECOVERY_KEY_FOR_${HOST}: $(<"$NEW_KEY_FILE")"
echo "OK: $TARGET $MODE completed."
exit "$SUCCESS"
