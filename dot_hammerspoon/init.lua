-- Hammerspoon config.
--
-- Scope: a global option+space toggle for Ghostty that behaves like a
-- drop-down terminal — show it on whichever Space is currently active,
-- sized to the top 70% of the screen; press again to hide.
--
-- Note: Ghostty has a built-in quick terminal (`toggle_quick_terminal`,
-- bound to ctrl+` in dot_config/ghostty/config) that covers much of this
-- natively. This drives the MAIN Ghostty window instead, so the same
-- session/tabs are always one keystroke away rather than a separate
-- scratch surface.

-- Enables the `hs` CLI (installed by the cask as /opt/homebrew/bin/hs), so
-- config can be poked at from a shell: `hs -c 'hs.reload()'`.
require("hs.ipc")

local GHOSTTY = "Ghostty"

-- Fraction of the screen height the window occupies when shown, anchored to
-- the top edge and spanning the full width.
local HEIGHT_FRACTION = 0.7

-- Place `win` across the top of whichever screen the mouse is on, so the
-- terminal follows the display you're actually looking at on a multi-monitor
-- setup. `frame` (not `fullFrame`) excludes the menu bar and Dock, so the
-- window sits flush under the menu bar instead of behind it.
local function positionTop(win)
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = screen:frame()
    win:setFrame({
        x = f.x,
        y = f.y,
        w = f.w,
        h = f.h * HEIGHT_FRACTION,
    })
end

-- Pull a window onto the Space that's currently active.
--
-- Without this, hitting the hotkey on another Space makes macOS *switch* to
-- wherever Ghostty already lives, instead of bringing it here — the opposite
-- of drop-down behaviour.
--
-- hs.spaces.moveWindowToSpace uses private CoreGraphics APIs, so treat it as
-- best-effort: wrap in pcall and carry on if a macOS update breaks it. The
-- window still gets focused, just possibly on its original Space.
local function moveToActiveSpace(win)
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local target = hs.spaces.activeSpaceOnScreen(screen)
    if not target then return end

    -- Already here — moving would be a no-op that can still flicker.
    local current = hs.spaces.windowSpaces(win)
    if current then
        for _, s in ipairs(current) do
            if s == target then return end
        end
    end

    pcall(hs.spaces.moveWindowToSpace, win, target)
end

-- Bring the app forward and place it. Shared by every "show" path.
--
-- `app:activate()` alone is not enough when the app was hidden: unhiding is
-- asynchronous, and a setFrame issued in the same tick lands on a window the
-- window server hasn't remapped yet — it silently does nothing, which reads
-- as "the hotkey doesn't open it". Hence unhide first, then position on the
-- next runloop turn.
local function showGhostty(app, win)
    app:unhide()
    app:activate()

    hs.timer.doAfter(0.05, function()
        local w = win
        if not w or not w:isVisible() then
            local a = hs.application.get(GHOSTTY)
            w = a and a:mainWindow()
        end
        if not w then return end

        moveToActiveSpace(w)
        positionTop(w)
        w:raise()
        w:focus()
    end)
end

local function toggleGhostty()
    local app = hs.application.get(GHOSTTY)

    -- Not running: launch it. The window won't exist yet, so position it
    -- once it appears rather than racing the launch.
    if not app then
        hs.application.launchOrFocus(GHOSTTY)
        hs.timer.doAfter(0.6, function()
            local a = hs.application.get(GHOSTTY)
            local w = a and a:mainWindow()
            if w then
                positionTop(w)
                w:focus()
            end
        end)
        return
    end

    local win = app:mainWindow()

    -- Running but no window (all closed): ask it for a fresh one.
    if not win then
        app:activate()
        app:selectMenuItem({ "File", "New Window" })
        hs.timer.doAfter(0.4, function()
            local w = hs.application.get(GHOSTTY)
            w = w and w:mainWindow()
            if w then
                positionTop(w)
                w:focus()
            end
        end)
        return
    end

    -- Hide only when Ghostty is genuinely in front. Pressing the hotkey from
    -- another app brings Ghostty forward instead — otherwise one key would
    -- mean two different things depending on invisible state.
    --
    -- `isHidden()` is checked explicitly rather than inferred from
    -- `isFrontmost()`: a hidden app can still report frontmost briefly while
    -- macOS finishes the hide, and treating that as "visible" makes the next
    -- press hide again — the bug where it hides but never comes back.
    if not app:isHidden() and app:isFrontmost() then
        app:hide()
        return
    end

    showGhostty(app, win)
end

hs.hotkey.bind({ "alt" }, "space", toggleGhostty)

-- Global like dotfilesStatus: a local lets GC reap the menubar.
local okXdebug, xdebugOrErr = pcall(function() return require("xdebug-status") end)
xdebugStatus = okXdebug and xdebugOrErr or nil
if not okXdebug then
    hs.notify.new({ title = "xdebug-status failed", informativeText = tostring(xdebugOrErr) }):send()
end

-- Pull Zed forward when a debug session starts: it never asks macOS to
-- activate itself on a breakpoint, so a hit from another Space goes unnoticed.
-- Its GPU-drawn UI exposes no "stopped" state to accessibility, leaving the
-- adapter's socket as the only signal.
--
-- A rising count marks a new session; stepping reuses the connection, so focus
-- isn't yanked on every step. Orphaned adapters: see xdebug-status.lua.
local ZED_BUNDLE = "dev.zed.Zed"
local DEBUG_PORT = 9003
local FAST_INTERVAL = 1 -- adapter listening: a session may start any moment
local SLOW_INTERVAL = 15 -- Zed up, no adapter: nothing to race
local zedDebugConns = nil
local zedPortListening = nil

local function focusZed()
    local app = hs.application.get(ZED_BUNDLE)
    local win = app and app:mainWindow()
    if not win then return end

    app:unhide()
    app:activate()
    moveToActiveSpace(win)
    win:raise()
    win:focus()
end

-- ~0.1ms, against lsof's ~28ms scan of every process's fd table.
local function probePortOpen(done)
    local sock = hs.socket.new()
    if not sock then return done(true) end
    local settled = false
    local function settle(open)
        if settled then return end
        settled = true
        pcall(function() sock:disconnect() end)
        done(open)
    end
    sock:setCallback(function() end)
    pcall(function()
        sock:connect("127.0.0.1", DEBUG_PORT, function() settle(true) end)
    end)
    -- A refused connect is silent, so "closed" reads as absence after timeout.
    hs.timer.doAfter(0.3, function() settle(false) end)
end

-- hs.task, not hs.execute: the latter blocks the UI runloop for lsof's ~30ms.
local function runLsof()
    local task = hs.task.new("/usr/sbin/lsof", function(_, stdout)
        stdout = stdout or ""
        local listening = stdout:find("LISTEN", 1, true) ~= nil

        -- Re-pace before returning: an idle adapter doesn't warrant a 1s tick.
        if zedDebugWatcher then
            zedDebugWatcher:setNextTrigger(listening and FAST_INTERVAL or SLOW_INTERVAL)
        end

        -- Only on transitions: the indicator costs an extra lsof + ps.
        if listening ~= zedPortListening then
            zedPortListening = listening
            if xdebugStatus then xdebugStatus.refresh() end
        end

        if not listening then
            zedDebugConns = nil
            return
        end

        local count = 0
        for _ in stdout:gmatch("ESTABLISHED") do count = count + 1 end

        local previous = zedDebugConns
        zedDebugConns = count
        -- First tick only records a baseline; a drop just means sockets went away.
        if previous == nil or count <= previous then return end

        focusZed()
    end, { "-nP", "-iTCP:" .. DEBUG_PORT })
    if task then task:start() end
end

local function pollXdebugPort()
    probePortOpen(function(open)
        if open then return runLsof() end
        -- Nothing bound: skip lsof and re-pace, mirroring its no-listener branch.
        if zedDebugWatcher then zedDebugWatcher:setNextTrigger(SLOW_INTERVAL) end
        if zedPortListening ~= false then
            zedPortListening = false
            if xdebugStatus then xdebugStatus.refresh() end
        end
        zedDebugConns = nil
    end)
end

zedDebugWatcher = hs.timer.new(SLOW_INTERVAL, pollXdebugPort)

-- Gated on Zed: lsof scans every process's fd table, too costly to run always.
local function syncZedDebugWatcher()
    if hs.application.get(ZED_BUNDLE) then
        if not zedDebugWatcher:running() then
            zedDebugConns = nil
            zedPortListening = nil
            zedDebugWatcher:start()
        end
    elseif zedDebugWatcher:running() then
        zedDebugWatcher:stop()
        zedDebugConns = nil
        zedPortListening = nil
    end
    if xdebugStatus then xdebugStatus.refresh() end
end

-- `terminated` yields a dead object with nil bundleID; re-check rather than skip.
zedAppWatcher = hs.application.watcher.new(function(_, event, app)
    if event ~= hs.application.watcher.launched and event ~= hs.application.watcher.terminated then
        return
    end
    local bundle = app and app:bundleID()
    if bundle == nil or bundle == ZED_BUNDLE then
        syncZedDebugWatcher()
    end
end):start()

syncZedDebugWatcher()

-- Global: the module holds menubar userdata a local would let GC collect.
-- pcall'd so a broken indicator can't take down the hotkeys above.
local okStatus, statusOrErr = pcall(function() return require("dotfiles-status").start() end)
if okStatus then
    dotfilesStatus = statusOrErr
else
    hs.notify.new({ title = "dotfiles-status failed", informativeText = tostring(statusOrErr) }):send()
end

local okContainer, containerOrErr = pcall(function() return require("container-status").start() end)
if okContainer then
    containerStatus = containerOrErr
else
    hs.notify.new({ title = "container-status failed", informativeText = tostring(containerOrErr) }):send()
end

local okTabs, tabsOrErr = pcall(function() return require("tab-state").start() end)
if okTabs then
    tabState = tabsOrErr
    -- Global entry point for the shell's slow-command hook (`hs -c`).
    function tabNotify(title, message, tty)
        tabState.notify(title, message, tty)
    end
else
    hs.notify.new({ title = "tab-state failed", informativeText = tostring(tabsOrErr) }):send()
end

local okClaude, claudeOrErr = pcall(function() return require("claude-status").start() end)
if okClaude then
    claudeStatus = claudeOrErr
    -- Global entry point for ~/.claude/hooks/claude-notify.sh (`hs -c`).
    function claudeNotify(title, message, dir, tty, kind, urgent)
        claudeStatus.notify(title, message, dir, tty, kind, urgent)
    end
else
    hs.notify.new({ title = "claude-status failed", informativeText = tostring(claudeOrErr) }):send()
end

local okActions, actionsOrErr = pcall(function() return require("actions").bind({ "cmd", "alt" }, "space") end)
actions = okActions and actionsOrErr or nil
if not okActions then
    hs.notify.new({ title = "actions failed", informativeText = tostring(actionsOrErr) }):send()
end

-- A failed module leaves a persistent red marker: its notification is easy to
-- miss, and a silently absent indicator reads like "nothing to report".
local failures = {}
if not okStatus then table.insert(failures, "dotfiles") end
if not okContainer then table.insert(failures, "container") end
if not okClaude then table.insert(failures, "claude") end
if not okTabs then table.insert(failures, "tabs") end

if #failures > 0 then
    configAlarm = hs.menubar.new()
    if configAlarm then
        configAlarm:setTitle(hs.styledtext.new("⚠ hs", {
            font = { name = "Menlo", size = 13 },
            color = { hex = "#f38ba8" },
        }))
        configAlarm:setTooltip("failed: " .. table.concat(failures, ", "))
        configAlarm:setClickCallback(function() hs.toggleConsole() end)
    end
else
    hs.alert.show("hs reloaded", 0.7)
end
