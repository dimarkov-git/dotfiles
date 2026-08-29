#!/bin/bash

# Pins a Claude session to the tty it runs on. Unlike a terminal id, a tty is
# unique per tab and inherited intact, so resume and splits cannot collide.

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

# This hook runs detached (its own tty reads "??"), so both the tab and the
# liveness marker come from the `claude` process up the parent chain.
claude_pid=$PPID
walk=$PPID
while [ -n "$walk" ] && [ "$walk" != "1" ]; do
    case "$(/bin/ps -o comm= -p "$walk" 2>/dev/null)" in
        *claude) claude_pid=$walk; break ;;
    esac
    walk=$(/bin/ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')
done

tty_name=$(/bin/ps -o tty= -p "$claude_pid" 2>/dev/null | tr -d ' ')
[ "$tty_name" = "??" ] && tty_name=""

started=$(/usr/bin/sed -n 's/.*"started"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$file" 2>/dev/null | head -1)
[ -n "$started" ] || started=$(date +%s)

/bin/cat > "$file" <<EOF
{
  "session_id": "$session_id",
  "tty": "$tty_name",
  "pid": $claude_pid,
  "cwd": "$cwd",
  "started": $started,
  "busy": false, "waiting_since": null
}
EOF

exit 0
