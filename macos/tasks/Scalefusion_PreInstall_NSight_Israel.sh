#!/bin/bash
# =============================================================================
# Scalefusion_PreInstall_NSight_Israel.sh - Pre-Install script for N-Sight agent (Israel / Helfy Office)
# =============================================================================
#
# SYNOPSIS:
#     Writes settings.ini to /tmp before Scalefusion runs Install.pkg
#
# DESCRIPTION:
#     Upload this as the Pre-Install Script in Scalefusion PKG deployment.
#     Runs before Install.pkg executes so the N-Sight agent installer finds
#     the ini at /tmp/settings.ini on first launch.
#     Site: Israel / Helfy Office (SITEID=690373)
#
# USAGE:
#     Scalefusion > App Management > PKG > Pre-Install Script
#
# =============================================================================

set -e

cat > /tmp/settings.ini << 'EOF'
[GENERAL]
SERVER1=https://upload1europe1.systemmonitor.eu.com/
SERVER2=https://upload2europe1.systemmonitor.eu.com/
SERVER3=https://upload3europe1.systemmonitor.eu.com/
SERVER4=https://upload4europe1.systemmonitor.eu.com/
USERNAME=nir.l@helfy.co
USERKEY=clmmbbbgiennencienhgdoeamfccnahhjfjedpjdilmpjemaoofcckmlolmenalgfhajbhnhgejbndddcfpcnceffmjpkhnkdgebgabkeiagnbdmdknkceenglennlpk
AGENTMODE=1
[AUTOINSTALL]
ON=1
SITEID=690373
[DEBUG]
VERBOSE=1
EOF

echo "settings.ini written to /tmp/settings.ini"
