#!/bin/bash
# Install_Chrome_linux.sh - Flatpak + Flathub Google Chrome
# For N-Sight RMM deployment
#
# SYNOPSIS:
#     Ensures flatpak + flathub remote, installs com.google.Chrome (system-wide).
#     Pins .desktop + /usr/local/bin wrapper so app drawer / CLI work without re-login.
#     https://flathub.org/en/apps/com.google.Chrome
#
# EXIT CODES:
#     0    = Success
#     1002 = Critical/Error
#
# N-Sight:
#     Type = Automated Task
#     OS   = Linux
#     Timeout = 600
#
# EXECUTION:
#     sudo bash Install_Chrome_linux.sh
#     curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/tasks/Install_Chrome_linux.sh" | sudo bash
#
# RUN CHROME:
#     flatpak run com.google.Chrome
#     google-chrome          # after this script (wrapper)

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APP_ID="com.google.Chrome"
FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"
DESKTOP_SRC="/var/lib/flatpak/exports/share/applications/${APP_ID}.desktop"
DESKTOP_DST="/usr/share/applications/${APP_ID}.desktop"
ICON_SRC="/var/lib/flatpak/exports/share/icons/hicolor/scalable/apps/${APP_ID}.svg"
BIN_WRAPPER="/usr/local/bin/google-chrome"

if [ "$(id -u)" -ne 0 ]; then
  echo "CRITICAL: Root required"
  exit 1002
fi

chrome_version() {
  flatpak info --system "$APP_ID" 2>/dev/null | awk -F': *' '/Version:/ {print $2; exit}'
}

# Flatpak apps live under /var/lib/flatpak/exports - GNOME only sees that after
# login (profile.d). Copy .desktop + icon into system paths so drawer works now.
expose_launcher() {
  if [ -f "$DESKTOP_SRC" ]; then
    cp -f "$DESKTOP_SRC" "$DESKTOP_DST" 2>/dev/null || true
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  fi
  # Icon=com.google.Chrome only resolves if hicolor has the file outside flatpak exports
  if [ -f "$ICON_SRC" ]; then
    mkdir -p /usr/share/icons/hicolor/scalable/apps
    cp -f "$ICON_SRC" /usr/share/icons/hicolor/scalable/apps/com.google.Chrome.svg
    gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
  fi
  # CLI + Activities search alias
  cat > "$BIN_WRAPPER" << 'EOF'
#!/bin/sh
exec /usr/bin/flatpak run com.google.Chrome "$@"
EOF
  chmod 755 "$BIN_WRAPPER"
  # optional common names
  ln -sfn google-chrome /usr/local/bin/google-chrome-stable 2>/dev/null || true
}

# --- flatpak package ---
if ! command -v flatpak >/dev/null 2>&1; then
  echo "Installing flatpak..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq flatpak >/dev/null 2>&1 || {
      echo "CRITICAL: apt install flatpak failed"
      exit 1002
    }
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q flatpak >/dev/null 2>&1 || {
      echo "CRITICAL: dnf install flatpak failed"
      exit 1002
    }
  else
    echo "CRITICAL: need apt or dnf to install flatpak"
    exit 1002
  fi
fi

if ! command -v flatpak >/dev/null 2>&1; then
  echo "CRITICAL: flatpak still missing after install"
  exit 1002
fi

# --- flathub remote (system) ---
if ! flatpak remote-list --system 2>/dev/null | grep -qw flathub; then
  echo "Adding flathub remote..."
  flatpak remote-add --if-not-exists --system flathub "$FLATHUB_URL" >/dev/null 2>&1 || {
    echo "CRITICAL: flathub remote-add failed"
    exit 1002
  }
fi

# --- install if missing ---
if ! flatpak info --system "$APP_ID" >/dev/null 2>&1; then
  echo "Installing $APP_ID from flathub..."
  if ! flatpak install -y --noninteractive --system flathub "$APP_ID" >/dev/null 2>&1; then
    if ! flatpak install -y --system flathub "$APP_ID" >/dev/null 2>&1; then
      echo "CRITICAL: flatpak install $APP_ID failed"
      exit 1002
    fi
  fi
fi

if ! flatpak info --system "$APP_ID" >/dev/null 2>&1; then
  echo "CRITICAL: Chrome flatpak missing after install"
  exit 1002
fi

expose_launcher
VER=$(chrome_version)
echo "OK: Chrome (flatpak) v${VER:-unknown} | run: flatpak run com.google.Chrome | drawer: Google Chrome"
exit 0
