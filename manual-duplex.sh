#!/bin/bash
#
# manual-duplex - two-sided printing for printers without a duplexer
#
# Invoked as a macOS PDF Service (from the PDF dropdown in any print dialog),
# or directly:   manual-duplex.sh [--calibrate|--setup|--config] [file.pdf]
#
# No dependencies beyond what ships with macOS. Page selection is handed to CUPS
# via -o page-ranges rather than by splitting the PDF; the only PDF edit is
# appending a blank page to odd-sided documents so the printer feeds the extra
# sheet itself.

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

mkdir -p "$CONFIG_DIR" "$JOB_DIR"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG:-/dev/null}"; }

# Clean up our working copy of the spooled PDF however we leave.
CLEANUP_FILE=""
PAD_FILE=""
on_exit() {
  [ -n "$CLEANUP_FILE" ] && rm -f "$CLEANUP_FILE"
  [ -n "$PAD_FILE" ] && rm -f "$PAD_FILE"
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
    *)
      log "dialog failed: ${raw:-<no output>}"
      ;;
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

# Which side gets printed first, and in which direction each pass runs.
#
#   evens-first : backs (2,4,6...) then fronts (1,3,5...)
#   odds-first  : fronts then backs
#
# Both passes reversed - the evens-first default - means a 10-page document
# prints 10,8,6,4,2 and then 9,7,5,3,1. That pairs each sheet correctly and
# leaves the finished stack in reading order on a printer that ejects face-up.
#
# The two REVERSE knobs exist because stacking behaviour varies by printer. If
# the pairing comes out wrong, flipping PASS2_REVERSE is the first thing to try.
PASS_ORDER="evens-first"     # evens-first | odds-first
PASS1_REVERSE="yes"          # reverse the first pass
PASS2_REVERSE="yes"          # reverse the second pass
FLIP_HINT="Flip the stack over, keeping the same edge at the top, and put it back in the input tray."
PASSTHROUGH_ENABLED=1  # forward the print dialog's settings to both passes

load_config() { [ -f "$CONFIG" ] && . "$CONFIG"; }

save_config() {
  cat >"$CONFIG" <<EOF
# manual-duplex configuration - written $(date '+%Y-%m-%d %H:%M:%S')
PRINTER="$PRINTER"
PRINTER_LABEL="${PRINTER_LABEL//\"/\\\"}"

# evens-first | odds-first, and the direction of each pass.
PASS_ORDER="$PASS_ORDER"
PASS1_REVERSE="$PASS1_REVERSE"
PASS2_REVERSE="$PASS2_REVERSE"
FLIP_HINT="${FLIP_HINT//\"/\\\"}"

# Forward quality / colour / paper / tray choices from the print dialog to both
# passes. Set to 0 if a vendor-specific option ever makes lp reject the job;
# the queue defaults are then used instead.
PASSTHROUGH_ENABLED=${PASSTHROUGH_ENABLED:-1}
EOF
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
# Page count. Three strategies, most reliable first.
# ---------------------------------------------------------------------------

page_count() {
  local f="$1" n=""

  # 1. PDFKit / CoreGraphics via JavaScript for Automation.
  #
  # The "-" is load-bearing: osascript treats its first non-option argument as
  # the program file, so without it osascript tries to execute the PDF itself as
  # a script and never reads the heredoc at all.
  n=$(osascript -l JavaScript - "$f" 2>/dev/null <<'JXA'
function run(argv) {
  ObjC.import('Quartz');
  var url = $.NSURL.fileURLWithPath(argv[0]);
  try {
    var doc = $.PDFDocument.alloc.initWithURL(url);
    if (doc && !doc.isNil() && doc.pageCount > 0) { return String(doc.pageCount); }
  } catch (e) {}
  try {
    var cg = $.CGPDFDocumentCreateWithURL(url);
    if (cg) {
      var n = $.CGPDFDocumentGetNumberOfPages(cg);
      if (n > 0) { return String(n); }
    }
  } catch (e) {}
  return '';
}
JXA
  )
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  [ -n "$n" ] && [ "$n" -gt 0 ] && { printf '%s' "$n"; return 0; }
  log "page_count: JXA returned nothing for $f"

  # 2. Read the page tree out of the PDF itself. Works on uncompressed page
  # trees; returns nothing when the document uses object streams.
  n=$(LC_ALL=C grep -a -o '/Type[[:space:]]*/Page[^s]' "$f" 2>/dev/null | wc -l | tr -d ' ')
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  [ -n "$n" ] && [ "$n" -gt 0 ] && { log "page_count: fell back to raw scan ($n)"; printf '%s' "$n"; return 0; }

  # 3. Ask, rather than guess wrong and waste a stack of paper.
  n=$(osascript -e 'tell me to activate' \
        -e 'display dialog "Could not read the page count automatically." & return & return & "How many pages is this document?" default answer "" with title "Two-Sided Printing"' \
        2>/dev/null \
        | sed 's/.*text returned://; s/,.*//')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] && { printf '%s' "$n"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

submit() {
  # submit <pdf> <title> <page-ranges> [extra lp opts...]
  local f="$1" title="$2" ranges="$3"; shift 3
  local out jobid o
  local -a lpargs
  lpargs=(-d "$PRINTER" -t "$title" -o "page-ranges=$ranges")

  # Copies are handled here rather than by repeating the whole flow, so there is
  # only ever one flip. Collation is set explicitly because it must match across
  # both passes - see the note in run_duplex.
  if [ "${COPIES_N:-1}" -gt 1 ]; then
    lpargs+=(-o "copies=${COPIES_N}" -o "collate=${COLLATE_V:-true}")
  fi

  # Forward the settings the user chose in the print dialog.
  if [ "${PASSTHROUGH_ENABLED:-1}" = "1" ]; then
    while IFS= read -r o; do
      [ -n "$o" ] && lpargs+=(-o "$o")
    done <<<"${PASSTHROUGH:-}"
  fi

  out=$(lp "${lpargs[@]}" "$@" -- "$f" 2>&1)
  if [ $? -ne 0 ]; then
    log "lp failed: $out"
    alert "The printer rejected the job:

$out"
    return 1
  fi
  jobid=$(printf '%s' "$out" | sed -n 's/.*request id is \([^ ]*\).*/\1/p')
  log "submitted $jobid  ranges=$ranges  opts=$*"
  printf '%s' "$jobid"
}

# How many pages a range string covers: "1-2,5-6" -> 4, "2,4,6" -> 3
count_in_ranges() {
  local r="$1" tot=0 part a b oldifs="$IFS"
  IFS=','
  for part in $r; do
    case "$part" in
      *-*) a="${part%%-*}"; b="${part##*-}"; tot=$(( tot + b - a + 1 )) ;;
      *)   tot=$(( tot + 1 )) ;;
    esac
  done
  IFS="$oldifs"
  printf '%s' "$tot"
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

wait_for_job() {
  # Block until the job leaves the queue, so the flip prompt does not appear
  # while pages are still feeding.
  # <jobid> [budget_seconds]
  local jobid="$1" budget="${2:-1800}" waited=0
  [ -z "$jobid" ] && { sleep 5; return 0; }
  while lpstat -W not-completed -o "$PRINTER" 2>/dev/null | grep -q "^$jobid "; do
    sleep 2
    waited=$((waited + 2))

    # A queue that has gone disabled will never drain, so stop waiting on it
    # rather than sitting here for the full timeout with nothing on screen.
    if [ $((waited % 10)) -eq 0 ]; then
      if lpstat -p "$PRINTER" 2>/dev/null | grep -qi "disabled\|stopped"; then
        log "printer is stopped/disabled while waiting for $jobid"
        return 1
      fi
    fi

    # Log progress so a slow job is visibly progressing rather than looking hung.
    [ $((waited % 60)) -eq 0 ] && log "still waiting on $jobid (${waited}s of ${budget}s)"

    if [ "$waited" -ge "$budget" ]; then
      log "job $jobid still queued after ${waited}s (budget ${budget}s) - asking the user"
      return 1
    fi
  done
  # Give the mechanism a moment to finish ejecting the final sheet.
  sleep 3
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
    sides|multiple-document-handling) return 1 ;;
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

# ---------------------------------------------------------------------------
# Page ranges
#
# Split by *sheet side*, not by document page. With N-up layout, K document
# pages share one side, so sheet i covers pages (i-1)*K+1 .. i*K. With the
# usual K=1 this degenerates to the plain 1,3,5 / 2,4,6 split.
# ---------------------------------------------------------------------------

side_ranges() {
  # side_ranges <pages> <number-up> <odd|even>
  local pages="$1" k="$2" parity="$3"
  local sides start end i out=""
  [ "$k" -lt 1 ] && k=1
  sides=$(( (pages + k - 1) / k ))

  i=1
  [ "$parity" = "even" ] && i=2
  while [ "$i" -le "$sides" ]; do
    start=$(( (i - 1) * k + 1 ))
    end=$(( i * k ))
    [ "$end" -gt "$pages" ] && end="$pages"
    if [ "$start" -eq "$end" ]; then
      out="${out}${start},"
    else
      out="${out}${start}-${end},"
    fi
    i=$(( i + 2 ))
  done
  [ -z "$out" ] && return 1
  printf '%s' "${out%,}"
}

# Append blank pages to a copy of the document.
#
# An odd-sided document needs one more sheet than the first pass prints, and lp
# cannot feed a sheet for a page that does not exist. Rather than asking you to
# add paper by hand, append a real blank page: the printer then feeds and ejects
# that sheet itself, and the second pass prints on its back.
#
# Uses PDFKit through JavaScript for Automation - part of macOS, nothing to
# install. Blank pages are sized to match the last real page.
pad_pdf() {
  # pad_pdf <src> <dst> <count>  -> prints OK, or ERR ...
  osascript -l JavaScript - "$1" "$2" "$3" 2>&1 <<'JXA'
function run(argv) {
  ObjC.import('Quartz');
  var n = parseInt(argv[2], 10);
  if (!(n > 0)) { return 'ERR bad count'; }

  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  if (!doc || doc.isNil()) { return 'ERR cannot open source'; }
  var count = doc.pageCount;
  if (count < 1) { return 'ERR source has no pages'; }

  var bounds = doc.pageAtIndex(count - 1).boundsForBox($.kPDFDisplayBoxMediaBox);
  for (var i = 0; i < n; i++) {
    var blank = $.PDFPage.alloc.init;
    if (!blank || blank.isNil()) { return 'ERR cannot create blank page'; }
    blank.setBoundsForBox(bounds, $.kPDFDisplayBoxMediaBox);
    doc.insertPageAtIndex(blank, doc.pageCount);
  }
  if (!doc.writeToFile(argv[1])) { return 'ERR write failed'; }
  return 'OK';
}
JXA
}


# ---------------------------------------------------------------------------
# Main duplex run
# ---------------------------------------------------------------------------

pass_submit() {
  # pass_submit <pdf> <title> <ranges> <reverse:yes|no>
  if [ "$4" = "yes" ]; then
    submit "$1" "$2" "$3" -o outputorder=reverse
  else
    submit "$1" "$2" "$3"
  fi
}

one_pass_pair() {
  # Print one complete two-sided copy.
  # <pdf> <title> <p1_ranges> <p1_rev> <p1_name> <p2_ranges> <p2_rev> <p2_name>
  # <sheets> <note> <label>
  local pdf="$1" title="$2" \
        p1="$3" p1rev="$4" p1name="$5" \
        p2="$6" p2rev="$7" p2name="$8" \
        sheets="$9" note="${10}" label="${11}"
  local jobid

  local budget
  budget=$(estimate_timeout "$(( $(count_in_ranges "$p1") * ${COPIES_N:-1} ))")
  log "pass 1: $(count_in_ranges "$p1") side(s) x ${COPIES_N:-1} copy/copies, allowing ${budget}s"

  jobid=$(pass_submit "$pdf" "$title [$p1name]$label" "$p1" "$p1rev") || fail "The printer rejected the job. See the log for details."
  if ! wait_for_job "$jobid" "$budget"; then
    [ "$(dialog "The first pass has not finished - the printer may be paused, offline or jammed.

Check it, then click Continue once the fronts have come out.

Printer:  $PRINTER_LABEL" "Continue" "Stop")" = "Continue" ] || { log "stopped at stalled-job prompt"; exit 0; }
  fi

  # Re-show the prompt if it comes back empty. An empty answer is not a Cancel -
  # it means the Apple Event failed or timed out, and abandoning the job there
  # would leave you holding a half-printed stack with no way to finish it.
  local prompt answer tries=0
  prompt="Printed $sheets sheet(s) - the $p1name.$label

$FLIP_HINT$note

Click Continue when the paper is loaded."

  while :; do
    answer=$(dialog "$prompt" "Continue" "Cancel")
    case "$answer" in
      Continue) break ;;
      Cancel)   log "cancelled at flip prompt"; exit 0 ;;
      *)
        tries=$((tries + 1))
        log "flip prompt returned nothing (attempt $tries) - reshowing"
        if [ "$tries" -ge 30 ]; then
          log "giving up after $tries attempts; backs not printed"
          exit 0
        fi
        sleep 2
        ;;
    esac
  done

  budget=$(estimate_timeout "$(( $(count_in_ranges "$p2") * ${COPIES_N:-1} ))")
  log "pass 2: $(count_in_ranges "$p2") side(s) x ${COPIES_N:-1} copy/copies, allowing ${budget}s"

  jobid=$(pass_submit "$pdf" "$title [$p2name]$label" "$p2" "$p2rev") || fail "The printer rejected the job. See the log for details."
  wait_for_job "$jobid" "$budget"
}

run_duplex() {
  local pdf="$1" title="${2:-Document}"
  local pages fronts backs sheets nup copies n note label

  pages=$(page_count "$pdf") || fail "Could not determine the page count. Nothing was printed."

  # Layout and copies come from the print dialog, not from us.
  nup=$(opt_value "${RAW_OPTS:-}" "number-up"); [ -z "$nup" ] && nup=1
  case "$nup" in ''|*[!0-9]*) nup=1 ;; esac
  [ "$nup" -lt 1 ] && nup=1

  # Apple spells this com.apple.print.PrintSettings.PMCopies..n. rather than
  # copies=, so fall back to digging it out of the raw dictionary.
  copies=$(opt_value "${RAW_OPTS:-}" "copies")
  if [ -z "$copies" ]; then
    copies=$(printf '%s' "${RAW_OPTS:-}" \
      | tr ' ' '\n' \
      | sed -n 's/.*PMCopies[^=]*=\([0-9][0-9]*\).*/\1/p' | head -n1)
  fi
  [ -z "$copies" ] && copies=1
  case "$copies" in ''|*[!0-9]*) copies=1 ;; esac
  [ "$copies" -lt 1 ] && copies=1

  log "job '$title' pages=$pages nup=$nup copies=$copies printer=$PRINTER order=$PASS_ORDER rev=$PASS1_REVERSE/$PASS2_REVERSE"
  log "  passthrough: $(printf '%s' "${PASSTHROUGH:-}" | tr '\n' ' ')"

  local sides=$(( (pages + nup - 1) / nup ))
  if [ "$sides" -lt 2 ]; then
    if [ "$(dialog "This document only fills one side, so there is no second side to print.

Print it normally?" "Print" "Cancel")" = "Print" ]; then
      submit "$pdf" "$title" "1-$pages" >/dev/null
    fi
    exit 0
  fi

  # Odd number of sides? Pad the document so the printer supplies the extra
  # sheet itself, instead of asking you to slot one in at the flip.
  if [ $((sides % 2)) -eq 1 ]; then
    local want_pages=$(( (sides + 1) * nup )) padded result
    padded="${JOB_DIR}/padded-$$-$(date +%s).pdf"
    result=$(pad_pdf "$pdf" "$padded" $(( want_pages - pages )))
    if [ "$result" = "OK" ] && [ -s "$padded" ]; then
      log "padded with $(( want_pages - pages )) blank page(s) - printer will eject the extra sheet"
      PAD_FILE="$padded"
      pdf="$padded"
      pages="$want_pages"
      sides=$(( (pages + nup - 1) / nup ))
    else
      log "could not pad ($result) - will ask for a blank sheet instead"
    fi
  fi

  fronts=$(side_ranges "$pages" "$nup" odd)
  backs=$(side_ranges "$pages" "$nup" even)

  # Which pass runs first, and in which direction.
  local p1 p1rev p1name p2 p2rev p2name
  if [ "$PASS_ORDER" = "evens-first" ]; then
    p1="$backs";  p1rev="$PASS1_REVERSE"; p1name="back sides"
    p2="$fronts"; p2rev="$PASS2_REVERSE"; p2name="front sides"
  else
    p1="$fronts"; p1rev="$PASS1_REVERSE"; p1name="front sides"
    p2="$backs";  p2rev="$PASS2_REVERSE"; p2name="back sides"
  fi

  # How many sheets each pass covers, per copy.
  local evens_n=$(( sides / 2 )) odds_n=$(( (sides + 1) / 2 ))
  local p1_n p2_n blanks
  if [ "$PASS_ORDER" = "evens-first" ]; then p1_n=$evens_n; p2_n=$odds_n
  else                                       p1_n=$odds_n;  p2_n=$evens_n
  fi
  sheets=$(( p1_n * copies ))
  blanks=$(( (p2_n - p1_n) * copies ))
  [ "$blanks" -lt 0 ] && blanks=0

  # Copies go in a single pass, so there is only ever one flip. That is safe
  # because the copies are identical: reversing the whole job produces the same
  # sequence as reversing within each copy.
  #
  # Collation must match across both passes, and for an odd-page document with
  # more than one copy it must be OFF. Collated output groups each copy
  # together, which bunches all the blank sheets at the top instead of one per
  # copy; uncollated groups by sheet, so the blanks land where they belong.
  COPIES_N="$copies"
  COLLATE_V="true"
  [ "$blanks" -gt 0 ] && [ "$copies" -gt 1 ] && COLLATE_V="false"

  note=""
  if [ "$blanks" -gt 0 ]; then
    note="

Could not add a blank page automatically, so this pass needs $blanks more sheet(s) than the last one printed. Add $blanks blank sheet(s) on TOP of the stack before continuing."
  fi

  local label=""
  [ "$copies" -gt 1 ] && label="  ($copies copies)"

  one_pass_pair "$pdf" "$title" \
                "$p1" "$p1rev" "$p1name" \
                "$p2" "$p2rev" "$p2name" \
                "$sheets" "$note" "$label"

  log "job '$title' complete"
  exit 0
}

# ---------------------------------------------------------------------------
# Calibration - works out this printer's stacking convention once
# ---------------------------------------------------------------------------

make_test_pdf() {
  # Writes a valid 4-page PDF (one big numeral per page) to $1.
  # Built by hand so there is nothing to install; xref offsets are computed
  # from the actual byte lengths rather than assumed.
  local out="$1"
  local -a objs
  local i n label

  objs[1]='<< /Type /Catalog /Pages 2 0 R >>'
  objs[2]='<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R 9 0 R] /Count 4 >>'

  n=3
  for i in 1 2 3 4; do
    case $i in
      1) label='FRONT of sheet 1  (page 1)' ;;
      2) label='BACK of sheet 1  (page 2)' ;;
      3) label='FRONT of sheet 2  (page 3)' ;;
      4) label='BACK of sheet 2  (page 4)' ;;
    esac
    objs[$n]="<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 11 0 R >> >> /Contents $((n+1)) 0 R >>"
    local stream="BT /F1 200 Tf 240 430 Td ($i) Tj ET
BT /F1 16 Tf 90 340 Td ($label) Tj ET
BT /F1 12 Tf 90 300 Td (manual-duplex calibration sheet) Tj ET"
    objs[$((n+1))]="<< /Length ${#stream} >>
stream
${stream}
endstream"
    n=$((n+2))
  done
  objs[11]='<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'

  # Emit, recording the byte offset of each object as we go.
  local -a offsets
  : >"$out"
  # Octal escapes rather than \xHH: portable back to bash 3.2's printf.
  printf '%%PDF-1.4\n%%\342\343\317\323\n' >>"$out"
  for i in $(seq 1 11); do
    offsets[$i]=$(wc -c <"$out" | tr -d ' ')
    printf '%d 0 obj\n%s\nendobj\n' "$i" "${objs[$i]}" >>"$out"
  done

  local startxref
  startxref=$(wc -c <"$out" | tr -d ' ')
  {
    printf 'xref\n0 12\n'
    printf '0000000000 65535 f \n'
    for i in $(seq 1 11); do printf '%010d 00000 n \n' "${offsets[$i]}"; done
    printf 'trailer\n<< /Size 12 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' "$startxref"
  } >>"$out"
}

calibrate() {
  local tmp="${TMPDIR:-/tmp}/manual-duplex-calibration.pdf"
  make_test_pdf "$tmp"

  [ "$(dialog "Calibration prints 2 sheets to work out how your printer stacks paper. You only ever do this once.

Load at least 2 sheets, then click Start." "Start" "Cancel")" = "Start" ] || exit 0

  # Calibrate whichever mode is configured, so the answer applies to real jobs.
  local jobid p1 p2 p1n p2n key partner other
  if [ "$PASS_ORDER" = "evens-first" ]; then
    p1="2,4"; p1n="back sides";  p2="1,3"; p2n="front sides"
    key="2"; partner="1"; other="3"
  else
    p1="1,3"; p1n="front sides"; p2="2,4"; p2n="back sides"
    key="1"; partner="2"; other="4"
  fi

  jobid=$(pass_submit "$tmp" "Duplex calibration [$p1n]" "$p1" "$PASS1_REVERSE") || fail "The printer rejected the job. See the log for details."
  wait_for_job "$jobid" "$(estimate_timeout 2)"

  [ "$(dialog "You should now have 2 sheets, printed on one side.

$FLIP_HINT

Click Continue when loaded." "Continue" "Cancel")" = "Continue" ] || exit 0

  jobid=$(pass_submit "$tmp" "Duplex calibration [$p2n]" "$p2" "yes") || fail "The printer rejected the job. See the log for details."
  wait_for_job "$jobid" "$(estimate_timeout 2)"

  # One question tells us whether the sheets fed back in the order the second
  # pass assumed. That is the only thing that varies between printers.
  local answer
  answer=$(dialog "Find the sheet with $key on it.

What is printed on the other side of it?" "$partner" "$other")

  case "$answer" in
    "$partner") PASS2_REVERSE="yes" ;;
    "$other")   PASS2_REVERSE="no"  ;;
    *) exit 0 ;;
  esac

  save_config
  rm -f "$tmp"
  alert "Calibrated.

Print anything, choose PDF > Print Two-Sided, and follow the prompt."
}

setup() {
  if [ "$(dialog "Two-Sided Printing lets a printer with no duplexer print on both sides.

It prints the fronts, waits while you flip the stack, then prints the backs.

Two quick questions and you are set up." "Get Started" "Cancel")" != "Get Started" ]; then
    exit 0
  fi

  pick_printer
  save_config

  if [ "$(dialog "Printer: $PRINTER_LABEL

Now a 2-sheet calibration, to work out which way your printer stacks paper.

Skipping means the first real job may come out back-to-front - which is the one mistake this tool exists to prevent." "Calibrate" "Skip")" = "Calibrate" ]; then
    calibrate
  else
    alert "Saved.

Print anything, choose PDF > Print Two-Sided, and follow the prompt.

Run calibration later with:  manual-duplex --calibrate"
  fi
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
    [ -x "$app/Contents/MacOS/applet" ] \
      && echo "$ok bundle executable present" \
      || echo "$bad bundle looks incomplete - reinstall"
  else
    echo "$bad not installed."
    echo "       Printing from Preview, TextEdit or Pages will silently do"
    echo "       nothing without it. Reinstall with: bash install.sh"
  fi

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
    echo "       order=$PASS_ORDER  pass1_rev=$PASS1_REVERSE  pass2_rev=$PASS2_REVERSE"
  else
    echo "$bad configured queue '$PRINTER' is not available"
  fi

  echo
  echo "Handoff test (simulates exactly what the print dialog does)"
  if [ ! -x "$svc" ]; then
    echo "$bad skipped - PDF Service not installed"
  else
    local tmp before after
    tmp="${TMPDIR:-/tmp}/manual-duplex-doctor.pdf"
    make_test_pdf "$tmp"
    before=$( [ -f "$LOG" ] && wc -l <"$LOG" || echo 0 )
    echo "       invoking the service with a 4-page test document..."
    "$svc" "Doctor test" "" "$tmp" >/dev/null 2>&1
    sleep 4
    after=$( [ -f "$LOG" ] && wc -l <"$LOG" || echo 0 )
    if [ "$after" -gt "$before" ]; then
      echo "$ok the service ran and the engine started. Recent log:"
      tail -n $(( after - before )) "$LOG" | sed 's/^/       /'
      echo
      echo "       If paper came out, everything works and you can print normally."
    else
      echo "$bad the service ran but the engine never logged anything."
      echo "       The handoff is being killed. Reinstall with: bash install.sh"
    fi
    rm -f "$tmp"
  fi
  echo
}

status() {
  local first="back sides (evens) first"
  [ "$PASS_ORDER" = "odds-first" ] && first="front sides (odds) first"
  alert "Printer:  ${PRINTER_LABEL:-none selected}
Queue:  ${PRINTER:-none}
Order:  $first
Pass 1 reversed:  $PASS1_REVERSE
Pass 2 reversed:  $PASS2_REVERSE
Settings passthrough:  $([ "${PASSTHROUGH_ENABLED:-1}" = "1" ] && echo on || echo off)

Print anything and choose PDF > Print Two-Sided."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

load_config

# Config written before labels existed, or a printer renamed since: fill it in.
if [ -n "$PRINTER" ] && [ -z "$PRINTER_LABEL" ]; then
  PRINTER_LABEL=$(printer_label "$PRINTER")
fi

# Drop keys from the older schemes and adopt the current defaults. Deliberately
# does NOT carry the old fronts-first setting over - evens-first is the intended
# behaviour now, and silently preserving the previous mode would mean the new
# default never actually takes effect.
if [ -n "${EVEN_ORDER:-}" ] || [ -n "${FRONT_ORDER:-}" ]; then
  unset EVEN_ORDER FRONT_ORDER
  save_config
  log "migrated config to PASS_ORDER=$PASS_ORDER rev=$PASS1_REVERSE/$PASS2_REVERSE"
fi

case "${1:-}" in
  --setup)     setup; exit 0 ;;
  --calibrate) [ -z "$PRINTER" ] && pick_printer; calibrate; exit 0 ;;
  --printer)   pick_printer; save_config; status; exit 0 ;;
  --status)    status; exit 0 ;;
  --doctor)    doctor; exit 0 ;;
  --config)    open -t "$CONFIG" 2>/dev/null || cat "$CONFIG"; exit 0 ;;
  --log)       cat "$LOG"; exit 0 ;;
  --help|-h)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    echo "       manual-duplex --doctor | --status | --setup | --calibrate" >&2
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

[ -z "$PRINTER" ] && { pick_printer; save_config; }

# Printer may have been removed or renamed since we saved it.
if ! lpstat -p "$PRINTER" >/dev/null 2>&1; then
  log "configured printer '$PRINTER' is gone; reselecting"
  pick_printer; save_config
fi

run_duplex "$PDF" "$TITLE"
