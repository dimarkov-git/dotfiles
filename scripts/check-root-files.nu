#!/usr/bin/env nu
# Root-owned targets from the sudo run_onchange scripts: outside destDir, so
# chezmoi records no hash and check-drift.nu is blind to them.

# Empty stdout means no divergence, matching check-drift.nu's contract.

# A `dir` entry compares the whole tree, so an extra file in the target is
# divergence too — that is how /etc/resolver drift shows up.
const ROOT_FILES = [
    { source: "etc/hosts", target: "/etc/hosts", kind: "file" },
]

def _repo []: nothing -> string {
    $env.FILE_PWD | path dirname
}

def _hash [path: string]: nothing -> any {
    try { open --raw $path | hash sha256 } catch { null }
}

# `ls` with a glob throws when nothing matches; `glob` returns an empty list.
def _rel_files [root: string]: nothing -> list<string> {
    glob ($root | path join "**" "*")
    | where ($it | path type) == "file"
    | each { |p| $p | path relative-to $root }
    | sort
}

def _check_file [src: string, target: string]: nothing -> any {
    let want = (_hash $src)
    let have = (_hash $target)
    if $want == null or $have == null { return { unreadable: true } }
    if $want != $have { { differs: true } } else { null }
}

# Divergence, not a diff: any name or content mismatch collapses to one line.
def _check_dir [src: string, target: string]: nothing -> any {
    let want = (_rel_files $src)
    let have = (_rel_files $target)
    if $want != $have { return { differs: true } }

    let mismatched = (
        $want | any { |rel|
            let a = (_hash ($src | path join $rel))
            let b = (_hash ($target | path join $rel))
            $a == null or $b == null or $a != $b
        }
    )
    if $mismatched { { differs: true } } else { null }
}

def _check [repo: string]: nothing -> list {
    $ROOT_FILES | each { |f|
        let src = ($repo | path join $f.source)
        # A missing target is not divergence — the run_onchange script creates it.
        if not ($src | path exists) or not ($f.target | path exists) { return null }

        # Comparing needs no sudo; only the write does.
        let kind = ($f.kind? | default "file")
        let r = if $kind == "dir" {
            _check_dir $src $f.target
        } else {
            _check_file $src $f.target
        }

        if $r == null { null } else { ($r | merge { target: $f.target, source: $f.source }) }
    } | compact
}

def main [--json] {
    let checked = (_check (_repo))

    if $json {
        let unreadable = ($checked | where ($it.unreadable? == true) | get target)
        return ({
            ok: ($unreadable | is-empty),
            error: (if ($unreadable | is-empty) { "" } else { $"unreadable: ($unreadable | str join ', ')" }),
            differing: ($checked | where ($it.unreadable? != true) | select target source),
        } | to json --raw)
    }

    for r in $checked {
        if ($r.unreadable? == true) {
            print $"($r.target): unreadable"
        } else {
            print $"($r.target): differs from ($r.source)"
        }
    }
}
