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
Only the optional helper queues need your password; everything else installs into your
home folder.

## Use

**File → Print → PDF dropdown (bottom-left) → Print Two-Sided**

1. Fronts print.
2. A dialog tells you to flip the stack. Flip it, click **Print Backs**.
3. Backs print.

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

macOS hands a PDF Service the print options you picked, so both passes are printed with
the same settings rather than falling back to the queue defaults:

| Setting | Behaviour |
|---|---|
| Quality (draft / normal / best) | forwarded |
| Colour vs greyscale | forwarded |
| Paper type, paper size, tray | forwarded |
| Vendor-specific HP options | forwarded |
| Layout / pages-per-sheet (N-up) | forwarded, and the split accounts for it |
| Copies | handled specially — see below |
| Page range | already applied to the spooled PDF |
| Two-sided setting | ignored, obviously |

Anything that selects pages or ordering is deliberately stripped before forwarding, since
that is the one thing this tool has to control itself.

If some vendor option ever makes `lp` reject a job, set `PASSTHROUGH_ENABLED=0` in
`~/.config/manual-duplex/config` to fall back to queue defaults.

### Copies

Asking for 3 copies runs the front/back cycle three times, prompting between each, rather
than sending `copies=3` in one job. That is deliberate: a single multi-copy job interleaves
the copies in the output stack, and reversing then applies *across* copies instead of
within one — which is exactly how page 2 ends up on the back of page 7.

Three prompts instead of one, in exchange for never re-printing a ruined stack.

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

An odd-page document has one more sheet than it has even pages, so with evens-first the
first pass comes up a sheet short. A 7-page document has 4 sheets but only 3 even pages.

The tool detects this and the flip prompt tells you to **add one blank sheet on top of the
stack**. Pass 2 prints in reverse, so the highest page comes out first and lands on that
blank sheet:

```
pass 1 sends       6, 4, 2          (3 sheets)
feed after flip    blank, 6, 4, 2   (you added one on top)
pass 2 sends       7, 5, 3, 1
result             7/blank, 5/6, 3/4, 1/2
```

With `odds-first` there's no extra sheet — the last sheet simply keeps a blank back.

## How it works

No PDF splitting and no dependencies. macOS `lp` already accepts page selection and output
ordering, so the whole thing is two calls:

```bash
lp -o page-ranges=2,4,6,8,10 -o outputorder=reverse \
   -o cupsPrintQuality=5 -o ColorModel=Gray doc.pdf     # pass 1: backs
lp -o page-ranges=1,3,5,7,9  -o outputorder=reverse \
   -o cupsPrintQuality=5 -o ColorModel=Gray doc.pdf     # pass 2: fronts
```

A PDF Service tool is invoked with three parameters — document title, a string of the CUPS
print options for the job, and the path to the spooled PDF. Parsing the second one is what
makes the settings passthrough above possible.

Everything else is page counting (PDFKit via `osascript -l JavaScript`, falling back to
Spotlight metadata, falling back to asking you), waiting for the first pass to actually
finish before prompting, and remembering your settings.

It installs as a **PDF Service** — an executable in `~/Library/PDF Services` that macOS
lists in every print dialog's PDF menu. This deliberately avoids the CUPS printer-driver
API, which Apple deprecated back in CUPS 2.3 and intends to remove.

## The helper queues

**Opt-in, via `bash install.sh --with-queues`.** They are the only part that needs an admin
password, and the only part whose behaviour isn't verified.

If the password prompt ever appears and the installer carries straight on without waiting,
that means `sudo` was handed EOF instead of your keystrokes — it happens when the script is
run without a real terminal (piped, or via an editor's run button). The installer now reads
the password from `/dev/tty` and skips the queues cleanly if there's no terminal, rather
than half-creating them.

These add two entries to your printer list:

- `<printer>-Two-Sided-1-Fronts`
- `<printer>-Two-Sided-2-Backs`

These give you a printer-list entry rather than a PDF-menu entry, but they rely on the
CUPS `page-set` option, which some driverless queues silently ignore.

**Verify once:** print a 4-page document to `...Two-Sided-1-Fronts`. If you get pages 1
and 3, they work. If you get all 4, your queue ignores `page-set` — remove them and use
the PDF dropdown, which computes explicit page ranges and always works.

The PDF Service is the reliable path. The queues are a convenience.

## Files it touches

| Path | What |
|---|---|
| `~/.local/bin/manual-duplex` | the engine |
| `~/Library/PDF Services/Print Two-Sided` | the print-dialog menu item |
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

bash install.sh              # install (no password needed)
bash install.sh --with-queues # also add helper printer queues (needs sudo)
bash install.sh --uninstall   # remove everything
```

The plain install never asks for a password. Only `--with-queues` does, and it asks once
up front rather than partway through.

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

## The Continue prompt disappears on its own

Talking to System Events is an Apple Event, and Apple Events time out after **120 seconds**
by default. Take longer than two minutes to flip the stack — easy when an odd-page job asks
you to find a blank sheet — and the event times out and the dialog vanishes, leaving the
backs unprinted.

Every dialog is now wrapped in `with timeout of 86400 seconds`, and the flip prompt
re-shows itself if it ever comes back empty. An empty answer is treated as "something went
wrong", not as Cancel, so a hiccup can't abandon a half-printed stack. Only clicking
**Cancel** stops the job.

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
