# Bootstrap a new macOS machine

Fresh macOS install → fully provisioned environment. Run in order; each step
is idempotent.

Phase 1 (steps 1–5) is everything that must exist **before** the repo is
cloned — done by hand in stock Terminal.app, no dotfiles present.

## 0. Before you wipe the old mac

### Do NOT use Migration Assistant

Migration Assistant copies managed files into the new `$HOME` as ordinary
files without carrying chezmoi's state
(`~/.local/share/chezmoi/chezmoistate.boltdb`) consistently. Drift detection
compares target hashes against the SHA256s in that state (see
`scripts/check-drift.nu`), so a migrated `$HOME` reports drift on files
nobody edited — and `make apply` refuses to run until `make re-add`
"resolves" it by writing the migrated copies back over source. Clean install
+ `git clone` gives consistent state on the first apply.

### Grab what is not in this repo

Not recoverable from the repo — copy off before wiping:

```sh
~/.config/chezmoi/chezmoi.toml     # the only copy of the private [data] values
~/.local/share/atuin/key           # atuin history is undecryptable without it
~/.kube/config                     # cluster contexts; holds OIDC client secrets
~/.kube/crt/                       # CA certs the deac-* contexts point at
```

Put them in 1Password, not on a USB stick — the new machine has 1Password
before anything else (step 5).

**`~/.kube/` is deliberately not managed** — `config` holds OIDC client
secrets in plaintext. Copy it preserving layout: the CA paths are *relative*
(`crt/deac/stg/ca.crt`), so a flattened copy breaks those contexts with a
TLS error. Skip `cache/` and the `kind-*` context (stale once the old
cluster is gone). Tooling comes from the Brewfile, but the keycloak and
`*.local` endpoints need the VPN.

**SSH keys are deliberately absent from that list.** They live in the
1Password vault and are served by its agent; nothing in `~/.ssh/` needs
carrying over. If any key still exists only as a file on the old mac, import
it into 1Password now.

Also: `sw-snapshot` on the old mac, then copy `~/.local/state/system-watch/`
off-machine — it is the ground truth for what was installed outside brew,
which is how [`manual-installs.md`](manual-installs.md) gets verified. Copy
the directory directly; its git repo is push-blocked four ways.

### Time Machine

`tmutil destinationinfo` — "No destinations configured" means there is no
backup to fall back on.

---

# Phase 1 — prerequisites (by hand, before cloning)

Stock **Terminal.app** with bash/zsh. Nushell and Ghostty do not exist yet.

## 1. FileVault

Do this **first**: FileVault encrypts data as it is written, so turning it on
later leaves earlier blocks unprotected. SSH material, `gh` tokens and the
atuin key all land in `$HOME` in later steps.

> System Settings → Privacy & Security → FileVault → Turn On

Store the recovery key in a *different* vault than the one you are about to
rely on for SSH, or print it.

```sh
sudo fdesetup status    # "FileVault is On."
```

`sudo` matters: without it the command can fail with "Unknown volume or
device specifier" instead of reporting state.

## 2. Apple toolchain (`clang`, `git`, headers, SDK)

Command Line Tools are required either way — Homebrew and cgo want them even
when full Xcode is installed, and `brew config` reports `CLT` and `Xcode` as
separate versions.

```sh
xcode-select --install
```

If you also install Xcode (step 13), accept its license and point
`xcode-select` at it — until then `git` and `clang` refuse to run and
complain about the agreement, which reads like a broken toolchain:

```sh
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcode-select -p    # → /Applications/Xcode.app/Contents/Developer
```

## 3. Homebrew

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
```

The `shellenv` line is needed for the next steps; subsequent shells get brew
via `dot_config/nushell/env.nu`.

## 4. Claude Code (optional)

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

Deliberately not Homebrew: the cask lags upstream and `claude update`
self-manages. `run_once_after_060-install-claude-code.sh` runs the same
installer during the first apply and no-ops when `claude` is on PATH.

`dot_claude/` carries the config (settings, hooks, agents, skills). Two things
apply cannot restore: `~/.claude/settings.local.json` with `CONTEXT7_API_KEY`,
and MCP servers using interactive auth. Plugins in `enabledPlugins` refetch on
first run.

## 5. 1Password + SSH agent

This unblocks `git clone`, so it cannot move later.

Install the app from <https://1password.com/downloads/mac>. Not via brew: it
self-updates through Sparkle. The `1password-cli` package *is* in the
Brewfile and arrives with the first apply — `op` will be missing until then,
which is fine.

Then, in the GUI:

1. Sign in to your account.
2. **Settings → Developer → "Use the SSH agent"** — turn it on.
3. Confirm the git signing/auth key is present in the vault.

`~/.ssh/config` points `IdentityAgent` at the agent socket — but it is
managed by *this repo*, which is not cloned yet. So for the clone in step 6
only, point ssh at the agent through the environment:

```sh
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
ssh-add -l          # should list the vault key
```

That export lasts only for the current Terminal session; from the first
`chezmoi apply` onward `~/.ssh/config` does the same job for every shell.

---

# Phase 2 — the repo

## 6. chezmoi + dotfiles

Clone directly to the final location — do **not** use `chezmoi init --apply`:

```sh
brew install chezmoi
mkdir -p ~/dev-zone
git clone git@github.com:<you>/dotfiles.git ~/dev-zone/dotfiles
mkdir -p ~/.config/chezmoi
printf 'sourceDir = "~/dev-zone/dotfiles"\n' > ~/.config/chezmoi/chezmoi.toml
```

If the clone hangs or asks for a password, the agent export from step 5 is
missing from *this* shell — re-run it, not the whole step.

`chezmoi init --apply <repo>` would clone to `~/.local/share/chezmoi`
instead, leaving chezmoi's recorded state pointing at the wrong source dir.

**Fill in the `[data]` keys now**, before the first apply — see
[Per-machine `[data]` keys](#per-machine-data-keys). Applying without them
renders `.gitconfig` with no identity, so you just apply a second time.

Then, **`chezmoi apply`, not `make apply`** — the one time to call it
directly, since `make apply` requires `nu`, which only arrives with the
Brewfile run inside this very apply:

```sh
chezmoi apply
```

Every apply after this one goes through `make apply`.

The first `apply`:
- `run_once_before_020-install-brew-bundle.sh.tmpl` → installs every package
  in `Brewfile` (~5–10 min).
- `run_onchange_before_030-symlink-nushell-macos.sh` → the
  `~/Library/Application Support/nushell` → `~/.config/nushell` symlink.
- `run_onchange_after_040-generate-nushell-integrations.sh` → vendor autoload
  modules for starship, zoxide, atuin, carapace.
- `run_onchange_after_050-install-k9s-skin.sh` → Catppuccin skins for k9s,
  into `~/.config/k9s/skins/` (see `K9S_CONFIG_DIR` in `env.nu`).
- `run_once_after_060-install-claude-code.sh` → no-op if step 4 ran it.
- `run_onchange_after_090-apply-defaults.sh` → `defaults write` for Dock,
  Finder, Ghostty, Zed.
- `run_onchange_after_100-apply-etc-hosts.sh.tmpl` → **prompts for your sudo
  password**; `/etc/hosts` is root-owned and outside destDir. Declining leaves
  it unchanged and the apply still succeeds.
- `run_onchange_after_110-reload-hammerspoon.sh.tmpl` → skipped until the `hs`
  CLI exists, which is after the Brewfile run. Sole reload trigger (init.lua has
  no pathwatcher); fails the apply on a Lua syntax error rather than reloading
  into an empty menubar.

It also writes `~/.ssh/config` (0600) with the 1Password `IdentityAgent`
line, making the step 5 `SSH_AUTH_SOCK` export unnecessary from here on.

If anything fails mid-run, re-running `chezmoi apply` retries only the failed
scripts — `run_once_*` state is recorded per script.

---

# Phase 3 — post-apply setup

## 7. Set Ghostty as the default terminal

Open Ghostty once from Spotlight so it registers with macOS.

Hammerspoon binds **option+space** to show/hide it (see
`dot_hammerspoon/init.lua`), which needs Accessibility granted once:

> System Settings → Privacy & Security → Accessibility → enable Hammerspoon

Grant it *before* testing the hotkey — Hammerspoon caches the permission at
startup, so quit and reopen it if it was already running.

Ghostty's own drop-down terminal on `ctrl+\`` works without Accessibility
and coexists: it opens a separate scratch surface, option+space raises the
main window with your tabs.

## 8. Switch the login shell to Nushell

```sh
echo "/opt/homebrew/bin/nu" | sudo tee -a /etc/shells
chsh -s /opt/homebrew/bin/nu
```

Ghostty pins `command = /opt/homebrew/bin/nu`, so this is only needed for
other terminals.

## 9. Rust toolchain

```sh
rustup default stable
```

`rustup` is keg-only and ships **no toolchain** until you select one.
Without this the `cargo install` in step 10 has no compiler.

## 10. Nushell plugins

```sh
make bootstrap-plugins
```

Installs `nu_plugin_gstat`, `nu_plugin_query`, `nu_plugin_polars` into
`~/.cargo/bin/` and registers them in `~/.config/nushell/plugin.msgpackz`
(binary, per-machine, not under chezmoi). Each is installed independently,
so one build failure leaves the others working.

The `plugin use` lines live in `vendor/autoload/plugins.nu`, generated only
when the registry already exists — so regenerate after this step and restart
the shell:

```sh
make update-integrations
nu -c 'plugin list'   # gstat, query, polars
```

`make apply` alone does not do it: the generator is a `run_onchange_after`
script, which chezmoi skips entirely when no managed file changed.

A missing plugin did not build; the shell still starts fine. Retry that one
with `cargo install nu_plugin_<name>`, `nu -c 'plugin add
~/.cargo/bin/nu_plugin_<name>'`, then regenerate as above.

## 11. Per-tool first-run setup

- **gh CLI**: `gh auth login`. Creates `~/.config/gh/hosts.yml` (chezmoi-ignored).
- **atuin**: `atuin login -u <username>` then `atuin sync`. Needs the key saved in step 0 (`~/.local/share/atuin/key`); without it the synced history cannot be decrypted.
- **1Password CLI**: `op signin` — authorises `op` for `op://` references in chezmoi templates.
- **direnv**: nothing; `direnv allow` once per project with an `.envrc`.
- **SSH**: nothing — keys stay in the vault, `~/.ssh/config` was deployed in step 6.
- **Claude Code menubar indicator**: `dot_hammerspoon/claude-status.lua` renders
  session state from `~/.local/state/claude-sessions/` and is poked by
  `dot_claude/hooks/claude-notify.sh` via `hs -c`. Both are chezmoi-managed; the
  state directory is created by the hooks on first session.

**Commit signing** is configured by `.gitconfig` (SSH signing via
`op-ssh-sign`, same key as auth), but the forge needs the key registered a
*second* time as a signing key. Auth-only registration still shows
"Unverified" in the web UI.

```sh
gh ssh-key add --type signing ~/path/to/key.pub    # or paste in the web UI
git log --show-signature -1                        # local check
```

GitLab: Preferences → SSH Keys, usage type "Signing". Verify a real commit:

```sh
git cat-file -p HEAD | grep -q gpgsig && echo "signed"
```

## 12. Verify

```sh
make drift                 # should print "No drift"
make diff                  # should be empty
nu -c 'plugin list'        # gstat, query, polars
gh auth status
atuin status
command -v claude          # see note below
sudo fdesetup status       # "FileVault is On."
ssh-add -l                 # vault key, in a shell with no SSH_AUTH_SOCK export
```

Run `ssh-add -l` in a **new Ghostty tab**, not the Terminal.app window you
bootstrapped in — that proves `~/.ssh/config` is doing the work rather than
the step 5 export, which dies with that window.

`command -v claude`: `run_once_after_060-install-claude-code.sh` soft-fails on
network errors by design, so a flaky connection leaves a green `make apply`
and no binary. Re-run `curl -fsSL https://claude.ai/install.sh | bash`.

For the Brewfile prefer `make update` over `brew bundle check` — the latter
exits non-zero when a pinned formula is merely *outdated*, which is noise
right after a fresh install.

## 13. Manual installs (out of scope for `make apply`)

Apps without a Homebrew cask and Mac App Store apps are listed in
[`manual-installs.md`](manual-installs.md). macOS preference tweaks are
applied by `run_onchange_after_090-apply-defaults.sh` during `make apply`.

**Prefer arm64 builds while reinstalling these.** macOS 27 (Sept 2026) is
the last release carrying full Rosetta 2; it ends with macOS 28 in late
2027. Vendor pkgs are where x86_64-only builds linger.

## Per-machine `[data]` keys

The repo is public; private values live in `~/.config/chezmoi/chezmoi.toml`
outside chezmoi's source dir. Set them once per machine via
`chezmoi edit-config`:

```toml
sourceDir = "~/dev-zone/dotfiles"

[data]
gitName        = "Your Name"
gitEmail       = "you@example.com"
gitSigningKey  = "ssh-ed25519 AAAA..."           # optional; SSH public key, not GPG

# optional; second identity, activated for repos under gitWorkDir
gitWorkDir        = "~/dev-zone/work"
gitWorkName       = "Your Name"
gitWorkEmail      = "you@company.com"
gitWorkSigningKey = "ssh-ed25519 AAAA..."        # a different key than the personal one

gitlabHost     = "gitlab.your-company.com"        # optional; enables ssh-rewrite, GOPRIVATE
gitlabSshPort  = 32322                            # optional; only read when gitlabHost is set
extraGonosumdb = "*.other-internal.example"      # optional; appended to GONOSUMDB
dockerPhpRepo  = "registry.example.com/php-tools" # optional; activates `d-php` family
workGoTools    = [                                 # optional; extra `go install`-style Brewfile entries
  "your.gitlab.example/team/internal-cli",
]

sshUser = "your.name"                # optional; default User for sshHosts entries

# optional; work ssh hosts. Unset renders ~/.ssh/config with no host blocks —
# `host` is the only required field per entry.
[[data.sshHosts]]
host      = "bastion"
hostname  = "bastion.internal.example"
user      = "your.name"              # optional; falls back to sshUser
proxyJump = "other-host"             # optional
options   = ["ForwardAgent yes"]     # optional; raw config lines
```

Run `make apply` after editing. Missing keys are not an error — the
corresponding template sections are silently omitted (full table in
`CLAUDE.md`).
