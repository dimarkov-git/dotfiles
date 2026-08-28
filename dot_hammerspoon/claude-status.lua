-- Menubar indicator for Claude Code sessions running in Ghostty tabs. Tab state
-- rides tab-state.lua's poll; timings come from ~/.claude/hooks/.

local M = {}

local STATE_DIR = os.getenv("HOME") .. "/.local/state/claude-sessions"

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

-- Frame per terminal id from the previous tick, so a changed frame reads as work
-- in progress. A session first seen is assumed running until a tick proves otherwise.
M.lastFrame = {}

local function classify(id, glyph)
    local prev = M.lastFrame[id]
    M.lastFrame[id] = glyph
    if prev == nil then return "running" end
    return prev ~= glyph and "running" or "waiting"
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

-- Timings keyed by terminal id. Hook-written, so a session started outside
-- Ghostty (or before the hooks existed) simply has none.
local function readTimings()
    local byTerm = {}
    -- hs.fs.dir returns iterator AND state; dropping the second breaks iteration.
    local ok, iter, dirObj = pcall(hs.fs.dir, STATE_DIR)
    if not ok or not iter then return byTerm end
    for file in iter, dirObj do
        if file:sub(-5) == ".json" then
            local fh = io.open(STATE_DIR .. "/" .. file)
            if fh then
                local body = fh:read("a")
                fh:close()
                local term = body:match('"terminal_id"%s*:%s*"([^"]*)"')
                if term and term ~= "" then
                    byTerm[term] = {
                        started = tonumber(body:match('"started"%s*:%s*(%d+)')),
                        waitingSince = tonumber(body:match('"waiting_since"%s*:%s*(%d+)')),
                        -- nil when the session predates the status hook.
                        busy = body:match('"busy"%s*:%s*(%a+)'),
                    }
                end
            end
        end
    end
    return byTerm
end

-- Answering a permission prompt fires neither Stop nor UserPromptSubmit, so
-- `busy` can't clear a wait — only a newer stamp or a click that nulls it can.
function M.stillWaiting(termId, stamp)
    local t = readTimings()[termId]
    if not t then return false end
    if t.busy == "true" then return false end
    return t.waitingSince == stamp
end

-- Clearing the stamp on click keeps the menubar from ageing a wait the user has
-- already answered. Files are keyed by session id, so the terminal is matched inside.
function M.clearWaiting(termId)
    termId = (termId or ""):match("^%s*(.-)%s*$")
    if termId == "" then return end
    local ok, iter, dirObj = pcall(hs.fs.dir, STATE_DIR)
    if not ok or not iter then return end
    for file in iter, dirObj do
        if file:sub(-5) == ".json" then
            local path = STATE_DIR .. "/" .. file
            local fh = io.open(path)
            if fh then
                local body = fh:read("a")
                fh:close()
                if body:match('"terminal_id"%s*:%s*"([^"]*)"') == termId then
                    local out = body:gsub('("waiting_since"%s*:%s*)[^,}%s]+', "%1null", 1)
                    local wh = io.open(path, "w")
                    if wh then wh:write(out); wh:close() end
                    return
                end
            end
        end
    end
end

local function parse(out)
    local sessions = {}
    local seen = {}
    local timings = readTimings()
    local now = os.time()
    for line in (out or ""):gmatch("[^\n]+") do
        local id, idx, sel, cwd, title =
            line:match("^(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.*)$")
        -- Membership from state files: title glyphs change with Claude's spinner.
        local t = timings[id]
        if t then
            seen[id] = true
            -- Hook-written truth; the glyph heuristic only covers sessions
            -- started before the status hook existed.
            local status
            if t.busy == "true" then status = "running"
            elseif t.busy == "false" then status = "waiting"
            else status = classify(id, title and firstGlyph(title) or "") end
            table.insert(sessions, {
                id = id,
                index = tonumber(idx),
                selected = sel == "true",
                cwd = cwd,
                title = label(title),
                status = status,
                uptime = t.started and (now - t.started) or nil,
                -- Only meaningful while idle: the stamp is not cleared on resume.
                waiting = (status == "waiting" and t.waitingSince)
                    and (now - t.waitingSince) or nil,
            })
        end
    end

    -- Drop closed tabs, or their stale frame would misjudge a reused id.
    for id in pairs(M.lastFrame) do
        if not seen[id] then M.lastFrame[id] = nil end
    end
    return sessions
end

-- `focus` raises the terminal's window and follows it across Spaces, so the tab
-- need not be the selected one. False when the tab is gone.
function M.focusTerminal(id)
    local ok, tabState = pcall(require, "tab-state")
    return ok and tabState.focusTerminal(id)
end

-- Last resort when no specific tab can be focused; without it the click looks
-- like it did nothing at all.
local function activateGhostty()
    local app = hs.application.get("Ghostty")
    if app then app:activate() end
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
        for _, s in ipairs(sessions) do
            local glyph = s.status == "waiting" and WAITING or "•"
            local mark = s.selected and "  ▸" or ""
            item(string.format("%s %s%s", glyph, s.title, mark), {
                fn = function()
                    if not M.focusTerminal(s.id) then activateGhostty() end
                end,
            })

            local meta = { tilde(s.cwd) }
            if s.waiting then table.insert(meta, "waiting " .. ageLabel(s.waiting)) end
            if s.uptime then table.insert(meta, "up " .. ageLabel(s.uptime)) end
            item("      " .. table.concat(meta, "  ·  "), { disabled = true })
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

-- Answering within this window needs no banner; the wait is already over.
local NOTIFY_DELAY = 8

-- Pending banners keyed by terminal id, so a second prompt from the same tab
-- replaces the first rather than queueing behind it.
M.pending = {}

-- True while the tab is both selected and Ghostty is frontmost — the user is
-- looking straight at the prompt.
local function tabIsWatched(termId)
    local app = hs.application.get("Ghostty")
    if not (app and app:isFrontmost() and not app:isHidden()) then return false end
    for _, s in ipairs(M.state or {}) do
        if s.id == termId then return s.selected end
    end
    return false
end

-- Cancels a pending banner: the session stopped waiting on its own.
function M.cancelPending(termId)
    local t = M.pending[termId]
    if t then t:stop(); M.pending[termId] = nil end
end

-- Called from ~/.claude/hooks/claude-notify.sh via `hs -c`. Clicking the banner
-- jumps to the tab that raised it; withdrawn on click so it can't outlive the wait.
function M.notify(title, message, dir, termId, kind)
    termId = (termId or ""):match("^%s*(.-)%s*$")
    -- No terminal to check against: nothing can prove the wait ended, so send.
    if termId == "" then
        M.send(title, message, dir, termId, kind)
        return M.refresh()
    end

    -- Read before the delay: this is the wait this banner belongs to.
    local stamp = (readTimings()[termId] or {}).waitingSince

    M.cancelPending(termId)
    M.pending[termId] = hs.timer.doAfter(NOTIFY_DELAY, function()
        M.pending[termId] = nil
        if not M.stillWaiting(termId, stamp) then return end
        if tabIsWatched(termId) then return end
        M.send(title, message, dir, termId, kind)
    end)
    M.refresh()
end

function M.send(title, message, dir, termId, kind)
    local n = hs.notify.new(function(notif)
        -- A stale id is treated as no id: both leave us with no tab to focus.
        if not (termId and termId ~= "" and M.focusTerminal(termId)) then
            activateGhostty()
        end
        if termId and termId ~= "" then M.clearWaiting(termId) end
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
