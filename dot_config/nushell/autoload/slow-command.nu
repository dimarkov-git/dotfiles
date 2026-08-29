# Notify when a slow command finishes in a tab that isn't in front. Tab state
# comes from Hammerspoon's tab-state.lua; without it this module stays silent.

const THRESHOLD = 30sec
const STATE = "~/.local/state/ghostty-tabs.json"

# Interactive or long by nature — notifying on these is pure noise.
const IGNORED = ["nu" "claude" "yazi" "k9s" "lazygit" "btop" "ssh" "fzf" "bat" "less" "nano" "zed" "sudo"]

export-env {
    # `history` reads the whole sqlite db, not just this session — without a
    # birth stamp a new tab notifies about the previous tab's last slow command.
    $env.SLOW_CMD_BORN = (date now)
}

# The mirror keys tabs by terminal id; this shell knows only its tty.
def _tab-in-front [] {
    let path = ($STATE | path expand)
    if not ($path | path exists) { return true }
    let st = (do -i { open $path } | default {})
    let active = ($st.active? | default "")
    if ($active | is-empty) { return false }
    (($st.tabs? | default {} | get -o $active | get -o tty | default "") == $env.GHOSTTY_TTY)
}

$env.config.hooks.pre_prompt = (
  $env.config.hooks.pre_prompt?
  | default []
  | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "slow-command-notify")) }
  | append {
    name: "slow-command-notify"
    code: { ||
      if ($env.GHOSTTY_TTY? | default "") == "" { return }

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
      let call = ([ "tabNotify('" $status " " ($dur | into string) "', '" $body "', '" $env.GHOSTTY_TTY "')" ] | str join)
      do -i { ^hs -c $call } | complete | ignore
    }
  }
)
