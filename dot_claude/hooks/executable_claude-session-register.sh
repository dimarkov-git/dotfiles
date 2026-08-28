#!/bin/bash

# Maps a Claude session to its Ghostty terminal, resolved as the focused one —
# at SessionStart that is this session's tab. Titles and cwd are unreliable anchors.

set -uo pipefail

STATE_DIR="$HOME/.local/state/claude-sessions"
payload=$(cat)

field() { printf '%s' "$payload" | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

session_id=$(field session_id)
event=$(field hook_event_name)
cwd=$(field cwd)
[ -n "$session_id" ] || exit 0

mkdir -p "$STATE_DIR"
file="$STATE_DIR/$session_id.json"

if [ "$event" = "SessionEnd" ]; then
    rm -f "$file"
    exit 0
fi

# Ghostty exports the surface id of the tab this process runs in; despite the
# name it is the terminal id `focus` takes. Asking AppleScript for the *focused*
# tab instead pins whichever tab happened to be front, which is wrong for a
# session started in a background tab.
term_id="${GHOSTTY_TAB_ID:-}"
if [ -z "$term_id" ] && [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
    term_id=$(/usr/bin/osascript -e \
        'tell application "Ghostty" to return id of focused terminal of selected tab of front window' \
        2>/dev/null)
fi

# Keep a previously resolved terminal rather than blanking it: an unpinned
# session raises banners that do nothing on click.
if [ -z "$term_id" ]; then
    term_id=$(/usr/bin/sed -n 's/.*"terminal_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -1)
    # A closed tab's id would otherwise ride every resume forward, and `focus`
    # on a dead id fails silently — the click reads as broken, not as unpinned.
    # `run script`, not a bare tell: AppleScript launches Ghostty at compile
    # time, so validating a resumed id would resurrect the app it just left.
    if [ -n "$term_id" ]; then
        /usr/bin/osascript \
            -e 'tell application "System Events"' \
            -e 'if not (exists process "Ghostty") then return ""' \
            -e 'end tell' \
            -e 'return run script "tell application \"Ghostty\" to return id of every terminal"' \
            2>/dev/null | /usr/bin/grep -qF "$term_id" || term_id=""
    fi
fi

# A resumed session keeps its original start time; only the terminal is re-pinned.
started=$(/usr/bin/sed -n 's/.*"started"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$file" 2>/dev/null | head -1)
[ -n "$started" ] || started=$(date +%s)

/bin/cat > "$file" <<EOF
{
  "session_id": "$session_id",
  "terminal_id": "$term_id",
  "cwd": "$cwd",
  "started": $started,
  "waiting_since": null
}
EOF

exit 0
