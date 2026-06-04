-- Floating candidate bar for SKK candidate selection.
-- Non-toast: intercepts taps in its own area so candidates can be
-- selected by tapping.  The keyboard below is unaffected because it
-- occupies a different screen region.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")

local FACE      = Font:getFace("cfont", 18)
local PAGE_SIZE = 9

local SKKCandidateBar = InputContainer:extend{
    -- NOT toast: we handle taps to select candidates directly.
    -- is_always_active so taps reach us even though VirtualKeyboard (modal=true)
    -- sits above us on the window stack — without this flag UIManager:sendEvent
    -- never gives the bar a chance to consume taps in its area.
    is_always_active = true,
    bordersize  = Size.border.window,
    background  = Blitbuffer.COLOR_WHITE,
    padding     = Size.padding.small,
    candidates  = nil,
    page_start  = 1,
    current_idx = 1,
    on_select   = nil,  -- callback(abs_idx) called when a candidate is tapped
    on_next_page = nil, -- callback called when ▶ is tapped
    on_prev_page = nil, -- callback called when ◀ is tapped
}

local SLOT_PAD_X = Size.padding.large

function SKKCandidateBar:init()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
    self:_rebuild()
end

function SKKCandidateBar:onTapSelect(_, ges)
    local meta = self._slot_meta or {}
    if #meta == 0 then return true end
    local offsets = self._slot_offsets or {}
    local bar_x   = (self.dimen and self.dimen.x) or 0
    local inner_x = bar_x + Size.border.window + self.padding
    local tap_x   = ges.pos.x - inner_x

    for i = 1, #meta do
        if tap_x >= (offsets[i] or 0) and tap_x < (offsets[i+1] or 0) then
            local m = meta[i]
            if m.kind == "cand" and self.on_select then
                self.on_select(m.abs_idx)
            elseif m.kind == "next" and self.on_next_page then
                self.on_next_page()
            elseif m.kind == "prev" and self.on_prev_page then
                self.on_prev_page()
            end
            return true
        end
    end
    return true  -- consume all taps in bar area
end

function SKKCandidateBar:_rebuild()
    local screen_w = Device.screen:getWidth()
    local cands    = self.candidates or {}
    local n_shown  = math.min(PAGE_SIZE, #cands - self.page_start + 1)
    local has_next = #cands > self.page_start + PAGE_SIZE - 1
    local has_prev = self.page_start > 1
    local frame_overhead = 2 * (Size.border.window + self.padding)
    local inner_w  = screen_w - frame_overhead

    local probe    = TextWidget:new{ text = "あ", face = FACE }
    local slot_h   = probe:getSize().h
    probe:free()
    local underline_h = Size.line.thick + 2 * Size.padding.tiny
    local cell_h      = slot_h + underline_h

    -- Arrow slots have a fixed width so the present arrow always sits at its
    -- screen edge; an absent arrow leaves no space — candidates simply pack
    -- toward that side.
    local arrow_probe   = TextWidget:new{ text = "◀", face = FACE }
    local arrow_slot_w  = arrow_probe:getSize().w + 2 * SLOT_PAD_X
    arrow_probe:free()
    local left_arrow_w  = has_prev and arrow_slot_w or 0
    local right_arrow_w = has_next and arrow_slot_w or 0
    local middle_w      = math.max(0, inner_w - left_arrow_w - right_arrow_w)

    -- Measure each candidate's natural width.
    local cand_items = {}
    for i = self.page_start, self.page_start + n_shown - 1 do
        local n   = i - self.page_start + 1
        local sel = (i == self.current_idx)
        local tw  = TextWidget:new{
            text = n .. ":" .. cands[i],
            face = FACE,
            bold = sel,
        }
        cand_items[#cand_items+1] = {
            tw = tw, w = tw:getSize().w, sel = sel,
            kind = "cand", abs_idx = i,
        }
    end

    -- Candidate slot widths: natural + padding when they fit, equal share of
    -- middle_w otherwise.
    local cands_natural = 0
    for _, it in ipairs(cand_items) do
        cands_natural = cands_natural + it.w + 2 * SLOT_PAD_X
    end
    local use_equal = n_shown > 0 and cands_natural > middle_w
    local equal_w   = n_shown > 0 and math.floor(middle_w / n_shown) or 0
    local cands_total = 0
    for _, it in ipairs(cand_items) do
        if use_equal then
            it.slot_w = equal_w
            it.tw.max_width = equal_w - 2
        else
            it.slot_w = it.w + 2 * SLOT_PAD_X
        end
        cands_total = cands_total + it.slot_w
    end

    local hg = HorizontalGroup:new{}
    self._slot_offsets = { 0 }
    self._slot_meta    = {}
    local cursor = 0

    local function append_slot(width, meta, cell)
        if cell then
            table.insert(hg, CenterContainer:new{
                dimen = Geom:new{ w = width, h = cell_h },
                cell,
            })
        else
            table.insert(hg, HorizontalSpan:new{ width = width })
        end
        cursor = cursor + width
        self._slot_offsets[#self._slot_offsets+1] = cursor
        self._slot_meta[#self._slot_meta+1] = meta
    end

    -- Left arrow (only when there's a previous page).
    if has_prev then
        local tw = TextWidget:new{ text = "◀", face = FACE }
        append_slot(arrow_slot_w, { kind = "prev" }, tw)
    end

    -- Candidates.
    for _, it in ipairs(cand_items) do
        local cell = UnderlineContainer:new{
            color = it.sel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            it.tw,
        }
        append_slot(it.slot_w, it, cell)
    end

    -- Pad to fill the bar. When ▶ is present, the pad sits before it so ▶
    -- still hugs the right edge; otherwise the pad just trails the last
    -- candidate (still needed so the FrameContainer spans the full width and
    -- previous-frame pixels don't bleed through on rebuild).
    local pad_w = inner_w - cursor - right_arrow_w
    if pad_w > 0 then
        append_slot(pad_w, { kind = "blank" }, nil)
    end

    -- Right arrow (only when there's a next page).
    if has_next then
        local tw = TextWidget:new{ text = "▶", face = FACE }
        append_slot(arrow_slot_w, { kind = "next" }, tw)
    end

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding    = self.padding,
        hg,
    }
end

function SKKCandidateBar:update(candidates, current_idx, page_start)
    self.candidates  = candidates
    self.current_idx = current_idx or 1
    self.page_start  = page_start  or 1
    self:_rebuild()
    -- Refresh dimen.w/h to match the new self[1] size so the tap GestureRange
    -- stays aligned with the rendered bar (slot widths can change between pages).
    if self.dimen and self[1] then
        local s = self[1]:getSize()
        self.dimen.w = s.w
        self.dimen.h = s.h
    end
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
