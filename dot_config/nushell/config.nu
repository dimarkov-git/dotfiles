# Nushell configuration. Loaded after env.nu.
# Docs: https://www.nushell.sh/book/configuration.html

$env.config.show_banner = false

$env.config.table.mode = "rounded"
$env.config.table.index_mode = "always"
$env.config.table.header_on_separator = true

# Fixed ISO-ish format; the locale default varies by machine and breaks grep/awk.
$env.config.datetime_format.normal = "%Y-%m-%d %H:%M:%S"

# `rm` routes deletes through the macOS Trash. Slower for very large deletes;
# override per-call with `rm --permanent`.
$env.config.rm.always_trash = true

# Kitty keyboard protocol (Ghostty supports it): distinct Ctrl+i vs Tab,
# Ctrl+m vs Enter, and unambiguous modifier+arrow keys in TUIs.
$env.config.use_kitty_protocol = true

$env.config.edit_mode = "emacs"

# `--wait` is mandatory: Zed's CLI returns immediately, which would race
# nushell into reading the buffer file before edits are saved.
$env.config.buffer_editor = ["zed", "--wait"]

# --- History ---
# sqlite stores cwd, exit status and duration per command; plaintext doesn't.
$env.config.history.max_size = 100_000
$env.config.history.file_format = "sqlite"
$env.config.history.sync_on_enter = true
# Up arrow sees only this session; all sessions still write one sqlite file.
$env.config.history.isolation = true

# --- Completions ---

$env.config.completions.algorithm = "fuzzy"
$env.config.completions.case_sensitive = false
$env.config.completions.quick = true
$env.config.completions.partial = true

# Set explicitly so the shell doesn't override the terminal's block cursor.
$env.config.cursor_shape.emacs = "block"

$env.config.error_style = "fancy"

# The `plugin use` lines are NOT here — they live in the generated
# vendor/autoload/plugins.nu (see run_onchange_after_02-…). `plugin use` is a
# parser keyword needing the registry at PARSE time, so a missing registry
# aborts this whole file and every new shell opens broken — including the one
# you'd fix it from. An `if` guard doesn't help; it evaluates after parsing.

# Ctrl+R is not bound here: atuin's vendor/autoload script installs its own
# keybinding and full-screen search UI.

# --- Keybindings ---
# Additions, not overrides. `keybindings list` shows current bindings.

# Ctrl+L — clear the screen (Nushell doesn't bind it by default).
$env.config.keybindings = ($env.config.keybindings | append {
    name: clear_screen
    modifier: control
    keycode: char_l
    mode: [emacs vi_normal vi_insert]
    event: { send: executehostcommand cmd: "clear" }
})

# --- Hooks ---
# Fires on every directory change, including transient cd's — keep it cheap.
# Named record, so re-sourcing replaces rather than stacks; append-only.
$env.config.hooks.env_change.PWD = (
    $env.config.hooks.env_change.PWD?
    | default []
    | where { |h| not (($h | describe | str starts-with "record") and ($h.name? == "project-banner")) }
    | append {
    name: "project-banner"
    code: {|before, after|
    if ($after | path join "package.json" | path exists) {
        let pkg = (open ($after | path join "package.json"))
        print $"📦 ($pkg.name? | default '?')@($pkg.version? | default '?')"
    }
    if ($after | path join "go.mod" | path exists) {
        let first_line = (open ($after | path join "go.mod") | lines | first)
        print $"🐹 ($first_line)"
    }
    # PEP 621 [project] block; poetry-only [tool.poetry] files are skipped.
    if ($after | path join "pyproject.toml" | path exists) {
        let py = (open ($after | path join "pyproject.toml"))
        let proj = ($py.project? | default {})
        let name = ($proj.name? | default '?')
        let version = ($proj.version? | default '?')
        print $"🐍 ($name)@($version)"
    }
    # Workspace roots have [workspace] and no [package] — silently skipped.
    if ($after | path join "Cargo.toml" | path exists) {
        let cargo = (open ($after | path join "Cargo.toml"))
        if ($cargo.package? | is-not-empty) {
            let name = ($cargo.package.name? | default '?')
            let version = ($cargo.package.version? | default '?')
            print $"🦀 ($name)@($version)"
        }
    }
    }
    }
)

# autoload/ needs explicit sourcing (XDG_CONFIG_HOME unset on macOS); vendor/
# autoload/ is auto-loaded — re-sourcing a hook-installing one registers it twice.

source ~/.config/nushell/autoload/aliases.nu
source ~/.config/nushell/autoload/yazi.nu
source ~/.config/nushell/autoload/docker-php.nu
source ~/.config/nushell/autoload/ghostty-title.nu
# Before slow-command and tabs: both read the GHOSTTY_TTY it publishes.
use ~/.config/nushell/autoload/tab-identity.nu *
source ~/.config/nushell/autoload/slow-command.nu
use ~/.config/nushell/autoload/tabs.nu *
source ~/.config/nushell/autoload/k-cache.nu
source ~/.config/nushell/autoload/k-ctx.nu
source ~/.config/nushell/autoload/k-pg.nu
source ~/.config/nushell/autoload/k-kind.nu
source ~/.config/nushell/autoload/direnv.nu
source ~/.config/nushell/autoload/dot-ask.nu
source ~/.config/nushell/autoload/dot-check.nu
source ~/.config/nushell/autoload/system-watch.nu
source ~/.config/nushell/autoload/projects.nu
use ~/.config/nushell/autoload/mac-finder-ds.nu *
source ~/.config/nushell/vendor/autoload/zoxide.nu
source ~/.config/nushell/vendor/autoload/starship.nu
source ~/.config/nushell/vendor/autoload/carapace.nu
