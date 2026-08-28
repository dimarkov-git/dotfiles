# system-watch — surface config changes outside chezmoi's reach (~/Library,
# ~/.config, /opt/homebrew/etc, …). Complements `make drift` and
# `dot-check`, which only see chezmoi-managed files.
#
#   sw-status              # diff against last snapshot
#   sw-snapshot            # capture new state, commit to local git
#   sw-log [n]             # history of snapshots
#   sw-diff <ref> [<ref>]  # diff between two snapshots
#
# Three layers, configured in dot_config/system-watch/config.toml:
#   discovery — wide directory listing + blacklist. Names + kind only.
#   hashing   — narrow whitelist: sha256 + size + mtime. File content is
#               never stored, so secrets can be hashed safely.
#   commands  — output of read-only commands. Stored as content.
#
# State at ~/.local/state/system-watch/ is a local git repo with push blocked
# four ways (see _sw-init-repo).

def _sw-config-path [] {
    $env.HOME | path join ".config/system-watch/config.toml"
}

def _sw-state-dir [] {
    $env.HOME | path join ".local/state/system-watch"
}

# First-run init. Idempotent — bails on the marker file.
def _sw-init-repo [] {
    let dir = (_sw-state-dir)
    let marker = ($dir | path join ".git/system-watch-bootstrapped")

    if ($marker | path exists) { return }

    mkdir $dir
    mkdir ($dir | path join "commands")

    if not (($dir | path join ".git") | path exists) {
        git -C $dir init --quiet --initial-branch=main
    }

    # Four independent layers block pushing this repo of system-file hashes.
    # Layer 1 is the absence of `git remote add` — nothing to push to.

    # Layer 2: pre-push hook that always fails.
    let hook = ($dir | path join ".git/hooks/pre-push")
    "#!/bin/sh\necho 'system-watch: push disabled (state repo contains hashes of system files)' >&2\nexit 1\n" | save -f $hook
    chmod +x $hook

    # Layer 3: refuse push without explicit refspec.
    git -C $dir config push.default nothing

    # Layer 4: pushDefault points to a non-existent remote.
    git -C $dir config remote.pushDefault no-such-remote

    # Local identity, overriding any global name/email.
    git -C $dir config user.name "system-watch"
    git -C $dir config user.email "system-watch@localhost"

    # .DS_Store: Finder drops it here on every folder open, churning sw-diff.
    "# All files in this repo are intentional snapshot output.\n# Push is disabled — see CLAUDE.md.\n.DS_Store\n" | save -f ($dir | path join ".gitignore")

    "" | save -f $marker
    print $"(ansi green)system-watch:(ansi reset) initialized state repo at ($dir)"
}

def _sw-load-config [] {
    let cfg_path = (_sw-config-path)
    if not ($cfg_path | path exists) {
        error make { msg: $"system-watch config not found at ($cfg_path)" }
    }
    open $cfg_path
}

def _sw-expand [p: string] {
    $p | path expand
}

# Supports `**/X/**` (X anywhere) and `**/X` (X at end), by converting the
# glob to a regex once and matching path strings against it.
def _sw-glob-to-regex [pattern: string] {
    # Escape regex metachars except * and /
    let escaped = ($pattern
        | str replace --all '.' '\.'
        | str replace --all '+' '\+'
        | str replace --all '(' '\('
        | str replace --all ')' '\)'
        | str replace --all '[' '\['
        | str replace --all ']' '\]'
        | str replace --all '$' '\$'
        | str replace --all '^' '\^'
        | str replace --all '?' '.')

    # ** matches across /, * doesn't. Order matters: ** before *.
    let with_globs = ($escaped
        | str replace --all '**' '__DOUBLESTAR__'
        | str replace --all '*' '[^/]*'
        | str replace --all '__DOUBLESTAR__' '.*')

    $"^($with_globs)$"
}

def _sw-matches-any [path: string, regexes: list] {
    for re in $regexes {
        if ($path =~ $re) { return true }
    }
    false
}

# Returns {path, kind} entries below `root`, depth-limited, skipping anything
# matching ignore_regexes.
def _sw-walk [root: string, depth: int, ignore_regexes: list] {
    let expanded = (_sw-expand $root)
    if not ($expanded | path exists) { return [] }

    mut results = []
    mut queue = [{ path: $expanded, depth: 0 }]

    while ($queue | length) > 0 {
        let item = ($queue | first)
        $queue = ($queue | skip 1)

        if (_sw-matches-any $item.path $ignore_regexes) { continue }

        let kind = if ($item.path | path type) == "dir" { "dir" } else { "file" }
        $results = ($results | append { path: $item.path, kind: $kind })

        if $kind == "dir" and $item.depth < $depth {
            let children = (try { ls -a $item.path | get name } catch { [] })
            for child in $children {
                let bn = ($child | path basename)
                if $bn == "." or $bn == ".." { continue }
                $queue = ($queue | append { path: $child, depth: ($item.depth + 1) })
            }
        }
    }

    $results
}

def _sw-collect-discovery [config: record] {
    let default_depth = ($config.discovery.default_depth? | default 3)
    let ignore_regexes = ($config.discovery.ignore_patterns
        | each { |p| _sw-glob-to-regex $p })

    mut all = []
    for root in $config.discovery.roots {
        let d = ($root.depth? | default $default_depth)
        let entries = (_sw-walk $root.path $d $ignore_regexes)
        $all = ($all | append $entries)
    }
    # Sorted for stable diffs across snapshots.
    $all | sort-by path | uniq-by path
}

# Read errors are silent: record nothing rather than fail the whole snapshot.
def _sw-hash-file [path: string] {
    try {
        let stat = (ls -l $path | first)
        let sha = (open --raw $path | hash sha256)
        {
            path: $path,
            sha256: $sha,
            size: $stat.size,
            mtime: ($stat.modified | format date "%+"),
        }
    } catch {
        null
    }
}

def _sw-expand-hashing-entry [entry: record, ignore_regexes: list] {
    let p = (_sw-expand $entry.path)
    if not ($p | path exists) { return [] }

    if ($p | path type) == "file" {
        return [$p]
    }

    if not $entry.recursive {
        let children = (try { ls $p | where type == file | get name } catch { [] })
        return $children
    }

    let depth = ($entry.depth? | default 4)
    let walked = (_sw-walk $p $depth $ignore_regexes)
    $walked | where kind == "file" | get path
}

def _sw-collect-hashing [config: record] {
    # Reuse discovery's ignore_patterns to skip noise inside recursive hashes.
    let ignore_regexes = ($config.discovery.ignore_patterns
        | each { |p| _sw-glob-to-regex $p })

    mut all_files = []
    for entry in $config.hashing.paths {
        let files = (_sw-expand-hashing-entry $entry $ignore_regexes)
        $all_files = ($all_files | append $files)
    }

    let unique = ($all_files | uniq | sort)
    $unique | each { |f| _sw-hash-file $f } | compact
}

def _sw-run-commands [config: record] {
    let cmds = $config.commands
    let names = ($cmds | columns)
    $names | reduce --fold {} { |name, acc|
        let cmd = ($cmds | get $name)
        let output = (do --ignore-errors { ^bash -c $cmd } | complete | get stdout)
        $acc | upsert $name $output
    }
}

def _sw-write-snapshot [config: record] {
    let dir = (_sw-state-dir)

    print "  scanning discovery roots..."
    let discovery = (_sw-collect-discovery $config)
    $discovery | to json --indent 2 | save -f ($dir | path join "discovery.json")

    print $"  hashing watched paths..."
    let hashes = (_sw-collect-hashing $config)
    $hashes | to json --indent 2 | save -f ($dir | path join "hashes.json")

    print "  running commands..."
    let cmds_dir = ($dir | path join "commands")
    rm -rf $cmds_dir
    mkdir $cmds_dir
    let outputs = (_sw-run-commands $config)
    for name in ($outputs | columns) {
        ($outputs | get $name) | save -f ($cmds_dir | path join $"($name).txt")
    }

    {
        discovery_count: ($discovery | length),
        hashing_count: ($hashes | length),
        command_count: ($outputs | columns | length),
    }
}

# Compare two file lists by path. Returns {added, removed}.
def _sw-diff-paths [old: list, new: list] {
    let old_set = ($old | each { |r| $r.path })
    let new_set = ($new | each { |r| $r.path })
    {
        added: ($new_set | where { |p| not ($p in $old_set) }),
        removed: ($old_set | where { |p| not ($p in $new_set) }),
    }
}

# Compare two hash lists by path+sha256. Returns {added, removed, modified}.
def _sw-diff-hashes [old: list, new: list] {
    let old_by_path = ($old | reduce --fold {} { |r, acc| $acc | upsert $r.path $r })
    let new_by_path = ($new | reduce --fold {} { |r, acc| $acc | upsert $r.path $r })

    let old_paths = ($old_by_path | columns)
    let new_paths = ($new_by_path | columns)

    let added = ($new_paths | where { |p| not ($p in $old_paths) })
    let removed = ($old_paths | where { |p| not ($p in $new_paths) })
    let common = ($new_paths | where { |p| $p in $old_paths })
    let modified = ($common | where { |p|
        ($old_by_path | get $p | get sha256) != ($new_by_path | get $p | get sha256)
    })

    { added: $added, removed: $removed, modified: $modified }
}

# Show what changed since the last snapshot.
def "sw-status" [] {
    _sw-init-repo
    let cfg = (_sw-load-config)
    let dir = (_sw-state-dir)

    let head_check = (git -C $dir rev-parse --verify HEAD | complete)
    let has_head = ($head_check.exit_code == 0)
    let disc_file = ($dir | path join "discovery.json")
    let hash_file = ($dir | path join "hashes.json")

    if not $has_head or not ($disc_file | path exists) or not ($hash_file | path exists) {
        print $"(ansi yellow)system-watch:(ansi reset) no snapshot yet — run `sw-snapshot` to create one"
        return
    }

    print "computing current state (this may take a few seconds)..."
    let cur_discovery = (_sw-collect-discovery $cfg)
    let cur_hashes = (_sw-collect-hashing $cfg)

    let old_discovery = (open ($dir | path join "discovery.json"))
    let old_hashes = (open ($dir | path join "hashes.json"))

    let disc_diff = (_sw-diff-paths $old_discovery $cur_discovery)
    let hash_diff = (_sw-diff-hashes $old_hashes $cur_hashes)

    let total_changes = (
        ($disc_diff.added | length) + ($disc_diff.removed | length) +
        ($hash_diff.added | length) + ($hash_diff.removed | length) +
        ($hash_diff.modified | length)
    )

    if $total_changes == 0 {
        print $"(ansi green)✓(ansi reset) no changes since last snapshot"
        return
    }

    if ($disc_diff.added | length) > 0 {
        print $"(ansi cyan)appeared(ansi reset) (($disc_diff.added | length)) — files/dirs newly visible:"
        $disc_diff.added | each { |p| print $"  + ($p)" } | ignore
    }
    if ($disc_diff.removed | length) > 0 {
        print $"(ansi yellow)disappeared(ansi reset) (($disc_diff.removed | length)) — files/dirs gone:"
        $disc_diff.removed | each { |p| print $"  - ($p)" } | ignore
    }
    if ($hash_diff.added | length) > 0 {
        print $"(ansi cyan)hashed file added(ansi reset) (($hash_diff.added | length)):"
        $hash_diff.added | each { |p| print $"  + ($p)" } | ignore
    }
    if ($hash_diff.removed | length) > 0 {
        print $"(ansi yellow)hashed file removed(ansi reset) (($hash_diff.removed | length)):"
        $hash_diff.removed | each { |p| print $"  - ($p)" } | ignore
    }
    if ($hash_diff.modified | length) > 0 {
        print $"(ansi magenta)content changed(ansi reset) (($hash_diff.modified | length)) — file modified \(hash differs\):"
        $hash_diff.modified | each { |p| print $"  ~ ($p)" } | ignore
    }

    print ""
    print $"run `sw-snapshot` to commit this state, or `sw-diff HEAD` for command-output diffs"
}

# Take a new snapshot and commit it to the local git repo.
def "sw-snapshot" [
    --message (-m): string  # custom commit message
] {
    _sw-init-repo
    let cfg = (_sw-load-config)
    let dir = (_sw-state-dir)

    let stats = (_sw-write-snapshot $cfg)

    # An empty commit would fail, so check for staged changes first.
    git -C $dir add -A
    let staged = (git -C $dir diff --cached --name-only | complete | get stdout | str trim)
    if ($staged | is-empty) {
        print $"(ansi green)✓(ansi reset) snapshot unchanged — nothing to commit"
        return
    }

    let msg = ($message | default $"snapshot: ($stats.discovery_count) discovery, ($stats.hashing_count) hashed, ($stats.command_count) commands")
    git -C $dir commit --quiet -m $msg
    let sha = (git -C $dir rev-parse --short HEAD | complete | get stdout | str trim)
    print $"(ansi green)✓(ansi reset) snapshot committed: ($sha) — ($msg)"
}

# Show snapshot history.
def "sw-log" [
    n?: int  # how many entries (default 20)
] {
    let dir = (_sw-state-dir)
    if not (($dir | path join ".git") | path exists) {
        print $"(ansi yellow)system-watch:(ansi reset) no snapshots yet"
        return
    }
    let count = ($n | default 20)
    git -C $dir log --oneline --decorate -n $count
}

# Show diff between snapshots.
def "sw-diff" [
    ref1: string  # baseline ref (e.g. HEAD~1, abc123)
    ref2?: string  # target ref (default: working tree)
] {
    let dir = (_sw-state-dir)
    if ($ref2 | is-empty) {
        git -C $dir diff $ref1
    } else {
        git -C $dir diff $ref1 $ref2
    }
}
