#!/usr/bin/env nu
# Find chezmoi state entries whose target file no longer exists in $HOME.
#
# chezmoi's state is append-only for file entries: rename a file in source or
# delete it from $HOME and the old target path stays forever. Harmless, but
# check-drift.nu deliberately ignores them, so this is where they surface.
# Purge with:
#   chezmoi state delete --bucket=entryState --key=<absolute-target-path>

def main [] {
    let state = (^chezmoi state dump | from json)
    let stale = (
        $state.entryState
        | transpose path entry
        | where entry.type == "file"
        | each {|row|
            if ($row.path | path exists) {
                null
            } else {
                {
                    path: $row.path,
                    sha256: ($row.entry.contentsSHA256 | str substring 0..8),
                }
            }
        }
        | compact
    )

    if ($stale | is-empty) {
        print "No stale state entries — every chezmoi-tracked target exists in \$HOME."
        return
    }

    print $"($stale | length) stale state entr\(ies\) — target file missing from \$HOME:"
    print ""
    $stale | print
    print ""
    print "To purge an entry (does NOT touch any real file):"
    print "  chezmoi state delete --bucket=entryState --key=<path>"
    print ""
    print "Or purge all of the above in one go:"
    let cmds = ($stale | each {|r| $"  chezmoi state delete --bucket=entryState --key='($r.path)'" })
    $cmds | str join "\n" | print
}
