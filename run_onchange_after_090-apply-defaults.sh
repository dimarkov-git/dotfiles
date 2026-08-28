#!/usr/bin/env bash
# macOS preferences, as `defaults write` calls rather than chezmoi-managed
# plists: those are binary, carry per-machine state, and are rewritten
# constantly by the owning process. This script is the source of truth — add
# a key when you find yourself tweaking the same setting on every fresh mac
# (discover them via a `system-watch` diff of commands/defaults_*.txt).
#
# The killalls are needed because apps cache plist values in memory.

set -euo pipefail

# ─── Keyboard ───────────────────────────────────────────────────────────────

# Press-and-hold shows an accent menu, eating held j/k in Zed and Ghostty.
defaults write -g ApplePressAndHoldEnabled -bool false

# Below the GUI slider's floor, which stops at 2 / 15.
defaults write -g KeyRepeat -int 2
defaults write -g InitialKeyRepeat -int 15

# Substitutions corrupt code pasted through any Cocoa text field.
defaults write -g NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write -g NSAutomaticDashSubstitutionEnabled -bool false
defaults write -g NSAutomaticCapitalizationEnabled -bool false
defaults write -g NSAutomaticPeriodSubstitutionEnabled -bool false

# ─── Dock ───────────────────────────────────────────────────────────────────
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.4
defaults write com.apple.dock largesize -int 16
defaults write com.apple.dock tilesize -int 104
defaults write com.apple.dock mru-spaces -bool false

# Hot corner: bottom-right = Mission Control, gated on ⌘ to avoid accidental
# triggers. 1048576 = 0x100000 = NSCommandKeyMask.
defaults write com.apple.dock "wvous-br-corner" -int 1
defaults write com.apple.dock "wvous-br-modifier" -int 1048576

killall Dock 2>/dev/null || true

# ─── Finder ─────────────────────────────────────────────────────────────────
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
defaults write com.apple.finder _FXSortFoldersFirst -bool true
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
# Applies only to unseen folders — a per-folder .DS_Store choice wins.
defaults write com.apple.finder FXDefaultSearchScope -string SCcf
defaults write com.apple.finder FXPreferredSearchViewStyle -string Nlsv
defaults write com.apple.finder FXPreferredGroupBy -string Name
# View style: Nlsv = list, icnv = icon, Flwv = cover-flow, clmv = column
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv

killall Finder 2>/dev/null || true

# ─── Ghostty ────────────────────────────────────────────────────────────────
# NSWindow/Sparkle settings, only readable from the plist. Everything else
# lives in the chezmoi-managed ~/.config/ghostty/config.
# false to match `window-save-state = never`: left true, macOS restores the
# windows Ghostty declined to save.
defaults write com.mitchellh.ghostty NSQuitAlwaysKeepsWindows -bool false
defaults write com.mitchellh.ghostty SUEnableAutomaticChecks -bool false

# ─── Zed ────────────────────────────────────────────────────────────────────
# AppKit-level toggle, not exposed in Zed's settings.json.
defaults write dev.zed.Zed NSAutoFillHeuristicControllerEnabled -bool false

# ─── Desktop services ───────────────────────────────────────────────────────
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# ─── Screenshots ────────────────────────────────────────────────────────────

# screencapture silently falls back to the Desktop if the dir is missing.
mkdir -p "$HOME/Pictures/Screenshots"
defaults write com.apple.screencapture location -string "$HOME/Pictures/Screenshots"
defaults write com.apple.screencapture disable-shadow -bool true
killall SystemUIServer 2>/dev/null || true

# version-stamp: 1
