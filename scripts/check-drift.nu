#!/usr/bin/env nu
# Detect drift: $HOME files diverged from what chezmoi recorded on the last
# `apply`. Not `chezmoi status` — its second column shows `M` for both "target
# drifted" and "source ahead". The state file's SHA256s are only written by
# `apply`, so a mismatch there is unambiguously a hand-edited target.
#
# Both content and mode divergence count, because `chezmoi apply` prompts for
# either, and a prompt with no TTY (i.e. `make apply`) dies with the unhelpful
# "could not open a new TTY".
#
# Output contract (consumed by the Makefile's drift / apply targets):
#   exit 0 + empty stdout     → no drift
#   exit 0 + non-empty stdout → one line per file:
#     `<expected>  <path>: FAILED`
#     `<path>: FAILED (mode <actual>, expected <want>)`
#
# A state entry whose target no longer exists is deliberately NOT drift:
# chezmoi will recreate it, and state carries stale entries for files removed
# long ago — reporting those would false-positive constantly. `make
# state-stale` surfaces them instead.

# Permission bits as an octal string ("644") to compare with `stat -f %Lp`.
# Arithmetic because `fmt` returns a byte stream here and there is no
# `into string --radix`.
def _octal [n: int] {
    $"(($n // 64) mod 8)(($n // 8) mod 8)($n mod 8)"
}

def main [] {
    let state = (^chezmoi state dump | from json)
    let entries = (
        $state.entryState
        | transpose path entry
        | where entry.type == "file"
        | each {|r| {
            path: $r.path,
            expected: $r.entry.contentsSHA256,
            # Decimal int (420 = 0o644). Null-safe: older entries predate it.
            mode: ($r.entry.mode? | default null)
          }}
    )

    let drifted = (
        $entries
        | par-each {|row|
            if not ($row.path | path exists) { return null }

            let actual = (open --raw $row.path | hash sha256)
            if $actual != $row.expected {
                return { path: $row.path, expected: $row.expected }
            }

            # Real case: Zed rewrites its settings.json as 0600 where chezmoi
            # wrote 0644 — contents identical, apply still stops to prompt.
            if $row.mode != null {
                let actual_mode = (^stat -f "%Lp" $row.path | str trim)
                let expected_mode = (_octal $row.mode)
                if $actual_mode != $expected_mode {
                    return {
                        path: $row.path,
                        expected: $row.expected,
                        mode_expected: $expected_mode,
                        mode_actual: $actual_mode
                    }
                }
            }

            null
        }
        | compact
    )

    # `for`, not `each`: `each` returns its collected list, which nushell
    # would render as `[null, null, …]` after the prints.
    for r in $drifted {
        if ($r | get mode_actual? | is-not-empty) {
            # Spell out mode-only drift; a bare "FAILED" reads as corruption.
            print $"($r.path): FAILED \(mode ($r.mode_actual), expected ($r.mode_expected)\)"
        } else {
            print $"($r.expected)  ($r.path): FAILED"
        }
    }
}
