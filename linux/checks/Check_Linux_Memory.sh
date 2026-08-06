#!/bin/bash
# Check_Linux_Memory.sh - Memory usage monitoring for N-sight RMM
#
# SYNOPSIS:
#     Check system memory usage with threshold alerts.
#
# DESCRIPTION:
#     Calculates actual memory usage (excluding buffers/cache) and
#     reports status based on configurable thresholds.
#
#     Exit Codes:
#     - 0 = OK (Memory usage below 90%)
#     - 1 = WARNING (Memory usage 90-94%)
#     - 2 = CRITICAL (Memory usage 95%+)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Linux_Memory.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/checks/Check_Linux_Memory.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Platform: Linux (all distributions)

mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_free=$(grep MemFree /proc/meminfo | awk '{print $2}')
buffers=$(grep Buffers /proc/meminfo | awk '{print $2}')
cached=$(grep -w Cached /proc/meminfo | awk '{print $2}')

used=$((mem_total - mem_free - buffers - cached))
percent=$((used * 100 / mem_total))

echo "Memory usage (real): ${percent}%"

if [ "$percent" -ge 95 ]; then
  echo "CRITICAL: Memory usage ${percent}%"
  exit 2
elif [ "$percent" -ge 90 ]; then
  echo "WARNING: Memory usage ${percent}%"
  exit 1
else
  echo "OK: Memory usage ${percent}%"
  exit 0
fi
