-- Floating candidate bar for SKK candidate selection.
-- Non-toast: intercepts taps in its own area so candidates can be
-- selected by tapping.  The keyboard below is unaffected because it
-- occupies a different screen region.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size           = require("ui/size")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")

local FACE      = Font:getFace("cfont", 18)
local PAGE_SIZE = 9

local SKKCandidateBar = InputContainer:extend{
    -- NOT toast: we handle taps to select candidates directly.
    bordersize  = Size.border.window,
    background  = Blitbuffer.COLOR_WHITE,
    padding     = Size.padding.small,
    candidates  = nil,
    page_start  = 1,
    current_idx = 1,
    on_select   = nil,  -- callback(abs_idx) called when a candidate is tapped
}

function SKKCandidateBar:init()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
    self:_rebuild()
end

function SKKCandidateBar:onTapSelect(_, ges)
    local cands   = self.candidates or {}
    local n_shown = math.min(PAGE_SIZE, #cands - self.page_start + 1)
    if n_shown <= 0 or not self.on_select then return true end
    -- Divide bar width into equal slots and map tap x to candidate index.
    local bar_w   = self.dimen and self.dimen.w or Device.screen:getWidth()
    local slot_w  = bar_w / n_shown
    local tap_x   = ges.pos.x  -- bar always starts at x = 0
    local slot    = math.floor(tap_x / slot_w) + 1
    if slot >= 1 and slot <= n_shown then
        local abs_idx = self.page_start + slot - 1
        if cands[abs_idx] then
            self.on_select(abs_idx)
        end
    end
    return true  -- consume all taps in bar area
end

function SKKCandidateBar:_rebuild()
    local w     = Device.screen:getWidth()
    local cands = self.candidates or {}
    local parts = {}
    for i = self.page_start, math.min(self.page_start + PAGE_SIZE - 1, #cands) do
        local n   = i - self.page_start + 1
        local sel = (i == self.current_idx)
        table.insert(parts,
            (sel and "【" or "  ") .. n .. ":" .. cands[i] ..
            (sel and "】" or "  "))
    end
    if #cands > self.page_start + PAGE_SIZE - 1 then
        table.insert(parts, " ▶")
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding    = self.padding,
        TextWidget:new{
            text      = table.concat(parts),
            face      = FACE,
            max_width = w - 4 * Size.border.window - 2 * self.padding,
        },
    }
end

function SKKCandidateBar:update(candidates, current_idx, page_start)
    self.candidates  = candidates
    self.current_idx = current_idx or 1
    self.page_start  = page_start  or 1
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Show at a fixed y position (top-left origin).
function SKKCandidateBar:showAt(y)
    -- Set self.dimen with the real screen position BEFORE UIManager:show so
    -- GestureRange:match() uses the correct y coordinate.  Without this,
    -- dimen.y defaults to 0 and taps on the bar (at y≈900) never match,
    -- causing events to fall through to the inputbox instead.
    local size = self:getSize()
    self.dimen = Geom:new{ x = 0, y = y, w = size.w, h = size.h }
    UIManager:show(self, "ui", nil, 0, y)
end

SKKCandidateBar.PAGE_SIZE = PAGE_SIZE

return SKKCandidateBar
