# Park kind clusters instead of deleting them — the cluster CLI's `down` destroys
# the containers; `k-kind stop|start|list [cluster]` only stops the battery drain.

const KKIND_CLUSTER_LABEL = "io.x-k8s.kind.cluster"
const KKIND_ROLE_LABEL = "io.x-k8s.kind.role"
const KKIND_READY_TIMEOUT = 90  # seconds

def _kkind-require-docker [] {
    if (which docker | is-empty) { error make { msg: "docker is required" } }
}

def _kkind-nodes [] {
    let out = (
        do { ^docker ps -a --filter $"label=($KKIND_CLUSTER_LABEL)" --format $"{{.Names}}\t{{.State}}\t{{.Label \"($KKIND_CLUSTER_LABEL)\"}}\t{{.Label \"($KKIND_ROLE_LABEL)\"}}" }
        | complete
    )
    if $out.exit_code != 0 { error make { msg: ($out.stderr | str trim) } }

    $out.stdout | lines | where { |l| ($l | str trim) != "" }
    | each { |l|
        let f = ($l | split row "\t")
        {
            cluster: ($f | get 2? | default "")
            node: ($f | get 0? | default "")
            role: ($f | get 3? | default "")
            state: ($f | get 1? | default "")
        }
    }
    | sort-by cluster role node
}

def _kkind-complete-clusters [] {
    _kkind-nodes | group-by cluster | items { |name, nodes|
        let running = ($nodes | where state == "running" | length)
        { value: $name, description: $"  ($running)/($nodes | length) running" }
    }
}

# A bare `k-kind stop` is only unambiguous with one cluster around.
def _kkind-resolve [cluster?: string] {
    let nodes = (_kkind-nodes)
    if ($nodes | is-empty) { error make { msg: "No kind containers found" } }

    if $cluster != null {
        let hits = ($nodes | where cluster == $cluster)
        if ($hits | is-empty) {
            let known = ($nodes | get cluster | uniq | str join ', ')
            error make { msg: $"Unknown cluster '($cluster)'. Known: ($known)" }
        }
        return $hits
    }

    let names = ($nodes | get cluster | uniq)
    if ($names | length) > 1 {
        error make { msg: $"Several clusters exist — name one: ($names | str join ', ')" }
    }
    $nodes
}

def _kkind-ordered [nodes: list, control_first: bool] {
    let control = ($nodes | where role == "control-plane")
    let rest = ($nodes | where role != "control-plane")
    if $control_first { $control | append $rest } else { $rest | append $control }
}

# Kubelet needs a moment after the container returns; until then kubectl says
# connection refused, which reads as a broken cluster.
def _kkind-wait-ready [cluster: string] {
    if (which kubectl | is-empty) {
        print "kubectl not found — skipping readiness check."
        return
    }

    let context = $"kind-($cluster)"
    let deadline = ((date now) + ($KKIND_READY_TIMEOUT * 1sec))

    print -n $"Waiting for ($context) to be ready"
    mut ready = false
    while (date now) < $deadline {
        let out = (do { ^kubectl --context $context get nodes --no-headers } | complete)
        if $out.exit_code == 0 {
            let states = (
                $out.stdout | lines | where { |l| ($l | str trim) != "" }
                | each { |l| $l | split row -r '\s+' | get 1? | default "" }
            )
            if (not ($states | is-empty)) and ($states | all { |s| $s == "Ready" }) {
                $ready = true
                break
            }
        }
        print -n "."
        ^sleep 2
    }
    print ""

    if $ready {
        print $"($context) ready."
    } else {
        print $"($context) not ready after ($KKIND_READY_TIMEOUT)s — check: kubectl --context ($context) get nodes"
    }
}

export def "k-kind list" [] {
    _kkind-require-docker
    _kkind-nodes
}

export def "k-kind stop" [cluster?: string@_kkind-complete-clusters] {
    _kkind-require-docker
    let nodes = (_kkind-resolve $cluster)
    # Workers first, so the control-plane isn't the one logging the outage.
    let targets = (_kkind-ordered ($nodes | where state == "running") false)

    if ($targets | is-empty) {
        print $"($nodes | get cluster | first) is already stopped."
        return
    }

    for n in $targets {
        let out = (do { ^docker stop $n.node } | complete)
        if $out.exit_code != 0 {
            print $"($n.node): ($out.stderr | str trim)"
        } else {
            print $"stopped ($n.node)"
        }
    }
}

export def "k-kind start" [cluster?: string@_kkind-complete-clusters] {
    _kkind-require-docker
    let nodes = (_kkind-resolve $cluster)
    let name = ($nodes | get cluster | first)
    let targets = (_kkind-ordered ($nodes | where state != "running") true)

    if ($targets | is-empty) {
        print $"($name) is already running."
        return
    }

    for n in $targets {
        let out = (do { ^docker start $n.node } | complete)
        if $out.exit_code != 0 {
            error make { msg: $"($n.node): ($out.stderr | str trim)" }
        }
        print $"started ($n.node)"
    }

    _kkind-wait-ready $name
}

export def k-kind [cluster?: string@_kkind-complete-clusters] {
    _kkind-require-docker
    let nodes = (_kkind-nodes)

    if ($nodes | is-empty) {
        print "No kind containers found."
        return
    }

    let scoped = if $cluster == null { $nodes } else { _kkind-resolve $cluster }

    $scoped | group-by cluster | items { |name, ns|
        let running = ($ns | where state == "running" | length)
        let total = ($ns | length)
        let state = match $running {
            0 => "stopped"
            $total => "running"
            _ => $"partial \(($running)/($total)\)"
        }
        print $"($name) — ($state)"
    } | ignore

    $scoped
}
