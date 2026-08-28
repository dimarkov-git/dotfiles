# Notify when a slow command finishes in a tab that isn't in front. Tab state
# comes from Hammerspoon's tab-state.lua; without it this module stays silent.

const THRESHOLD = 10sec
const STATE = "~/.local/state/ghostty-tabs.json"

# Interactive or long by nature — notifying on these is pure noise.
const IGNORED = ["nu" "claude" "yazi" "k9s" "lazygit" "btop" "ssh" "fzf" "bat" "less" "nano" "zed" "sudo"]

# Resolved once at startup, while this tab is necessarily the selected one —
# there is no env var carrying it and no way to ask again later.
export-env {
    # `history` reads the whole sqlite db, not just this session — without a
    # birth stamp a new tab notifies about the previous tab's last slow command.
    $env.SLOW_CMD_BORN = (date now)

    $env.GHOSTTY_TAB_ID = (
        if ($env.TERM_PROGRAM? | default "") != "ghostty" { "" } else {
            # Hammerspoon already polled this; osascript costs ~76ms of startup,
            # so it is the fallback, not the first try.
            let mirror = (_tab-id-from-mirror)
            if ($mirror | is-not-empty) { $mirror } else {
                do -i {
                    # `run script`: a bare tell would launch Ghostty at compile
                    # time. This shell runs inside it, but a torn-down tab races.
                    ^osascript -e 'tell application "System Events"' -e 'if not (exists process "Ghostty") then return ""' -e 'end tell' -e 'return run script "tell application \"Ghostty\" to return id of focused terminal of selected tab of front window"'
                } | complete | get stdout | str trim
            }
        }
    )
}

# The active tab from the mirror, when it is fresh enough to be this shell's.
# Empty on a stale file, or when Ghostty was backgrounded (active goes blank).
def _tab-id-from-mirror []: nothing -> string {
    let path = ($STATE | path expand)
    if not ($path | path exists) { return "" }
    let st = (do -i { open $path } | default {})
    let updated = ($st.updated? | default 0)
    let now = (date now | into int) // 1_000_000_000
    # A new tab is younger than one poll interval, so a stale mirror would hand
    # back the previously focused tab's id.
    if ($now - $updated) > 3 { return "" }
    $st.active? | default ""
}

def _tab-in-front [] {
    let path = ($STATE | path expand)
    if not ($path | path exists) { return true }
    let st = (do -i { open $path } | default {})
    ($st.active? | default "") == $env.GHOSTTY_TAB_ID
}

$env.config.hooks.pre_prompt = (
  $env.config.hooks.pre_prompt?
  | default []
  | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "slow-command-notify")) }
  | append {
    name: "slow-command-notify"
    code: { ||
      if ($env.GHOSTTY_TAB_ID? | default "") == "" { return }

      let last = (history | last 1)
      if ($last | is-empty) { return }

      let entry = ($last | first)
      let dur = ($entry.duration? | default 0sec)
      if $dur < $THRESHOLD { return }

      let started = ($entry.start_timestamp? | default null)
      if $started == null or $started < ($env.SLOW_CMD_BORN? | default (date now)) { return }

      let cmd = ($entry.command? | default "" | str trim)
      let head = ($cmd | split row --regex '\s+' | first | default "")
      if ($head in $IGNORED) { return }

      # pre_prompt also fires on bare Enter; without this the last slow command
      # would re-notify on every prompt.
      if $cmd == ($env.SLOW_CMD_LAST? | default "") { return }
      $env.SLOW_CMD_LAST = $cmd

      if (_tab-in-front) { return }

      let status = (if ($entry.exit_status? | default 0) == 0 { "✓" } else { "✗" })
      let body = ($cmd | split chars | first 120 | str join | str replace --all (char sq) "")
      let call = ([ "tabNotify('" $status " " ($dur | into string) "', '" $body "', '" $env.GHOSTTY_TAB_ID "')" ] | str join)
      do -i { ^hs -c $call } | complete | ignore
    }
  }
)
