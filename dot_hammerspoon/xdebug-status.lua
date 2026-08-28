-- Menubar indicator for the Xdebug listener. Shown only while something holds
-- the port; flags orphaned adapters that keep it and swallow every session.

local M = {}

local ZED_BUNDLE = "dev.zed.Zed"
local PORT = 9003

M.bar = nil
M.state = nil

local GREEN = { hex = "#a6e3a1" }  -- Catppuccin Green
local RED = { hex = "#f38ba8" }    -- Red

-- `[[dd-]hh:]mm:ss` from ps(1).
local function parseElapsed(s)
    local days, rest = s:match("^(%d+)%-(.+)$")
    local secs = 0
    for part in (rest or s):gmatch("[^:]+") do
        secs = secs * 60 + (tonumber(part) or 0)
    end
    return secs + (tonumber(days) or 0) * 86400
end

-- Zed itself is reparented to launchd, so PPID says nothing; an adapter older
-- than the running Zed is the orphan that outlived its parent.
local function classify(procs, zedAge)
    for _, p in ipairs(procs) do
        p.stale = zedAge ~= nil and p.age > zedAge + 5
    end
    return procs
end

local function ageLabel(secs)
    if secs < 60 then return string.format("%ds", secs) end
    if secs < 3600 then return string.format("%dm", secs // 60) end
    return string.format("%dh%dm", secs // 3600, (secs % 3600) // 60)
end

function M.buildMenu()
    local st = M.state
    local menu = {}
    local function item(t, extra)
        local e = extra or {}
        e.title = t
        table.insert(menu, e)
    end

    if not st or #st.procs == 0 then
        item("nothing listening on " .. PORT, { disabled = true })
    else
        for _, p in ipairs(st.procs) do
            local tag = p.stale and "  ⚠ stale" or ""
            item(string.format("%s  pid %d  up %s%s", p.name, p.pid, ageLabel(p.age), tag),
                { disabled = true })
        end
        if st.stale > 0 then
            item("-")
            -- The whole point of the indicator: a dead adapter holding the port
            -- makes every session fail with no visible error.
            item("Kill stale adapter(s)", { fn = function()
                for _, p in ipairs(st.procs) do
                    if p.stale then hs.execute("/bin/kill " .. p.pid) end
                end
                hs.timer.doAfter(0.5, M.refresh)
            end })
        end
    end

    item("-")
    item("Refresh now", { fn = function() M.refresh() end })
    return menu
end

local function render(procs, zedAge)
    if not M.bar then
        M.bar = hs.menubar.new(false)
        if not M.bar then return end
    end

    -- No Zed means no debugging; the indicator would be noise.
    if zedAge == nil then
        M.state = nil
        M.bar:removeFromMenuBar()
        return
    end

    classify(procs, zedAge)
    local stale = 0
    for _, p in ipairs(procs) do
        if p.stale then stale = stale + 1 end
    end
    M.state = { procs = procs, stale = stale }

    -- Zed runs all day with an idle port: no listener is the resting state.
    if #procs == 0 then
        M.bar:removeFromMenuBar()
        return
    end

    M.bar:returnToMenuBar()

    local glyph, tint
    if stale > 0 then
        glyph, tint = "⚠", RED
    else
        glyph, tint = "●", GREEN
    end

    M.bar:setTitle(hs.styledtext.new("🐛" .. glyph, { font = { name = "Menlo", size = 13 }, color = tint }))
    M.bar:setTooltip(string.format("Xdebug :%d — %d listener(s), %d stale", PORT, #procs, stale))
    M.bar:setMenu(function() return M.buildMenu() end)
end

-- Two spawns rather than one shell pipeline: hs.task takes no shell, and the
-- pid list must exist before ps can be asked about it.
local function probe(done)
    local zed = hs.application.get(ZED_BUNDLE)
    if not zed then return done({}, nil) end

    local lsof = hs.task.new("/usr/sbin/lsof", function(_, out)
        local pids = {}
        for pid in (out or ""):gmatch("(%d+)") do pids[pid] = true end

        local args = { "-o", "pid=,etime=,comm=" }
        local any = false
        for pid in pairs(pids) do
            table.insert(args, "-p")
            table.insert(args, pid)
            any = true
        end
        -- Zed's own age is the yardstick, so it joins the same ps call.
        table.insert(args, "-p")
        table.insert(args, tostring(zed:pid()))

        local ps = hs.task.new("/bin/ps", function(_, psOut)
            local procs, zedAge = {}, nil
            for line in (psOut or ""):gmatch("[^\n]+") do
                local pid, elapsed, comm = line:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
                if pid then
                    local age = parseElapsed(elapsed)
                    if tonumber(pid) == zed:pid() then
                        zedAge = age
                    elseif any then
                        table.insert(procs, {
                            pid = tonumber(pid),
                            age = age,
                            name = comm:match("([^/]+)$") or comm,
                        })
                    end
                end
            end
            done(procs, zedAge)
        end, args)
        if ps then ps:start() else done({}, nil) end
    end, { "-nP", "-iTCP:" .. PORT, "-sTCP:LISTEN", "-t" })

    if lsof then lsof:start() else done({}, nil) end
end

function M.refresh()
    probe(render)
end

return M
