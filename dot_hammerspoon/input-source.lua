-- Layout switching on a tapped left shift (ABC) / right shift (Russian).
--
-- Two keys rather than one toggle: a toggle desynchronises whenever macOS
-- changes the layout behind your back (per-app memory, a swallowed press),
-- and then the key does the opposite of what you wanted.
--
-- Karabiner turns the taps into f18/f19; shift used as a modifier is passed
-- through untouched, so nothing here sees ordinary capitalisation.

local M = {}

local ABC = "com.apple.keylayout.ABC"
local RUSSIAN = "com.apple.keylayout.Russian"

-- setLayout takes the menu name, not the source id above.
local NAMES = { [ABC] = "ABC", [RUSSIAN] = "Russian" }

-- setLayout is a no-op when a text field has a stale input context, so the
-- result is read back and retried once on the next runloop turn.
local function select(id)
    local name = NAMES[id]
    if hs.keycodes.currentSourceID() == id then return end

    hs.keycodes.setLayout(name)

    hs.timer.doAfter(0.05, function()
        if hs.keycodes.currentSourceID() ~= id then
            hs.keycodes.currentSourceID(id)
        end
    end)
end

function M.start()
    M.hotkeys = {
        hs.hotkey.bind({}, "f18", function() select(ABC) end),
        hs.hotkey.bind({}, "f19", function() select(RUSSIAN) end),
    }
    return M
end

return M
