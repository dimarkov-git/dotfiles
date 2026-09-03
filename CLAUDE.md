# CLAUDE.md

Personal macOS dotfiles managed by **chezmoi**. Source dir `~/dev-zone/dotfiles`
(set in `~/.config/chezmoi/chezmoi.toml`); `dot_` prefixes map to `~/.`. Shell is
**Nushell**, prompt starship, terminal Ghostty. Packages pinned in `Brewfile`.

The files here are heavily commented — read the one you're changing rather than
looking for a description of it in this file.

## Before starting work

```sh
make drift   # $HOME files edited directly, which apply would overwrite
make diff    # pending source → $HOME changes
git status
```

Resolve drift with `make re-add` first; otherwise `make apply` refuses to run.
Commit straight to `main` — no feature branches. Don't push unless asked.

`dot-check` is the interactive-Nushell equivalent (`dot-*` is the dotfiles
command family: `dot-ask`, `dot-check`, `dot-diff`), but autoloads don't fire
for agents — use the `make` targets.

Agents need `dangerouslyDisableSandbox` for much of this. The sandbox confines
writes to this repo and blocks Apple events and process listing, so `make diff`
(stats read-denied `~/.config/gh`), writes under `~/.local/state`, `hs`,
`osascript` and `pgrep` all fail, as does `make apply` (chezmoi's state db lives
under `~/.config/chezmoi`); only `make drift` runs clean. Worse than failing,
they misattribute: `hs` reports Hammerspoon as not running when it is, and
`osascript` claims an app isn't running while it is frontmost. Believe a
sandboxed "not running" only after re-running outside the sandbox.

## Commands

`make` lists the everyday targets; the rest are internal steps of `make update`.
No test suite, linter, or build step — validate by running `make apply` and using
the resulting shell. **Never run bare `chezmoi apply`**: it bypasses the drift guard.

Two hidden targets are occasionally needed by hand: `make update-integrations`
(regenerates `vendor/autoload/*.nu`; `chezmoi apply` skips `run_onchange_after`
scripts when no managed file changed) and `make trust-taps` (`brew bundle cleanup
--force` silently deletes `~/.homebrew/trust.json`).

`make apply` hard-requires chezmoi, brew, nu (`REQUIRED_TOOLS` in the Makefile).
Everything else is opportunistic: each `run_onchange_*` script guards its own
dependency with `command -v <tool> || { echo skipping; exit 0; }` so a fresh
machine can apply before the Brewfile run finishes.

## Scripts

Numbered in steps of 10; **renaming re-runs a script**, so insert rather than
renumber. Ordering and re-execution semantics are chezmoi's (`run_once_before`,
`run_onchange_after`, …) — each script's header comment explains what it does and
why. `chezmoi state delete-bucket --bucket=scriptState` re-triggers `run_once_*`.

`Brewfile` is generated from `Brewfile.tmpl` and gitignored; the template is the
source of truth. Both, plus `README.md`, are in `.chezmoiignore`.

## Templating and private data

The repo is public. Anything identifying the employer or internal hosts lives in
`~/.config/chezmoi/chezmoi.toml` under `[data]`, outside this repo. Templates use
`{{ if index . "key" }}…{{ end }}` so a missing key collapses the section and
forks render public-safe.

The full key table is in `docs/bootstrap.md` (§ Per-machine `[data]` keys) —
update it there when adding one. Adding a key: `git mv` the file to `*.tmpl`,
wrap the block, add the key locally, document it, `make apply`, verify drift = 0.
Debug with `chezmoi execute-template < path/to/file.tmpl`.

**`workGoTools` is only for tools that install unattended.** `brew bundle` treats
a failed `go install` as a bundle failure, so one tool needing a VPN or a
credential makes every `make update` end red.

## `dot_claude` (Claude Code config)

`~/.claude` is a live working directory — Claude Code writes sessions, caches and
plugin state into it. `dot_claude/.chezmoiignore` is therefore a **whitelist**
(`.claude/*` then `!` per managed path): a blocklist goes stale every release, as
each upgrade adds runtime directories. Its paths resolve against `$HOME`, not
against `dot_claude/` — write `.claude/agents`, never `agents`.

Adding a config file means adding its `!` line, or chezmoi ignores it. New config
surfaces Claude Code supports but this machine has yet to use: `commands/`,
`rules/`, `routines/`, `output-styles/`, `keybindings.json`.

`settings.local.json` holds API keys and stays unmanaged. `autoMode.environment`
is generated, not hand-written — it is deliberately absent from the tracked
`settings.json` so Claude Code profiles the real working directory.

### Session-to-tab pinning

tty is the primary key across the shell (`tab-identity.nu`), the hooks
(`dot_claude/hooks/`), and Hammerspoon (`tab-registry.lua`) — unique per tab and
inherited, so resume and splits cannot collide the way a terminal id did.

Ghostty exposes neither pid nor tty, so `focus` only takes a terminal id, which
`tab-registry.lua` infers from cwd: a tab binds only when its cwd leaves exactly
one unclaimed id. Two tabs opened in one directory therefore stay unbound until
one is claimed, after which bindings persist until the shell or tab dies. An
unresolved tty costs a jump (the banner raises Ghostty), never a merged session;
`t-tabs | where tty == ""` lists them and the menubar marks them `⚠`.

`t-tabs` returns raw data when piped and a formatted table on a terminal, so
`where age > 1hr` works on durations rather than display strings.

## Mode-matching (`private_` prefix)

`private_` normally means "secret", but three places use it purely to match a
mode the app itself writes: `dot_config/zed/private_settings.json` (Zed rewrites
0600), `dot_config/private_karabiner/` and `private_dot_ssh/` (0700 dirs). A
mismatch makes chezmoi stop and ask, which under `make apply` has no TTY and
aborts with `could not open a new TTY`. Don't "normalise" these to 0644.

`check-drift.nu` compares file modes only, so a directory-mode mismatch passes
`make drift` and still breaks apply.

## Nushell gotchas

Load order: `env.nu` → `config.nu` → `vendor/autoload/*.nu` (generated) →
`autoload/*.nu` (re-sourced explicitly by `config.nu`, since `XDG_CONFIG_HOME`
is unset on macOS).

- **Don't shadow `ls`, `cat`, `open`** — builtins return structured data.
- **`def --env`** is required to mutate the caller's PWD or env.
- **Hook-installing modules must append** (`default [] | append {…}`), never
  overwrite, or they silently disable existing hooks.
- **`plugin use` lines must NOT go in `config.nu`.** It's a parser keyword: on a
  machine without the registry the whole config aborts at parse time and every
  new shell opens broken. An `if ... | path exists` guard does not help. They're
  generated into `vendor/autoload/plugins.nu` only when the registry exists.
- Two parallel histories by design: nushell's SQLite (Up arrow) and atuin
  (Ctrl+R). Both record everything. Don't consolidate.
- Plugins are `cargo install`ed, registered in a binary registry outside chezmoi.
  `make bootstrap-plugins` on a new machine (needs `rustup default stable`);
  deliberately no `--locked` — published lockfiles pin transitive deps that fail
  on newer rustc.

## Git hooks

`dot_git-templates/hooks/prepare-commit-msg` prepends `[branch] ` to a commit
subject, skipping `main master develop staging test` and merges. It reaches repos
via `init.templatedir`, which copies at `git init`/`clone` time only — so editing
the template leaves every existing repo on the old copy. `projects hooks` reports
divergence for the repos in `$PWD` (`-d` for deeper trees), `--fix` recopies from
the deployed `~/.git-templates`, not from this repo. Repos with `core.hooksPath`
set are reported, never overwritten: there `.git/hooks` is dead.

## Git identity and signing

Two independent axes, both `includeIf` at the bottom of `dot_gitconfig.tmpl`:
identity by **path** (`gitdir:`) and GitLab push options by **remote URL**
(`hasconfig:` → `~/.gitconfig-gitlab`). Includes must stay below `[user]`; git
takes the last value.

Identities are `[[data.gitAccounts]]` entries, one `dot_gitconfig-<name>.tmpl`
each (bodies differ only in `$want`). **Array order is load-bearing**: a tree
nested inside an earlier account's `dir` matches both includes and the last
wins. An entry's `signFormat` picks ssh vs openpgp signing and keeps openpgp
ones out of `allowed_signers`.

Signing is SSH-format via 1Password's `op-ssh-sign` — no key on disk, so `~/.ssh/`
is safe to commit. Two traps worth knowing before touching it: `gitSigningKey`
must be an **SSH public key**, not a GPG fingerprint (a fingerprint isn't
rejected, commits just fail later); and the forge needs the key uploaded a
**second** time as a signing key or the web UI says "Unverified".

Verify against a real `.git` — `git -c includeIf…` is ignored, includes resolve
when reading files:

```sh
git -C <repo> config user.email
GIT_TRACE_PACKET=1 git push --dry-run 2>&1 | grep 'push> merge'
git -C <repo> log --show-signature -1
```

## No host PHP

There is **no PHP on this machine** — no `php`, `composer`, `pecl`, or
`shivammathur/*` taps. All PHP work goes through the project's docker image via
`d-php`/`d-make`/`d-composer`/`d-sh`. The container is the version of record.
Don't re-add a host PHP to `Brewfile.tmpl` or a host branch to
`docker-php.nu.tmpl`.

## Out of chezmoi's reach

- **`system-watch`** (`sw-status`/`sw-snapshot`/`sw-diff`) observes config drift
  *outside* chezmoi's surface: launch agents, `~/Library` plists, `defaults`
  domains, brew state. Config `dot_config/system-watch/config.toml`; state is a
  push-blocked local git repo. Hashing never stores file content, so credential
  files can be watched safely. Observability, not enforcement.
- **Manual installs** — vendor-pkg and Mac App Store apps, in
  `docs/manual-installs.md`. `mas` was rejected (Apple ID / 2FA friction).
- **macOS preferences** are automated separately, in
  `run_onchange_after_090-apply-defaults.sh` — add a tweak there when you find
  yourself setting it on every fresh mac.

## Editing conventions

- Comments explain **why**, not what. Preserve the existing style; leave
  self-explanatory settings uncommented.
- Edit the **generation script**, not the generated file in `vendor/autoload/`.
- Brewfile entries: grouped by kind, then `## Category: <Name>`, alphabetized,
  one-line description each. `# why:` above an entry when the choice isn't
  self-evident.
