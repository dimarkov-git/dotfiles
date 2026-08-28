# Git
alias g = git
alias gs = git status
alias gd = git diff
alias gl = git log --oneline --graph --decorate -20
alias gp = git push
alias gco = git checkout

# Do NOT shadow `ls` — the builtin returns a typed table other commands rely on.
alias ll  = eza --long --all --git --icons --group-directories-first
alias lt  = eza --tree --level=2 --icons --git-ignore
alias la  = eza --all --icons

# Likewise leave `cat` alone: the builtin streams bytes for pipelines.
alias bcat = bat --style=plain --paging=never

alias ..  = cd ..
alias ... = cd ../..

alias k = kubectl
alias cm = chezmoi

# `open` is a Nushell builtin (structured parse); `^` calls /usr/bin/open
# for LaunchServices instead.
alias mac-open = ^open
