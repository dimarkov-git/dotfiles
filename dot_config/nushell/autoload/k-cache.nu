# Shared completion cache for k-ctx and k-pg; sourced before both in config.nu.
# Per-boot by design — stale cluster listings beat a slow first completion.

const KCACHE_TTL = 300  # seconds

export def k-cache-dir [] {
    $env.TMPDIR? | default "/tmp" | str trim --right --char '/'
}

export def k-cache-path [prefix: string, key: string] {
    $"(k-cache-dir)/($prefix)-($key).nuon"
}

export def k-cache-get [prefix: string, key: string] {
    let path = (k-cache-path $prefix $key)
    if not ($path | path exists) { return null }
    let age = (((date now) - (ls $path | get modified | first)) | into int) / 1_000_000_000
    if $age > $KCACHE_TTL { return null }
    open $path
}

export def k-cache-set [prefix: string, key: string, values: list] {
    $values | save --force (k-cache-path $prefix $key)
}

export def k-cache-clean [prefix: string] {
    let files = (try { ls $"(k-cache-dir)/($prefix)-*.nuon" | get name } catch { [] })
    if ($files | is-empty) {
        print "No cache files found."
        return
    }
    $files | each { |f| rm --force --permanent $f }
    print $"Removed ($files | length) cache file\(s)."
}
