#!/bin/bash
# Install Claude Code via Anthropic's native installer.
#
# Not Homebrew: the cask lags upstream and `claude update` self-manages
# versioning, so brew would fight the binary's own update channel.

set -euo pipefail

if command -v claude >/dev/null 2>&1; then
    echo "claude already installed at $(command -v claude); skipping."
    exit 0
fi

echo "Installing Claude Code via https://claude.ai/install.sh ..."

# Soft-fail: a missing optional tool must not break `make apply`.
if ! curl -fsSL https://claude.ai/install.sh | bash; then
    echo "WARNING: Claude Code install failed (network? rate limit?)." >&2
    echo "Re-run later with: curl -fsSL https://claude.ai/install.sh | bash" >&2
    exit 0
fi

echo "Claude Code installed. Run 'claude' to verify."
