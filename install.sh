#!/bin/bash
#
# Installer for manual-duplex.
#
# Copyright (C) 2026 Yasas Alwis
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
#   ./install.sh              install
#   ./install.sh --uninstall  remove everything
#
# Nothing here needs sudo. Everything installs into your home folder.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_SRC="${SRC_DIR}/manual-duplex.sh"

BIN_DIR="${HOME}/.local/bin"
ENGINE="${BIN_DIR}/manual-duplex"
SERVICES="${HOME}/Library/PDF Services"
SERVICE="${SERVICES}/Print Two-Sided"
APP_DIR="${HOME}/Applications"
APP="${APP_DIR}/Two-Sided Printing.app"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()   { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Do not let this run as root. macOS sudo resets HOME to /var/root, so the PDF
# Service and config would install into root's home where the print dialog will
# never look for them - and it would all report success.
if [ "$(id -u)" -eq 0 ]; then
  die "Do not run this with sudo.

Run it as yourself:   bash install.sh

Nothing here needs admin rights."
fi

# Reject stray arguments rather than silently ignoring them.
case "${1:-}" in
  ""|--uninstall) ;;
  *) die "Unknown option: $1

Usage:
  bash install.sh             install
  bash install.sh --uninstall remove everything" ;;
esac

# ---------------------------------------------------------------------------

# An earlier version of this installer handed jobs off with `launchctl submit`.
# Those jobs persist in the user's launchd domain and get respawned, and because
# the PDF they reference is deleted once the job finishes, each respawn pops a
# "No PDF was handed to Two-Sided Printing" dialog out of nowhere. Clear them.
clear_stale_launchd_jobs() {
  local j found=0
  command -v launchctl >/dev/null 2>&1 || return 0
  while read -r j; do
    [ -z "$j" ] && continue
    launchctl remove "$j" 2>/dev/null && found=1
  done < <(launchctl list 2>/dev/null | awk '/manualduplex/ {print $3}')
  [ "$found" -eq 1 ] && green "Removed stale launchd jobs from a previous version"
  return 0
}

uninstall() {
  clear_stale_launchd_jobs
  rm -f "$SERVICE"    && green "Removed PDF Service"
  rm -rf "$APP"       && green "Removed $APP"
  rm -f "$ENGINE"     && green "Removed $ENGINE"
  local q
  for q in $(lpstat -p 2>/dev/null | awk '/^printer/ {print $2}' | grep -- '-Two-Sided-' || true); do
    if lpadmin -x "$q" 2>/dev/null; then
      green "Removed queue $q"
    else
      warn  "Queue $q needs admin rights: sudo lpadmin -x $q"
    fi
  done
  warn "Config and log kept at ~/.config/manual-duplex (delete by hand if you want them gone)."
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

[ -f "$ENGINE_SRC" ] || die "Cannot find manual-duplex.sh next to this installer."
[ "$(uname)" = "Darwin" ] || die "This installs a macOS print workflow; it only runs on macOS."

# --- 1. the engine -----------------------------------------------------------

clear_stale_launchd_jobs

mkdir -p "$BIN_DIR"
cp "$ENGINE_SRC" "$ENGINE"
chmod 755 "$ENGINE"
green "Installed engine  -> $ENGINE"

# --- 1b. the icon ------------------------------------------------------------
# Built from the shipped .iconset with iconutil, which is part of macOS. If it
# fails the dialogs quietly fall back to the system note icon.

CONFIG_DIR="${HOME}/.config/manual-duplex"
mkdir -p "$CONFIG_DIR"

if [ -d "${SRC_DIR}/icon.iconset" ] && command -v iconutil >/dev/null 2>&1; then
  if iconutil -c icns -o "${CONFIG_DIR}/manual-duplex.icns" "${SRC_DIR}/icon.iconset" 2>/dev/null; then
    green "Installed icon    -> shown in every prompt"
  else
    warn "Could not build the icon - prompts will use the default macOS icon."
  fi
else
  warn "No icon.iconset found - prompts will use the default macOS icon."
fi

# --- 1c. the launcher app ----------------------------------------------------
# Since Big Sur the printtool process that runs PDF Services is sandboxed:
# scripts placed there cannot reliably write files or spawn processes, and fail
# silently. Printing from a sandboxed app such as Preview hits this hardest.
#
# An app launched through LaunchServices runs in the normal user session, so the
# PDF Service script does the one thing it is still allowed to do - `open -a`
# this app - and the app does the real work.

if [ -f "${SRC_DIR}/app.applescript" ] && command -v osacompile >/dev/null 2>&1; then
  mkdir -p "$APP_DIR"
  rm -rf "$APP"
  if osacompile -o "$APP" "${SRC_DIR}/app.applescript" 2>/dev/null; then
    PLIST="${APP}/Contents/Info.plist"
    PB=/usr/libexec/PlistBuddy
    if [ -x "$PB" ]; then
      # No Dock icon, and accept PDFs so the open event is delivered.
      "$PB" -c "Add :LSUIElement bool true" "$PLIST" 2>/dev/null || \
        "$PB" -c "Set :LSUIElement true" "$PLIST" 2>/dev/null || true
      "$PB" -c "Set :CFBundleIdentifier com.manualduplex.twosided" "$PLIST" 2>/dev/null || \
        "$PB" -c "Add :CFBundleIdentifier string com.manualduplex.twosided" "$PLIST" 2>/dev/null || true
      "$PB" -c "Add :CFBundleDocumentTypes array" "$PLIST" 2>/dev/null || true
      "$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string PDF" "$PLIST" 2>/dev/null || true
      "$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" "$PLIST" 2>/dev/null || true
      "$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$PLIST" 2>/dev/null || true
      "$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string com.adobe.pdf" "$PLIST" 2>/dev/null || true
    fi
    [ -f "${CONFIG_DIR}/manual-duplex.icns" ] && \
      cp "${CONFIG_DIR}/manual-duplex.icns" "${APP}/Contents/Resources/applet.icns" 2>/dev/null || true
    # Register with LaunchServices so `open -a` finds it immediately.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "$APP" >/dev/null 2>&1 || true
    green "Installed app     -> $APP"
  else
    warn "Could not compile the launcher app. Printing from sandboxed apps"
    warn "(Preview, TextEdit, Pages) may silently do nothing."
  fi
else
  warn "osacompile or app.applescript missing - skipping the launcher app."
fi

# --- 2. the PDF Service ------------------------------------------------------
# Deliberately minimal: it runs inside printtool's sandbox, so it does as little
# as possible and hands off immediately.

mkdir -p "$SERVICES"
cat >"$SERVICE" <<EOF
#!/bin/bash
#
# macOS PDF Service entry point for manual-duplex.
#
# This script runs inside printtool's sandbox, which since Big Sur blocks
# writing files and spawning processes. Anything ambitious here fails silently -
# no error, no output, nothing printed. That is why it does almost nothing:
# stash the CUPS options next to the spool file (best effort - the sandbox often
# refuses, and losing them only costs the quality/colour passthrough), then hand
# the PDF to the launcher app through LaunchServices, which runs outside the
# sandbox and does the real work.

TITLE="\${1:-Document}"
OPTS="\${2:-}"
SPOOL="\${3:-}"

[ -n "\$SPOOL" ] && [ -f "\$SPOOL" ] || exit 0

printf '%s' "\$OPTS" > "\${SPOOL}.mdopts" 2>/dev/null || true

if ! /usr/bin/open -a "$APP" "\$SPOOL" 2>/dev/null; then
  # LaunchServices refused. Try the engine directly - works from apps that are
  # not sandboxed, which at least keeps those printing.
  ( ( nohup "$ENGINE" "\$TITLE" "\$OPTS" "\$SPOOL" \
        >>"\$HOME/.config/manual-duplex/manual-duplex.log" 2>&1 & ) & )
fi

exit 0
EOF
chmod 755 "$SERVICE"
green "Installed service -> PDF dropdown item \"Print Two-Sided\""

# --- 3. leftover helper queues ----------------------------------------------
# Earlier versions could add two extra printers ("...-Two-Sided-1-Fronts" and
# "-2-Backs") as a way to drive this from the printer list. That was a mistake:
# a print queue has no way to pause and ask you to flip the paper, and it relied
# on the CUPS page-set option that driverless queues often ignore. Both passes
# have always gone to your one real printer. The feature is gone; if a previous
# install left the queues behind, point them out - removing a queue needs admin
# rights, so it is not something to do silently mid-install.

STALE=$(lpstat -p 2>/dev/null | awk '/^printer/ {print $2}' | grep -- '-Two-Sided-' || true)
if [ -n "$STALE" ]; then
  echo
  warn "Found leftover helper queues from an earlier version:"
  printf '%s\n' "$STALE" | sed 's/^/        /'
  warn "They are no longer used. Remove them with:"
  printf '%s\n' "$STALE" | sed 's/^/        sudo lpadmin -x /'
fi

# --- 4. first-run setup ------------------------------------------------------

echo
green "Installed."
echo
echo "Running first-time setup (pick printer + calibrate the paper flip)..."
echo
"$ENGINE" --setup || true

cat <<'EOF'

How to use it
-------------
  In any app:  File > Print > PDF dropdown (bottom-left) > Print Two-Sided
  Follow the prompt, flip the stack when asked, done.

  Re-calibrate:  ~/.local/bin/manual-duplex --calibrate
  Edit settings: ~/.local/bin/manual-duplex --config
  See the log:   ~/.local/bin/manual-duplex --log
  Uninstall:     ./install.sh --uninstall
EOF
