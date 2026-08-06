#!/usr/bin/env bash
# Remediate_DisplayLink.sh - Optimize Ubuntu for DisplayLink docks
# For N-Sight RMM deployment
#
# SYNOPSIS:
#     Optimize Ubuntu system for DisplayLink dock performance.
#
# DESCRIPTION:
#     - Installs TLP and power management tools
#     - Sets power profile to performance
#     - Configures TLP for dock usage
#     - Disables power saving on Thunderbolt devices
#     - Forces GDM to use Xorg instead of Wayland
#     - Disables GNOME animations for better performance
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_DisplayLink.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_DisplayLink.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Platform: Ubuntu with GNOME desktop
#     Requires: Reboot after running

set -e

echo "=== Ubuntu + DisplayLink Performance Optimizer ==="

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo:"
  echo "  sudo $0"
  exit 1
fi

if [ -z "$SUDO_USER" ]; then
  echo "Warning: SUDO_USER is not set. GNOME settings will be applied for root, not your desktop user."
  echo "Run this script with: sudo $0"
fi

DESKTOP_USER="${SUDO_USER:-$USER}"

echo
echo "Running as root, desktop user detected as: $DESKTOP_USER"
echo

echo "=== Step 1: Install needed packages (tlp, gnome-tweaks, powerprofilesctl provider) ==="
apt update
apt install -y tlp tlp-rdw gnome-tweaks power-profiles-daemon

echo
echo "=== Step 2: Set power profile to PERFORMANCE (if supported) ==="
if command -v powerprofilesctl >/dev/null 2>&1; then
  sudo -u "$DESKTOP_USER" powerprofilesctl set performance || true
  echo "Current power profiles:"
  sudo -u "$DESKTOP_USER" powerprofilesctl || true
else
  echo "powerprofilesctl not found, skipping. (This is fine on some systems.)"
fi

echo
echo "=== Step 3: Configure TLP for dock / performance ==="
TLP_CONF="/etc/tlp.conf"

if [ -f "$TLP_CONF" ]; then
  cp "$TLP_CONF" "${TLP_CONF}.bak-$(date +%F-%H%M%S)"
  echo "Backup of $TLP_CONF created."
fi

cat << 'EOF' >> "$TLP_CONF"

# === Added by Remediate_DisplayLink.sh ===
# Performance on AC and avoid USB / PCIe power saving issues with docks
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_AC=performance

USB_AUTOSUSPEND=0
RUNTIME_PM_ON_AC=on
PCIE_ASPM_ON_AC=performance
# === End of Remediate_DisplayLink.sh block ===
EOF

systemctl enable tlp.service || true
systemctl start tlp.service || true
echo "TLP configured and (re)started."

echo
echo "=== Step 4: Disable power saving on Thunderbolt devices ==="
TB_PATH="/sys/bus/thunderbolt/devices"
if [ -d "$TB_PATH" ]; then
  for dev in "$TB_PATH"/*; do
    if [ -d "$dev/power" ] && [ -f "$dev/power/control" ]; then
      echo "on" > "$dev/power/control" || true
      echo "Set Thunderbolt device $(basename "$dev") power/control to 'on'"
    fi
  done
else
  echo "No Thunderbolt devices directory found at $TB_PATH (maybe no TB or using pure USB-C only)."
fi

echo
echo "=== Step 5: Force GDM to use Xorg instead of Wayland (better for DisplayLink) ==="
GDM_CONF="/etc/gdm3/custom.conf"
if [ -f "$GDM_CONF" ]; then
  cp "$GDM_CONF" "${GDM_CONF}.bak-$(date +%F-%H%M%S)"
  echo "Backup of $GDM_CONF created."

  # Uncomment or add WaylandEnable=false
  if grep -q "^#*WaylandEnable=" "$GDM_CONF"; then
    sed -i 's/^#*WaylandEnable=.*/WaylandEnable=false/' "$GDM_CONF"
  else
    sed -i '/^\[daemon\]/a WaylandEnable=false' "$GDM_CONF"
  fi
  echo "Wayland disabled. GDM will use Xorg."
else
  echo "GDM config not found at $GDM_CONF, skipping Xorg enforcement."
fi

echo
echo "=== Step 6: GNOME performance tweaks (for user: $DESKTOP_USER) ==="
if command -v sudo >/dev/null 2>&1; then
  # Disable animations
  sudo -u "$DESKTOP_USER" dbus-launch gsettings set org.gnome.desktop.interface enable-animations false || true

  # Avoid fractional scaling (keeps scaling simple, better for DisplayLink)
  sudo -u "$DESKTOP_USER" dbus-launch gsettings set org.gnome.mutter experimental-features "[]" || true

  echo "GNOME animations disabled and fractional scaling experimental features cleared (if supported)."
else
  echo "sudo not available? Very unusual. GNOME tweaks skipped."
fi

echo
echo "=== SUMMARY ==="
echo "- TLP set to performance on AC with USB autosuspend disabled."
echo "- Thunderbolt devices (if any) set to 'on' (no power saving)."
echo "- GDM set to use Xorg instead of Wayland."
echo "- GNOME animations disabled; fractional scaling experimental features cleared."
echo
echo "Recommended next steps:"
echo "  1) Reboot your system."
echo "  2) After reboot, confirm login session is Xorg (Wayland should be OFF now)."
echo "  3) Make sure you're using the latest DisplayLink driver from Synaptics website."
echo
echo "OK: DisplayLink optimization complete. Reboot recommended."
exit 0
