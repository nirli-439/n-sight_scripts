#!/usr/bin/env bash
# =============================================================================
# Refresh_RMM_Agent_mac.sh — compatibility wrapper (logic lives in checks/)
# =============================================================================
#
# The full refresh implementation is maintained as a 24x7 Shell check:
#   macos/checks/Check_Mac_RMM_Agent_Refresh.sh
#
# This file remains so existing N-sight tasks and bookmarks that reference
# macos/tasks/Refresh_RMM_Agent_mac.sh keep working.
#
# EXECUTION (unchanged URL path):
#     curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Refresh_RMM_Agent_mac.sh" | sudo bash
#
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/../checks/Check_Mac_RMM_Agent_Refresh.sh" "$@"
