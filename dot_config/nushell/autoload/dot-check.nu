# Manual health check for the dotfiles repo. Reports drift ($HOME edited
# directly), pending source changes, and the repo's own git state.
#
# Kept manual on purpose: a startup check taxes every new window, and an
# indicator that's green 99% of the time stops being noticed when it turns red.

def dot-check [] {
    let repo = ($env.HOME | path join "dev-zone/dotfiles")

    # Delegated so mode drift counts too — `make apply` blocks on it, and a
    # local reimplementation drifted from that once already.
    let drift = (
        do { ^$nu.current-exe ($repo | path join "scripts/check-drift.nu") } | complete
        | get stdout
        | lines
        | where { |l| ($l | str trim) != "" }
        | each { |l| $l | str replace --regex '^\S+\s+' '' | str replace --regex ': FAILED' '' }
    )

    # Source ahead of target: `chezmoi status` col 1 = source, col 2 = target.
    # Non-empty col 1 means the target is behind.
    let pending = (
        do { chezmoi status } | complete | get stdout
        | lines
        | where { |l| ($l | str length) > 0 and ($l | str substring 0..0) != " " }
    )

    let git_dirty = (
        do { git -C $repo status --porcelain } | complete | get stdout
        | lines | where { |l| ($l | str length) > 0 }
    )
    let git_ahead = (
        do { git -C $repo rev-list --count "@{u}..HEAD" } | complete
        | get stdout | str trim | into int --signed
    )

    mut ok = true

    if ($drift | length) > 0 {
        print $"(ansi yellow)drift(ansi reset): ($drift | length) file\(s) edited in \$HOME — run `make re-add`"
        $drift | each { |p| print $"  ($p)" }
        $ok = false
    }

    if ($pending | length) > 0 {
        print $"(ansi yellow)pending(ansi reset): ($pending | length) source change\(s) not applied — run `make apply`"
        $pending | each { |l| print $"  ($l)" }
        $ok = false
    }

    if ($git_dirty | length) > 0 {
        print $"(ansi yellow)git(ansi reset): ($git_dirty | length) uncommitted change\(s) in repo"
        $ok = false
    }

    if $git_ahead > 0 {
        print $"(ansi yellow)git(ansi reset): ($git_ahead) commit\(s) ahead of origin — `git push`"
        $ok = false
    }

    if $ok {
        print $"(ansi green)✓(ansi reset) dotfiles clean: no drift, no pending changes, repo in sync"
    }
}

# Diff viewer for everything dot-check reports, all of it through delta.
#
#   dot-diff            # everything that differs
#   dot-diff drift      # $HOME → source (what re-add would take)
#   dot-diff pending    # source → $HOME (what apply would write)
#   dot-diff root       # repo → /etc/hosts et al (needs sudo to fix)
def dot-diff [
    what: string@_dot-diff-what = "all"
] {
    let repo = ($env.HOME | path join "dev-zone/dotfiles")
    # --paging=never: delta spawning less would swallow the later sections.
    let pager = { delta --paging=never }

    if $what in ["all", "drift"] {
        let out = (do { chezmoi diff --reverse --no-pager } | complete | get stdout)
        if ($out | str trim | is-not-empty) {
            print $"(ansi cyan)── drift: $HOME → source(ansi reset)"
            $out | do $pager
        }
    }

    if $what in ["all", "pending"] {
        let out = (do { chezmoi diff --no-pager } | complete | get stdout)
        if ($out | str trim | is-not-empty) {
            print $"(ansi cyan)── pending: source → $HOME(ansi reset)"
            $out | do $pager
        }
    }

    if $what in ["all", "root"] {
        # Keep in sync with ROOT_FILES in scripts/dotfiles-status-json.nu.
        for f in [{ source: "etc/hosts", target: "/etc/hosts" }] {
            let src = ($repo | path join $f.source)
            if not ($src | path exists) or not ($f.target | path exists) { continue }
            let out = (do { ^diff -u $f.target $src } | complete | get stdout)
            if ($out | str trim | is-not-empty) {
                print $"(ansi cyan)── root: ($f.target) \(fix: make apply, needs sudo\)(ansi reset)"
                $out | do $pager
            }
        }
    }
}

def _dot-diff-what [] { ["all", "drift", "pending", "root"] }
