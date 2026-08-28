# Ghostty's bundled ghostty.nu handles ssh/sudo but never emits OSC 7, so the
# tab title freezes and `window-inherit-working-directory` breaks. Emit it here.
#
# Named record, so re-sourcing replaces rather than stacks; append-only.

$env.config.hooks.pre_prompt = (
  $env.config.hooks.pre_prompt?
  | default []
  | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "ghostty-osc7")) }
  | append {
    name: "ghostty-osc7"
    code: { ||
      let host = (hostname | str trim)
      let dir  = (pwd | str replace --all ' ' '%20')
      print -n $"\e]7;file://($host)($dir)\a"
    }
  }
)
