-- Menubar indicator for dotfiles health. Renders scripts/dotfiles-status-json.nu;
-- hidden entirely while everything is clean.

local M = {}

local REPO = os.getenv("HOME") .. "/dev-zone/dotfiles"
local STATUS_SCRIPT = REPO .. "/scripts/dotfiles-status-json.nu"
local NU = "/opt/homebrew/bin/nu"
local INTERVAL = 600

-- Module state, not locals: userdata would be GC'd out of the menu bar.
M.bar = nil
M.timer = nil
M.watcher = nil
M.power = nil

local function color(hex)
    return { hex = hex }
end

local RED = color("#f38ba8")    -- Catppuccin Maroon/Red, matches the Ghostty theme
local YELLOW = color("#f9e2af") -- Peach
local SUBTLE = color("#9399b2") -- Overlay2

-- Absolute path, no shell: Hammerspoon inherits launchd's bare PATH, where
-- `nu` is not found.
local function probe(done)
    local task = hs.task.new(NU, function(_, stdout)
        local ok, decoded = pcall(hs.json.decode, stdout)
        done(ok and decoded or nil)
    end, { STATUS_SCRIPT })
    if task then task:start() end
end

-- Keystrokes, not the cmux CLI: its socket refuses processes started outside cmux.
local function openInTerminal(command)
    local term = hs.application.get("cmux")
    if not term then
        hs.application.launchOrFocus("cmux")
        hs.timer.usleep(800000)
        term = hs.application.get("cmux")
        if not term then return end
    end
    term:activate()
    hs.timer.usleep(150000)

    -- cmd+n (new workspace) needs a window; with none, cmd+shift+n opens one.
    local mods = term:focusedWindow() and { "cmd" } or { "cmd", "shift" }
    hs.eventtap.keyStroke(mods, "n", 0)
    hs.timer.usleep(400000)

    -- `;`, not `&&`: the shell is Nushell, which rejects `&&`.
    hs.eventtap.keyStrokes(string.format("cd %s; %s", REPO, command))
    hs.eventtap.keyStroke({}, "return", 0)
end

-- Truncate long paths from the left; the tail identifies the file.
local function short(path, max)
    max = max or 44
    if #path <= max then return path end
    return "…" .. path:sub(#path - max + 1)
end

-- Exported so the menu can be inspected without clicking:
--   hs -c 'hs.inspect(require("dotfiles-status").buildMenu(...))'
function M.buildMenu(st)
    local menu = {}
    local function item(t, extra)
        -- Collapse consecutive separators: which sections are present varies,
        -- and each appends its own trailing rule.
        if t == "-" and (#menu == 0 or menu[#menu].title == "-") then return end
        local e = extra or {}
        e.title = t
        table.insert(menu, e)
    end

    if not st then
        item("status unavailable", { disabled = true })
    else
        if not st.probes_ok then
            item("⚠ some checks failed to run", { disabled = true })
            for _, probe in ipairs({ st.drift, st.pending, st.git, st.root_files }) do
                if probe and probe.ok == false and probe.error and probe.error ~= "" then
                    item("   " .. short(probe.error, 60), { disabled = true })
                end
            end
            item("-")
        end

        local drift = st.drift and st.drift.files or {}
        local pending = st.pending and st.pending.entries or {}

        if #drift > 0 then
            item(string.format("drift: %d file(s) edited in $HOME", #drift), { disabled = true })
            for _, f in ipairs(drift) do
                local label = "   " .. short(f.path)
                if f.note then label = label .. "  (" .. f.note .. ")" end
                -- Reveal in Finder: the path is the useful payload here.
                item(label, { fn = function() hs.execute("open -R " .. ("%q"):format(f.path:gsub("^~", os.getenv("HOME")))) end })
            end
            item("-")
        end

        if #pending > 0 then
            item(string.format("pending: %d source change(s) not applied", #pending), { disabled = true })
            for _, e in ipairs(pending) do
                item("   " .. short(e, 56), { disabled = true })
            end
            item("-")
        end

        local rootFiles = (st.root_files and st.root_files.differing) or {}
        if #rootFiles > 0 then
            item("root-owned files differ from repo", { disabled = true })
            for _, f in ipairs(rootFiles) do
                item("   " .. f.target, { fn = function() openInTerminal("dot-diff root") end })
            end
            -- `make apply` only rewrites these when the repo copy itself changed.
            item("Overwrite with sudo (make restore)", { fn = function() openInTerminal("make restore") end })
            item("-")
        end

        if st.git and st.git.ok then
            local bits = {}
            if st.git.dirty > 0 then table.insert(bits, st.git.dirty .. " uncommitted") end
            if st.git.ahead > 0 then table.insert(bits, st.git.ahead .. " unpushed") end
            if #bits > 0 then
                item("git: " .. table.concat(bits, ", "), { disabled = true })
                item("-")
            end
        end

        if #drift > 0 then
            item("Run make re-add", { fn = function() openInTerminal("make re-add") end })
        end
        if #pending > 0 then
            item("Run make apply", { fn = function() openInTerminal("make apply") end })
        end
        if #drift > 0 or #pending > 0 or #rootFiles > 0 then
            item("Show diff", { fn = function() openInTerminal("dot-diff") end })
        end
    end

    item("-")
    item("Refresh now", { fn = function() M.refresh() end })
    return menu
end

local function render(st)
    local driftN = (st and st.drift and st.drift.files) and #st.drift.files or 0
    local pendingN = (st and st.pending and st.pending.entries) and #st.pending.entries or 0
    local gitDirty = (st and st.git and st.git.ok and (st.git.dirty > 0 or st.git.ahead > 0)) or false
    local rootN = (st and st.root_files and st.root_files.differing) and #st.root_files.differing or 0
    local degraded = (st == nil) or (st.probes_ok == false)

    -- Create once and hide/show, never delete-and-recreate: a fresh item is not
    -- guaranteed a slot in the menu bar.
    if not M.bar then
        -- Created hidden so a clean startup doesn't flash an icon.
        M.bar = hs.menubar.new(false)
        if not M.bar then return end
    end

    if driftN == 0 and pendingN == 0 and rootN == 0 and not gitDirty and not degraded then
        M.bar:removeFromMenuBar()
        return
    end
    M.bar:returnToMenuBar()

    local parts = {}
    if driftN > 0 then table.insert(parts, tostring(driftN)) end
    if pendingN > 0 then table.insert(parts, pendingN .. "p") end
    if rootN > 0 then table.insert(parts, "⊕") end
    if gitDirty then table.insert(parts, "●") end
    if degraded then table.insert(parts, "⚠") end

    local tint = SUBTLE
    if driftN > 0 or rootN > 0 or degraded then
        tint = RED
    elseif pendingN > 0 then
        tint = YELLOW
    end

    M.bar:setTitle(hs.styledtext.new("⌂" .. table.concat(parts, " "), {
        color = tint,
        font = { name = "Menlo", size = 13 },
    }))
    M.bar:setTooltip(string.format("dotfiles — drift %d, pending %d", driftN, pendingN))
    M.bar:setMenu(function() return M.buildMenu(st) end)
end

-- Asynchronous: hs.execute would block Hammerspoon's UI for the probe's ~200ms
-- on every tick.
function M.refresh()
    probe(render)
end

function M.start()
    M.refresh()

    M.timer = hs.timer.doEvery(INTERVAL, M.refresh)

    -- chezmoi rewrites its state on every apply/re-add. Debounced: boltdb
    -- touches the file repeatedly within one apply.
    local debounce = nil
    M.watcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.config/chezmoi/", function()
        if debounce then debounce:stop() end
        debounce = hs.timer.doAfter(2, M.refresh)
    end):start()

    -- Drift accumulates while asleep; don't wait out the interval after waking.
    M.power = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake
            or event == hs.caffeinate.watcher.screensDidUnlock then
            M.refresh()
        end
    end):start()

    return M
end

return M
