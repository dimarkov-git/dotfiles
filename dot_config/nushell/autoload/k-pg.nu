# kubectl port-forward helper for PostgreSQL workloads, with contextual
# tab-completion for context, namespace, kind and name.
#
# Usage: k-pg <context> <namespace> <pod|svc|deployment> <name> [port] [--detach]; subcommands: list, kill [ns/kind/name|port|all], cache clean
#
# - `pod` is for Patroni/Spilo clusters (shows spilo-role in the completion
#   description). Pod names carry replicaset/random suffixes that change on
#   recreation, so history entries go stale — prefer svc/deployment.
# - `svc`/`deployment` give stable, replayable history entries; selector-less
#   services carry no pod and are flagged in the completion.

use ~/.config/nushell/autoload/k-cache.nu *

const KPG_CACHE_PREFIX = "k-pg"
const KPG_KINDS = [pod svc deployment]

def _kpg-cache-get [key: string] {
    k-cache-get $KPG_CACHE_PREFIX $key
}

def _kpg-cache-set [key: string, values: list] {
    k-cache-set $KPG_CACHE_PREFIX $key $values
}

def _kpg-complete-contexts [] {
    let cached = (_kpg-cache-get "contexts")
    if $cached != null { return $cached }
    let result = (^kubectl config get-contexts -o name | lines | str trim | where { |l| $l != "" })
    _kpg-cache-set "contexts" $result
    $result
}

def _kpg-complete-namespaces [context: string] {
    let key = $"ns-($context)"
    let cached = (_kpg-cache-get $key)
    if $cached != null { return $cached }
    let result = (
        do { ^kubectl --context $context get namespaces --no-headers }
        | complete | get stdout | lines | str trim
        | where { |l| $l != "" }
        | each { |l| $l | split row ' ' | first }
    )
    _kpg-cache-set $key $result
    $result
}

def _kpg-complete-kinds [] {
    $KPG_KINDS
}

# Filtered to names containing "postgres" — this helper is Postgres-only by
# design. kind=pod entries are annotated with the spilo-role label when present.
def _kpg-complete-resources [context: string, namespace: string, kind: string] {
    let key = $"($kind)s-($context)-($namespace)"
    let cached = (_kpg-cache-get $key)
    if $cached != null { return $cached }

    let names = (
        do { ^kubectl --context $context -n $namespace get $kind --no-headers }
        | complete | get stdout | lines | str trim
        | where { |l| $l != "" }
        | each { |l| $l | split row ' ' | first }
        | where { |l| $l | str contains "postgres" }
    )

    let result = match $kind {
        "pod" => {
            let roles = (
                do { ^kubectl --context $context -n $namespace get pods -l spilo-role --no-headers -o "custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.spilo-role" }
                | complete | get stdout | lines | str trim
                | where { |l| $l != "" }
                | each { |l|
                    let parts = ($l | split row ' ' | where { |x| ($x | str trim) != "" })
                    { name: ($parts | get 0? | default ""), role: ($parts | get 1? | default "") }
                }
                | where { |r| $r.name != "" }
            )
            $names | each { |n|
                let role = ($roles | where name == $n | get role? | get 0? | default "")
                { value: $n, description: $role }
            }
        }
        # A selector-less Service (external DB behind hand-written Endpoints) has
        # no pod to attach to — port-forward fails. Flag it, don't hide it.
        "svc" => {
            let selectorless = (
                do { ^kubectl --context $context -n $namespace get svc --no-headers -o "custom-columns=NAME:.metadata.name,SEL:.spec.selector" }
                | complete | get stdout | lines | str trim
                | where { |l| $l != "" }
                # A multi-key selector prints as `map[a:1 b:2]`, so the column
                # itself contains spaces — rejoin the tail before comparing.
                | where { |l| ($l | split row -r '\s+' | skip 1 | str join ' ') == "<none>" }
                | each { |l| $l | split row -r '\s+' | first }
            )
            $names | each { |n|
                let desc = if ($n in $selectorless) { "⚠ no selector — use pod/deployment" } else { "" }
                { value: $n, description: $desc }
            }
        }
        _ => $names
    }

    _kpg-cache-set $key $result
    $result
}

def _kpg-complete-namespaces-ctx [context: string] {
    # `context` is the whole command line Nu's completer passes in:
    # ["k-pg", "<ctx>", "<partial-ns>"]
    let parts = ($context | str trim | split row ' ' | where { |x| $x != "" })
    let ctx = ($parts | get 1? | default "")
    if ($ctx | is-empty) { return [] }
    _kpg-complete-namespaces $ctx
}

def _kpg-complete-resources-ctx [context: string] {
    # parts: ["k-pg", "<ctx>", "<ns>", "<kind>", "<partial-name>"]
    let parts = ($context | str trim | split row ' ' | where { |x| $x != "" })
    let ctx  = ($parts | get 1? | default "")
    let ns   = ($parts | get 2? | default "")
    let kind = ($parts | get 3? | default "")
    if ($ctx | is-empty) or ($ns | is-empty) or ($kind | is-empty) { return [] }
    if not ($kind in $KPG_KINDS) { return [] }
    _kpg-complete-resources $ctx $ns $kind
}

export def "k-pg cache clean" [] {
    k-cache-clean $KPG_CACHE_PREFIX
}

# Detached forwards are invisible once the shell is gone — these make them
# findable. Parses the target back out of the recorded command line.
export def "k-pg list" [] {
    ^pgrep -fl "kubectl.*port-forward" | complete | get stdout | lines
    | where { |l| $l != "" }
    | each { |l|
        let fields = ($l | split row -r '\s+')
        let args = ($fields | skip 1)
        let fwd = ($args | where { |a| $a =~ '^\d+:\d+$' } | get 0? | default "")
        let pid = ($fields | first | into int)
        let ns = ($args | window 2 | where { |w| $w.0 == "-n" } | get 0?.1? | default "")
        let target = ($args | where { |a| $a =~ '^\w+/' } | get 0? | default "")
        {
            pid: $pid
            port: (if ($fwd | is-empty) { null } else { $fwd | split row ':' | first | into int })
            namespace: $ns
            target: $target
            ref: (if ($ns | is-empty) { $target } else { $"($ns)/($target)" })
            age: (^ps -o etime= -p ($pid | into string) | complete | get stdout | str trim)
        }
    }
}

def _kpg-complete-live [] {
    let live = (
        k-pg list
        | each { |f|
            let age = (if ($f.age | is-empty) { "" } else { $"  up ($f.age)" })
            { value: $f.ref, description: $"  :($f.port | default '?')($age)" }
        }
    )
    if ($live | length) > 1 {
        $live | append { value: "all", description: $"  kill all ($live | length)" }
    } else {
        $live
    }
}

# Targets are addressed by `namespace/kind/name`; a bare number still means a
# port, so older history entries keep working.
export def "k-pg kill" [target?: string@_kpg-complete-live] {
    let running = (k-pg list)
    if ($target == null) or ($target == "all") {
        if ($running | is-empty) {
            print "No port-forwards running."
            return
        }
        for f in $running { do { ^kill $f.pid } | complete | ignore }
        print $"Killed ($running | length) port-forward\(s\)."
        return
    }

    let hits = if ($target =~ '^\d+$') {
        $running | where port == ($target | into int)
    } else {
        $running | where ref == $target
    }

    if ($hits | is-empty) {
        print $"No port-forward matching '($target)'."
        if not ($running | is-empty) {
            print $"Running: ($running | get ref | str join ', ')"
        }
        return
    }

    for f in $hits {
        do { ^kill $f.pid } | complete | ignore
        print $"Killed ($f.target) \(:($f.port | default '?')\)."
    }
}

export def k-pg [
    context: string@_kpg-complete-contexts,
    namespace: string@_kpg-complete-namespaces-ctx,
    kind: string@_kpg-complete-kinds,
    name: string@_kpg-complete-resources-ctx,
    port: int = 5432,
    --detach (-d),  # survive the shell; for GUI clients (TablePlus)
] {
    if (which kubectl | is-empty) { error make { msg: "kubectl is required" } }
    if not ($kind in $KPG_KINDS) {
        error make { msg: $"kind must be one of (($KPG_KINDS | str join ' | ')), got: ($kind)" }
    }

    let in_use = (do { ^lsof -i $":($port)" -sTCP:LISTEN } | complete | get exit_code) == 0
    if $in_use {
        let pf_running = (do { ^pgrep -f $"port-forward.*($port):" } | complete | get exit_code) == 0
        if $pf_running {
            print $"Killing existing port-forward on :($port)"
            do { ^pkill -f $"port-forward.*($port):" } | complete | ignore
            ^sleep 0.3
        } else {
            error make { msg: $"Port ($port) is already in use \(not by port-forward\)" }
        }
    }

    let flag = (if $detach { " --detach" } else { "" })
    print $"Repeat: k-pg ($context) ($namespace) ($kind) ($name) ($port)($flag)"
    print $"kubectl -n ($namespace) port-forward ($kind)/($name) ($port):5432"
    print ""

    if not $detach {
        ^kubectl --context $context -n $namespace port-forward $"($kind)/($name)" $"($port):5432"
        return
    }

    let log = $"(k-cache-dir)/k-pg-($port).log"
    # Orphan via sh subshell — nu's own `&` still waits for the child.
    ^sh -c $"\(nohup kubectl --context ($context) -n ($namespace) port-forward ($kind)/($name) ($port):5432 > ($log) 2>&1 &\)"

    # kubectl exits non-zero on a bad target; poll until the port listens.
    mut ready = false
    for _ in 1..20 {
        ^sleep 0.25
        if (do { ^lsof -i $":($port)" -sTCP:LISTEN } | complete | get exit_code) == 0 {
            $ready = true
            break
        }
    }

    if not $ready {
        print $"Failed to establish forward on :($port) — see ($log)"
        do { ^pkill -f $"port-forward.*($port):5432" } | complete | ignore
        return
    }

    print $"Forwarding on 127.0.0.1:($port) in background — log: ($log)"
    print $"Stop with: k-pg kill ($namespace)/($kind)/($name)"
}
