# Interactive claude session in the dotfiles repo, launched from anywhere.
# `cd` in a non-`--env` def is block-scoped, so the caller's PWD survives.

def --wrapped dot-ask [...args: string] {
    let repo = ($env.HOME | path join "dev-zone/dotfiles")
    if not ($repo | path exists) {
        print $"(ansi red)error(ansi reset): ($repo) not found"
        return
    }
    cd $repo
    ^claude ...$args
}
