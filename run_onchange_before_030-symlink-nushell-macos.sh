#!/bin/bash
# macOS Nushell reads config from ~/Library/Application Support/nushell/;
# the source of truth is the XDG path so the same files work on Linux.

set -euo pipefail

XDG_NUSHELL="$HOME/.config/nushell"
MACOS_NUSHELL="$HOME/Library/Application Support/nushell"

if [[ "$(uname)" != "Darwin" ]]; then
    exit 0
fi

mkdir -p "$XDG_NUSHELL"

if [[ -L "$MACOS_NUSHELL" ]] && [[ "$(readlink "$MACOS_NUSHELL")" == "$XDG_NUSHELL" ]]; then
    exit 0
fi

if [[ -e "$MACOS_NUSHELL" ]] && [[ ! -L "$MACOS_NUSHELL" ]]; then
    backup="${MACOS_NUSHELL}.pre-chezmoi.$(date +%Y%m%d%H%M%S)"
    mv "$MACOS_NUSHELL" "$backup"
    echo "Backed up existing macOS nushell dir to: $backup"
fi

ln -s "$XDG_NUSHELL" "$MACOS_NUSHELL"
echo "Symlinked $MACOS_NUSHELL -> $XDG_NUSHELL"
