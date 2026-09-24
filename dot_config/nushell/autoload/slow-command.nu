# Notify when a slow command finishes; cmux itself holds the banner back for a
# focused pane.

const THRESHOLD = 30sec

# Interactive or long by nature — notifying on these is pure noise.
const IGNORED = ["nu" "claude" "codex" "yazi" "k9s" "lazygit" "btop" "ssh" "fzf" "bat" "less" "nano" "zed" "sudo"]

export-env {
    # `history` reads the whole sqlite db, not just this session — without a
    # birth stamp a new tab notifies about the previous tab's last slow command.
    $env.SLOW_CMD_BORN = (date now)
}

$env.config.hooks.pre_prompt = (
  $env.config.hooks.pre_prompt?
  | default []
  | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "slow-command-notify")) }
  | append {
    name: "slow-command-notify"
    code: { ||
      if not ("CMUX_SURFACE_ID" in $env) { return }

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

      let status = (if ($entry.exit_status? | default 0) == 0 { "✓" } else { "✗" })
      let body = ($cmd | split chars | first 120 | str join)
      do -i { ^cmux notify --title $"($status) ($dur)" --body $body } | complete | ignore
    }
  }
)
