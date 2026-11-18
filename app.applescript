-- Two-Sided Printing.app
--
-- Copyright (C) 2026 Yasas Alwis
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.
--
-- Compiled by install.sh with osacompile. This exists because of a macOS
-- sandbox restriction, not because AppleScript is a good fit.
--
-- Since Big Sur the printtool process that runs items in ~/Library/PDF Services
-- is sandboxed. A shell script placed there cannot reliably write files or
-- spawn long-running processes - it fails silently, which is exactly what you
-- see when printing from a sandboxed app like Preview.
--
-- An application launched through LaunchServices runs in the normal user
-- session instead, outside that sandbox. So the PDF Service shell script does
-- one permitted thing - `open -a` this app with the spool file - and everything
-- real happens here.

on run
	-- Double-clicked with no document: offer setup.
	runEngine("--setup", "", "")
end run

on open theFiles
	repeat with f in theFiles
		handlePDF(POSIX path of (f as text))
	end repeat
end open

on handlePDF(spoolPath)
	set homePath to POSIX path of (path to home folder)
	set jobsDir to homePath & ".config/manual-duplex/jobs"

	do shell script "/bin/mkdir -p " & quoted form of jobsDir

	-- Take our own copy: the print system reclaims the spool file.
	set stamp to do shell script "/bin/date +%Y%m%d-%H%M%S"
	set copyPath to jobsDir & "/" & stamp & "-" & (random number from 1000 to 9999) & ".pdf"
	do shell script "/bin/cp " & quoted form of spoolPath & " " & quoted form of copyPath

	-- Document title, from the spool file name the printing app chose.
	set docTitle to do shell script "/usr/bin/basename " & quoted form of spoolPath & " .pdf"

	-- The PDF Service script leaves the CUPS options beside the spool file when
	-- the sandbox permits it. Missing sidecar just means queue defaults.
	set optsPath to spoolPath & ".mdopts"
	set cupsOpts to ""
	try
		set cupsOpts to (do shell script "/bin/cat " & quoted form of optsPath)
		do shell script "/bin/rm -f " & quoted form of optsPath
	end try

	runEngine(docTitle, cupsOpts, copyPath)
end handlePDF

on runEngine(arg1, arg2, arg3)
	set homePath to POSIX path of (path to home folder)
	set enginePath to homePath & ".local/bin/manual-duplex"
	set logPath to homePath & ".config/manual-duplex/manual-duplex.log"

	set cmd to quoted form of enginePath & " " & quoted form of arg1 & " " & quoted form of arg2
	if arg3 is not "" then set cmd to cmd & " " & quoted form of arg3

	-- Detached, so the app can return and the flow keeps running.
	do shell script cmd & " >> " & quoted form of logPath & " 2>&1 &"
end runEngine
