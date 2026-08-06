#!/usr/bin/env bash
# =============================================================================
# Remediate_Hostname_Linux.sh - Rename system hostname (N-Sight RMM)
# =============================================================================
#
# SYNOPSIS:
#     Set system hostname on Linux (systemd-based).
#
# DESCRIPTION:
#     - Validates hostname format (letters, numbers, dots, hyphens)
#     - Sets hostname via hostnamectl
#     - Updates /etc/hosts so 127.0.0.1/127.0.1.1 use the new hostname
#     - Designed for N-Sight RMM (silent, no user interaction)
#
# USAGE:
#     sudo ./Remediate_Hostname_Linux.sh NEW_HOSTNAME
#     In N-Sight: pass NEW_HOSTNAME as script parameter.
#
# EXIT CODES (N-Sight):
#     0    = Success
#     1002 = Critical (not root, missing/invalid hostname, or set failed)
#
# EXECUTION:
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Hostname_Linux.sh" | sudo bash
#     sudo bash /path/to/Remediate_Hostname_Linux.sh my-new-hostname
#
# NOTES:
#     Platform: Fedora 38+, Ubuntu 22.04+ (systemd-based)
#     Requires: Root (sudo)
#
# =============================================================================

set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_CRITICAL=1002

NEW_HOSTNAME="${1:-}"

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
  echo "CRITICAL: This script must be run as root (sudo)."
  exit $EXIT_CRITICAL
fi

if [[ -z "$NEW_HOSTNAME" ]]; then
  echo "CRITICAL: No hostname supplied. Usage: $0 NEW_HOSTNAME"
  exit $EXIT_CRITICAL
fi

# Allow letters, numbers, dashes, and dots (FQDN-style; max 253 chars)
if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "CRITICAL: Invalid hostname '$NEW_HOSTNAME'. Use only letters, numbers, dots and hyphens."
  exit $EXIT_CRITICAL
fi
if [[ ${#NEW_HOSTNAME} -gt 253 ]]; then
  echo "CRITICAL: Hostname too long (max 253 characters)."
  exit $EXIT_CRITICAL
fi

# Determine if this is a systemd system
if ! command -v hostnamectl &>/dev/null; then
  echo "CRITICAL: hostnamectl command not found (requires systemd)."
  exit $EXIT_CRITICAL
fi

OLD_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"
echo "Old hostname: $OLD_HOSTNAME"
echo "New hostname: $NEW_HOSTNAME"

# --- Set the hostname ---
if ! hostnamectl set-hostname "$NEW_HOSTNAME"; then
  echo "CRITICAL: hostnamectl set-hostname failed."
  exit $EXIT_CRITICAL
fi

# --- Update /etc/hosts ---
if [[ -f /etc/hosts ]]; then
  # Replace old hostname with new one (word boundary)
  sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts
fi

CURRENT="$(hostnamectl --static 2>/dev/null || hostname)"
echo "OK: Hostname set to $CURRENT"
exit $EXIT_SUCCESS
