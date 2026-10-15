-- Clicks "Quit anyway" in Claude's "Claude is still working" dialog (a sheet or a window), for Rotor autopilot.
on logLine(t)
	do shell script "echo \"$(date '+%FT%T') quitter: " & t & "\" >> $HOME/.claude/rotor-autopilot/autopilot.log"
end logLine
my logLine("started")
set lastErr to ""
repeat 150 times
	try
		tell application "System Events"
			if not (exists process "Claude") then
				my logLine("Claude gone; done")
				exit repeat
			end if
			tell process "Claude"
				repeat with w in windows
					if exists sheet 1 of w then
						if exists button "Quit anyway" of sheet 1 of w then
							click button "Quit anyway" of sheet 1 of w
							my logLine("clicked Quit anyway (sheet)")
						end if
					end if
					if exists button "Quit anyway" of w then
						click button "Quit anyway" of w
						my logLine("clicked Quit anyway (window)")
					end if
				end repeat
			end tell
		end tell
	on error e
		if e is not lastErr then
			my logLine("error: " & e)
			set lastErr to e
		end if
	end try
	delay 1
end repeat
