#!/bin/bash
#
# Installer for manual-duplex.
#
#   ./install.sh              install PDF Service + helper queues
#   ./install.sh --no-queues  install the PDF Service only
#   ./install.sh --uninstall  remove everything
#
# Nothing here needs sudo except creating the helper printer queues, and you
# will be prompted for that separately (and can decline).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_SRC="${SRC_DIR}/manual-duplex.sh"

BIN_DIR="${HOME}/.local/bin"
ENGINE="${BIN_DIR}/manual-duplex"
SERVICES="${HOME}/Library/PDF Services"
SERVICE="${SERVICES}/Print Two-Sided"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()   { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Do not let this run as root. macOS sudo resets HOME to /var/root, so the PDF
# Service and config would install into root's home where the print dialog will
# never look for them - and it would all report success.
if [ "$(id -u)" -eq 0 ]; then
  die "Do not run this with sudo.

Run it as yourself:   bash install.sh

It will ask for your password on its own, and only for the optional
printer-queue step."
fi

# Reject stray arguments rather than silently ignoring them.
case "${1:-}" in
  ""|--no-queues|--uninstall) ;;
  *) die "Unknown option: $1

Usage:
  bash install.sh              install PDF Service + helper queues
  bash install.sh --no-queues  install the PDF Service only
  bash install.sh --uninstall  remove everything" ;;
esac

# ---------------------------------------------------------------------------

uninstall() {
  rm -f "$SERVICE" && green "Removed PDF Service"
  rm -f "$ENGINE"  && green "Removed $ENGINE"
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

# --- 2. the PDF Service ------------------------------------------------------
# An executable in ~/Library/PDF Services appears in the PDF dropdown of every
# app's print dialog. macOS hands it the spooled PDF as an argument.

mkdir -p "$SERVICES"
cat >"$SERVICE" <<EOF
#!/bin/bash
#
# macOS PDF Service entry point for manual-duplex.
#
# This wrapper must return immediately. The print system expects a PDF Service
# tool to consume the spool file and exit; the two-pass duplex flow blocks for
# minutes waiting for the paper to be flipped, and holding the workflow open
# that long makes macOS abandon it with "Error running print workflow".
#
# So: take our own copy of the spool file, hand it to the engine as a detached
# background process, and exit 0 straight away.

set -u

TITLE="\${1:-Document}"
OPTS="\${2:-}"
SPOOL="\${3:-}"

WORK="\$HOME/.config/manual-duplex/jobs"
LOGF="\$HOME/.config/manual-duplex/manual-duplex.log"
mkdir -p "\$WORK"

# Older spool files from abandoned jobs should not accumulate.
find "\$WORK" -name '*.pdf' -mtime +7 -delete 2>/dev/null || true

if [ -z "\$SPOOL" ] || [ ! -f "\$SPOOL" ]; then
  echo "\$(date '+%Y-%m-%d %H:%M:%S')  wrapper: no spool file in args: \$*" >>"\$LOGF"
  exit 0
fi

COPY="\$WORK/\$(date +%Y%m%d-%H%M%S)-\$\$.pdf"
if ! cp "\$SPOOL" "\$COPY" 2>>"\$LOGF"; then
  echo "\$(date '+%Y-%m-%d %H:%M:%S')  wrapper: could not copy spool file" >>"\$LOGF"
  exit 0
fi

# Apple's docs: the tool is responsible for removing the spooled PDF.
rm -f "\$SPOOL"

nohup "$ENGINE" "\$TITLE" "\$OPTS" "\$COPY" >>"\$LOGF" 2>&1 &
disown 2>/dev/null || true

exit 0
EOF
chmod 755 "$SERVICE"
green "Installed service -> PDF dropdown item \"Print Two-Sided\""

# --- 3. helper queues --------------------------------------------------------

if [ "${1:-}" != "--no-queues" ]; then
  echo
  echo "Optional: add two entries to your printer list so you can drive this"
  echo "straight from the Printer menu instead of the PDF dropdown."
  echo

  # No mapfile here: macOS ships bash 3.2, which predates it.
  QUEUES=""
  while IFS= read -r q; do
    [ -n "$q" ] && QUEUES="${QUEUES}${q}"$'\n'
  done < <(lpstat -p 2>/dev/null | awk '/^printer/ {print $2}' | grep -v -- '-Two-Sided-' || true)

  if [ -z "$QUEUES" ]; then
    warn "No printers found - skipping helper queues."
  else
    QCOUNT=$(printf '%s' "$QUEUES" | grep -c . || true)
    if [ "$QCOUNT" -eq 1 ]; then
      BASE=$(printf '%s' "$QUEUES" | head -n1)
    else
      echo "Which printer?"
      # shellcheck disable=SC2086
      select BASE in $QUEUES "skip"; do
        [ -n "${BASE:-}" ] && break
      done
      [ "$BASE" = "skip" ] && BASE=""
    fi

    if [ -n "${BASE:-}" ]; then
      URI=$(lpstat -v "$BASE" 2>/dev/null | sed -n 's/.*: *//p')
      if [ -z "$URI" ]; then
        warn "Could not read the device URI for $BASE - skipping helper queues."
      else
        echo
        echo "Creating two queues pointing at $URI"
        echo "(you will be asked for your password)"

        make_queue() {
          local name="$1" desc="$2"; shift 2
          sudo lpadmin -p "$name" -v "$URI" -E -m everywhere \
               -D "$desc" -o printer-is-shared=false "$@" 2>/dev/null \
            || sudo lpadmin -p "$name" -v "$URI" -E \
               -D "$desc" -o printer-is-shared=false "$@"
        }

        if make_queue "${BASE}-Two-Sided-1-Fronts" "Two-Sided step 1: fronts" \
             -o page-set-default=odd \
           && make_queue "${BASE}-Two-Sided-2-Backs" "Two-Sided step 2: backs" \
             -o page-set-default=even -o outputorder-default=reverse; then
          green "Created helper queues."
          echo
          warn "Verify these once: print a 4-page document to '...Two-Sided-1-Fronts'."
          warn "If all 4 pages come out instead of just 1 and 3, your driver ignores"
          warn "page-set. Remove them with ./install.sh --uninstall and use the PDF"
          warn "dropdown instead, which computes explicit page ranges and always works."
        else
          warn "Could not create helper queues. The PDF Service works regardless."
        fi
      fi
    fi
  fi
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
