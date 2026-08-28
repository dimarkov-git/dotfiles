# dotfiles

Managed by [chezmoi](https://chezmoi.io). Source dir: `~/dev-zone/dotfiles`.

Shell is Nushell, prompt is starship, terminal is Ghostty.

## Setup

1. [`docs/bootstrap.md`](docs/bootstrap.md) — new mac, start to finish. The
   clone needs 1Password's SSH agent for the git key, so the first steps are
   by hand.
2. [`docs/manual-installs.md`](docs/manual-installs.md) — apps `make apply`
   doesn't handle.

Day-to-day: `make apply` deploys, `make drift` shows files edited in `$HOME`
without updating source. Don't run bare `chezmoi apply` — it skips the drift
guard.
