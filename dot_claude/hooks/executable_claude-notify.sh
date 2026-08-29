#!/bin/bash

# Notification: raise a clickable banner via Hammerspoon, and stamp the moment
# the session started waiting so the menubar can age it.

set -uo pipefail

STATE_DIR="$HOME/.local/state/claude-sessions"
HS=/opt/homebrew/bin/hs
payload=$(cat)

field() { printf '%s' "$payload" | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

session_id=$(field session_id)
message=$(field message)
ntype=$(field notification_type)
cwd=$(field cwd)
file="$STATE_DIR/$session_id.json"

tty_name=$(/usr/bin/sed -n 's/.*"tty"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -1)

# Stamp the wait so elapsed time survives across ticks; the menubar reads it back.
if [ -f "$file" ]; then
    /usr/bin/sed -i '' "s/\"waiting_since\"[[:space:]]*:[[:space:]]*[^,}]*/\"waiting_since\": $(date +%s)/" "$file"
fi

[ -x "$HS" ] || exit 0

# A blocked session is worth interrupting for; a merely idle one can wait.
case "$ntype" in
    permission_prompt)   title="🔐 Claude — needs permission"; urgent=true ;;
    elicitation_dialog)  title="❓ Claude — question";          urgent=true ;;
    agent_needs_input)   title="👋 Agent — needs input";        urgent=true ;;
    agent_completed)     title="✅ Agent — done";               urgent=false ;;
    *)                   title="✳ Claude — waiting for input";  urgent=false ;;
esac

# A payload title is more specific than the type-derived one.
payload_title=$(field title)
[ -n "$payload_title" ] && title="$payload_title"

# Escaped for Lua: a prompt echoed into the message can carry quotes or newlines.
esc() { printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/' | tr -d '\n'; }

"$HS" -t 3 -c "claudeNotify(\"$(esc "$title")\", \"$(esc "${message:-waiting for input}")\", \"$(esc "${cwd##*/}")\", \"$(esc "$tty_name")\", \"$(esc "$ntype")\", $urgent)" >/dev/null 2>&1

exit 0
