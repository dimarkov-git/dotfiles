-- Maps a shell's tty to its Ghostty terminal id. Ghostty exposes neither pid nor
-- tty, so the link is inferred from cwd.

local M = {}

local STATE_DIR = os.getenv("HOME") .. "/.local/state/ghostty-shells"

-- tty -> { id, cwd }
M.links = {}

local function readShells()
    local shells = {}
    local ok, iter, dirObj = pcall(hs.fs.dir, STATE_DIR)
    if not ok or not iter then return shells end
    for file in iter, dirObj do
        if file:sub(-5) == ".json" then
            local fh = io.open(STATE_DIR .. "/" .. file)
            if fh then
                local body = fh:read("a")
                fh:close()
                local tty = body:match('"tty"%s*:%s*"([^"]*)"')
                if tty and tty ~= "" then
                    shells[tty] = {
                        pid = tonumber(body:match('"pid"%s*:%s*(%d+)')),
                        cwd = body:match('"cwd"%s*:%s*"([^"]*)"'),
                        path = STATE_DIR .. "/" .. file,
                    }
                end
            end
        end
    end
    return shells
end

local function shellAlive(pid)
    if not pid then return false end
    return os.execute(string.format("/bin/kill -0 %d 2>/dev/null", pid)) and true or false
end

M.shellAlive = shellAlive

local function terminalsByCwd(tabs)
    local byCwd = {}
    for id, t in pairs(tabs) do
        local cwd = t.cwd or ""
        byCwd[cwd] = byCwd[cwd] or {}
        table.insert(byCwd[cwd], id)
    end
    return byCwd
end

-- Ids already bound to a live tty, so two tabs in one directory can't both
-- resolve to the same terminal.
local function claimedIds(shells)
    local taken = {}
    for tty, link in pairs(M.links) do
        if shells[tty] then taken[link.id] = tty end
    end
    return taken
end

function M.reconcile(tabs)
    local shells = readShells()

    for tty, sh in pairs(shells) do
        if not shellAlive(sh.pid) then
            os.remove(sh.path)
            shells[tty] = nil
            M.links[tty] = nil
        end
    end

    for tty, link in pairs(M.links) do
        if not shells[tty] or not tabs[link.id] then M.links[tty] = nil end
    end

    local byCwd = terminalsByCwd(tabs)
    local taken = claimedIds(shells)

    for tty, sh in pairs(shells) do
        if not M.links[tty] then
            local free = {}
            for _, id in ipairs(byCwd[sh.cwd or ""] or {}) do
                if not taken[id] then table.insert(free, id) end
            end
            if #free == 1 then
                M.links[tty] = { id = free[1], cwd = sh.cwd }
                taken[free[1]] = tty
            end
        end
    end

    return M.links
end

function M.idForTty(tty)
    local link = M.links[tty]
    return link and link.id or nil
end

function M.ttyForId(id)
    for tty, link in pairs(M.links) do
        if link.id == id then return tty end
    end
    return nil
end

return M
