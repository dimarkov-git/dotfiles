# Manual installs

Apps `make apply` cannot install. Anything with a Homebrew cask belongs in
`Brewfile.tmpl` instead — check there before adding a row here.

## Mac App Store

Sign into the same Apple ID, then install each manually. `mas` CLI was
rejected — Apple ID / 2FA friction beats the reproducibility win at this
frequency.

| App | Notes |
|-----|-------|
| Xcode | Apple's IDE |
| Numbers | Apple's spreadsheets |
| Pages | Apple's word processor |
| Keynote | Apple's presentations |
| GarageBand | Audio production |
| iMovie | Video editing |

The iWork three sit on disk as `Numbers Creator Studio.app` and friends; the
App Store names are the short ones.

After Xcode, point `xcode-select` at it — [`bootstrap.md`](bootstrap.md)
step 2. The Command Line Tools are still needed separately.

## Vendor installers

| App | Source |
|-----|--------|
| 1Password | https://1password.com/downloads/mac — **install first, before cloning this repo**: its SSH agent holds the git key (see [`bootstrap.md`](bootstrap.md) step 5). Self-updates via Sparkle; a `1password` cask exists but brew adds nothing. The `1password-cli` package is separate and *is* in the Brewfile |
| Microsoft Teams | https://www.microsoft.com/microsoft-teams/download-app (work install; vendor pkg only) |
