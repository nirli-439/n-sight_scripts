#!/usr/bin/env bash
# =============================================================================
# build_nsight_ppcc_mobileconfig.sh — Build MDM PPPC (.mobileconfig) for N-sight
# =============================================================================
#
# Generates a Privacy Preferences Policy Control (TCC) profile aligned with
# N-sight RMM documentation:
#   https://documentation.n-able.com/remote-management/userguide/Content/install_mac_agent_access.htm
#
# Covers (per N-sight): Accessibility, Full Disk Access, Screen & System Audio
# Recording. Also includes PostEvent and ListenEvent for remote control paths
# (Take Control / system input). Re-deploy after agent upgrades if signing changes.
#
# REQUIREMENTS:
#   - Run on a Mac with N-sight components installed (codesign reads real DR).
#   - Install only via User Approved MDM (UAMDM), e.g. N-sight Device Management
#     for Apple (DMA) or another MDM. Manual user install of TCC profiles is
#     blocked in most cases on modern macOS.
#
# USAGE:
#   ./build_nsight_ppcc_mobileconfig.sh > N-Sight_RMM_TCC.mobileconfig
#   ./build_nsight_ppcc_mobileconfig.sh /path/to/N-Sight_RMM_TCC.mobileconfig
#
# =============================================================================
set -euo pipefail

OUT_PATH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec /usr/bin/python3 "${SCRIPT_DIR}/build_nsight_ppcc_mobileconfig.py" ${OUT_PATH:+"$OUT_PATH"}
