# Ghostty tabs + Claude session state, from Hammerspoon's tab-state.lua mirror.

const STATE = "~/.local/state/ghostty-tabs.json"

def _age [d: duration] {
    let secs = ($d | into int) // 1_000_000_000
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

    let rows = ($rows
        | each {|r|
            let c = ($r.t.claude? | default null)
            let waiting = (if $c == null { null } else { $c.waiting_since? | default null })
            {
                index: $r.t.index
                title: $r.t.title
                cwd: ($r.t.cwd | str replace $env.HOME "~")
                active: ($r.id == $st.active)
                mine: (($r.t.tty? | default "") == ($env.GHOSTTY_TTY? | default ""))
                split: (($r.t.index | into string) in $split_idx)
                claude: ($c != null)
                busy: (if $c == null { false } else { $c.busy? | default false })
                waiting: ($waiting != null)
                waiting_for: (if $waiting == null { null } else { ($now - $waiting) | into duration --unit sec })
                age: (($now - $r.t.born) | into duration --unit sec)
                idle: (if $r.t.last_selected == 0 { null } else { ($now - $r.t.last_selected) | into duration --unit sec })
                visits: $r.t.selections
                tty: ($r.t.tty? | default "")
            }
        }
        | sort-by index)

    # Colouring the values themselves would embed ANSI codes in the data, so
    # `where busy` and `where age > 1hr` would never match. Shape on display only.
    if (is-redirected) or not (is-terminal --stdout) {
        return $rows
    }

    $rows | each {|r|
        let short = ($r.cwd | path basename)
        let name = (if $r.split {
            $"($r.title | split chars | first 30 | str join) ⧉ ($short)"
        } else {
            $r.title | split chars | first 44 | str join
        })
        {
            # Named `index`, not `#`: nushell substitutes it for the row-number
            # column instead of printing both.
            index: $r.index
            tab: $"(if $r.active { '▶' } else if $r.mine { '·' } else { ' ' }) ($name)"
            claude: (if not $r.claude { "" } else if $r.waiting {
                $"(ansi yellow)✳ (_age $r.waiting_for)(ansi reset)"
            } else if $r.busy { $"(ansi cyan)• busy(ansi reset)" } else { $"(ansi dark_gray)idle(ansi reset)" })
            age: (_age $r.age)
            idle: (if $r.active { $"(ansi dark_gray)—(ansi reset)" } else if $r.idle == null { $"(ansi dark_gray)never(ansi reset)" } else { _age $r.idle })
            visits: $r.visits
            cwd: $r.cwd
        }
    }
}

def _tgo-complete-tabs [] {
    let path = ($STATE | path expand)
    if not ($path | path exists) { return [] }
    do -i { open $path }
    | default {} | get tabs? | default {} | transpose id t
    | sort-by {|r| $r.t.index }
    | each {|r|
        let short = ($r.t.cwd | str replace $env.HOME "~")
        { value: ($r.t.index | into string), description: $"  ($r.t.title) — ($short)" }
    }
}

# Jump to a tab by its number in `t-tabs`, or by a substring of its title or cwd.
export def t-go [target: string@_tgo-complete-tabs] {
    let path = ($STATE | path expand)
    let st = (open $path)
    let rows = ($st.tabs | transpose id t)
    let match = (if ($target =~ '^[0-9]+$') {
        $rows | where {|r| $r.t.index == ($target | into int) }
    } else {
        let q = ($target | str lowercase)
        $rows | where {|r| (($r.t.title | str lowercase) =~ $q) or (($r.t.cwd | str lowercase) =~ $q) }
    })
    if ($match | is-empty) { error make --unspanned { msg: $"no tab matching ($target)" } }
    if ($match | length) > 1 {
        let names = ($match | each {|r| $"#($r.t.index) ($r.t.cwd)" } | str join ", ")
        error make --unspanned { msg: $"ambiguous: ($names)" }
    }
    let id = ($match | first | get id)
    # `run script`: a bare tell launches Ghostty at compile time, so jumping to
    # a tab from a closed Ghostty would resurrect it with its saved session.
    # `activate` sits inside the guard for the same reason.
    let script = $"tell application \"Ghostty\"\nfocus \(terminal id \"($id)\"\)\nactivate\nend tell"
    ^osascript -e $"tell application \"System Events\"\nif not \(exists process \"Ghostty\"\) then return \"\"\nend tell\nreturn run script ($script | to json)" | ignore
}
