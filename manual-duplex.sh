#!/bin/bash
#
# manual-duplex - two-sided printing for printers without a duplexer
#
# Invoked as a macOS PDF Service (from the PDF dropdown in any print dialog),
# or directly:   manual-duplex.sh [--calibrate|--setup|--config] [file.pdf]
#
# No dependencies beyond what ships with macOS. No PDF splitting: page
# selection is handed to CUPS via -o page-ranges.

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
on_exit() { [ -n "$CLEANUP_FILE" ] && rm -f "$CLEANUP_FILE"; return 0; }
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
# Dialog helpers (osascript). All dialogs are attached to System Events so they
# come to the front even though we are a background script.
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
  # `activate` matters: System Events is a faceless background app, so without
  # it the dialog can open behind the document window you just printed from -
  # the job looks stalled and the prompt is nowhere to be seen.
  osascript -e 'tell application "System Events"' -e 'activate' -e "$script" -e 'end tell' 2>/dev/null \
    | sed 's/.*button returned://; s/,.*//'
}

alert() {
  local text="$1"
  text="${text//\\/\\\\}"; text="${text//\"/\\\"}"
  osascript -e 'tell application "System Events"' -e 'activate' \
            -e "display dialog \"$text\" buttons {\"OK\"} default button \"OK\" with title \"$APP_NAME\" $ICON_CLAUSE" \
            -e 'end tell' >/dev/null 2>&1
}

choose_from() {
  # choose_from <prompt> <item1> <item2> ...
  local prompt="$1"; shift
  local list="" i
  for i in "$@"; do list+="\"${i//\"/\\\"}\", "; done
  list="${list%, }"
  osascript -e 'tell application "System Events"' -e 'activate' \
    -e "choose from list {$list} with prompt \"${prompt//\"/\\\"}\" with title \"$APP_NAME\"" \
    -e 'end tell' 2>/dev/null
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

  # 1. PDFKit via JavaScript for Automation. Present on every modern macOS.
  n=$(osascript -l JavaScript <<'JXA' "$f" 2>/dev/null
function run(argv) {
  ObjC.import('Quartz');
  var url = $.NSURL.fileURLWithPath(argv[0]);
  var doc = $.PDFDocument.alloc.initWithURL(url);
  if (!doc || doc.isNil()) { return ''; }
  return String(doc.pageCount);
}
JXA
  )
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  [ -n "$n" ] && [ "$n" -gt 0 ] && { printf '%s' "$n"; return 0; }

  # 2. Spotlight metadata. Often unavailable for files in /var/folders.
  n=$(mdls -raw -name kMDItemNumberOfPages "$f" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  [ -n "$n" ] && [ "$n" -gt 0 ] && { printf '%s' "$n"; return 0; }

  # 3. Ask the user rather than guessing wrong and wasting a stack of paper.
  n=$(osascript -e 'tell application "System Events"' -e 'activate' \
        -e 'display dialog "Could not read the page count automatically." & return & return & "How many pages is this document?" default answer "" with title "Two-Sided Printing"' \
        -e 'end tell' 2>/dev/null \
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

wait_for_job() {
  # Block until the job leaves the queue, so the flip prompt does not appear
  # while pages are still feeding.
  local jobid="$1" waited=0
  [ -z "$jobid" ] && { sleep 5; return 0; }
  while lpstat -W not-completed -o "$PRINTER" 2>/dev/null | grep -q "^$jobid "; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge 600 ]; then
      log "timeout waiting for $jobid"
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

opt_is_blocked() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    page-ranges|page-set|page-label|outputorder|output-order|copies|collate|\
    sides|multiple-document-handling|job-uuid|job-id|job-name|\
    job-originating-host-name|job-originating-user-name|ap_documentname|\
    document-name) return 0 ;;
    *duplex*|*tumble*|booklet*) return 0 ;;
  esac
  return 1
}

# Split the options string into tokens, honouring the quoting CUPS uses for
# values containing spaces. xargs does this without an eval.
passthrough_opts() {
  local raw="$1" tok key
  [ -z "$raw" ] && return 0
  printf '%s' "$raw" | xargs -n1 2>/dev/null | while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    key="${tok%%=*}"
    opt_is_blocked "$key" && continue
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

sheet_count() {
  # sheet_count <pages> <number-up>  -> physical sheets needed
  local pages="$1" k="$2" sides
  [ "$k" -lt 1 ] && k=1
  sides=$(( (pages + k - 1) / k ))
  printf '%s' "$(( (sides + 1) / 2 ))"
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

  jobid=$(pass_submit "$pdf" "$title [$p1name]$label" "$p1" "$p1rev") || fail "The printer rejected the job. See the log for details."
  if ! wait_for_job "$jobid"; then
    [ "$(dialog "The first pass is taking longer than expected - it may be paused or jammed.

Continue anyway?" "Continue" "Stop")" = "Continue" ] || exit 0
  fi

  if [ "$(dialog "Printed $sheets sheet(s) - the $p1name.$label

$FLIP_HINT$note

Click Continue when the paper is loaded." "Continue" "Cancel")" != "Continue" ]; then
    log "cancelled at flip prompt"
    exit 0
  fi

  jobid=$(pass_submit "$pdf" "$title [$p2name]$label" "$p2" "$p2rev") || fail "The printer rejected the job. See the log for details."
  wait_for_job "$jobid"
}

run_duplex() {
  local pdf="$1" title="${2:-Document}"
  local pages fronts backs sheets nup copies n note label

  pages=$(page_count "$pdf") || fail "Could not determine the page count. Nothing was printed."

  # Layout and copies come from the print dialog, not from us.
  nup=$(opt_value "${RAW_OPTS:-}" "number-up"); [ -z "$nup" ] && nup=1
  case "$nup" in ''|*[!0-9]*) nup=1 ;; esac
  [ "$nup" -lt 1 ] && nup=1

  copies=$(opt_value "${RAW_OPTS:-}" "copies"); [ -z "$copies" ] && copies=1
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

  fronts=$(side_ranges "$pages" "$nup" odd)
  backs=$(side_ranges "$pages" "$nup" even)
  sheets=$(sheet_count "$pages" "$nup")

  # Which pass runs first, and in which direction.
  local p1 p1rev p1name p2 p2rev p2name
  if [ "$PASS_ORDER" = "evens-first" ]; then
    p1="$backs";  p1rev="$PASS1_REVERSE"; p1name="back sides"
    p2="$fronts"; p2rev="$PASS2_REVERSE"; p2name="front sides"
  else
    p1="$fronts"; p1rev="$PASS1_REVERSE"; p1name="front sides"
    p2="$backs";  p2rev="$PASS2_REVERSE"; p2name="back sides"
  fi

  note=""
  if [ $((sides % 2)) -eq 1 ]; then
    if [ "$PASS_ORDER" = "evens-first" ]; then
      # Printing backs first leaves the run one sheet short: the final sheet has
      # no even side, so nothing feeds it in pass 1. Pass 2 prints in reverse,
      # so the highest page comes out first and needs that sheet fed first.
      sheets=$(( sides / 2 ))
      note="

IMPORTANT: this document has an odd number of sides, so pass 2 needs one more sheet than pass 1 printed.

Add ONE BLANK SHEET on top of the stack before continuing. Page $pages prints on it."
    else
      note="

Note: the last sheet's back stays blank. Leave it in the stack - it is handled."
    fi
  fi

  # Multiple copies are run as separate two-sided passes rather than by handing
  # copies=N to lp. A single N-copy job would interleave the copies in the
  # output stack, and outputorder=reverse would then reverse across copies
  # instead of within one - which is precisely how you end up with page 2 on
  # the back of page 7.
  n=1
  while [ "$n" -le "$copies" ]; do
    label=""
    [ "$copies" -gt 1 ] && label="  (copy $n of $copies)"
    one_pass_pair "$pdf" "$title" \
                  "$p1" "$p1rev" "$p1name" \
                  "$p2" "$p2rev" "$p2name" \
                  "$sheets" "$note" "$label"
    n=$(( n + 1 ))
  done

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
  wait_for_job "$jobid"

  [ "$(dialog "You should now have 2 sheets, printed on one side.

$FLIP_HINT

Click Continue when loaded." "Continue" "Cancel")" = "Continue" ] || exit 0

  jobid=$(pass_submit "$tmp" "Duplex calibration [$p2n]" "$p2" "yes") || fail "The printer rejected the job. See the log for details."
  wait_for_job "$jobid"

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
  fail "No PDF was handed to Two-Sided Printing.

If you ran this from Terminal, pass a file:
  manual-duplex.sh yourfile.pdf"
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
