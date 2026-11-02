#!/usr/bin/env bash
# =============================================================================
# Remediate_Hostname_Linux.sh - Rename system hostname (N-Sight RMM)
# =============================================================================
#
# SYNOPSIS:
#     Set the system hostname on Linux (Ubuntu / Fedora, systemd-based).
#
# DESCRIPTION:
#     - Takes the new name from $1 or the NEW_HOSTNAME env var (N-Sight)
#     - Validates format (RFC 1123: letters, digits, hyphens, max 63 chars)
#     - Sets static + pretty hostname via hostnamectl
#     - Ensures /etc/hosts has "127.0.1.1 <name>" (avoids sudo
#       "unable to resolve host" on Ubuntu) and drops the old name
#     - Idempotent: exits OK without changes if already set
#
# USAGE:
#     sudo bash Remediate_Hostname_Linux.sh IA-119
#     N-Sight: script parameter "IA-119" (or env NEW_HOSTNAME=IA-119)
#
# EXIT CODES (N-Sight):
#     0    = OK (renamed, or already correct)
#     1001 = WARNING (renamed but /etc/hosts or verification mismatch)
#     1002 = CRITICAL (not root, missing/invalid name, hostnamectl failed)
#
# EXECUTION:
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/tasks/Remediate_Hostname_Linux.sh" | sudo bash -s "IA-119"
#     Linux (local):  sudo bash /path/to/Remediate_Hostname_Linux.sh IA-119
#
# NOTES:
#     Version: 1.1
#     Platform: Ubuntu 22.04+, Fedora 38+ (systemd)
#     Requires: root
#     Changelog:
#       1.1 - NEW_HOSTNAME env support, idempotent, 127.0.1.1 hosts entry,
#             pretty hostname, status-first output, fixed repo one-liner
#       1.0 - Initial version
#
# =============================================================================

set -uo pipefail

readonly SCRIPT_VERSION="1.1"
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002
readonly HOSTS_FILE="/etc/hosts"

# --- Input: parameter wins, then env var; strip whitespace ---
NEW_HOSTNAME="${1:-${NEW_HOSTNAME:-}}"
NEW_HOSTNAME="$(printf '%s' "$NEW_HOSTNAME" | tr -d '[:space:]')"

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
  echo "CRITICAL: Must run as root (sudo)."
  exit $EXIT_CRITICAL
fi

if [[ -z "$NEW_HOSTNAME" ]]; then
  echo "CRITICAL: No hostname supplied. Usage: $0 NEW_HOSTNAME (or set NEW_HOSTNAME)"
  exit $EXIT_CRITICAL
fi

# --- Validate (single label, RFC 1123) ---
if ! [[ "$NEW_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
  echo "CRITICAL: Invalid hostname '$NEW_HOSTNAME'. Use letters, digits and hyphens (max 63, no leading/trailing hyphen)."
  exit $EXIT_CRITICAL
fi
if [[ "$NEW_HOSTNAME" =~ ^[0-9]+$ ]]; then
  echo "CRITICAL: Hostname cannot be all digits."
  exit $EXIT_CRITICAL
fi

if ! command -v hostnamectl &>/dev/null; then
  echo "CRITICAL: hostnamectl not found (systemd required)."
  exit $EXIT_CRITICAL
fi

OLD_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"

hosts_ok() {
  grep -Eq "^127\.0\.1\.1[[:space:]]+(.*[[:space:]])?${NEW_HOSTNAME}([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null
}

# --- Idempotency ---
if [[ "$OLD_HOSTNAME" == "$NEW_HOSTNAME" ]] && hosts_ok; then
  echo "OK: Hostname already '$NEW_HOSTNAME' - no change (v$SCRIPT_VERSION)"
  exit $EXIT_SUCCESS
fi

# --- Set hostname ---
if ! hostnamectl set-hostname "$NEW_HOSTNAME" 2>/tmp/rename_host_err; then
  echo "CRITICAL: hostnamectl set-hostname failed: $(head -c 200 /tmp/rename_host_err)"
  rm -f /tmp/rename_host_err
  exit $EXIT_CRITICAL
fi
rm -f /tmp/rename_host_err
hostnamectl set-hostname --pretty "$NEW_HOSTNAME" 2>/dev/null || true

# --- /etc/hosts: point 127.0.1.1 at the new name ---
HOSTS_NOTE="hosts updated"
if [[ -f "$HOSTS_FILE" ]]; then
  cp -p "$HOSTS_FILE" "${HOSTS_FILE}.bak-rename" 2>/dev/null || true
  if grep -Eq '^127\.0\.1\.1[[:space:]]' "$HOSTS_FILE"; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${NEW_HOSTNAME}/" "$HOSTS_FILE"
  else
    printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> "$HOSTS_FILE"
  fi
  # Drop stale old-name tokens from other lines (escape regex chars in old name)
  if [[ -n "$OLD_HOSTNAME" && "$OLD_HOSTNAME" != "$NEW_HOSTNAME" && "$OLD_HOSTNAME" != "localhost" ]]; then
    OLD_ESC="$(printf '%s' "$OLD_HOSTNAME" | sed 's/[][\.*^$/]/\\&/g')"
    sed -i -E "/^127\.0\.1\.1[[:space:]]/! s/([[:space:]])${OLD_ESC}([[:space:]]|$)/\1\2/g" "$HOSTS_FILE"
  fi
else
  printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$NEW_HOSTNAME" > "$HOSTS_FILE"
  HOSTS_NOTE="hosts created"
fi

# --- Verify ---
CURRENT="$(hostnamectl --static 2>/dev/null || hostname)"
if [[ "$CURRENT" != "$NEW_HOSTNAME" ]]; then
  echo "WARNING: Rename ran but static hostname is '$CURRENT' (expected '$NEW_HOSTNAME')"
  exit $EXIT_WARNING
fi
if ! hosts_ok; then
  echo "WARNING: Hostname set to '$NEW_HOSTNAME' but /etc/hosts 127.0.1.1 entry missing"
  exit $EXIT_WARNING
fi

echo "OK: Hostname renamed '$OLD_HOSTNAME' -> '$NEW_HOSTNAME' ($HOSTS_NOTE, v$SCRIPT_VERSION)"
echo "Backup: ${HOSTS_FILE}.bak-rename | GNOME 'About' may show the new name after re-login."
exit $EXIT_SUCCESS
