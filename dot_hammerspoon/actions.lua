-- Searchable palette of clipboard/text actions, bound globally so Slack and
-- the browser get them too. Add an entry to ACTIONS and it shows up.

local M = {}

local JQ = "/opt/homebrew/bin/jq"
local INFLATE_FILTER = os.getenv("HOME") .. "/.config/zed/json-inflate.jq"

-- hs.alert over hs.notify: a script's notifications never banner, they only
-- pile up in the Notification Center.
local function fail(msg)
  hs.alert.show(msg:gsub("^jq: ", ""):gsub("%s+$", ""), 3)
end

-- hs.task, not hs.execute: the latter blocks the UI runloop while jq runs.
local function pipeClipboard(args, label)
  local input = hs.pasteboard.getContents()
  if not input or input == "" then
    fail("clipboard is empty")
    return
  end

  local task = hs.task.new(JQ, function(code, stdout, stderr)
    if code ~= 0 then
      fail(stderr)
      return
    end
    hs.pasteboard.setContents(stdout)
    local _, lines = stdout:gsub("\n", "")
    hs.alert.show(label .. " — " .. lines .. " lines copied", 1)
  end, args)

  task:setInput(input)
  task:start()
end

local ACTIONS = {
  {
    text = "JSON: inflate",
    subText = "expand escaped JSON-in-a-string on the clipboard",
    run = function() pipeClipboard({ "-f", INFLATE_FILTER }, "JSON inflated") end,
  },
  {
    text = "JSON: deflate body",
    subText = "re-escape .body back into a string",
    run = function() pipeClipboard({ "-c", ".body |= tojson" }, "JSON deflated") end,
  },
  {
    text = "JSON: format",
    subText = "pretty-print the clipboard",
    run = function() pipeClipboard({ "." }, "JSON formatted") end,
  },
  {
    text = "JSON: minify",
    subText = "collapse the clipboard to one line",
    run = function() pipeClipboard({ "-c", "." }, "JSON minified") end,
  },
}

function M.bind(mods, key)
  local chooser = hs.chooser.new(function(choice)
    if choice then ACTIONS[choice.idx].run() end
  end)

  local rows = {}
  for i, a in ipairs(ACTIONS) do
    rows[i] = { text = a.text, subText = a.subText, idx = i }
  end
  chooser:choices(rows)
  chooser:searchSubText(true)

  M.hotkey = hs.hotkey.bind(mods, key, function() chooser:show() end)
  return M
end

return M
