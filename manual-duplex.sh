#!/bin/bash
#
# manual-duplex - two-sided printing for printers without a duplexer
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
# Invoked as a macOS PDF Service (from the PDF dropdown in any print dialog),
# or directly:   manual-duplex [--paper-settings|--setup|--config] [file.pdf]
# The native helper prepares two equal-length PDFs before the first submission.

set -uo pipefail

# The print system runs PDF Services with a minimal environment, so do not rely
# on the caller's PATH for lp, lpstat, osascript and friends.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CONFIG_DIR="${HOME}/.config/manual-duplex"
JOB_DIR="${CONFIG_DIR}/jobs"
CONFIG="${CONFIG_DIR}/config"
LOG="${CONFIG_DIR}/manual-duplex.log"
ICON="${CONFIG_DIR}/manual-duplex.icns"
APP_NAME="Two-Sided Printing"
PLAN_HELPER="${HOME}/.local/bin/manual-duplex-plan"

mkdir -p "$CONFIG_DIR" "$JOB_DIR"

# Owner-only. The jobs folder briefly holds copies of whatever you print, and
# the config is sourced by this script - so neither should be readable or
# writable by other accounts on the machine.
chmod 700 "$CONFIG_DIR" "$JOB_DIR" 2>/dev/null || true

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG:-/dev/null}"; }

# Clean up our working copy of the spooled PDF however we leave.
CLEANUP_FILE=""
PASS_DIR=""
on_exit() {
  [ -n "$CLEANUP_FILE" ] && rm -f "$CLEANUP_FILE"
  if [ -n "$PASS_DIR" ]; then
    rm -f "$PASS_DIR/first.pdf" "$PASS_DIR/second.pdf"
    rmdir "$PASS_DIR"
  fi
  return 0
}
trap on_exit EXIT

# Always leave with status 0.
#
# macOS reports any non-zero exit from a PDF Service as "Error running print
# workflow" with no detail, which is worse than useless. We report our own
# problems in a dialog and in the log, and never let that message appear.
fail() {
  log "FAILED: $1"
  alert "$1"
  exit 0
}

# Dialogs show the app icon when it is installed, and fall back to the system
# note icon if the .icns is missing, so a failed icon build is cosmetic only.
if [ -f "$ICON" ]; then
  ICON_CLAUSE="with icon (POSIX file \"${ICON}\")"
else
  ICON_CLAUSE="with icon note"
fi

# ---------------------------------------------------------------------------
# Dialog helpers. osascript shows its own dialogs - deliberately not via System
# Events, which would need Automation permission this process cannot get.
# ---------------------------------------------------------------------------

dialog() {
  # dialog <text> <button1> [button2] ; echoes the button pressed
  local text="$1" b1="$2" b2="${3:-}" script
  text="${text//\\/\\\\}"; text="${text//\"/\\\"}"
  if [ -n "$b2" ]; then
    script="display dialog \"$text\" buttons {\"$b2\", \"$b1\"} default button \"$b1\" with title \"$APP_NAME\" $ICON_CLAUSE"
  else
    script="display dialog \"$text\" buttons {\"$b1\"} default button \"$b1\" with title \"$APP_NAME\" $ICON_CLAUSE"
  fi
  # Do NOT route this through `tell application "System Events"`.
  #
  # That is an Apple Event to another app, which macOS gates behind the
  # Automation privacy permission. A shell script launched in the background has
  # no application identity, so the system denies it outright - and does not
  # even show a prompt to approve:
  #
  #   execution error: Not authorized to send Apple events to System Events. (-1743)
  #
  # osascript displaying its own dialog needs no permission at all. `tell me to
  # activate` brings it to the front, replacing what System Events was for.
  local raw
  raw=$(osascript -e 'tell me to activate' -e "$script" 2>&1)

  # Never swallow osascript's error text. A dialog that fails to appear at all
  # is almost always an AppleScript compile error in the message, and without
  # this the only symptom is silence.
  case "$raw" in
    *"button returned"*)
      printf '%s' "$raw" | sed 's/.*button returned://; s/,.*//'
      ;;
    *"-128"*|*"User canceled"*|*"User cancelled"*)
      # AppleScript treats a button literally named "Cancel" as the dialog's
      # cancel button: pressing it raises error -128 instead of returning a
      # button name. Without this, callers see an empty answer, read it as a
      # glitch, and re-show the dialog - so Cancel becomes impossible to press.
      printf 'Cancel'
      ;;
    *)
      log "dialog failed: ${raw:-<no output>}"
      ;;
  esac
}

# A dialog that closes itself after <seconds> if untouched. Echoes the button
# pressed, or nothing if it timed out - which lets a message stay on screen while
# a condition is polled, without the user having to dismiss it.
dialog_timed() {
  # dialog_timed <text> <button> <seconds>
  local text="$1" b="$2" secs="$3" script raw
  text="${text//\\/\\\\}"; text="${text//\"/\\\"}"
  script="display dialog \"$text\" buttons {\"$b\"} with title \"$APP_NAME\" $ICON_CLAUSE giving up after $secs"
  raw=$(osascript -e 'tell me to activate' -e "$script" 2>&1)
  case "$raw" in
    *"gave up:true"*)    : ;;                 # nobody touched it - stay silent
    *"button returned"*) printf '%s' "$raw" | sed 's/.*button returned://; s/,.*//' ;;
    *"-128"*|*"User canceled"*|*"User cancelled"*) printf '%s' "$b" ;;
    *) log "timed dialog failed: ${raw:-<no output>}" ;;
  esac
}

alert() {
  local text="$1"
  text="${text//\\/\\\\}"; text="${text//\"/\\\"}"
  osascript -e 'tell me to activate' \
            -e "display dialog \"$text\" buttons {\"OK\"} default button \"OK\" with title \"$APP_NAME\" $ICON_CLAUSE" \
            >/dev/null 2>&1
}

choose_from() {
  # choose_from <prompt> <item1> <item2> ...
  local prompt="$1"; shift
  local list="" i
  for i in "$@"; do list+="\"${i//\"/\\\"}\", "; done
  list="${list%, }"
  osascript -e 'tell me to activate' \
    -e "choose from list {$list} with prompt \"${prompt//\"/\\\"}\" with title \"$APP_NAME\"" \
    2>/dev/null
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

PRINTER=""             # CUPS queue name, e.g. HP_Smart_Tank_510_series__95C868_
PRINTER_LABEL=""       # what the user calls it, e.g. HP Smart Tank 510 series

BIND_EDGE="long"       # long | short, the physical edge used to turn the finished sheet
OUTPUT_FACE=""        # down | up, orientation of the printed face in the output tray
RELOAD_FACE=""        # down | up, orientation of the printed face in the input tray
OUTPUT_HEAD="inside"  # inside | outside, where the top edge lands in the output tray
PASSTHROUGH_ENABLED=1  # forward the print dialog's settings to both passes
SHOW_QUEUE=1           # open the printer's queue window so the Dock shows progress

# Loading the config *executes* it - it is shell. That is fine for a file only
# you can write, so check that before trusting it. A config another account can
# modify would be a way to run code as you.
config_is_safe() {
  local perms g o
  perms=$(stat -f '%Lp' "$CONFIG" 2>/dev/null || stat -c '%a' "$CONFIG" 2>/dev/null)
  [ -z "$perms" ] && return 1
  perms="00$perms"
  g="${perms: -2:1}"; o="${perms: -1}"
  case "$g" in 2|3|6|7) return 1 ;; esac      # group-writable
  case "$o" in 2|3|6|7) return 1 ;; esac      # world-writable
  return 0
}

load_config() {
  [ -f "$CONFIG" ] || return 0
  if ! config_is_safe; then
    log "refusing to load $CONFIG - it is writable by other users; using defaults"
    return 0
  fi
  . "$CONFIG"
}

save_config() {
  local pending
  pending=$(mktemp "$CONFIG_DIR/config.XXXXXX") || return 1
  if {
    printf '# manual-duplex configuration\n'
    printf 'PRINTER=%q\nPRINTER_LABEL=%q\n' "$PRINTER" "$PRINTER_LABEL"
    printf 'BIND_EDGE=%q\nOUTPUT_FACE=%q\nRELOAD_FACE=%q\nOUTPUT_HEAD=%q\n' \
      "$BIND_EDGE" "$OUTPUT_FACE" "$RELOAD_FACE" "$OUTPUT_HEAD"
    printf 'PASSTHROUGH_ENABLED=%q\nSHOW_QUEUE=%q\n' "$PASSTHROUGH_ENABLED" "$SHOW_QUEUE"
  } >"$pending" && mv -f "$pending" "$CONFIG"; then
    return 0
  fi
  rm -f "$pending"
  return 1
}

load_paper_defaults() {
  # The existing HP profile used reversed backs and forward fronts. Derive the
  # new face settings from both directions for other previously configured printers.
  if [ -z "$OUTPUT_FACE" ]; then
    OUTPUT_FACE=down
    [ "${PASS2_REVERSE:-no}" = "yes" ] && OUTPUT_FACE=up
  fi
  if [ -z "$RELOAD_FACE" ]; then
    RELOAD_FACE="$OUTPUT_FACE"
    if [ -n "${PASS1_REVERSE:-}" ] && [ "$PASS1_REVERSE" = "${PASS2_REVERSE:-}" ]; then
      case "$OUTPUT_FACE" in down) RELOAD_FACE=up ;; up) RELOAD_FACE=down ;; esac
    fi
  fi
}

choose_paper() {
  local selected rc
  [ -x "$PLAN_HELPER" ] || fail "缺少双面打印组件。请重新安装 Print Two-Sided。"
  selected=$("$PLAN_HELPER" choose "$1" "$PRINTER_LABEL" \
             "$BIND_EDGE" "$OUTPUT_FACE" "$RELOAD_FACE" "$OUTPUT_HEAD" "$0" "$PRINTER" 2>>"$LOG")
  rc=$?
  [ "$rc" -eq 2 ] && exit 0
  [ "$rc" -eq 0 ] || fail "无法打开双面打印设置。请查看日志。"
  read_paper "$selected" || fail "无法读取双面打印设置。"
  if [ "$1" = settings ]; then
    save_config || fail "无法保存双面打印设置。"
  fi
}

read_paper() {
  local selected="$1"
  [[ "$selected" =~ ^(long|short)\ (down|up)\ (down|up)\ (inside|outside)$ ]] || return 1
  IFS=' ' read -r BIND_EDGE OUTPUT_FACE RELOAD_FACE OUTPUT_HEAD <<<"$selected"
}

default_printer() {
  local d
  d=$(lpstat -d 2>/dev/null | sed -n 's/.*: *//p')
  [ -n "$d" ] && { printf '%s' "$d"; return; }
  lpstat -p 2>/dev/null | awk '/^printer/ {print $2; exit}'
}

list_queues() {
  lpstat -p 2>/dev/null | awk '/^printer/ {print $2}' | grep -v -- '-Two-Sided-' || true
}

# CUPS queue names are mangled for use as identifiers - "HP Smart Tank 510
# series (95C868)" becomes "HP_Smart_Tank_510_series__95C868_". Show people the
# name they actually recognise, and keep the queue name for talking to lp.
printer_label() {
  local q="$1" d
  d=$(lpstat -l -p "$q" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Description:[[:space:]]*//p' | head -n1)
  d="${d%"${d##*[![:space:]]}"}"      # trim trailing whitespace
  if [ -n "$d" ]; then
    printf '%s' "$d"
    return
  fi
  # No description available: de-mangle the queue name instead.
  local name last
  name=$(printf '%s' "$q" | tr '_' ' ' | tr -s ' ' | sed 's/[[:space:]]*$//')

  # Drop a trailing hex serial like "95C868", but keep model numbers. The test
  # is letters AND digits together: "95C868" and "A1B2C3" are serials, while
  # "2850" and "510" are part of the product name and must survive.
  case "$name" in
    *" "*)
      last="${name##* }"
      if [ "${#last}" -ge 4 ] \
         && printf '%s' "$last" | grep -Eq '^[0-9A-Fa-f]+$' \
         && printf '%s' "$last" | grep -q '[A-Fa-f]' \
         && printf '%s' "$last" | grep -q '[0-9]'; then
        name="${name% *}"
      fi
      ;;
  esac
  printf '%s' "$name"
}

pick_printer() {
  local q label choice def map="" count=0
  local -a labels

  def=$(default_printer)

  while IFS= read -r q; do
    [ -z "$q" ] && continue
    label=$(printer_label "$q")
    [ "$q" = "$def" ] && label="$label  -  system default"
    map="${map}${label}	${q}"$'\n'
    labels[$count]="$label"
    count=$((count + 1))
  done <<<"$(list_queues)"

  if [ "$count" -eq 0 ]; then
    fail "No printers found.

Add your printer in System Settings > Printers & Scanners, then run setup again."
  fi

  if [ "$count" -eq 1 ]; then
    choice="${labels[0]}"
  else
    choice=$(choose_from "Which printer do you print two-sided on?" "${labels[@]}")
    if [ -z "$choice" ] || [ "$choice" = "false" ]; then
      exit 0
    fi
  fi

  # Map the chosen label back to its queue name.
  PRINTER=$(printf '%s' "$map" | awk -F'\t' -v L="$choice" '$1 == L { print $2; exit }')
  if [ -z "$PRINTER" ]; then
    fail "Could not match \"$choice\" back to a printer queue. Please run setup again."
  fi
  PRINTER_LABEL=$(printer_label "$PRINTER")
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

submit() {
  local f="$1" title="$2" sheets="$3"
  local out jobid o
  local -a lpargs
  lpargs=(-d "$PRINTER" -t "$title")

  if [ "$PASSTHROUGH_ENABLED" = 1 ]; then
    while IFS= read -r o; do
      [ -n "$o" ] && lpargs+=(-o "$o")
    done <<<"$PASSTHROUGH"
  fi

  # The PDF already contains one page for each physical side in feed order.
  lpargs+=(-n 1 -o sides=one-sided -o number-up=1 -o outputorder=normal
    -o page-set=all -o "page-ranges=1-$sheets" -o job-sheets=none,none)
  if ! out=$(LC_ALL=C lp "${lpargs[@]}" -- "$f" 2>&1); then
    log "lp failed: $out"
    return 1
  fi
  jobid=$(printf '%s' "$out" | sed -n 's/.*request id is \([^ ]*\).*/\1/p')
  [ -n "$jobid" ] || { log "could not identify CUPS job: $out"; return 1; }
  log "submitted $jobid ($sheets sheets)"
  printf '%s' "$jobid"
}

# Work out how long this pass could reasonably take.
#
# A fixed cap is wrong at both ends: it nags on a short draft job and expires
# mid-print on a long one. An inkjet at best quality can spend the better part of
# a minute on a single side, so scale with the actual sheet count and the quality
# that was asked for, then double it for headroom.
estimate_timeout() {
  # estimate_timeout <sheets_in_this_pass> -> seconds
  local sheets="$1" per=20 base=180 q colour budget

  q=$(printf '%s' "${PASSTHROUGH:-}" \
      | sed -n 's/.*cupsPrintQuality=\([^ ]*\).*/\1/p' | head -n1)
  case "$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')" in
    5|high|best|photo) per=60 ;;
    4)                 per=35 ;;
    3|normal)          per=20 ;;
    2|draft|fast)      per=8  ;;
  esac

  # Colour costs more passes of the head than greyscale.
  colour=$(printf '%s' "${PASSTHROUGH:-}" \
           | sed -n 's/.*ColorModel=\([^ ]*\).*/\1/p' | head -n1)
  case "$(printf '%s' "$colour" | tr '[:upper:]' '[:lower:]')" in
    gray|grayscale|black|mono) ;;
    ?*) per=$(( per * 3 / 2 )) ;;
  esac

  budget=$(( base + sheets * per * 2 ))
  [ "$budget" -lt 300 ]   && budget=300      # never nag inside 5 minutes
  [ "$budget" -gt 21600 ] && budget=21600    # but do not wait past 6 hours
  printf '%s' "$budget"
}

# What the printer is complaining about, in plain words, or nothing if it is
# happy. CUPS exposes printer-state-reasons on the Alerts line of `lpstat -l -p`.
#
# Checking only whether the queue is disabled is not enough: a printer that has
# run out of paper usually leaves the queue enabled with the job sitting in it,
# so the job never drains and nothing explains why.
#
# Order matters - report the most actionable fault first. "low" states are
# deliberately absent: they are warnings and printing continues.
printer_alert() {
  local raw
  raw=$(lpstat -l -p "$PRINTER" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -z "$raw" ] && return 0
  case "$raw" in
    *media-jam*)                                printf 'there is a paper jam' ;;
    *media-needed*|*media-empty*)               printf 'it is out of paper' ;;
    *cover-open*|*door-open*|*interlock-open*)  printf 'a cover or door is open' ;;
    *marker-supply-empty*|*toner-empty*|*ink-empty*)
                                                printf 'it is out of ink' ;;
    *offline-report*|*shutdown*)                printf 'it is offline' ;;
    *paused*)                                   printf 'the queue is paused' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Print-settings passthrough
#
# macOS hands a PDF Service three arguments: title, a CUPS options string, and
# the spooled PDF. That options string carries what the user picked in the
# print dialog - quality, colour mode, paper type, tray, copies, layout - so we
# forward it to both passes instead of falling back to the queue defaults.
#
# Options we must own ourselves are stripped: anything selecting pages or
# ordering would fight our two-pass split, and any duplex key would ask a
# printer with no duplexer to do the thing it cannot do.
# ---------------------------------------------------------------------------

# What macOS actually hands over in $2 is not a tidy CUPS options string - it is
# Apple's internal print-settings dictionary, and many of its values contain
# spaces:
#
#   com.apple.print.DialogDismissedBy=Print Two-Sided
#   com.apple.print.pageRange=All 11 Pages
#
# Split on whitespace and those produce bare fragments - "Two-Sided", "11",
# "Pages" - which then get passed to lp as `-o Two-Sided`. CUPS accepts the job
# and the printer then sits on it, which looks exactly like a hung prompt.
#
# So this is a whitelist by shape, not a blacklist: a token is only forwarded if
# it is key=value, the key is a plain option name with no dots, and the value is
# non-empty. That alone removes every com.apple.print.* key and every stray
# fragment. The named cases below are real CUPS options we must own ourselves.
opt_is_allowed() {
  local key="$1"

  # Plain option name only: letters, digits, underscore, hyphen. Apple's keys
  # are dotted, so this drops all of them in one go.
  printf '%s' "$key" | grep -Eq '^[A-Za-z][A-Za-z0-9_-]*$' || return 1

  case "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" in
    # page selection and ordering - this tool controls these
    page-ranges|page-set|page-label|outputorder|output-order|copies|collate|\
    number-up|number-up-layout|page-border|orientation-requested|landscape|\
    skip-blank-*|suppress-blank-*|blankpageskip|sides|multiple-document-handling) return 1 ;;
    # duplex of any flavour: the printer has no duplexer
    *duplex*|*tumble*|booklet*) return 1 ;;
    # job bookkeeping and routing, not print settings
    destinationprinterid|job-*|document-name|ap_documentname|\
    pserrorhandler-requested|emit-jcl|disallow-binary-quoting) return 1 ;;
  esac
  return 0
}

# Split the options string into tokens, honouring the quoting CUPS uses for
# values containing spaces. xargs does this without an eval.
passthrough_opts() {
  local raw="$1" tok key
  [ -z "$raw" ] && return 0
  printf '%s' "$raw" | xargs -n1 2>/dev/null | while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in *=*) ;; *) continue ;; esac   # bare fragment - drop it
    key="${tok%%=*}"
    [ -z "${tok#*=}" ] && continue               # empty value - drop it
    opt_is_allowed "$key" || continue
    printf '%s\n' "$tok"
  done
}

# Read one option's value out of the raw string, e.g. copies=3 -> 3
# The loop is fed by a here-string rather than a pipe so that `return` actually
# leaves the function instead of just a subshell.
opt_value() {
  local raw="$1" want="$2" tok key
  [ -z "$raw" ] && return 1
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    key="${tok%%=*}"
    if [ "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
      printf '%s' "${tok#*=}"
      return 0
    fi
  done <<<"$(printf '%s' "$raw" | xargs -n1 2>/dev/null)"
  return 1
}

# Show the native print progress.
#
# Jobs submitted with `lp` are ordinary CUPS jobs and do appear in the normal
# queue - but nothing launches the queue window, so there is no Dock icon and no
# progress, unlike printing from an app.
#
# macOS keeps a per-printer proxy app in ~/Library/Printers, named after the
# printer. Opening it gives exactly the native progress UI. `-g` keeps it in the
# background so it does not steal focus from whatever you are doing.
open_print_queue() {
  [ "${SHOW_QUEUE:-1}" = "1" ] || return 0

  local app base want_a want_b
  want_a=$(printf '%s' "${PRINTER_LABEL:-}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
  want_b=$(printf '%s' "${PRINTER:-}"       | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')

  for app in "$HOME/Library/Printers/"*.app; do
    [ -d "$app" ] || continue
    base=$(basename "$app" .app | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
    if [ -n "$base" ] && { [ "$base" = "$want_a" ] || [ "$base" = "$want_b" ]; }; then
      open -g "$app" 2>/dev/null && { log "opened print queue: $(basename "$app")"; return 0; }
    fi
  done

  # Names do not always match exactly - fall back to a containment test.
  for app in "$HOME/Library/Printers/"*.app; do
    [ -d "$app" ] || continue
    base=$(basename "$app" .app | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
    case "$want_b" in
      *"$base"*) [ ${#base} -ge 6 ] && open -g "$app" 2>/dev/null \
                   && { log "opened print queue (fuzzy): $(basename "$app")"; return 0; } ;;
    esac
  done

  log "no printer proxy app found in ~/Library/Printers - no Dock progress"
  return 0
}

wait_until_ready() {
  local jobid="$1" budget="$2"
  local waited=0 fault ans queued last=""

  while :; do
    queued=no
    if [ -n "$jobid" ]; then
      lpstat -W not-completed -o "$PRINTER" 2>/dev/null | grep -q "^$jobid " && queued=yes
    fi
    fault=$(printer_alert)

    # Clean: nothing queued, nothing wrong.
    if [ "$queued" = "no" ] && [ -z "$fault" ]; then
      sleep 3                      # let the last sheet finish ejecting
      return 0
    fi

    if [ -n "$fault" ]; then
      [ "$fault" != "$last" ] && log "waiting - printer reports: $fault"
      last="$fault"
      ans=$(dialog_timed "$PRINTER_LABEL says $fault.

Printing continues by itself once this is fixed - you do not need to click anything.

This message will close when the printer is ready." "Stop" 8)
      if [ "$ans" = "Stop" ]; then
        log "user stopped at fault prompt ($fault)"
        return 1
      fi
      waited=0                     # time spent faulted is not the print taking long
      continue
    fi

    sleep 2
    waited=$((waited + 2))
    [ $((waited % 60)) -eq 0 ] && log "still waiting on $jobid (${waited}s of ${budget}s)"

    if [ "$waited" -ge "$budget" ]; then
      ans=$(dialog "The first side is taking longer than expected on $PRINTER_LABEL.

No fault is being reported, so it may just be slow.

Keep waiting?" "Keep Waiting" "Stop")
      [ "$ans" = "Stop" ] && { log "user stopped at slow-job prompt"; return 1; }
      waited=0
    fi
  done
}

one_pass_pair() {
  local title="$1" sheets="$2"
  local budget jobid prompt action face binding answer tries=0
  budget=$(estimate_timeout "$sheets")

  jobid=$(submit "$PASS_DIR/first.pdf" "$title [双面 1/2]" "$sheets") ||
    fail "无法确认第一趟作业的状态。请查看打印队列。"
  open_print_queue
  if ! wait_until_ready "$jobid" "$budget"; then
    log "stopped while waiting for the first pass"
    return 1
  fi

  face="已印面朝下，空白面朝上"
  [ "$RELOAD_FACE" = "up" ] && face="已印面朝上，空白面朝下"
  binding="长边翻转"
  [ "$BIND_EDGE" = "short" ] && binding="短边翻转"
  if [ "$OUTPUT_FACE" = "$RELOAD_FACE" ]; then
    action="把纸整叠原样从上方出纸口移到下方进纸盘，不翻面、不调头。"
  else
    action="将整叠纸左右翻面后放回下方进纸盘。原来朝机身的那条边继续朝机身。"
  fi
  prompt="第一趟完成。请取出整叠 $sheets 张纸，包括空白纸。

$action
放回时${face}。

已选${binding}。放好后点「继续」，第二趟同样走 $sheets 张。"

  while :; do
    answer=$(dialog "$prompt" "继续" "取消")
    case "$answer" in
      继续) break ;;
      取消|Cancel)
        log "cancelled at reload prompt"
        return 1
        ;;
      *)
        tries=$((tries + 1))
        log "reload prompt returned nothing (attempt $tries)"
        [ "$tries" -ge 30 ] && return 1
        sleep 2
        ;;
    esac
  done

  jobid=$(submit "$PASS_DIR/second.pdf" "$title [双面 2/2]" "$sheets") ||
    fail "无法确认第二趟作业的状态。请查看打印队列。"
  open_print_queue
  wait_until_ready "$jobid" "$budget"
}

run_duplex() {
  local pdf="$1" title="$2"
  local nup layout border copies collate sheets
  choose_paper print

  nup=$(opt_value "$RAW_OPTS" number-up)
  layout=$(opt_value "$RAW_OPTS" number-up-layout)
  border=$(opt_value "$RAW_OPTS" page-border)
  copies=$(opt_value "$RAW_OPTS" copies)
  if [ -z "$copies" ]; then
    copies=$(printf '%s' "$RAW_OPTS" | tr ' ' '\n' |
      sed -n 's/.*PMCopies[^=]*=\([0-9][0-9]*\).*/\1/p' | head -n1)
  fi
  collate=$(opt_value "$RAW_OPTS" collate)
  case "$(printf '%s' "$collate" | tr '[:upper:]' '[:lower:]')" in
    false|off|no|0) collate=false ;;
    *) collate=true ;;
  esac

  PASS_DIR=$(mktemp -d "$JOB_DIR/pass.XXXXXX") || fail "无法创建打印临时目录。"
  if ! sheets=$("$PLAN_HELPER" prepare "$pdf" "$PASS_DIR" \
      "$BIND_EDGE" "$OUTPUT_FACE" "$RELOAD_FACE" "$OUTPUT_HEAD" \
      "${nup:-1}" "${layout:-lrtb}" "${border:-none}" "${copies:-1}" "$collate" 2>&1); then
    fail "无法生成两趟等张数的打印作业。

$sheets"
  fi
  case "$sheets" in ''|*[!0-9]*|0) fail "两趟打印张数校验失败。" ;; esac

  log "job '$title': $sheets sheets per pass, edge=$BIND_EDGE output=$OUTPUT_FACE reload=$RELOAD_FACE head=$OUTPUT_HEAD"
  log "  passthrough: $(printf '%s' "$PASSTHROUGH" | tr '\n' ' ')"
  if one_pass_pair "$title" "$sheets"; then
    log "job '$title' complete"
  fi
}

setup() {
  pick_printer
  choose_paper settings
}

# Terminal-facing health check. Answers the question "I pressed Print and
# nothing happened" by testing each link in the chain separately.
doctor() {
  local svc="${HOME}/Library/PDF Services/Print Two-Sided"
  local ok="  [ ok ]" bad="  [FAIL]" warn="  [warn]"
  local t

  echo "manual-duplex doctor"
  echo "===================="
  echo
  echo "Engine"
  echo "  running from : $0"
  [ -x "$0" ] && echo "$ok executable" || echo "$bad not executable - chmod +x it"

  echo
  echo "PDF Service"
  if [ -f "$svc" ]; then
    echo "$ok installed at ~/Library/PDF Services/Print Two-Sided"
    [ -x "$svc" ] && echo "$ok executable" \
                  || echo "$bad NOT executable - macOS will silently ignore it"
    # Match the quoted absolute path the wrapper hands to launchctl/nohup, not
    # the bare ~/.config/manual-duplex strings that also appear in the file.
    t=$(grep -oE '"/[^"]*/manual-duplex"' "$svc" 2>/dev/null | head -n1 | tr -d '"')
    if [ -n "$t" ] && [ -x "$t" ]; then
      echo "$ok points at an installed engine: $t"
    else
      echo "$bad points at '$t' which is missing or not executable"
    fi
  else
    echo "$bad not installed - run: bash install.sh"
  fi

  echo
  echo "Launcher app  (needed for sandboxed apps like Preview)"
  local app="${HOME}/Applications/Two-Sided Printing.app"
  if [ -d "$app" ]; then
    echo "$ok installed at ~/Applications/Two-Sided Printing.app"
    t=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)
    [ -n "$t" ] && [ -x "$app/Contents/MacOS/$t" ] \
      && echo "$ok bundle executable present" \
      || echo "$bad bundle looks incomplete - reinstall"
  else
    echo "$bad not installed."
    echo "       Printing from Preview, TextEdit or Pages will silently do"
    echo "       nothing without it. Reinstall with: bash install.sh"
  fi

  echo
  echo "Native print progress"
  local found=0 a
  for a in "$HOME/Library/Printers/"*.app; do
    [ -d "$a" ] && { echo "$ok proxy app: $(basename "$a")"; found=1; }
  done
  [ "$found" -eq 0 ] && echo "$warn none in ~/Library/Printers - no Dock progress will show"

  echo
  echo "Tools"
  for t in lp lpstat osascript; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "$ok $t -> $(command -v $t)"
    else
      echo "$bad $t not found on PATH"
    fi
  done

  echo
  echo "Printer"
  if [ -z "$PRINTER" ]; then
    echo "$warn none configured - run: manual-duplex --setup"
  elif lpstat -p "$PRINTER" >/dev/null 2>&1; then
    echo "$ok $PRINTER_LABEL ($PRINTER)"
    echo "       binding=$BIND_EDGE  output=$OUTPUT_FACE  reload=$RELOAD_FACE  head=$OUTPUT_HEAD"
  else
    echo "$bad configured queue '$PRINTER' is not available"
  fi

  echo
  echo "Paper planner"
  if [ -x "$PLAN_HELPER" ]; then
    echo "$ok $PLAN_HELPER"
  else
    echo "$bad missing native planner - reinstall with: bash install.sh"
  fi
}

usage() {
  cat <<'USAGE'
manual-duplex - two-sided printing for printers without a duplexer

  manual-duplex FILE.pdf     print a PDF two-sided
  manual-duplex --setup      pick printer and configure paper
  manual-duplex --paper-settings  change binding and paper orientation
  manual-duplex --printer    switch printer
  manual-duplex --status     show current settings
  manual-duplex --doctor     diagnose "nothing happened when I pressed Print"
  manual-duplex --config     open the settings file
  manual-duplex --log        show recent job history
  manual-duplex --version    licence information

Normally you do not run this by hand: print from any app and choose
"Print Two-Sided" from the PDF dropdown in the print dialog.

Free software under the GNU GPL v3 or later, with NO WARRANTY.
USAGE
}

status() {
  alert "打印机  ${PRINTER_LABEL:-未设置}
翻转  $BIND_EDGE
出纸时已印面  $OUTPUT_FACE
放回时已印面  $RELOAD_FACE
出纸时页首  $OUTPUT_HEAD"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

load_config

# Config written before labels existed, or a printer renamed since: fill it in.
if [ -n "$PRINTER" ] && [ -z "$PRINTER_LABEL" ]; then
  PRINTER_LABEL=$(printer_label "$PRINTER")
fi

load_paper_defaults

case "${1:-}" in
  --save-paper)
    [ "$#" -eq 4 ] && [ -n "$2" ] && read_paper "$4" || exit 1
    PRINTER="$2"
    PRINTER_LABEL="$3"
    save_config
    exit $?
    ;;
  --setup|--printer) setup; exit 0 ;;
  --paper-settings|--calibrate)
    [ -z "$PRINTER" ] && pick_printer
    choose_paper settings
    exit 0
    ;;
  --status)    status; exit 0 ;;
  --doctor)    doctor; exit 0 ;;
  --config)    open -t "$CONFIG" 2>/dev/null || cat "$CONFIG"; exit 0 ;;
  --log)       cat "$LOG"; exit 0 ;;
  --help|-h)   usage; exit 0 ;;
  --version)   echo "manual-duplex - GPL-3.0-or-later - https://www.gnu.org/licenses/"; exit 0 ;;
esac

# macOS invokes a PDF Service tool with exactly three parameters:
#   $1  the document title
#   $2  a string of the CUPS print options chosen in the print dialog
#   $3  the path to the spooled PDF
# We honour that contract, but locate the PDF by magic number as well so the
# script still works when run by hand or if the ordering ever changes.
TITLE="${1:-Document}"
RAW_OPTS="${2:-}"
PDF=""

is_pdf() { [ -f "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null)" = "%PDF" ]; }

if is_pdf "${3:-}"; then
  PDF="$3"
else
  for arg in "$@"; do
    is_pdf "$arg" && PDF="$arg"
  done
  # Run by hand as `manual-duplex file.pdf`: $1 was the file, not a title.
  if [ -n "$PDF" ] && [ "$TITLE" = "$PDF" ]; then
    TITLE="$(basename "$PDF" .pdf)"
    RAW_OPTS=""
  fi
fi

PASSTHROUGH="$(passthrough_opts "$RAW_OPTS")"

if [ -z "$PDF" ]; then
  # Only complain to a human who typed the command. A launch with no usable
  # file - a stale launchd job, a re-run of a finished job whose working copy is
  # already deleted - must stay silent, or it pops a dialog out of nowhere with
  # no print in progress.
  # Any tty at all means a person typed this; a launchd or app launch has none.
  # Testing only stdout would miss `manual-duplex | less`.
  if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then
    echo "manual-duplex: no PDF given." >&2
    echo "usage: manual-duplex yourfile.pdf" >&2
    echo "       manual-duplex --doctor | --status | --setup | --paper-settings" >&2
  else
    log "no usable PDF in args (${*:-none}) - ignoring silently"
  fi
  exit 0
fi

# Our working copy lives in the jobs folder and is ours to delete on the way out.
case "$PDF" in
  "$JOB_DIR"/*) CLEANUP_FILE="$PDF" ;;
esac

log "started: title='$TITLE' pdf='$PDF'"

[ -z "$PRINTER" ] && pick_printer

# Printer may have been removed or renamed since we saved it.
if ! lpstat -p "$PRINTER" >/dev/null 2>&1; then
  log "configured printer '$PRINTER' is gone; reselecting"
  pick_printer
fi

run_duplex "$PDF" "$TITLE"
