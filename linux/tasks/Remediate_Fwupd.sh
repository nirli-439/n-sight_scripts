#!/bin/bash
# Remediate_Fwupd.sh - Fix fwupd firmware update daemon
# For N-Sight RMM deployment (Ubuntu/Debian)
#
# SYNOPSIS:
#     Diagnose and fix fwupd service issues.
#
# DESCRIPTION:
#     - Checks if fwupd is installed
#     - Installs if missing
#     - Restarts service if not active
#     - Attempts reinstall if service fails
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Fwupd.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Fwupd.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Platform: Ubuntu/Debian

SERVICE="fwupd"
echo "Checking $SERVICE daemon status..."

if ! systemctl is-active --quiet $SERVICE; then
    echo "$SERVICE is not active. Attempting to fix..."

    # Ensure package is installed
    if ! dpkg -l | grep -q fwupd; then
        echo "fwupd not installed. Installing..."
        sudo apt-get update -y && sudo apt-get install -y fwupd
    fi

    # Try restarting the service
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE
    sudo systemctl restart $SERVICE
fi

# Verify service again
if systemctl is-active --quiet $SERVICE; then
    echo "OK: $SERVICE service is running."
    exit 0
else
    echo "Error: $SERVICE failed to start. Attempting reinstall..."
    sudo apt-get remove --purge -y fwupd
    sudo apt-get install -y fwupd
    sudo systemctl enable --now $SERVICE
fi

# Final status report
if systemctl is-active --quiet $SERVICE; then
    echo "OK: $SERVICE service is running after reinstall."
    exit 0
else
    echo "FAIL: $SERVICE could not be started."
    exit 1
fi
