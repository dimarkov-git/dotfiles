#!/usr/bin/env nu
# Machine-readable dotfiles health for the Hammerspoon indicator; `dot-check`
# is the human-facing equivalent. Drift is delegated to check-drift.nu.
#
# A probe that cannot run reports `ok: false`, never an empty result — otherwise
# a broken chezmoi reads as a clean bill of health.

const REPO = "dev-zone/dotfiles"

# Hammerspoon spawns with launchd's bare PATH, where `chezmoi`/`git` are absent.
def _bin [name: string, fallback: string]: nothing -> string {
    let found = (which $name | get path? | first)
    if ($found | is-not-empty) { $found } else { $fallback }
}

def main [] {
    let repo = ($env.HOME | path join $REPO)
    let drift = (_drift $repo)
    let pending = (_pending $repo)
    let git = (_git $repo)
    let root_files = (_root_files $repo)

    {
        drift: $drift,
        pending: $pending,
        git: $git,
        root_files: $root_files,
        # Whether the probes ran, NOT whether the tree is clean.
        probes_ok: ($drift.ok and $pending.ok and $git.ok and $root_files.ok),
    } | to json --raw
}

# Delegated to check-root-files.nu, which the Makefile's drift target shares.
def _root_files [repo: string] {
    let r = (
        do { ^$nu.current-exe ($repo | path join "scripts/check-root-files.nu") --json } | complete
    )
    if $r.exit_code != 0 {
        return { ok: false, error: ($r.stderr | str trim), differing: [] }
    }
    $r.stdout | from json
}

def _drift [repo: string] {
    # The child needs the brew prefix on PATH too: check-drift.nu calls `chezmoi`.
    let chezmoi = (_bin "chezmoi" "/opt/homebrew/bin/chezmoi")
    let r = (
        do {
            with-env { PATH: ($env.PATH? | default [] | prepend ($chezmoi | path dirname) | uniq) } {
                ^$nu.current-exe ($repo | path join "scripts/check-drift.nu")
            }
        } | complete
    )
    if $r.exit_code != 0 {
        return { ok: false, error: ($r.stderr | str trim), files: [] }
    }
    {
        ok: true,
        files: ($r.stdout | lines | where { |l| ($l | str trim) != "" } | each { |l| _drift_line $l }),
    }
}

# Two shapes from check-drift.nu: `<sha>  <path>: FAILED` for content, and
# `<path>: FAILED (mode …)` for permissions — the mode note changes the fix.
def _drift_line [line: string] {
    let mode = ($line | parse --regex '^(?P<path>.+): FAILED \((?P<note>mode .+)\)$')
    if ($mode | is-not-empty) {
        return { path: ($mode.0.path | _tilde), note: $mode.0.note }
    }
    let content = ($line | parse --regex '^\S+\s+(?P<path>.+): FAILED$')
    if ($content | is-not-empty) {
        return { path: ($content.0.path | _tilde), note: null }
    }
    { path: $line, note: null }
}

# `chezmoi status` column 1 = source, column 2 = target: a non-blank first
# character means $HOME is behind.
def _pending [repo: string] {
    let r = (do { ^(_bin "chezmoi" "/opt/homebrew/bin/chezmoi") status --source $repo } | complete)
    # chezmoi exits 0 while reporting per-file errors on stderr, so a partial
    # listing would otherwise read as "nothing pending".
    if $r.exit_code != 0 or ($r.stderr | str trim) != "" {
        return { ok: false, error: ($r.stderr | str trim), entries: [] }
    }
    {
        ok: true,
        entries: ($r.stdout | lines | where { |l| ($l | str length) > 0 and ($l | str substring 0..0) != " " }),
    }
}

def _git [repo: string] {
    let git = (_bin "git" "/usr/bin/git")
    let dirty = (do { ^$git -C $repo status --porcelain } | complete)
    if $dirty.exit_code != 0 {
        return { ok: false, error: ($dirty.stderr | str trim), dirty: 0, ahead: 0 }
    }
    # No upstream (fresh clone, detached HEAD) is normal, hence 0 rather than a
    # failed probe.
    let ahead = (do { ^$git -C $repo rev-list --count "@{u}..HEAD" } | complete)
    {
        ok: true,
        dirty: ($dirty.stdout | lines | where { |l| ($l | str length) > 0 } | length),
        ahead: (if $ahead.exit_code == 0 { $ahead.stdout | str trim | into int } else { 0 }),
    }
}

def _tilde []: string -> string {
    $in | str replace $env.HOME "~"
}
