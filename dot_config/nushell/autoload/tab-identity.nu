# Publishes this shell's tty so Hammerspoon can pin the tab. tty is unique per
# tab and needs no lookup, unlike a terminal id, which has to be guessed.

const SHELL_DIR = "~/.local/state/ghostty-shells"

export-env {
    # `ps` reports "??" for a shell with no controlling terminal.
    $env.GHOSTTY_TTY = (
        if ($env.TERM_PROGRAM? | default "") != "ghostty" { "" } else {
            let t = (^ps -o tty= -p $nu.pid | complete | get stdout | str trim)
            if ($t | str starts-with "ttys") { $t } else { "" }
        }
    )

    if ($env.GHOSTTY_TTY | is-not-empty) {
        let dir = ($SHELL_DIR | path expand)
        mkdir $dir
        {
            tty: $env.GHOSTTY_TTY
            pid: $nu.pid
            cwd: $env.PWD
        } | to json | save -f ($dir | path join $"($env.GHOSTTY_TTY).json")
    }
    # Keeps cwd current so the tab can be matched by directory between polls.
    $env.config.hooks.env_change = (
      $env.config.hooks.env_change?
      | default {}
      | upsert PWD (
          $env.config.hooks.env_change?.PWD?
          | default []
          | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "tab-identity")) }
          | append {
              name: "tab-identity"
              code: { |before, after|
                  if ($env.GHOSTTY_TTY? | default "") == "" { return }
                  let f = ($SHELL_DIR | path expand | path join $"($env.GHOSTTY_TTY).json")
                  if not ($f | path exists) { return }
                  do -i { open $f | upsert cwd $after | to json | save -f $f }
              }
          }
      )
    )
}
