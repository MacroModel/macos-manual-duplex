# manual-duplex

Two-sided printing on a Mac for printers with no duplexer — like the HP Smart Tank 510.

Instead of remembering to open the print dialog, find "Two-sided (Duplex) Printing", pick
"Print On Both Sides Manually", and hope you reload the paper the right way round, you pick
one menu item and follow a prompt.

![icon](icon.png)

## Install

```bash
cd manual-duplex
chmod +x install.sh manual-duplex.sh
./install.sh
```

The installer walks you through picking your printer and running a 2-sheet calibration.
It never asks for a password — everything installs into your home folder.

## Use

**File → Print → PDF dropdown (bottom-left) → Print Two-Sided**

1. The back sides print (evens-first is the default).
2. A dialog tells you to flip the stack. Flip it, click **Continue**.
3. The other sides print.

Works from any app that can print — Word, Chrome, Preview, Mail, anything.

## Why calibration matters

The one thing that ruins manual duplex is paper *stacking order*. Some printers eject
face-up, some face-down, and that decides which order the sheets feed back in after you
flip them. Get it wrong and page 2 lands on the back of page 7.

Calibration prints two sheets, asks you one question about what you're holding, and saves
the answer. You do it once. Re-run any time:

```bash
~/.local/bin/manual-duplex --calibrate
```

### What it's deciding

Calibration sets `PASS2_REVERSE` — whether the sheets fed back in the order the second
pass assumed. That's the only thing that genuinely varies between printers.

## Your print dialog settings carry over

Both passes print with the settings you picked, rather than falling back to queue defaults.

A caveat on how this works. Apple's documentation describes the PDF Service tool's second
argument as "a string that specifies the CUPS print options". In practice it is Apple's
internal print-settings dictionary, and many of its values contain spaces:

```
com.apple.print.DialogDismissedBy=Print Two-Sided
com.apple.print.pageRange=All 11 Pages
```

Forwarding that verbatim produces nonsense like `lp -o Two-Sided -o 11 -o Pages`, which
CUPS accepts and the printer then silently sits on. So options are filtered by shape: a
token is only passed on if it is `key=value`, the key is a plain option name with no dots,
and the value is non-empty. What survives:

| Setting | Behaviour |
|---|---|
| Quality (draft / normal / best) | forwarded |
| Colour vs greyscale | forwarded |
| Paper type, paper size, tray | forwarded |
| Vendor-specific HP options | forwarded |
| Layout / pages-per-sheet (N-up) | forwarded, and the split accounts for it |
| Copies | forwarded, single pass — see below |
| Page range | already applied to the spooled PDF |
| Two-sided setting | ignored, obviously |

Anything that selects pages or ordering is deliberately stripped before forwarding, since
that is the one thing this tool has to control itself.

If some vendor option ever makes `lp` reject a job, set `PASSTHROUGH_ENABLED=0` in
`~/.config/manual-duplex/config` to fall back to queue defaults.

### Copies

All copies print in a single pass, so there is only ever **one flip** no matter how many
you ask for. That is safe because the copies are identical: reversing the whole job
produces the same sequence as reversing within each copy.

Collation is set explicitly, because it has to match across both passes or the sheets stop
lining up.

### Pages per sheet

The split works in *sheet sides*, not document pages. An 8-page document at 2-up is 4
sides on 2 sheets, so it prints fronts `1-2,5-6` and backs `3-4,7-8`.

## Print order

Default is **evens-first**, both passes reversed. A 10-page document prints:

```
pass 1   10, 8, 6, 4, 2      the back sides
   ...flip the stack...
pass 2    9, 7, 5, 3, 1      the front sides
```

Each sheet pairs correctly and the finished stack lands in reading order.

Switch to `PASS_ORDER="odds-first"` in the config for the other arrangement (fronts first,
`1,3,5,7` then `2,4,6`).

## Odd page counts

An odd-page document has one more sheet than it has even pages, so the first pass comes up
a sheet short. A 7-page document is 4 sheets but only 3 even pages.

**A blank page is appended to the document, so the printer feeds and ejects that sheet
itself.** No manual step. A 7-page job becomes an 8-page one and prints:

```
pass 1   8, 6, 4, 2      page 8 is blank - the sheet comes out empty
   ...flip...
pass 2   7, 5, 3, 1      page 7 lands on the back of that blank sheet
```

The padding is done with PDFKit through `osascript -l JavaScript`, which is part of macOS —
still no dependencies. Blank pages are sized to match the last real page, and the padded
copy is deleted when the job finishes.

Under N-up the padding fills whole sides: 6 pages at 2-up is 3 sides, so 2 blank pages are
added to make 4.

**If padding fails** the tool falls back to the old behaviour — the flip prompt asks you to
add a blank sheet on top of the stack by hand — rather than printing something wrong.

## How it works

No dependencies. macOS `lp` already accepts page selection and output
ordering, so the whole thing is two calls:

```bash
lp -o page-ranges=2,4,6,8,10 -o outputorder=reverse \
   -o cupsPrintQuality=5 -o ColorModel=Gray doc.pdf     # pass 1: backs
lp -o page-ranges=1,3,5,7,9  -o outputorder=reverse \
   -o cupsPrintQuality=5 -o ColorModel=Gray doc.pdf     # pass 2: fronts
```

Everything else is page counting (PDFKit then CoreGraphics via `osascript -l JavaScript`,
falling back to a raw scan of the page tree, falling back to asking you), waiting for the
first pass to actually finish before prompting, and remembering your settings.

It hooks in as a **PDF Service** rather than a printer driver, deliberately: the CUPS
driver API was deprecated in CUPS 2.3 and is slated for removal.

## One printer, not three

Both passes go to your single installed printer — the same queue you already print to. All
that changes between them is the `-o page-ranges` argument:

```
lp -d HP_Smart_Tank_510_series__95C868_ -o page-ranges=2,4,6,8,10 -o outputorder=reverse ...
lp -d HP_Smart_Tank_510_series__95C868_ -o page-ranges=1,3,5,7,9  -o outputorder=reverse ...
```

Earlier versions could also add two extra printers to your list, `...-Two-Sided-1-Fronts`
and `-2-Backs`. That's been removed. It was the wrong shape for the problem: a print queue
has no way to pause and ask you to flip the paper, so it could never do the one thing this
tool exists to do — and it relied on the CUPS `page-set` option that driverless queues
often ignore.

If an earlier install left those queues behind, `install.sh` will point them out. Remove
them with:

```bash
sudo lpadmin -x <queue-name>
```

That is the only command in this project that needs a password, and it's only for cleaning
up something that shouldn't have existed.

## Files it touches

| Path | What |
|---|---|
| `~/.local/bin/manual-duplex` | the engine |
| `~/Library/PDF Services/Print Two-Sided` | the print-dialog menu item (sandboxed; hands off) |
| `~/Applications/Two-Sided Printing.app` | the launcher that does the work |
| `~/.config/manual-duplex/config` | printer + calibration result |
| `~/.config/manual-duplex/jobs/` | working copies of spooled PDFs, deleted after each job |
| `~/.config/manual-duplex/manual-duplex.log` | job history, for when something looks wrong |

## Commands

```bash
manual-duplex --doctor      # diagnose "nothing happened when I pressed Print"
manual-duplex --status      # which printer, calibration state
manual-duplex --printer     # switch printer
manual-duplex --setup       # pick printer, calibrate
manual-duplex --calibrate   # redo calibration only
manual-duplex --config      # open the settings file
manual-duplex --log         # what happened on recent jobs

bash install.sh             # install
bash install.sh --uninstall # remove everything
```

The install never asks for a password. Everything lives in your home folder.

## Icon

`icon.svg` is the source. `install.sh` builds `icon.iconset` into a `.icns` with
`iconutil` (part of macOS) and installs it to `~/.config/manual-duplex/`, so the artwork
appears in every prompt instead of the generic system alert badge. If the build fails the
dialogs fall back to the standard icon — cosmetic only, nothing breaks.

To change it, edit the SVG and re-render the ten sizes in `icon.iconset/`.

Note that macOS does *not* show icons in the print dialog's PDF dropdown itself — that menu
is text-only. The icon shows in the prompts, which is where you actually look.

## Printer names

CUPS mangles printer names into identifiers: your printer is
`HP_Smart_Tank_510_series__95C868_` internally. The UI reads the real description from CUPS
and shows **HP Smart Tank 510 series**, marks the system default, and maps your choice back
to the queue name behind the scenes.

If a printer has no description, the queue name is de-mangled instead. That de-mangling
drops a trailing hex serial (`95C868`) but deliberately keeps model numbers — `EPSON_ET_2850`
stays "EPSON ET 2850" rather than being truncated to "EPSON ET".

## "Error running print workflow"

That's macOS's generic PDF Service failure. It appears when the workflow tool exits
non-zero **or takes too long** — and it tells you nothing about which.

The tool is built to never trigger it:

- **The wrapper returns in milliseconds.** The print system expects a PDF Service to
  consume the spool file and exit. The duplex flow blocks for minutes waiting for you to
  flip paper, so holding the workflow open makes macOS abandon it — reliably, if another
  job is already printing. The wrapper instead copies the spool file, launches the engine
  detached, and exits 0 immediately.
- **The engine never exits non-zero.** Real problems are reported in a dialog and written
  to the log, so you get a message that says what happened.
- **PATH is set explicitly.** PDF Services run with a minimal environment; the engine does
  not rely on the caller's PATH to find `lp`, `lpstat` or `osascript`.

If it ever appears again, the log has the detail:

```bash
manual-duplex --log
```

## The sandbox problem (why there's an app bundle)

Since Big Sur, `printtool` — the process that runs items in `~/Library/PDF Services` — is
itself sandboxed. Scripts placed there can't reliably write files or spawn processes, and
they fail **silently**: no error, no output, nothing printed.

This bites hardest when printing from a sandboxed app: **Preview, TextEdit, Pages, Mail**.
Non-sandboxed apps like Chrome are often unaffected, which is what makes it so confusing —
the same tool works from one app and does nothing from another.

The way around it is to hand off to a real application, which LaunchServices runs in the
normal user session, outside that sandbox. So the install has two parts:

```
~/Library/PDF Services/Print Two-Sided   tiny, sandboxed, does one thing: open -a
~/Applications/Two-Sided Printing.app    compiled from app.applescript, does the work
```

The PDF Service also drops the CUPS options in a `.mdopts` sidecar next to the spool file.
The sandbox often refuses that write; when it does, you lose only the quality/colour
passthrough for that job and the queue defaults apply.

## "No PDF was handed to Two-Sided Printing" appearing at random

A pre-1.0 version of the installer handed jobs off with `launchctl submit`. Those jobs
persist in your launchd domain and get respawned — and since the working copy of the PDF is
deleted once a job finishes, each respawn found no file and popped that dialog, with no
print anywhere in sight.

`install.sh` now clears them on every install and uninstall. To check by hand:

```bash
launchctl list | grep manualduplex          # should print nothing
```

The engine also no longer shows that dialog unless you ran it from a terminal. A launch
with no usable file just logs and exits.

## The prompt never appears, or disappears on its own

Two separate causes, both fixed.

**Automation permission.** Dialogs used to be shown via `tell application "System Events"`,
which is an Apple Event to another app — and macOS gates those behind the Automation
privacy permission. A shell script launched in the background has no application identity,
so the system denies it outright and does not even offer a prompt to approve:

```
execution error: Not authorized to send Apple events to System Events. (-1743)
```

`osascript` showing its own dialog needs no permission, so that is what it does now, with
`tell me to activate` to bring it forward.

**Apple Event timeouts.** While System Events was still involved, the 120-second default
Apple Event timeout also made the prompt vanish mid-flip. Gone with the same change.

The flip prompt additionally re-shows itself if it ever comes back empty. An empty answer
is treated as "something went wrong", not as Cancel, so a hiccup cannot abandon a
half-printed stack. Only clicking **Cancel** stops the job.

## How long it waits before complaining

Each pass gets a time budget worked out from the job itself, rather than a fixed cap. A
fixed number is wrong at both ends — it nags on a two-page draft and expires mid-print on a
long one:

```
sides x copies x seconds-per-side x 2 (headroom)  +  3 min base
```

Seconds-per-side comes from the quality setting — 8s at draft, 20s normal, up to 60s at
best — multiplied by 1.5 for colour. Clamped to a 5-minute floor and a 6-hour ceiling.

| Job | Budget |
|---|---|
| 2 sides, draft, greyscale | 5 min |
| 5 sides, best, colour | 18 min |
| 15 sides (3 copies), best, colour | 48 min |
| 40 sides, best, colour | 2 hrs |

Hitting the budget is not fatal — it asks whether to continue or stop, since the printer may
just be paused or jammed. The log shows the budget for each pass and progress every 60s.

It also gives up early, regardless of budget, if the queue goes disabled — that will never
drain no matter how long you wait.

## Nothing happens at all

Run the health check — it tests each link in the chain separately and simulates exactly
what the print dialog does:

```bash
~/.local/bin/manual-duplex --doctor
```

The likely cause is the handoff being killed. `nohup … &` alone is not enough on macOS:
when the workflow tool returns, the process group can be torn down and the engine dies
with it — no output, no error, nothing in the log past the wrapper line. The wrapper
therefore prefers `launchctl submit`, which runs the engine in the user's launchd domain,
detached from the process group but still inside the GUI session so its dialogs appear.

The wrapper logs **every** invocation. If the log has no `wrapper: invoked` line after you
press Print, macOS never ran the item — check that it's executable:

```bash
ls -l ~/Library/PDF\ Services/
```

## Known limits

- A jam mid-stack leaves you half-printed. The log records the exact page ranges, so you
  can re-send the backs by hand with `lp -o page-ranges=...`.
- Page count for encrypted or damaged PDFs may fail; it asks you rather than guessing.
- Not sandboxed, so it can't ship on the Mac App Store. Fine for personal use; if you ever
  distribute it, it needs notarizing.
