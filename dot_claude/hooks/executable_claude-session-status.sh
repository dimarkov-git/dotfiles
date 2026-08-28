#!/bin/bash

# Flips "busy" in the session file so the menubar reads a real state instead of
# guessing from Claude's spinner glyph. UserPromptSubmit -> busy, Stop -> idle.

set -uo pipefail

STATE_DIR="$HOME/.local/state/claude-sessions"
payload=$(cat)

field() { printf '%s' "$payload" | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

session_id=$(field session_id)
event=$(field hook_event_name)
[ -n "$session_id" ] || exit 0

file="$STATE_DIR/$session_id.json"
[ -f "$file" ] || exit 0

case "$event" in
    UserPromptSubmit) busy=true ;;
    Stop)             busy=false ;;
    *)                exit 0 ;;
esac

body=$(cat "$file")
if printf '%s' "$body" | /usr/bin/grep -q '"busy"'; then
    printf '%s' "$body" | /usr/bin/sed 's/"busy"[[:space:]]*:[[:space:]]*[^,}]*/"busy": '"$busy"'/' > "$file"
else
    printf '%s' "$body" | /usr/bin/sed 's/"waiting_since"/"busy": '"$busy"', "waiting_since"/' > "$file"
fi

exit 0
