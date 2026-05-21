-- Floating candidate bar for SKK candidate selection.
-- Rendered as a toast (events pass through) so it does not block input.
-- Position is caller-determined; use SKKCandidateBar:showAbove(y_bottom).

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Size           = require("ui/size")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")

local FACE      = Font:getFace("cfont", 18)
local PAGE_SIZE = 9

local SKKCandidateBar = FrameContainer:extend{
    toast       = true,
    bordersize  = Size.border.window,
    background  = Blitbuffer.COLOR_WHITE,
    padding     = Size.padding.small,
    candidates  = nil,
    page_start  = 1,
    current_idx = 1,
}

function SKKCandidateBar:init()
    self:_rebuild()
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
    self[1] = TextWidget:new{
        text      = table.concat(parts),
        face      = FACE,
        max_width = w - 2 * Size.border.window - 2 * self.padding,
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
    UIManager:show(self, "ui", nil, 0, y)
end

SKKCandidateBar.PAGE_SIZE = PAGE_SIZE

return SKKCandidateBar
