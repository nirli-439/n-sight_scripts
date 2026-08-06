#!/bin/bash
# Remediate_Getty_TTY2.sh - Fix getty@tty2 service issues
# For N-Sight RMM deployment
#
# SYNOPSIS:
#     Diagnose and fix getty@tty2 service issues.
#
# DESCRIPTION:
#     - Checks getty@tty2 service status
#     - Restarts if not active
#     - Re-enables if restart fails
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Getty_TTY2.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Getty_TTY2.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Platform: Linux (systemd)

SERVICE="getty@tty2.service"

echo "Checking $SERVICE status..."
if ! systemctl is-active --quiet $SERVICE; then
  echo "Service not active. Attempting restart..."
  systemctl restart $SERVICE
  sleep 2
  if systemctl is-active --quiet $SERVICE; then
    echo "OK: $SERVICE restarted successfully."
    exit 0
  else
    echo "Restart failed, re-enabling service..."
    systemctl enable $SERVICE
    systemctl start $SERVICE
  fi
else
  echo "OK: $SERVICE is running fine."
  exit 0
fi

# Final check
if systemctl is-active --quiet $SERVICE; then
  echo "OK: $SERVICE is now running."
  exit 0
else
  echo "FAIL: $SERVICE could not be started."
  exit 1
fi
