# direnv bridge for Nushell — there is no `direnv hook nu`, so we call
# `direnv export json` from a PWD hook ourselves.
#
# Named-record registration: re-sourcing config drops the old copy instead of
# stacking a second hook. Append-only, so other modules' PWD hooks survive.

use std/config *

$env.config.hooks.env_change.PWD = (
    $env.config.hooks.env_change.PWD?
    | default []
    | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "direnv")) }
    | append {
        name: "direnv"
        code: { |before, after|
            # Silent return on a fresh machine — don't warn on every cd.
            if (which direnv | is-empty) {
                return
            }

            direnv export json | from json | default {} | load-env

            # direnv exports PATH as a string; Nushell needs a list or external
            # command lookup and completion break. Re-run the converter.
            $env.PATH = do (env-conversions).path.from_string $env.PATH
        }
    }
)
