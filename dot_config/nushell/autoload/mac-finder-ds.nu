# Finder keeps a per-folder view style in .DS_Store, and it beats
# FXPreferredViewStyle — deleting them restores the script-set default.

def _mac-finder-ds-find [depth: int, all: bool] {
    let args = (
        [$env.HOME -maxdepth $depth -name ".DS_Store"]
        | append (if $all { [] } else { [-not -path "*/Library/*"] })
        | append [-not -path "*/node_modules/*" -not -path "*/.Trash/*"]
    )
    # Permission errors on protected dirs are expected, hence stdout only.
    do { ^find ...$args } | complete | get stdout
    | lines
    | where { |l| ($l | str trim) != "" }
}

def _mac-finder-ds-rows [found: list<string>] {
    $found | each { |p|
        {
            path: ($p | str replace $env.HOME "~")
            size: (try { ls -l $p | get 0.size } catch { 0b })
        }
    } | sort-by path
}

export def main [] {
    mac-finder-ds list
}

# Show every .DS_Store under $HOME.
export def "mac-finder-ds list" [
    --all              # include ~/Library, normally skipped
    --depth: int = 6   # how deep to walk from $HOME
] {
    let found = (_mac-finder-ds-find $depth $all)
    if ($found | is-empty) {
        print $"(ansi green)✓(ansi reset) no .DS_Store found under ($env.HOME)"
        return
    }
    let rows = (_mac-finder-ds-rows $found)
    $rows | table --index false | print
    print $"($found | length) file\(s), ($rows | get size | math sum)"
}

# Delete every .DS_Store under $HOME, then restart Finder.
export def "mac-finder-ds clean" [
    --yes (-y)         # skip the confirmation prompt
    --all              # include ~/Library, normally skipped
    --depth: int = 6   # how deep to walk from $HOME
] {
    let found = (_mac-finder-ds-find $depth $all)
    if ($found | is-empty) {
        print $"(ansi green)✓(ansi reset) no .DS_Store found under ($env.HOME)"
        return
    }

    let rows = (_mac-finder-ds-rows $found)
    $rows | table --index false | print
    print $"($found | length) file\(s), ($rows | get size | math sum)"

    if not $yes {
        print ""
        let answer = (input $"(ansi red)delete all ($found | length)?(ansi reset) [y/N] ")
        if ($answer | str lowercase) not-in ["y", "yes"] {
            print "aborted"
            return
        }
    }

    let failed = (
        $found | where { |p| (do { ^rm -f $p } | complete).exit_code != 0 }
    )

    print $"(ansi green)✓(ansi reset) removed (($found | length) - ($failed | length)) file\(s)"
    if ($failed | is-not-empty) {
        print $"(ansi yellow)($failed | length) could not be removed(ansi reset):"
        $failed | each { |p| print $"  ($p | str replace $env.HOME '~')" }
    }

    ^killall Finder
    print "Finder restarted"
}
