# Security Policy

## Reporting a vulnerability

Please report privately rather than opening a public issue.

- **Preferred:** GitHub → *Security* tab → *Report a vulnerability* (private advisory)
- **Alternative:** yasaslive@gmail.com

Include what you did, what happened, and the macOS version. A log excerpt from
`~/.config/manual-duplex/manual-duplex.log` usually helps — **redact document titles first**,
since the log records them.

This is a spare-time project with no SLA. Expect an acknowledgement within a week or so.
Please allow a reasonable window to fix before disclosing publicly.

## Supported versions

Only the latest commit on the default branch. There are no release branches and no
backports — if you're running an older copy, update before reporting.

## What this software does

Worth knowing before assessing risk:

- Runs **entirely as your user account**. No root, no `sudo`, no setuid, no admin rights.
  The installer refuses to run as root.
- **Nothing persistent.** No LaunchAgent, LaunchDaemon, cron entry or login item. The
  engine exists only while a print job is in flight and exits when it finishes.
- **No network access.** It talks to `lp`/`lpstat` on the local machine. It does not
  connect anywhere, phone home, or transmit telemetry. Your printer may be on the network,
  but that traffic is CUPS's, not ours.
- **No dependencies.** Only tools shipped with macOS: `lp`, `lpstat`, `osascript`,
  `iconutil`, `osacompile`.

Installed files, all inside your home folder:

```
~/.local/bin/manual-duplex                     the engine
~/Library/PDF Services/Print Two-Sided         the print-dialog menu item
~/Applications/Two-Sided Printing.app          the launcher
~/.config/manual-duplex/                       config, log, working copies (mode 700)
```

## Threat model

### Untrusted input it handles

| Input | Source | Handling |
|---|---|---|
| The PDF being printed | any app | passed to `lp` as a file argument; never parsed by the shell |
| Print options (`$2`) | macOS print system | filtered by strict shape before use — see below |
| Document title (`$1`) | the printing app | only used in the job title and log |
| Printer names | CUPS | quoted throughout |
| Config file | your home folder | **executed** — see below |

### Print options are filtered, not trusted

macOS passes its internal print-settings dictionary, whose values contain spaces and
arbitrary text. A token is forwarded to `lp` only if it is `key=value`, the key matches
`^[A-Za-z][A-Za-z0-9_-]*$`, and the value is non-empty. Everything else is dropped.

This started as a correctness fix — unfiltered values produced `lp -o Two-Sided -o 11 -o
Pages` and stalled the printer — but it doubles as the main input-validation boundary.

Options are passed as separate array elements, never through a shell string, so a hostile
value cannot become a command. There is **no `eval`** anywhere in the codebase.

### The config file is executed

`~/.config/manual-duplex/config` is sourced as shell, so anything in it runs as you. That is
fine for a file only you can write, and the tool now enforces it:

- the config directory is created mode `700`
- the config is written with `umask 077`
- it is **not loaded** if it is group- or world-writable — the engine logs a refusal and
  falls back to defaults

If you edit it by hand, keep it `600`.

### Filenames cannot inject options

`lp` is always invoked with `--` before the filename, so a document called `-o something`
is treated as a file, not as an option.

### Dialog text is escaped

Text shown in dialogs is escaped for backslashes and double quotes before being embedded in
AppleScript. Document titles reach the dialogs, so this matters if you print a file with a
hostile name.

Dialogs are shown by `osascript` itself rather than through `System Events`, so the tool
does **not** request or rely on Automation permission.

## Privacy

- **Copies of what you print** are written to `~/.config/manual-duplex/jobs/` while a job
  runs, and deleted when it finishes. If the engine is force-killed, a copy can survive
  there. The folder is mode `700`.
- **The log records document titles** (`job 'Quarterly Report.pdf' pages=12`). It never
  records document contents. Delete it any time:
  ```bash
  rm ~/.config/manual-duplex/manual-duplex.log
  ```
- Nothing is sent off the machine.

## Known limitations, accepted

Not vulnerabilities, but worth stating so nobody reports them as such:

- **Not code-signed or notarized.** You are expected to read the source and install it
  yourself. Distributing it to others would need signing.
- **A `.mdopts` sidecar** is briefly written beside the spool file to carry print settings
  past the macOS sandbox. It contains print settings only — no document content — and is
  deleted when read.
- **No integrity checking of the install.** Anything that can write to your home folder can
  modify the engine. At that point it is already game over for your account, so the tool
  does not pretend otherwise.
- **It drives a printer.** Worst realistic outcome of a bug is wasted paper, not compromise.

## Out of scope

- Vulnerabilities in macOS, CUPS, or printer firmware — report those upstream.
- Anything requiring an attacker who already has write access to your home folder or root.
- Physical access to the printer or the printed output.
