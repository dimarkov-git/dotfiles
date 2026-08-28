#!/bin/bash
# Catppuccin skins for k9s.
#
# Skins live next to the config, under K9S_CONFIG_DIR (set in env.nu to
# ~/.config/k9s — k9s ignores XDG_CONFIG_HOME and would default to
# ~/Library/Application Support/k9s). This path must match that variable;
# a mismatch leaves `ui: {skin: catppuccin-mocha}` pointing at nothing.
#
# Not run through nu, so K9S_CONFIG_DIR is not in scope here — the default
# mirrors env.nu rather than reading it.
#
# Skins are fetched, not vendored: they track upstream and are reproducible
# from the URL below.

set -euo pipefail

SKINS_DIR="${K9S_CONFIG_DIR:-$HOME/.config/k9s}/skins"
mkdir -p "$SKINS_DIR"

BASE_URL="https://raw.githubusercontent.com/catppuccin/k9s/main/dist"

for variant in latte frappe macchiato mocha; do
    dest="$SKINS_DIR/catppuccin-${variant}.yaml"
    if curl -fsSL "$BASE_URL/catppuccin-${variant}.yaml" -o "$dest"; then
        echo "Installed $dest"
    else
        echo "WARN: failed to fetch catppuccin-${variant}.yaml"
    fi
done
