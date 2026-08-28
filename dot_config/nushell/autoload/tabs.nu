# Ghostty tabs + Claude session state, from Hammerspoon's tab-state.lua mirror.

const STATE = "~/.local/state/ghostty-tabs.json"

def _age [secs: int] {
    if $secs < 0 { return "—" }
    if $secs < 60 { return $"($secs)s" }
    if $secs < 3600 { return $"($secs // 60)m" }
    $"($secs // 3600)h($secs mod 3600 // 60)m"
}

# Current Ghostty tabs: age, cwd, and how long each has been out of focus.
export def t-tabs [] {
    let path = ($STATE | path expand)
    if not ($path | path exists) {
        error make --unspanned { msg: "no tab state — is Hammerspoon running?" }
    }

    let st = (open $path)
    let now = (date now | into int) // 1_000_000_000

    # A stale mirror silently reports dead tabs as live.
    if ($now - $st.updated) > 30 {
        print $"(ansi yellow)state is ($now - $st.updated)s old — Hammerspoon may be down(ansi reset)"
    }

    let rows = ($st.tabs | transpose id t)
    # Splits share one tab title, so panes are told apart by cwd instead.
    let split_idx = ($rows | group-by {|r| $r.t.index | into string } | items {|k, v| if ($v | length) > 1 { $k } else { null } } | compact)

    $rows
    | each {|r|
        let mine = ($r.id == ($env.GHOSTTY_TAB_ID? | default ""))
        let active = ($r.id == $st.active)
        let short = ($r.t.cwd | str replace $env.HOME "~" | path basename)
        let name = (if (($r.t.index | into string) in $split_idx) { $"($r.t.title | split chars | first 30 | str join) ⧉ ($short)" } else { $r.t.title | split chars | first 44 | str join })
        let c = ($r.t.claude? | default null)
        {
            "#": $r.t.index
            tab: $"(if $active { '▶' } else if $mine { '·' } else { ' ' }) ($name)"
            claude: (if $c == null { "" } else if ($c.waiting_since? | default null) != null {
                $"✳ ((_age ($now - $c.waiting_since)))"
            } else if ($c.busy? | default false) { "• busy" } else { "idle" })
            age: (_age ($now - $r.t.born))
            idle: (if $active { "—" } else if $r.t.last_selected == 0 { "never" } else { _age ($now - $r.t.last_selected) })
            visits: $r.t.selections
            cwd: ($r.t.cwd | str replace $env.HOME "~")
        }
    }
    | sort-by "#"
}

# Jump to a tab by its number in `t-tabs`.
export def t-go [n: int] {
    let path = ($STATE | path expand)
    let st = (open $path)
    let match = ($st.tabs | transpose id t | where {|r| $r.t.index == $n })
    if ($match | is-empty) { error make --unspanned { msg: $"no tab ($n)" } }
    let id = ($match | first | get id)
    # `run script`: a bare tell launches Ghostty at compile time, so jumping to
    # a tab from a closed Ghostty would resurrect it with its saved session.
    # `activate` sits inside the guard for the same reason.
    let script = $"tell application \"Ghostty\"\nfocus \(terminal id \"($id)\"\)\nactivate\nend tell"
    ^osascript -e $"tell application \"System Events\"\nif not \(exists process \"Ghostty\"\) then return \"\"\nend tell\nreturn run script ($script | to json)" | ignore
}
