.PHONY: help apply diff drift status re-add restore update update-go-tools update-krew update-nu-plugins update-integrations trust-taps bootstrap-plugins state-stale

.DEFAULT_GOAL := help

# Lists targets carrying a `## ` comment; the rest are internal steps of these.
help:
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / \
		{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Brewfile.tmpl is the source of truth; the rendered Brewfile is .gitignored,
# keeping chezmoi-data-gated private entries out of the public repo.
Brewfile: Brewfile.tmpl
	chezmoi execute-template < Brewfile.tmpl > Brewfile

# `binary:install-hint`; the hint is shown verbatim, so keep it copy-pasteable.
# nu's formula is `nushell`; brew can only bootstrap via its installer URL.
REQUIRED_TOOLS := \
	chezmoi:'brew install chezmoi' \
	brew:'see https://brew.sh' \
	nu:'brew install nushell'

# Always use this instead of bare `chezmoi apply`: it gates on required tools
# and on drift ($HOME files edited directly, which apply would overwrite).
# Drift can't be read off `chezmoi status` — its second column shows `M` for
# both "target drifted" and "source ahead"; scripts/check-drift.nu compares
# against the hashes in chezmoi's state instead.
apply: Brewfile ## Deploy source → $HOME (aborts on drift)
	@missing=""; \
	for spec in $(REQUIRED_TOOLS); do \
		bin=$${spec%%:*}; hint=$${spec#*:}; \
		if ! command -v $$bin >/dev/null 2>&1; then \
			missing="$$missing\n   - $$bin\n     ↳ $$hint"; \
		fi; \
	done; \
	if [ -n "$$missing" ]; then \
		printf "\nERROR: required tools missing — \`make apply\` cannot run.\n%b\n\nInstall them and retry.\n\n" "$$missing"; \
		exit 1; \
	fi
	@drift=$$(nu scripts/check-drift.nu); \
	if [ -n "$$drift" ]; then \
		echo ""; \
		echo "ERROR: \$$HOME has files that drifted from chezmoi's last-applied state:"; \
		echo ""; \
		echo "$$drift"; \
		echo ""; \
		echo "Run 'make re-add' to pull them back into source, then retry."; \
		echo ""; \
		echo "For a '(mode ...)' line the contents are fine and only the"; \
		echo "permissions moved — some tool rewrote the file with its own"; \
		echo "umask. 're-add' handles it by renaming the source file to"; \
		echo "'private_<name>' (chezmoi's 0600 marker), so check 'git status'"; \
		echo "afterwards and keep the rename if that mode is what you want."; \
		exit 1; \
	fi
	chezmoi apply
	@[ -f "$$HOME/.config/nushell/plugin.msgpackz" ] || \
		echo "note: nu plugins not registered — run 'make bootstrap-plugins' (needs 'rustup default stable' first)"

diff: ## Preview what `make apply` would write
	chezmoi diff

drift: ## Show $HOME files edited without updating source
	@drift=$$(nu scripts/check-drift.nu); \
	if [ -n "$$drift" ]; then \
		echo "$$drift"; \
		echo ""; \
		chezmoi diff --reverse; \
	else \
		echo "No drift — \$$HOME matches chezmoi's last-applied state."; \
	fi
	@root=$$(nu scripts/check-root-files.nu); \
	if [ -n "$$root" ]; then \
		echo ""; \
		echo "Root-owned targets (not managed by chezmoi; 'make restore' rewrites them):"; \
		echo "$$root"; \
	fi

status:
	chezmoi status

re-add: ## Pull deployed-side edits back into source (resolves drift)
	chezmoi re-add
	@root=$$(nu scripts/check-root-files.nu); \
	if [ -n "$$root" ]; then \
		echo ""; \
		echo "NOT re-added — root-owned, outside chezmoi's reach. Copy by hand to keep:"; \
		echo "$$root"; \
	fi

# Mirror image of re-add: that resolves drift by keeping the $HOME edits, this
# one by discarding them. --force skips apply's per-file prompt, which under
# make has no TTY anyway. /etc/hosts rides along because its run_onchange script
# only fires when etc/hosts itself changes — kubefwd's edits are invisible to it.
restore: Brewfile ## Discard $HOME edits — force source → $HOME
	@drift=$$(nu scripts/check-drift.nu); \
	if [ -n "$$drift" ]; then \
		echo ""; \
		echo "These \$$HOME files drifted and will be OVERWRITTEN from source:"; \
		echo ""; \
		echo "$$drift"; \
		echo ""; \
	else \
		echo "No drift — apply --force will be a no-op for managed files."; \
	fi; \
	printf "Discard those edits? [y/N] "; \
	read ans || true; \
	case "$$ans" in [yY]*) ;; *) echo "Aborted."; exit 1;; esac
	chezmoi apply --force
	@chezmoi execute-template < run_onchange_after_100-apply-etc-hosts.sh.tmpl | bash

# Harmless, but drift detection ignores them — the only place they surface.
state-stale:
	@nu scripts/check-state-stale.nu

# `brew bundle cleanup --force` silently deletes ~/.homebrew/trust.json, so
# trust-taps runs both before the bundle and after the cleanup that wipes it.
update: Brewfile apply ## Update everything: brew, Go tools, krew, nu plugins, integrations
	brew update
	@$(MAKE) --no-print-directory trust-taps
	brew bundle install --file=Brewfile
	brew bundle cleanup --file=Brewfile --force
	@$(MAKE) --no-print-directory trust-taps
	@$(MAKE) --no-print-directory update-go-tools
	@$(MAKE) --no-print-directory update-krew
	@$(MAKE) --no-print-directory update-nu-plugins

# `brew bundle` only checks these binaries exist, so a Go upgrade leaves them
# built by the old toolchain — which dlv rejects. List comes from the Brewfile.
update-go-tools: Brewfile
	@command -v go >/dev/null 2>&1 || { echo "go not installed; skipping"; exit 0; }; \
	failed=""; \
	for mod in $$(grep '^go "' Brewfile | sed 's/^go "//; s/"$$//'); do \
		echo "==> $$mod"; \
		go install "$$mod@latest" || failed="$$failed $$mod"; \
	done; \
	if [ -n "$$failed" ]; then \
		echo ""; \
		echo "WARNING: these Go tools did not build:"; \
		for mod in $$failed; do echo "  - $$mod"; done; \
		echo "A private module here usually means the VPN is down."; \
	fi

update-krew:
	@kubectl krew version >/dev/null 2>&1 || { echo "krew not installed; skipping"; exit 0; }; \
	kubectl krew update && kubectl krew upgrade

# Renders the run_onchange trust script rather than duplicating its tap list;
# chezmoi only re-runs that script when Brewfile.tmpl changes.
trust-taps:
	@chezmoi execute-template < run_onchange_before_010-trust-brew-taps.sh.tmpl | bash

# cargo has no built-in upgrade; cargo-update adds one. Re-registers each
# plugin afterwards — a rebuilt binary keeps its path but not its registration.
update-nu-plugins:
	@command -v cargo-install-update >/dev/null 2>&1 || { echo "cargo-update not installed; skipping"; exit 0; }; \
	cargo install-update -- nu_plugin_gstat nu_plugin_query nu_plugin_polars; \
	for p in nu_plugin_gstat nu_plugin_query nu_plugin_polars; do \
		[ -x "$$HOME/.cargo/bin/$$p" ] && nu -c "plugin add ~/.cargo/bin/$$p"; \
	done; \
	$(MAKE) --no-print-directory update-integrations

# Run directly: it's `run_onchange_after`, so `chezmoi apply` skips it entirely
# when no managed file changed — which is the normal case after a tool upgrade.
update-integrations:
	bash run_onchange_after_040-generate-nushell-integrations.sh

# Run AFTER `make apply` + `brew bundle install`. Deliberately NOT `--locked`:
# the published lockfiles pin transitive deps that fail to build on a newer
# rustc (nu_plugin_polars 0.114 pins ethnum 1.5.2 → E0512 on rustc 1.97).
# If an unpinned build ever breaks instead, try `--locked` first.
# Installed independently so one failure doesn't cost the others.
bootstrap-plugins: ## Install nu plugins (gstat, query, polars) on a fresh machine
	@failed=""; \
	for p in nu_plugin_gstat nu_plugin_query nu_plugin_polars; do \
		echo "==> $$p"; \
		if cargo install $$p; then \
			nu -c "plugin add ~/.cargo/bin/$$p"; \
		else \
			failed="$$failed $$p"; \
		fi; \
	done; \
	if [ -n "$$failed" ]; then \
		echo ""; \
		echo "WARNING: these plugins did not build:$$failed"; \
		echo "The others are registered and usable. Retry a failed one with:"; \
		echo "  cargo install <name> && nu -c 'plugin add ~/.cargo/bin/<name>'"; \
	fi
	@echo "Restart your shell, then run 'plugin list' to verify."
