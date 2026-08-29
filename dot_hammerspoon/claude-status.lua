-- Menubar indicator for Claude Code sessions running in Ghostty tabs. Tab state
-- rides tab-state.lua's poll; timings come from ~/.claude/hooks/.

local M = {}

local STATE_DIR = os.getenv("HOME") .. "/.local/state/claude-sessions"

local registry = require("tab-registry")

M.bar = nil
M.state = nil

local GREEN = { hex = "#a6e3a1" }  -- Catppuccin Green
local YELLOW = { hex = "#f9e2af" } -- Peach
local SUBTLE = { hex = "#9399b2" } -- Overlay2

-- Running vs idle is told by the title's leading glyph CHANGING between polls,
-- so which glyph Claude currently animates with doesn't matter.
local WAITING = "✳"

-- `\x1f`-separated fields: titles carry arbitrary prompt text, so any printable
-- delimiter could appear inside one.
local SEP = "\031"


-- First codepoint of a UTF-8 string, as a string.
local function firstGlyph(s)
    if s == "" then return "" end
    local b = s:byte(1)
    local n = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
    return s:sub(1, n)
end

-- Strip the status glyph; what remains is the summary Claude put there.
local function label(title)
    local g = firstGlyph(title)
    return (title:sub(#g + 1):gsub("^%s+", ""))
end

local function tilde(path)
    local home = os.getenv("HOME")
    if path:sub(1, #home) == home then return "~" .. path:sub(#home + 1) end
    return path
end

local function ageLabel(secs)
    if secs < 60 then return string.format("%ds", secs) end
    if secs < 3600 then return string.format("%dm", secs // 60) end
    return string.format("%dh%02dm", secs // 3600, (secs % 3600) // 60)
end

-- Sessions as a list: two Claudes can share a tab over its lifetime, and a map
-- keyed by tab would silently drop all but one.
local function readSessions()
    local ok, tabState = pcall(require, "tab-state")
    if not ok then return {} end
    return tabState.claudeSessions()
end

local function sessionForTty(tty)
    for _, s in ipairs(readSessions()) do
        if s.tty == tty then return s end
    end
    return nil
end

-- Answering a permission prompt fires neither Stop nor UserPromptSubmit, so
-- `busy` can't clear a wait — only a newer stamp or a click that nulls it can.
function M.stillWaiting(tty, stamp)
    local s = sessionForTty(tty)
    if not s then return false end
    if s.busy == "true" then return false end
    return s.waitingSince == stamp
end

-- Keeps the menubar from ageing a wait the user has already answered.
function M.clearWaiting(tty)
    tty = (tty or ""):match("^%s*(.-)%s*$")
    if tty == "" then return end
    local ok, iter, dirObj = pcall(hs.fs.dir, STATE_DIR)
    if not ok or not iter then return end
    for file in iter, dirObj do
        if file:sub(-5) == ".json" then
            local path = STATE_DIR .. "/" .. file
            local fh = io.open(path)
            if fh then
                local body = fh:read("a")
                fh:close()
                if body:match('"tty"%s*:%s*"([^"]*)"') == tty then
                    local out = body:gsub('("waiting_since"%s*:%s*)[^,}%s]+', "%1null", 1)
                    local wh = io.open(path, "w")
                    if wh then wh:write(out); wh:close() end
                    return
                end
            end
        end
    end
end

-- Tabs come from the poll, sessions from the hooks; a session whose tab is
-- unresolved still lists, it just cannot be jumped to.
local function parse(out)
    local tabByTty = {}
    for line in (out or ""):gmatch("[^\n]+") do
        local id, idx, sel, cwd, title =
            line:match("^(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.*)$")
        if id and id ~= "" then
            local tty = registry.ttyForId(id)
            if tty then
                tabByTty[tty] = {
                    id = id,
                    index = tonumber(idx),
                    selected = sel == "true",
                    cwd = cwd,
                    title = label(title),
                }
            end
        end
    end

    local now = os.time()
    local sessions = {}
    for _, sess in ipairs(readSessions()) do
        local tab = tabByTty[sess.tty]
        local status = sess.busy == "true" and "running" or "waiting"
        table.insert(sessions, {
            tty = sess.tty,
            id = tab and tab.id or nil,
            index = tab and tab.index or nil,
            selected = tab and tab.selected or false,
            cwd = sess.cwd or (tab and tab.cwd) or "",
            title = (tab and tab.title ~= "" and tab.title) or "Claude",
            status = status,
            uptime = sess.started and (now - sess.started) or nil,
            -- Only meaningful while idle: the stamp is not cleared on resume.
            waiting = (status == "waiting" and sess.waitingSince)
                and (now - sess.waitingSince) or nil,
        })
    end

    table.sort(sessions, function(a, b)
        if (a.index or 99) ~= (b.index or 99) then return (a.index or 99) < (b.index or 99) end
        return a.tty < b.tty
    end)
    return sessions
end

-- `focus` raises the terminal's window and follows it across Spaces, so the tab
-- need not be the selected one. False when the tty has no resolved tab.
function M.focusTty(tty)
    local ok, tabState = pcall(require, "tab-state")
    return ok and tabState.focusTty(tty)
end

-- Last resort when no specific tab can be focused; without it the click looks
-- like it did nothing at all.
local function activateGhostty()
    local app = hs.application.get("Ghostty")
    if app then app:activate() end
end

-- Repo root, so sessions in sibling worktrees group under one heading.
local function projectOf(path)
    local name = path:match("([^/]+)/%.claude/worktrees/") or path:match("([^/]+)$")
    return name or path
end

function M.buildMenu()
    local sessions = M.state or {}
    local menu = {}
    local function item(t, extra)
        local e = extra or {}
        e.title = t
        table.insert(menu, e)
    end

    if #sessions == 0 then
        item("no Claude sessions", { disabled = true })
    else
        local order, groups = {}, {}
        for _, s in ipairs(sessions) do
            local key = projectOf(s.cwd)
            if not groups[key] then groups[key] = {}; table.insert(order, key) end
            table.insert(groups[key], s)
        end

        for gi, key in ipairs(order) do
            if gi > 1 then item("-") end
            -- Flat lists stop being readable past a handful of sessions.
            if #order > 1 then item(key, { disabled = true }) end
            for _, s in ipairs(groups[key]) do
                local glyph = s.status == "waiting" and WAITING or "•"
                local mark = s.selected and "  ▸" or ""
                local pin = s.id and "" or "  ⚠"
                item(string.format("%s %s%s%s", glyph, s.title, mark, pin), {
                    fn = function()
                        if not M.focusTty(s.tty) then activateGhostty() end
                    end,
                })

                local meta = { tilde(s.cwd) }
                if s.waiting then table.insert(meta, "waiting " .. ageLabel(s.waiting)) end
                if s.uptime then table.insert(meta, "up " .. ageLabel(s.uptime)) end
                item("      " .. table.concat(meta, "  ·  "), { disabled = true })
            end
        end
    end

    item("-")
    item("Refresh now", { fn = function() M.refresh() end })
    return menu
end

local function render(sessions)
    if not M.bar then
        M.bar = hs.menubar.new(false)
        if not M.bar then return end
        -- Set once: the callback re-reads M.state per open, and re-setting it
        -- dismisses a menu the user has open.
        M.bar:setMenu(function() return M.buildMenu() end)
    end

    M.state = sessions

    if #sessions == 0 then
        M.bar:removeFromMenuBar()
        return
    end
    -- Unconditional returnToMenuBar re-adds the item, closing an open menu.
    if not M.bar:isInMenuBar() then M.bar:returnToMenuBar() end

    local waiting, running = 0, 0
    for _, s in ipairs(sessions) do
        if s.status == "waiting" then waiting = waiting + 1 else running = running + 1 end
    end

    local text, tint
    if waiting > 0 then
        text, tint = WAITING .. waiting, YELLOW
    else
        text, tint = "•" .. running, GREEN
    end

    M.bar:setTitle(hs.styledtext.new("⏣" .. text, {
        color = tint,
        font = { name = "Menlo", size = 13 },
    }))
    M.bar:setTooltip(string.format("Claude — %d waiting, %d running", waiting, running))
end

-- Renders from tab-state's poll; a standalone query would double its cost.
function M.refresh()
    if not hs.application.get("Ghostty") then return render({}) end
    local ok, tabState = pcall(require, "tab-state")
    if ok and tabState.lastOutput then render(parse(tabState.lastOutput)) end
end

-- Badge tint per notification type; the sender icon stays Hammerspoon's, since
-- macOS ignores setIdImage and only honours contentImage.
local BADGE = {
    permission_prompt = "#f9e2af",
    agent_completed = "#a6e3a1",
    elicitation_dialog = "#89b4fa",
}
local BADGE_DEFAULT = "#D97757"

local badgeCache = {}

-- The caller escapes every argument with a trailing newline; untrimmed it would
-- miss every BADGE key.
local function badge(kind)
    local hex = BADGE[(kind or ""):match("^%s*(.-)%s*$")] or BADGE_DEFAULT
    if not badgeCache[hex] then
        local c = hs.canvas.new({ x = 0, y = 0, w = 128, h = 128 })
        c[1] = { type = "rectangle", action = "fill", fillColor = { hex = hex },
                 roundedRectRadii = { xRadius = 28, yRadius = 28 } }
        c[2] = { type = "text", text = WAITING, textSize = 86, textColor = { hex = "#1e1e2e" },
                 textAlignment = "center", frame = { x = 0, y = 8, w = 128, h = 110 } }
        badgeCache[hex] = c:imageFromCanvas()
        c:delete()
    end
    return badgeCache[hex]
end

-- Idle waits are worth a delay; a blocked prompt is not, so it fires at once.
local IDLE_DELAY = 30

-- Pending banners keyed by tty, so a second prompt from the same tab replaces
-- the first rather than queueing behind it.
M.pending = {}

-- True while the tab is both selected and Ghostty is frontmost — the user is
-- looking straight at the prompt.
local function tabIsWatched(tty)
    local app = hs.application.get("Ghostty")
    if not (app and app:isFrontmost() and not app:isHidden()) then return false end
    for _, s in ipairs(M.state or {}) do
        if s.tty == tty then return s.selected end
    end
    return false
end

function M.cancelPending(tty)
    local t = M.pending[tty]
    if t then t:stop(); M.pending[tty] = nil end
end

-- Called from ~/.claude/hooks/claude-notify.sh via `hs -c`. Clicking the banner
-- jumps to the tab that raised it; withdrawn on click so it can't outlive the wait.
function M.notify(title, message, dir, tty, kind, urgent)
    tty = (tty or ""):match("^%s*(.-)%s*$")
    -- No tab to check against: nothing can prove the wait ended, so send.
    if tty == "" then
        M.send(title, message, dir, tty, kind)
        return M.refresh()
    end

    M.cancelPending(tty)

    if urgent then
        if not tabIsWatched(tty) then M.send(title, message, dir, tty, kind) end
        return M.refresh()
    end

    -- Read before the delay: this is the wait this banner belongs to.
    local stamp = (sessionForTty(tty) or {}).waitingSince

    M.pending[tty] = hs.timer.doAfter(IDLE_DELAY, function()
        M.pending[tty] = nil
        if not M.stillWaiting(tty, stamp) then return end
        if tabIsWatched(tty) then return end
        M.send(title, message, dir, tty, kind)
    end)
    M.refresh()
end

function M.send(title, message, dir, tty, kind)
    local n = hs.notify.new(function(notif)
        -- An unresolved tty is treated as no tty: both leave us with no tab.
        if not (tty and tty ~= "" and M.focusTty(tty)) then
            activateGhostty()
        end
        if tty and tty ~= "" then M.clearWaiting(tty) end
        notif:withdraw()
        M.refresh()
    end, {
        title = title,
        subTitle = dir ~= "" and dir or nil,
        informativeText = message,
        withdrawAfter = 0,
    })
    n:contentImage(badge(kind))
    n:send()
    M.refresh()
end

function M.start()
    local ok, tabState = pcall(require, "tab-state")
    if ok then
        tabState.subscribe(function(out) render(parse(out)) end)
        -- tab-state polls once before this subscribe lands; without replaying
        -- that output the bar stays empty until the next tick.
        if tabState.lastOutput then render(parse(tabState.lastOutput)) end
    else
        -- Without the shared poll there is no source of sessions at all.
        render({})
    end
    return M
end

return M
