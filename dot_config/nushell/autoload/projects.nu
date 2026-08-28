# Git overview: repos in $PWD (or `root`). `-d` counts repo nesting, so the
# default 1 means direct children only — a grouping dir like acme/gitlab
# needs `-d 2`. `projects hooks` audits .git/hooks against ~/.git-templates.
#
# Values stay raw when piped and are shaped only for display, so filters work on
# them: `projects | where dirty > 0`, `where not sync`, `where size > 100mb`.
# Piped columns mirror the displayed ones, widened by `--full`/`--size`.

# Walk for .git rather than a registry, so a fresh clone needs no bookkeeping.
# `depth` counts repo nesting (1 = repos directly in root); glob's own --depth
# counts the `.git` segment too, hence the +1.
def _projects-find [root: path, depth: int] {
    glob $"($root)/**/.git" --depth ($depth + 1) --no-file --no-symlink
    | each { |p| $p | path dirname }
    | sort
}

# Segment-wise, so "a-b/x" sorts as a sibling of "a" rather than inside it.
def _projects-before [a: string, b: string] {
    let x = ($a | split row "/")
    let y = ($b | split row "/")
    let n = ([($x | length), ($y | length)] | math min)

    mut i = 0
    while $i < $n {
        let l = ($x | get $i)
        let r = ($y | get $i)
        if $l != $r { return ($l < $r) }
        $i += 1
    }
    ($x | length) < ($y | length)
}

# Branch hygiene: merged-but-undeleted, and branches whose remote is gone.
def _projects-branches [repo: path, head: string, upstream: string] {
    let all = (
        do { git -C $repo branch --format="%(refname:short)|%(upstream:track)" } | complete
        | if $in.exit_code == 0 { $in.stdout | lines } else { [] }
        | each { |l| let p = ($l | split row "|"); { name: ($p | get -o 0 | default ""), track: ($p | get -o 1 | default "") } }
    )

    # "gone" = upstream was deleted on the remote; the local branch is a leftover.
    let gone = ($all | where { |b| $b.track =~ "gone" } | get name)

    # Merged is only meaningful against a real upstream, and never includes HEAD
    # itself (always merged into its own tip).
    let merged = (if ($upstream | is-empty) { [] } else {
        do { git -C $repo branch --format="%(refname:short)" --merged $upstream } | complete
        | if $in.exit_code == 0 { $in.stdout | lines } else { [] }
        | where { |b| $b != $head and $b not-in $gone }
    })

    { merged: $merged, gone: $gone }
}

# du walks the whole worktree, so this is the one metric worth gating behind a flag.
def _projects-size [repo: path, ignored: list<string>] {
    let total = (do { ^du -sk $repo } | complete
        | if $in.exit_code == 0 { $in.stdout | split row "\t" | get -o 0 | default "0" | into int } else { 0 })

    let git_dir = (do { ^du -sk ($repo | path join ".git") } | complete
        | if $in.exit_code == 0 { $in.stdout | split row "\t" | get -o 0 | default "0" | into int } else { 0 })

    # Sum only top-level ignored entries; nested ones are already inside them.
    let junk = ($ignored | reduce --fold 0 { |p, acc|
        let full = ($repo | path join $p)
        if ($full | path exists) {
            $acc + (do { ^du -sk $full } | complete
                | if $in.exit_code == 0 { $in.stdout | split row "\t" | get -o 0 | default "0" | into int } else { 0 })
        } else { $acc }
    })

    { size: ($total * 1kib), git_size: ($git_dir * 1kib), junk_size: ($junk * 1kib) }
}

# porcelain=v2 carries branch, upstream and ahead/behind in one call; plain
# --porcelain has no branch.ab line.
def _projects-stat [repo: path, want_size: bool] {
    let status = (do { git -C $repo status --porcelain=v2 --branch --ignored=matching } | complete)
    if $status.exit_code != 0 { return null }

    let lines = ($status.stdout | lines)
    let headers = ($lines | where { |l| $l starts-with "# " })
    let field = { |key|
        $headers
        | where { |l| $l starts-with $"# ($key) " }
        | get -o 0
        | default ""
        | str replace $"# ($key) " ""
    }

    let head = (do $field "branch.head")

    # Detached HEAD reports the literal "(detached)", not a name.
    let branch = (if $head == "(detached)" {
        let short = (do { git -C $repo rev-parse --short HEAD } | complete | get stdout | str trim)
        $"detached@($short)"
    } else { $head })

    let upstream = (do $field "branch.upstream")
    let ab = (do $field "branch.ab")

    # Upstream set but no branch.ab = it was deleted; no upstream = never pushed.
    let counts = (if ($ab | is-empty) {
        { ahead: null, behind: null }
    } else {
        let parts = ($ab | split row " ")
        {
            ahead: ($parts | get -o 0 | default "+0" | str replace "+" "" | into int)
            behind: ($parts | get -o 1 | default "-0" | str replace "-" "" | into int)
        }
    })

    let entries = ($lines | where { |l| not ($l starts-with "# ") })
    let ignored = ($entries | where { |l| $l starts-with "! " } | each { |l| $l | str substring 2.. })
    let untracked = ($entries | where { |l| $l starts-with "? " } | length)
    let tracked = ($entries | where { |l| not ($l starts-with "! ") and not ($l starts-with "? ") } | length)

    let tag = (
        do { git -C $repo describe --tags --abbrev=0 } | complete
        | if $in.exit_code == 0 { $in.stdout | str trim } else { "" }
    )

    let stash = (
        do { git -C $repo stash list } | complete
        | if $in.exit_code == 0 { $in.stdout | lines | length } else { 0 }
    )

    let branches = (_projects-branches $repo $head $upstream)

    let last = (
        do { git -C $repo log -1 --format=%cr } | complete
        | if $in.exit_code == 0 { $in.stdout | str trim } else { "" }
    )

    let sizes = (if $want_size {
        _projects-size $repo $ignored
    } else {
        { size: null, git_size: null, junk_size: null }
    })

    {
        repo: $repo
        branch: $branch
        tag: $tag
        dirty: $tracked
        untracked: $untracked
        ahead: $counts.ahead
        behind: $counts.behind
        upstream_gone: (($ab | is-empty) and ($upstream | is-not-empty))
        # The table shows these as ✓/✗; without them a filter has to restate the rule.
        sync: ($counts.ahead != null and $counts.ahead == 0 and $counts.behind == 0)
        clean: (($branches.merged | is-empty) and ($branches.gone | is-empty) and $stash == 0)
        merged: ($branches.merged | length)
        gone: ($branches.gone | length)
        stash: $stash
        size: $sizes.size
        git_size: $sizes.git_size
        junk_size: $sizes.junk_size
        merged_names: $branches.merged
        gone_names: $branches.gone
        last: $last
    }
}

# `init.templatedir` copies hooks at `git init`/`clone` time only, so a template
# edit never reaches existing repos — a stale prepare-commit-msg keeps prepending
# `[main]` on branches the current template skips. Source is the deployed
# ~/.git-templates, the copy git itself reads; a hook absent from it is left alone.
def _projects-hook-src [] {
    "~/.git-templates/hooks" | path expand
}

def _projects-hash [path: string] {
    try { open --raw $path | hash sha256 } catch { null }
}

# core.hooksPath moves hooks out of .git/hooks, so a copy there would never run.
def _projects-hooks-path [repo: path] {
    let r = (do { git -C $repo config --get core.hooksPath } | complete)
    if $r.exit_code != 0 { return null }
    let v = ($r.stdout | str trim)
    if ($v | is-empty) { null } else { $v }
}

def _projects-hook-state [repo: path, names: list<string>] {
    let redirected = (_projects-hooks-path $repo)
    if $redirected != null {
        return [{ repo: $repo, hook: "", status: "hooksPath", detail: $redirected }]
    }

    let src = (_projects-hook-src)
    $names | each { |name|
        let want = (_projects-hash ($src | path join $name))
        let target = ($repo | path join ".git" "hooks" $name)
        if not ($target | path exists) {
            { repo: $repo, hook: $name, status: "missing", detail: "" }
        } else if (_projects-hash $target) != $want {
            { repo: $repo, hook: $name, status: "stale", detail: "" }
        } else { null }
    } | compact
}

# Report hooks diverging from ~/.git-templates; --fix recopies them.
#   projects hooks              # repos in $PWD
#   projects hooks -d 3 --fix   # deeper tree
def "projects hooks" [
    root?: path
    --fix
    --depth (-d): int = 1
] {
    let src = (_projects-hook-src)
    if not ($src | path exists) {
        error make --unspanned { msg: $"no hook template: ($src)" }
    }

    let names = (
        glob ($src | path join "*") --no-dir
        | each { |p| $p | path basename }
        | sort
    )
    if ($names | is-empty) { return [] }

    let base = ($root | default $env.PWD | path expand)
    let rows = (
        _projects-find $base $depth
        | par-each { |repo| _projects-hook-state $repo $names }
        | flatten
    )

    if $fix {
        # hooksPath rows carry no hook to copy — they need a human decision.
        for row in ($rows | where status in ["missing", "stale"]) {
            let target = ($row.repo | path join ".git" "hooks" $row.hook)
            mkdir ($target | path dirname)
            cp --force ($src | path join $row.hook) $target
            chmod +x $target
        }
    }

    let shown = (if $fix { $rows | where status == "hooksPath" } else { $rows })

    if (is-redirected) or not (is-terminal --stdout) {
        return ($shown | each { |r| $r | update repo ($r.repo | str replace $"($base)/" "") })
    }

    if $fix {
        let fixed = ($rows | where status in ["missing", "stale"] | length)
        print $"(ansi green)✓(ansi reset) synced ($fixed) hook\(s) from ($src)"
    } else if ($rows | is-empty) {
        print $"(ansi green)✓(ansi reset) all repos match ($src)"
    }

    # Returning the empty table too would render a stray "empty list" under the ✓.
    if ($shown | is-empty) { return }

    $shown | each { |r|
        let name = ($r.repo | str replace $"($base)/" "")
        if $r.status == "hooksPath" {
            {
                repo: $name
                hook: $"(ansi dark_gray)—(ansi reset)"
                status: $"(ansi cyan)hooksPath(ansi reset) → ($r.detail)"
            }
        } else {
            {
                repo: $name
                hook: $r.hook
                status: (if $r.status == "missing" {
                    $"(ansi red)missing(ansi reset)"
                } else {
                    $"(ansi yellow)stale(ansi reset)"
                })
            }
        }
    }
}

# Without --fetch, ahead/behind and gone-branches reflect the last fetch, not the remote.
def projects [
    root?: path
    --fetch (-f)

    --size (-s)
    --full

    --depth (-d): int = 1
] {
    let base = ($root | default $env.PWD | path expand)
    let repos = (_projects-find $base $depth)

    if ($repos | is-empty) { return [] }

    if $fetch {
        # --prune is what turns a deleted remote branch into a "gone" marker.
        $repos | par-each { |r| do { git -C $r fetch --quiet --prune } | complete } | ignore
    }

    let rows = ($repos | par-each { |r| _projects-stat $r $size } | compact)


    # Strip the shared prefix, then sort on the paths as displayed.
    let rows = ($rows
        | each { |r|
            let name = ($r.repo | str replace $"($base)/" "" | str replace $base ($r.repo | path basename))
            $r | update repo $name
        }
        | sort-by --custom { |a, b| _projects-before $a.repo $b.repo })

    # Colouring the values themselves would embed ANSI codes in the data, so
    # `where branch != main` and `where dirty > 0` would never match. Shape only
    # on the display path, exactly as `ls` leaves its columns raw.
    #
    # The piped columns mirror the displayed ones — sync/health expanded into the
    # fields they summarise, since a "↑2" string cannot be filtered on.
    if (is-redirected) or not (is-terminal --stdout) {
        let cols = ([
            [repo branch tag dirty sync ahead behind upstream_gone clean]
            (if $full { [untracked merged merged_names gone gone_names stash last] } else { [] })
            (if $size { [size git_size junk_size] } else { [] })
        ] | flatten)
        return ($rows | select ...$cols)
    }

    let fmt = { |n| if $n == null { "" } else { $n } }

    let shaped = ($rows | each { |r|
        let sync = (match [$r.ahead, $r.behind] {
            [null, _] if $r.upstream_gone => $"(ansi red)upstream gone(ansi reset)"
            [null, _] => $"(ansi dark_gray)no upstream(ansi reset)"
            [0, 0] => $"(ansi green)✓(ansi reset)"
            _ => ([
                (if $r.ahead > 0 { $"(ansi yellow)↑($r.ahead)(ansi reset)" })
                (if $r.behind > 0 { $"(ansi red)↓($r.behind)(ansi reset)" })
            ] | compact | str join " ")
        })

        # Cleanup-worthy state only; untracked files are normal work, not rot.
        let health = ([
            (if $r.merged > 0 { $"(ansi yellow)($r.merged) merged(ansi reset)" })
            (if $r.gone > 0 { $"(ansi red)($r.gone) gone(ansi reset)" })
            (if $r.stash > 0 { $"(ansi cyan)($r.stash) stash(ansi reset)" })
        ] | compact | str join ", ")

        let base_row = {
            repo: $r.repo
            branch: $"(ansi cyan)($r.branch)(ansi reset)"
            tag: (if ($r.tag | is-empty) { $"(ansi dark_gray)—(ansi reset)" } else { $"(ansi magenta)($r.tag)(ansi reset)" })
            dirty: (if $r.dirty > 0 { $"(ansi yellow)($r.dirty)(ansi reset)" } else { $"(ansi green)✓(ansi reset)" })
            sync: $sync
            health: (if ($health | is-empty) { $"(ansi green)✓(ansi reset)" } else { $health })
        }

        let with_full = (if $full {
            $base_row | merge {
                merged: $r.merged
                gone: $r.gone
                stash: $r.stash
                untracked: $r.untracked
                last: $"(ansi dark_gray)($r.last)(ansi reset)"
            }
        } else { $base_row })

        if $size {
            $with_full | merge {
                size: (do $fmt $r.size)
                junk: (if $r.junk_size > 0 { $"(ansi yellow)(do $fmt $r.junk_size)(ansi reset)" } else { do $fmt $r.junk_size })
                git: (do $fmt $r.git_size)
            }
        } else { $with_full }
    })

    $shaped
}
