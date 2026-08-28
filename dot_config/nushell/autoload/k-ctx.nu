# Switching is global (writes ~/.kube/config), so k9s and other shells follow
# along — starship's [kubernetes] module is what keeps that visible.

use ~/.config/nushell/autoload/k-cache.nu *

const KCTX_CACHE_PREFIX = "k-ctx"

def _kctx-cache-get [key: string] {
    k-cache-get $KCTX_CACHE_PREFIX $key
}

def _kctx-cache-set [key: string, values: list] {
    k-cache-set $KCTX_CACHE_PREFIX $key $values
}

def _kctx-contexts [] {
    let cached = (_kctx-cache-get "contexts")
    if $cached != null { return $cached }
    let result = (
        do { ^kubectl config get-contexts -o name }
        | complete | get stdout | lines | str trim
        | where { |l| $l != "" }
    )
    _kctx-cache-set "contexts" $result
    $result
}

def _kctx-current [] {
    do { ^kubectl config current-context } | complete | get stdout | str trim
}

# Takes the context explicitly — completion runs against one not yet current.
def _kctx-namespaces [context: string] {
    let key = $"ns-($context)"
    let cached = (_kctx-cache-get $key)
    if $cached != null { return $cached }
    let result = (
        do { ^kubectl --context $context get namespaces -o name }
        | complete | get stdout | lines | str trim
        | where { |l| $l != "" }
        | each { |l| $l | str replace "namespace/" "" }
    )
    _kctx-cache-set $key $result
    $result
}

def _kctx-complete-contexts [] {
    let current = (_kctx-current)
    _kctx-contexts | each { |c|
        { value: $c, description: (if $c == $current { "  current" } else { "" }) }
    }
}

# parts: ["k-ctx", "<ctx>", "<partial-ns>"]
def _kctx-complete-namespaces-ctx [context: string] {
    let parts = ($context | str trim | split row ' ' | where { |x| $x != "" })
    let ctx = ($parts | get 1? | default "")
    if ($ctx | is-empty) { return [] }
    _kctx-namespaces $ctx
}

def _kns-complete-namespaces [] {
    let current = (_kctx-current)
    if ($current | is-empty) { return [] }
    _kctx-namespaces $current
}

# Built by concatenation: `[?(…)]` inside an interpolated string parses as a
# list containing a command call.
def _kctx-namespace-of [context: string] {
    let expr = ('jsonpath={.contexts[?(@.name=="' + $context + '")].context.namespace}')
    do { ^kubectl config view -o $expr } | complete | get stdout | str trim
}

def _kctx-report [context: string] {
    let ns = (_kctx-namespace-of $context)
    print $"($context) — namespace: (if ($ns | is-empty) { 'default' } else { $ns })"
}

export def "k-ctx cache clean" [] {
    k-cache-clean $KCTX_CACHE_PREFIX
}

export def "k-ctx list" [] {
    let current = (_kctx-current)
    do { ^kubectl config get-contexts --no-headers }
    | complete | get stdout | lines
    | where { |l| $l != "" }
    | each { |l|
        # Columns: CURRENT NAME CLUSTER AUTHINFO NAMESPACE — the `*` marker is a
        # field of its own, so drop it instead of indexing past it.
        let fields = ($l | str trim | split row -r '\s+' | where { |x| $x != "*" })
        {
            current: (($fields | get 0? | default "") == $current)
            name: ($fields | get 0? | default "")
            cluster: ($fields | get 1? | default "")
            namespace: ($fields | get 3? | default "")
        }
    }
}

export def k-ns [namespace?: string@_kns-complete-namespaces] {
    if (which kubectl | is-empty) { error make { msg: "kubectl is required" } }

    let current = (_kctx-current)
    if ($current | is-empty) { error make { msg: "No current context set" } }

    if $namespace == null {
        _kctx-report $current
        return
    }

    let result = (do { ^kubectl config set-context --current --namespace $namespace } | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    print $"($current) → ($namespace)"
}

export def k-ctx [
    context?: string@_kctx-complete-contexts,
    namespace?: string@_kctx-complete-namespaces-ctx,
] {
    if (which kubectl | is-empty) { error make { msg: "kubectl is required" } }

    if $context == null {
        let current = (_kctx-current)
        if ($current | is-empty) {
            print "No current context set."
            return
        }
        _kctx-report $current
        return
    }

    let known = (_kctx-contexts)
    if not ($context in $known) {
        error make { msg: $"Unknown context '($context)'. Known: ($known | str join ', ')" }
    }

    let result = (do { ^kubectl config use-context $context } | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }

    if $namespace != null {
        let ns_result = (do { ^kubectl config set-context $context --namespace $namespace } | complete)
        if $ns_result.exit_code != 0 { error make { msg: ($ns_result.stderr | str trim) } }
        print $"($context) / ($namespace)"
        return
    }

    _kctx-report $context
}
