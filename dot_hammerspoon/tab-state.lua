-- Live registry of Ghostty tabs, mirrored to STATE_FILE as JSON. Polled because
-- Ghostty raises no AppleScript events; one poller beats a query per shell prompt.
--
-- Every query goes through `guarded`: a bare `tell application "Ghostty"` LAUNCHES
-- it, so an unguarded poll resurrects the app you just quit -- with window-save-state
-- restoring its tabs.

local M = {}

-- Sole owner of the poll; claude-status subscribes rather than paying a second
-- ~77ms osascript. Backgrounded Ghostty can't change tabs; closed needs none.
local INTERVAL = 2
local IDLE_INTERVAL = 10
local STATE_FILE = os.getenv("HOME") .. "/.local/state/ghostty-tabs.json"

local SEP = "\031"

M.SCRIPT = [[
tell application "Ghostty"
  set AppleScript's text item delimiters to ""
  set out to {}
  repeat with w in windows
    repeat with t in tabs of w
      set focusedId to id of (focused terminal of t)
      repeat with tm in terminals of t
        set end of out to (id of tm) & "]] .. SEP .. [[" & (index of t) & "]] .. SEP .. [[" & ¬
          ((selected of t) and ((id of tm) is focusedId)) & "]] .. SEP .. [[" & ¬
          (working directory of tm) & "]] .. SEP .. [[" & (name of t) & linefeed
      end repeat
    end repeat
  end repeat
  return out as text
end tell
]]

-- AppleScript launches a target app when the `tell` is COMPILED, so a Lua-side
-- `hs.application.get` check cannot prevent it and an in-script `is running`
-- test fires too late. `run script` defers compilation until after the guard.
--
-- Hand-rolled, not string.format("%q"): Lua emits `\31` and a backslash-newline
-- continuation, neither of which AppleScript's tokenizer accepts.
local function guarded(body)
    local lit = body
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
    return 'tell application "System Events"\n'
        .. 'if not (exists process "Ghostty") then return ""\n'
        .. 'end tell\n'
        .. 'return run script "' .. lit .. '"'
end

-- Per-tab facts that outlive a single poll. Keyed by terminal id.
M.tabs = {}

-- lastOutput lets a subscriber repaint on demand without forcing a poll.
M.subscribers = {}
M.lastOutput = nil

function M.subscribe(fn)
    table.insert(M.subscribers, fn)
end

local function esc(s)
    return (tostring(s or "")
        :gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\n", "\\n"):gsub("\t", "\\t")
        :gsub("[\1-\31]", ""))
end

-- Claude sessions keyed by tty, so consumers of this file (t-tabs) see one
-- system rather than two. Written by ~/.claude/hooks/.
local SESSION_DIR = os.getenv("HOME") .. "/.local/state/claude-sessions"

local registry = require("tab-registry")

-- A tab can host several sessions over its life; only live ones are listed, so
-- collisions surface as multiple entries instead of silently overwriting.
function M.claudeSessions()
    local sessions = {}
    local ok, iter, dirObj = pcall(hs.fs.dir, SESSION_DIR)
    if not ok or not iter then return sessions end
    for file in iter, dirObj do
        if file:sub(-5) == ".json" then
            local path = SESSION_DIR .. "/" .. file
            local fh = io.open(path)
            if fh then
                local body = fh:read("a")
                fh:close()
                local tty = body:match('"tty"%s*:%s*"([^"]*)"')
                local pid = tonumber(body:match('"pid"%s*:%s*(%d+)'))
                -- Claude exits without SessionEnd often enough that a dead pid,
                -- not a missing file, is what marks a session gone.
                if not pid or not registry.shellAlive(pid) then
                    os.remove(path)
                elseif tty and tty ~= "" then
                    table.insert(sessions, {
                        tty = tty,
                        sessionId = body:match('"session_id"%s*:%s*"([^"]*)"'),
                        cwd = body:match('"cwd"%s*:%s*"([^"]*)"'),
                        busy = body:match('"busy"%s*:%s*(%a+)'),
                        started = tonumber(body:match('"started"%s*:%s*(%d+)')),
                        waitingSince = tonumber(body:match('"waiting_since"%s*:%s*(%d+)')),
                    })
                end
            end
        end
    end
    return sessions
end

local function claudeByTab()
    local byTab = {}
    for _, s in ipairs(M.claudeSessions()) do
        local id = registry.idForTty(s.tty)
        if id then byTab[id] = s end
    end
    return byTab
end

local function writeState(tabs, activeId)
    local parts = {}
    local claude = claudeByTab()
    for id, t in pairs(tabs) do
        local c = claude[id]
        local cjson = "null"
        if c then
            -- busy=nil predates the status hook; report it as unknown, not idle.
            cjson = string.format(
                '{"busy":%s,"started":%d,"waiting_since":%s,"cwd":"%s"}',
                c.busy or "null", c.started or 0,
                c.waitingSince and tostring(c.waitingSince) or "null", esc(c.cwd))
        end
        local tty = registry.ttyForId(id)
        table.insert(parts, string.format(
            '"%s":{"index":%d,"selected":%s,"cwd":"%s","title":"%s",' ..
            '"born":%d,"last_selected":%d,"selections":%d,"tty":"%s","claude":%s}',
            esc(id), t.index or 0, tostring(t.selected), esc(t.cwd), esc(t.title),
            t.born or 0, t.lastSelected or 0, t.selections or 0, esc(tty or ""), cjson))
    end
    local fh = io.open(STATE_FILE, "w")
    if not fh then return end
    fh:write(string.format('{"active":"%s","updated":%d,"tabs":{%s}}',
        esc(activeId), os.time(), table.concat(parts, ",")))
    fh:close()
end

local function parse(out)
    local seen = {}
    local activeId = ""
    local now = os.time()

    for line in (out or ""):gmatch("[^\n]+") do
        local id, idx, sel, cwd, title =
            line:match("^(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.*)$")
        if id and id ~= "" then
            seen[id] = true
            local selected = sel == "true"
            local prev = M.tabs[id]
            -- `tab` below IS `prev`; assigning tab.selected first erases the edge.
            local wasSelected = prev ~= nil and prev.selected

            local tab = prev or { born = now, selections = 0, lastSelected = 0 }
            tab.index, tab.cwd, tab.title, tab.selected = tonumber(idx) or 0, cwd, title, selected

            -- Count the edge: a tab left selected for an hour is one selection.
            if selected and not wasSelected then
                tab.selections = tab.selections + 1
            end
            if selected then
                tab.lastSelected = now
                activeId = id
            end

            M.tabs[id] = tab
        end
    end

    for id in pairs(M.tabs) do
        if not seen[id] then M.tabs[id] = nil end
    end

    -- Also reaps state whose shell died: the poll runs regardless of focus.
    pcall(function() registry.reconcile(M.tabs) end)

    -- Backgrounded Ghostty still reports its last tab as selected.
    local app = hs.application.get("Ghostty")
    if not (app and app:isFrontmost() and not app:isHidden()) then
        activeId = ""
    end

    writeState(M.tabs, activeId)
end

function M.refresh()
    local app = hs.application.get("Ghostty")
    -- No Ghostty means no tabs: querying would relaunch it via AppleScript.
    if not app then
        if next(M.tabs) ~= nil then
            M.tabs = {}
            writeState(M.tabs, "")
        end
        M.lastOutput = ""
        for _, fn in ipairs(M.subscribers) do fn("") end
        return
    end
    local task = hs.task.new("/usr/bin/osascript", function(_, stdout)
        parse(stdout)
        M.lastOutput = stdout or ""
        for _, fn in ipairs(M.subscribers) do fn(M.lastOutput) end
    end, { "-e", guarded(M.SCRIPT) })
    if task then task:start() end
end

-- Retimes itself rather than polling fast and discarding ticks.
local function tick()
    M.refresh()
    local app = hs.application.get("Ghostty")
    -- Closed: stop entirely, the app watcher restarts on launch.
    if not app then
        if M.timer then M.timer:stop(); M.timer = nil end
        M.period = nil
        return
    end
    local front = app:isFrontmost() and not app:isHidden()
    local want = front and INTERVAL or IDLE_INTERVAL
    if M.period ~= want then
        M.period = want
        if M.timer then M.timer:stop() end
        M.timer = hs.timer.doEvery(want, tick)
    end
end

function M.activateGhostty()
    local app = hs.application.get("Ghostty")
    if app then app:activate() end
end

-- In-block `activate` runs even after `focus` errors on a dead id, opening a window.
-- `guarded` returns "" for a closed Ghostty, which `focus` never does -- so an
-- empty result means "not running" and must not fall through to activate.
function M.focusTerminal(id)
    local ok, out = hs.osascript.applescript(guarded(string.format(
        'tell application "Ghostty"\nfocus (terminal id "%s")\nend tell', id)))
    if not ok or out == "" then return false end
    M.activateGhostty()
    return true
end

-- tty is the stable identity; its terminal id is resolved per call because a
-- tab can be closed and the link dropped between poll and click.
function M.focusTty(tty)
    local id = registry.idForTty(tty)
    return id ~= nil and M.focusTerminal(id)
end

-- Entry point for shells via `hs -c`; clicking the banner jumps to the tab.
function M.notify(title, message, tty)
    tty = (tty or ""):match("^%s*(.-)%s*$")
    local n = hs.notify.new(function(notif)
        if not (tty ~= "" and M.focusTty(tty)) then
            M.activateGhostty()
        end
        notif:withdraw()
    end, {
        title = title,
        informativeText = message,
        withdrawAfter = 0,
    })
    n:send()
end

function M.start()
    hs.fs.mkdir(os.getenv("HOME") .. "/.local/state")
    M.period = INTERVAL
    M.timer = hs.timer.doEvery(INTERVAL, tick)
    tick()

    -- Also the only way back from a stopped timer: `launched` restarts it.
    M.watcher = hs.application.watcher.new(function(name, event)
        if name ~= "Ghostty" then return end
        if event == hs.application.watcher.activated
            or event == hs.application.watcher.launched then
            if not M.timer then
                M.period = INTERVAL
                M.timer = hs.timer.doEvery(INTERVAL, tick)
            end
            tick()
        elseif event == hs.application.watcher.terminated then
            tick()
        end
    end)
    M.watcher:start()
    return M
end

return M
