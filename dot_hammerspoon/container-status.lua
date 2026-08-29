-- Menubar indicator for the container stack: OrbStack engine, docker containers,
-- and the active kube context's reachability.

local M = {}

local ORB_BIN = os.getenv("HOME") .. "/.orbstack/bin"
local ORB = ORB_BIN .. "/orb"
local DOCKER = ORB_BIN .. "/docker"
local KUBECTL = ORB_BIN .. "/kubectl"

local ORB_INTERVAL = 60
-- Engine stopped: containers can't change, so only the cheap `orb status` runs.
local ORB_IDLE_INTERVAL = 120
local K8S_INTERVAL = 300
-- An unreachable cluster costs a full 2s timeout per tick; back off further.
local K8S_UNREACHABLE_INTERVAL = 600
-- `docker stats` needs two samples to compute CPU and blocks ~2s; its own clock.
local STATS_INTERVAL = 300
-- GB of reclaimable docker data worth flagging.
local RECLAIM_WARN = 5
local K8S_TIMEOUT = "2s"

-- Created by every kind cluster; only project namespaces are worth a row.
local SYSTEM_NS = {
    ["default"] = true, ["kube-node-lease"] = true, ["kube-public"] = true,
    ["kube-system"] = true, ["local-path-storage"] = true,
}

-- Discovered, never named: the cluster name is work-internal and this repo is public.
local LOCAL_CTX_INTERVAL = 900
local BAR_RETRY_DELAY = 5

M.bar = nil
M.barRetry = nil
M.orbTimer = nil
M.k8sTimer = nil
M.statsTimer = nil
M.localCtxTimer = nil
M.power = nil

-- Long-lived: the probes run on independent clocks and each owns its fields.
M.state = { orb = "unknown", running = 0, stopped = 0, total = 0,
            context = nil, cluster = "unknown", localContext = nil,
            localUp = false, kindRunning = false, namespaces = {},
            cpu = nil, mem = nil }

local GREEN = "#a6e3a1"  -- Catppuccin Green
local RED = "#f38ba8"    -- Red
local YELLOW = "#f9e2af" -- Peach
local SUBTLE = "#9399b2" -- Overlay2
local TEXT = "#cdd6f4"   -- Text

-- Nerd Font glyphs, not emoji: Apple Color Emoji bakes its own colours and
-- ignores styledtext's, so an emoji whale could never show engine state.
local DOCKER_GLYPH = "\u{e7b0}"
local K8S_GLYPH = "\u{f10fe}"
local GLYPH_FONT = "JetBrainsMono NF"


-- JS reaches Lua through this handler name; it must match on both sides.

local function exists(path)
    return hs.fs.attributes(path) ~= nil
end

-- Fixed for the machine; read once so the stats row can express CPU both ways.
local CORES = tonumber(hs.execute("/usr/sbin/sysctl -n hw.ncpu"):match("%d+")) or 1

-- Docker is chained behind `orb status`, not run alongside it: it can only
-- answer once the engine is up.
local function probeOrb(done)
    local st = M.state

    local function probeDocker()
        if st.orb ~= "running" or not exists(DOCKER) then
            st.running, st.stopped, st.total, st.kindRunning = 0, 0, 0, false
            return done()
        end

        -- `.State` is machine-readable; the image identifies kind nodes without kubeconfig.
        local task = hs.task.new(DOCKER, function(_, out)
            local running, stopped, total, kind = 0, 0, 0, false
            for line in (out or ""):gmatch("[^\n]+") do
                local state, image = line:match("^(%S+)\t(%S+)")
                if state then
                    total = total + 1
                    if state == "running" then
                        running = running + 1
                        if image and image:find("kindest/node", 1, true) then kind = true end
                    else
                        stopped = stopped + 1
                    end
                end
            end
            st.running, st.stopped, st.total, st.kindRunning = running, stopped, total, kind
            done()
        end, { "ps", "-a", "--format", "{{.State}}\t{{.Image}}" })

        if task then task:start() else done() end
    end

    if not exists(ORB) then return done() end

    local task = hs.task.new(ORB, function(_, out)
        local word = (out or ""):match("^%s*(%S+)")
        st.orb = word and word:lower() or "unknown"
        probeDocker()
    end, { "status" })

    if task then task:start() else done() end
end

-- kind names its contexts `kind-*` and its API server listens on loopback;
-- both must hold, so a remote cluster merely named `kind-…` is never listed.
local function probeLocalContext(done)
    local task = hs.task.new(KUBECTL, function(code, out)
        if code ~= 0 then return done(nil, {}) end

        local ok, cfg = pcall(hs.json.decode, out or "")
        if not ok or type(cfg) ~= "table" then return done(nil, {}) end

        local loopback = {}
        for _, c in ipairs(cfg.clusters or {}) do
            local server = c.cluster and c.cluster.server or ""
            if server:find("127.0.0.1", 1, true) or server:find("//localhost", 1, true) then
                loopback[c.name] = true
            end
        end

        -- An exec credential plugin (oidc-login) opens a browser and blocks;
        -- probing such a context in the background nags or lies about liveness.
        local interactive = {}
        for _, u in ipairs(cfg.users or {}) do
            if u.user and u.user.exec then interactive[u.name] = true end
        end

        local localName, needsAuth = nil, {}
        for _, c in ipairs(cfg.contexts or {}) do
            local cluster = c.context and c.context.cluster
            if interactive[c.context and c.context.user] then
                needsAuth[c.name] = true
            end
            if not localName and c.name:sub(1, 5) == "kind-"
                and cluster and loopback[cluster] then
                localName = c.name
            end
        end
        done(localName, needsAuth)
    end, { "config", "view", "-o", "json" })

    if task then task:start() else done(nil, {}) end
end

-- The local cluster is listed in full; the active context — which may be a
-- shared stage or prod — is only asked whether it answers.
local function probeK8s(done)
    local st = M.state
    if not exists(KUBECTL) then return done() end

    local function probeLocal(after)
        if not st.localContext then
            st.localUp, st.namespaces = false, {}
            return after()
        end

        local pods = hs.task.new(KUBECTL, function(code, pout)
            if code ~= 0 then
                st.localUp, st.namespaces = false, {}
                return after()
            end
            st.localUp = true

            local counts, order = {}, {}
            for line in (pout or ""):gmatch("[^\n]+") do
                local ns, phase = line:match("^(%S+)%s+(%S+)")
                -- Succeeded is a finished job, not a running workload.
                if ns and not SYSTEM_NS[ns] and phase ~= "Succeeded" then
                    if not counts[ns] then
                        counts[ns] = { name = ns, pods = 0, notReady = 0 }
                        table.insert(order, counts[ns])
                    end
                    counts[ns].pods = counts[ns].pods + 1
                    if phase ~= "Running" then
                        counts[ns].notReady = counts[ns].notReady + 1
                    end
                end
            end
            table.sort(order, function(a, b) return a.name < b.name end)
            st.namespaces = order
            after()
        end, { "--context=" .. st.localContext, "get", "pods", "-A", "--no-headers",
               "-o", "custom-columns=NS:.metadata.namespace,PHASE:.status.phase",
               "--request-timeout=" .. K8S_TIMEOUT })

        if pods then pods:start() else after() end
    end

    local function probeContext()
        local ctx = hs.task.new(KUBECTL, function(_, out)
            st.context = (out or ""):match("^%s*(.-)%s*$")
            if st.context == "" then st.context = nil end
            if not st.context then
                st.cluster = "unknown"
                return done()
            end

            -- Local context: probeLocal already answered, so ask nothing twice.
            if st.context == st.localContext then
                st.cluster = st.localUp and "reachable" or "unreachable"
                return done()
            end

            -- Never probed: doing so would pop a browser for a token.
            if (st.needsAuth or {})[st.context] then
                st.cluster = "auth"
                return done()
            end

            -- `version` touches no workloads, so it stays cheap on a shared cluster.
            local ver = hs.task.new(KUBECTL, function(code, vout)
                local ok, decoded = pcall(hs.json.decode, vout or "")
                local live = ok and decoded and decoded.serverVersion ~= nil
                st.cluster = live and "reachable"
                    or (code == 0 and "unknown" or "unreachable")
                done()
            end, { "version", "-o", "json", "--request-timeout=" .. K8S_TIMEOUT })

            if ver then ver:start() else done() end
        end, { "config", "current-context" })

        if ctx then ctx:start() else done() end
    end

    probeLocal(probeContext)
end

-- kind runs each node as a container named <cluster>-control-plane/-worker;
-- summing them is the cluster's real cost to the mac.
local function probeStats(done)
    local st = M.state
    if st.orb ~= "running" or not exists(DOCKER) then
        st.cpu, st.mem, st.allCpu, st.allMem, st.kindNodes = nil, nil, nil, nil, 0
        return done()
    end

    -- Empty until discovery lands; the kind sums simply stay nil until then.
    local node = st.localContext and st.localContext:gsub("^kind%-", "") or nil

    local task = hs.task.new(DOCKER, function(code, out)
        if code ~= 0 then
            st.cpu, st.mem, st.allCpu, st.allMem, st.kindNodes = nil, nil, nil, nil, 0
            return done()
        end

        local cpu, mem, kindNodes = 0, 0, 0
        local allCpu, allMem, any = 0, 0, false
        for line in (out or ""):gmatch("[^\n]+") do
            local name, pct, used, unit = line:match("^(%S+)\t([%d%.]+)%%\t([%d%.]+)(%a+)")
            if name then
                local n = tonumber(used)
                -- docker prints whichever unit fits; normalise to GiB.
                if unit == "MiB" then n = n / 1024 elseif unit == "KiB" then n = n / 1048576 end

                any = true
                allCpu = allCpu + tonumber(pct)
                allMem = allMem + n

                if node and name:find(node, 1, true) then
                    kindNodes = kindNodes + 1
                    cpu = cpu + tonumber(pct)
                    mem = mem + n
                end
            end
        end
        st.kindNodes = kindNodes
        st.cpu = kindNodes > 0 and cpu or nil
        st.mem = kindNodes > 0 and mem or nil
        st.allCpu = any and allCpu or nil
        st.allMem = any and allMem or nil
        done()
    end, { "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" })

    if task then task:start() else done() end
end

-- docker prints sizes for humans ("3.186GB", "998.6MB"); normalise to GB.
local function parseSize(s)
    local n, unit = (s or ""):match("^([%d%.]+)%s*(%a+)")
    n = tonumber(n)
    if not n then return 0 end
    if unit == "TB" then return n * 1000 end
    if unit == "GB" then return n end
    if unit == "MB" then return n / 1000 end
    if unit == "kB" or unit == "KB" then return n / 1e6 end
    return n / 1e9
end

-- Disk is the one resource with no feedback: it grows silently until something
-- fails. `docker system df` costs ~0.4s, so it rides the slow stats clock.
local function probeDisk(done)
    local st = M.state
    if st.orb ~= "running" or not exists(DOCKER) then
        st.disk, st.reclaim = nil, nil
        return done()
    end

    local task = hs.task.new(DOCKER, function(code, out)
        if code ~= 0 then
            st.disk, st.reclaim = nil, nil
            return done()
        end

        local total, reclaim = 0, 0
        for line in (out or ""):gmatch("[^\n]+") do
            local ok, e = pcall(hs.json.decode, line)
            if ok and type(e) == "table" then
                total = total + parseSize(e.Size)
                reclaim = reclaim + parseSize(e.Reclaimable)
            end
        end
        st.disk, st.reclaim = total, reclaim
        done()
    end, { "system", "df", "--format", "{{json .}}" })

    if task then task:start() else done() end
end

-- Menu rows are single strings, so label and value are padded apart to a fixed
-- column. Menlo keeps the value column aligned; the label font is the default.
local ROW_W = 34

local function row(label, value, tint)
    local pad = ROW_W - utf8.len(label) - utf8.len(value)
    local text = label .. string.rep(" ", math.max(pad, 2)) .. value
    return { title = hs.styledtext.new(text, {
        font = { name = "Menlo", size = 12 },
        color = { hex = tint or TEXT },
    }), disabled = true }
end

function M.buildMenu()
    local st = M.state
    local menu = {}

    local function add(...)
        table.insert(menu, row(...))
    end

    local function sep()
        table.insert(menu, { title = "-" })
    end

    local orbTint = st.orb == "running" and GREEN or SUBTLE
    add("OrbStack", st.orb, orbTint)

    if st.orb == "running" then
        local dockerTint = st.stopped > 0 and YELLOW or GREEN
        local text = st.total == 0 and "no containers"
            or string.format("%d up / %d down", st.running, st.stopped)
        add("containers", text, st.total == 0 and SUBTLE or dockerTint)

        if st.allCpu then
            local share = st.allCpu / CORES
            add("resources", string.format("%.0f%% (%.0f%%) · %.1f GB",
                st.allCpu, share, st.allMem), share >= 25 and YELLOW or TEXT)
        end

        if st.disk then
            local text = string.format("%.1f GB", st.disk)
            if st.reclaim and st.reclaim >= 0.1 then
                text = text .. string.format(" · %.1f junk", st.reclaim)
            end
            add("disk", text, (st.reclaim or 0) >= RECLAIM_WARN and YELLOW or TEXT)
        end
    end

    sep()

    -- The dev cluster, reported whether or not kubectl currently points at it.
    if st.localContext then
        add(st.localContext, st.localUp and "up" or "down", st.localUp and GREEN or SUBTLE)
    end

    if st.localUp then
        -- Skipped when the cluster IS all of docker: the row above already said it.
        if st.cpu and st.total > (st.kindNodes or 0) then
            local share = st.cpu / CORES
            add("resources", string.format("%.0f%% (%.0f%%) · %.1f GB", st.cpu, share, st.mem),
                share >= 25 and YELLOW or TEXT)
        end

        if #st.namespaces == 0 then
            add("namespaces", "none", SUBTLE)
        else
            for _, ns in ipairs(st.namespaces) do
                local text = string.format("%d pods", ns.pods)
                if ns.notReady > 0 then
                    text = string.format("%d pods, %d down", ns.pods, ns.notReady)
                end
                add(ns.name, text, ns.notReady > 0 and YELLOW or TEXT)
            end
        end
    end

    -- Active context, only when it isn't the local one already listed above.
    if st.context and st.context ~= st.localContext then
        sep()
        local tint = st.cluster == "reachable" and GREEN
            or (st.cluster == "unreachable" and RED or SUBTLE)
        local label = st.cluster == "reachable" and "up"
            or (st.cluster == "auth" and "not checked (sso)" or "down")
        add(st.context, label, tint)
    elseif not st.context then
        sep()
        add("context", "none", SUBTLE)
    end

    table.insert(menu, { title = "-" })
    table.insert(menu, { title = "Refresh now", fn = function() M.refresh() end })
    return menu
end

local render
render = function()
    local st = M.state

    -- Fails while the menu bar settles after a reload. Retried on a timer: the
    -- poll clocks are re-paced at the end of render, so returning here strands it.
    if not M.bar then
        M.bar = hs.menubar.new(false)
        if not M.bar then
            if not M.barRetry then
                M.barRetry = hs.timer.doAfter(BAR_RETRY_DELAY, function()
                    M.barRetry = nil
                    render()
                end)
            end
            return
        end
    end

    -- Engine down: kind nodes are containers too, so every segment would be grey.
    if st.orb ~= "running" then
        M.bar:removeFromMenuBar()
        return
    end
    M.bar:returnToMenuBar()

    -- Rebuilt per open, so a menu held open shows the state it was opened with.
    M.bar:setMenu(function() return M.buildMenu() end)

    -- Coloured per segment, not as a whole: one tint would paint a healthy
    -- docker red just because the kind cluster stopped answering.
    local function segment(text, hex, font)
        return hs.styledtext.new(text, {
            font = { name = font or "Menlo", size = 13 },
            color = { hex = hex },
        })
    end

    local dockerTint = st.stopped > 0 and YELLOW or GREEN
    local title = segment(DOCKER_GLYPH, dockerTint, GLYPH_FONT)
        .. segment(string.format(" %d", st.running), dockerTint)

    -- Only the dev cluster gets a glyph — the active context is menu-only. Nodes
    -- up with no context is a kubeconfig gap, not a broken cluster: stay neutral.
    if st.kindRunning then
        local tint = not st.localContext and SUBTLE or (st.localUp and GREEN or RED)
        title = title .. segment(" " .. K8S_GLYPH, tint, GLYPH_FONT)
    end

    M.bar:setTitle(title)

    -- Re-pace each clock to what it's watching, mirroring pollXdebugPort in init.lua.
    if M.orbTimer then
        M.orbTimer:setNextTrigger(st.orb == "running" and ORB_INTERVAL or ORB_IDLE_INTERVAL)
    end
    if M.k8sTimer then
        M.k8sTimer:setNextTrigger(
            st.cluster == "unreachable" and K8S_UNREACHABLE_INTERVAL or K8S_INTERVAL)
    end
end

-- A kind node appearing or vanishing dates the k8s state instantly; without this
-- the glyph shows the previous cluster for up to K8S_INTERVAL.
function M.refreshOrb()
    local was = M.state.kindRunning
    probeOrb(function()
        render()
        if M.state.kindRunning ~= was then M.refreshLocalContext() end
    end)
end

function M.refreshK8s()
    probeK8s(render)
end

function M.refreshStats()
    probeStats(function()
        render()
        probeDisk(render)
    end)
end

-- Chained ahead of the k8s probe, which needs the discovered name to query it.
function M.refreshLocalContext()
    probeLocalContext(function(name, needsAuth)
        M.state.localContext = name
        M.state.needsAuth = needsAuth
        M.refreshK8s()
    end)
end

-- Discovery leads: stats needs the node name, k8s needs the context.
function M.refresh()
    probeLocalContext(function(name, needsAuth)
        M.state.localContext = name
        M.state.needsAuth = needsAuth
        probeOrb(function()
            render()
            M.refreshStats()
        end)
        M.refreshK8s()
    end)
end

function M.start()
    M.refresh()

    M.orbTimer = hs.timer.new(ORB_INTERVAL, M.refreshOrb):start()
    M.k8sTimer = hs.timer.new(K8S_INTERVAL, M.refreshK8s):start()
    M.statsTimer = hs.timer.new(STATS_INTERVAL, M.refreshStats):start()
    M.localCtxTimer = hs.timer.new(LOCAL_CTX_INTERVAL, M.refreshLocalContext):start()

    M.power = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake
            or event == hs.caffeinate.watcher.screensDidUnlock then
            M.refresh()
        end
    end):start()

    return M
end

return M
