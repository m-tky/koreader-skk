-- SKK-capable InputText subclass.
-- Works in both SDL (emulator) and physical-keyboard modes.
--
-- SDL mode:  printable chars arrive via onTextInput; shift detection via onKeyPress.
-- Other mode: all input arrives via onKeyPress.
--
-- State machine:
--   KANA     – romaji → hiragana direct insertion
--   KATAKANA – romaji → katakana direct insertion
--   CONV     – ▽ reading accumulation; Space → SELECTING
--   SELECT   – ▼ candidate cycling; Enter → commit

local Device = require("device")
local InputText = require("ui/widget/inputtext")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")

local Romaji = require("skk_romaji")
local Dict = require("skk_dictionary")
local CandidateBar = require("skk_candidate_bar")

local ST_KANA     = "kana"
local ST_KATAKANA = "katakana"
local ST_CONV     = "conv"
local ST_SELECT   = "select"

local MARK_CONV   = "▽"
local MARK_SELECT = "▼"

-- ----------------------------------------------------------------
-- SKKInputText
-- ----------------------------------------------------------------
local SKKInputText = InputText:extend{
    _skk_enabled         = false,
    _state               = ST_KANA,
    _romaji_buf          = "",
    _reading             = "",
    _candidates          = nil,
    _cand_idx            = 1,
    _cand_page           = 1,
    -- Preedit is tracked as (start index in charlist, exact chars inserted).
    -- This survives cursor movement and lets us bail out cleanly if the user
    -- edits inside the preedit region (rather than deleting the wrong chars).
    _preedit_start       = nil,
    _preedit_chars       = nil,
    _bar                 = nil,
    -- Set to the time.now() value at which a Shift+letter onKeyPress fired.
    -- The matching SDL onTextInput should arrive within a few ms; older values
    -- are stale and ignored so we never swallow an unrelated future char.
    _skip_textinput_at   = nil,
}

local SKIP_TEXTINPUT_WINDOW = time.ms(50)

local function preeditLen(self)
    return self._preedit_chars and #self._preedit_chars or 0
end

---------------------------------------------------------------------------
-- Preedit helpers
---------------------------------------------------------------------------

function SKKInputText:_clearPreedit()
    local pe = self._preedit_chars
    if not pe or #pe == 0 then
        self._preedit_chars = nil
        self._preedit_start = nil
        return
    end
    local start = self._preedit_start or 0
    -- Verify the slice in charlist still matches what we inserted. If the
    -- user moved the cursor and typed inside the preedit, the slice no
    -- longer matches — orphan our tracking rather than delete the wrong chars.
    if start < 1 or start + #pe - 1 > #self.charlist then
        self._preedit_chars = nil
        self._preedit_start = nil
        return
    end
    for i = 1, #pe do
        if self.charlist[start + i - 1] ~= pe[i] then
            self._preedit_chars = nil
            self._preedit_start = nil
            return
        end
    end
    for _ = 1, #pe do
        table.remove(self.charlist, start)
    end
    if self.charpos >= start + #pe then
        self.charpos = self.charpos - #pe
    elseif self.charpos > start then
        self.charpos = start
    end
    self._preedit_chars = nil
    self._preedit_start = nil
    self.is_text_edited = true
    self:initTextBox(nil, false)
end

function SKKInputText:_setPreedit(text)
    self:_clearPreedit()
    if text and text ~= "" then
        self._preedit_start = self.charpos
        self._preedit_chars = util.splitToChars(text)
        InputText.addChars(self, text)
    end
end

function SKKInputText:_commit(text)
    self:_clearPreedit()
    if text and text ~= "" then
        InputText.addChars(self, text)
    end
end

function SKKInputText:_preeditText()
    if self._state == ST_KANA or self._state == ST_KATAKANA then
        return self._romaji_buf
    elseif self._state == ST_CONV then
        return MARK_CONV .. self._reading .. self._romaji_buf
    elseif self._state == ST_SELECT then
        local sel   = self._candidates and self._candidates[self._cand_idx] or ""
        local okuri = self._romaji_buf ~= "" and ("*"..self._romaji_buf) or ""
        return MARK_SELECT .. sel .. okuri
    end
    return ""
end

function SKKInputText:_refreshPreedit()
    self:_setPreedit(self:_preeditText())
end

---------------------------------------------------------------------------
-- Candidate bar helpers
---------------------------------------------------------------------------

function SKKInputText:_showCandidateBar()
    local Screen = Device.screen
    if not self._bar then
        local this = self
        self._bar = CandidateBar:new{
            candidates  = self._candidates,
            current_idx = self._cand_idx,
            page_start  = self._cand_page,
            on_select   = function(abs_idx)
                if this._candidates and this._candidates[abs_idx] then
                    this._cand_idx = abs_idx
                    this:_commitCandidate()
                end
            end,
        }
        -- showAt() sets self.dimen before showing so taps inside the bar
        -- actually match its GestureRange (dimen.y defaults to 0 otherwise).
        local bar_h = self._bar:getSize().h
        self._bar:showAt(Screen:getHeight() - bar_h)
    else
        self._bar:update(self._candidates, self._cand_idx, self._cand_page)
    end
end

function SKKInputText:_closeCandidateBar()
    if self._bar then
        UIManager:close(self._bar, "ui")
        self._bar = nil
    end
end

---------------------------------------------------------------------------
-- Romaji processing
---------------------------------------------------------------------------

-- Commit one romaji char in direct kana/katakana mode.
function SKKInputText:_processRomajiDirect(ch)
    local committed, new_buf = Romaji.processChar(self._romaji_buf, ch)
    self._romaji_buf = new_buf
    if committed and committed ~= "" then
        if self._state == ST_KATAKANA then
            committed = Romaji.toKatakana(committed)
        end
        self:_clearPreedit()
        InputText.addChars(self, committed)
        if new_buf ~= "" then
            self:_setPreedit(new_buf)
        end
    else
        self:_setPreedit(new_buf)
    end
end

-- Accumulate one romaji char into the reading (▽ mode).
function SKKInputText:_processRomajiReading(ch)
    local committed, new_buf = Romaji.processChar(self._romaji_buf, ch)
    self._romaji_buf = new_buf
    if committed and committed ~= "" then
        self._reading = self._reading .. committed
    end
    self:_refreshPreedit()
end

---------------------------------------------------------------------------
-- Conversion / candidate helpers
---------------------------------------------------------------------------

function SKKInputText:_triggerConversion()
    local flushed = Romaji.flush(self._romaji_buf)
    self._romaji_buf = ""
    local query = self._reading .. flushed
    if query == "" then
        self._state = ST_KANA
        self:_clearPreedit()
        return
    end
    self._reading = query
    if not Dict.isReady() then
        -- Don't fall through to a "register new word" prompt while the DB is
        -- still being built; the lookup would return {} for everything.
        UIManager:show(require("ui/widget/notification"):new{
            text = Dict.isBuilding()
                and _("SKK: dictionary still preparing…")
                or  _("SKK: dictionary unavailable."),
            timeout = 2,
        })
        self:_refreshPreedit()
        return
    end
    local cands = Dict.lookup(query)
    if #cands == 0 then
        self:_showRegisterPrompt(query)
        return
    end
    self._candidates = cands
    self._cand_idx   = 1
    self._cand_page  = 1
    self._state      = ST_SELECT
    self:_refreshPreedit()
    self:_showCandidateBar()
end

function SKKInputText:_showRegisterPrompt(reading)
    -- Reset conversion state before showing the dialog.
    self._state      = ST_KANA
    self._reading    = ""
    self._romaji_buf = ""
    self:_clearPreedit()
    local InputDialog = require("ui/widget/inputdialog")
    local reg_dialog
    reg_dialog = InputDialog:new{
        title = _("Register") .. ": " .. reading,
        description = _("No candidates found. Enter the kanji to register:"),
        input = "",
        input_hint = _("kanji"),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(reg_dialog) end,
            },
            {
                text = _("Register"),
                is_enter_default = true,
                callback = function()
                    local kanji = reg_dialog:getInputText()
                    UIManager:close(reg_dialog)
                    if kanji and kanji ~= "" then
                        Dict.register(reading, kanji)
                        InputText.addChars(self, kanji)
                    end
                end,
            },
        }},
    }
    UIManager:show(reg_dialog)
end

function SKKInputText:_commitCandidate()
    local cand = (self._candidates and self._candidates[self._cand_idx]) or ""
    local saved_buf = self._romaji_buf  -- preserve okurigana consonant (e.g. "b")
    -- Track usage before clearing reading.
    if self._reading ~= "" and cand ~= "" then
        Dict.register(self._reading, cand)
    end
    self:_closeCandidateBar()
    self._state      = ST_KANA
    self._reading    = ""
    self._candidates = nil
    self._cand_idx   = 1
    self._cand_page  = 1
    self._romaji_buf = saved_buf
    self:_commit(cand)
    if saved_buf ~= "" then self:_setPreedit(saved_buf) end
end

function SKKInputText:_cancelSelection()
    self:_closeCandidateBar()
    self._state      = ST_CONV
    self._candidates = nil
    self._cand_idx   = 1
    self._cand_page  = 1
    self:_refreshPreedit()
end

function SKKInputText:_nextCandidate()
    if not self._candidates then return end
    self._cand_idx = math.min(self._cand_idx + 1, #self._candidates)
    if self._cand_idx >= self._cand_page + Dict.PAGE_SIZE then
        self._cand_page = self._cand_page + Dict.PAGE_SIZE
    end
    self:_refreshPreedit()
    self:_showCandidateBar()
end

function SKKInputText:_prevCandidate()
    if not self._candidates then return end
    self._cand_idx = math.max(1, self._cand_idx - 1)
    if self._cand_idx < self._cand_page then
        self._cand_page = math.max(1, self._cand_page - Dict.PAGE_SIZE)
    end
    self:_refreshPreedit()
    self:_showCandidateBar()
end

---------------------------------------------------------------------------
-- Core character dispatcher (called from both onKeyPress and onTextInput)
---------------------------------------------------------------------------

-- Process a single displayable character through the SKK state machine.
-- Returns true if consumed by SKK.
function SKKInputText:_processChar(ch)
    -- ---- KANA / KATAKANA ----
    if self._state == ST_KANA or self._state == ST_KATAKANA then
        if ch == " " then
            -- Space: flush buffer, insert regular space
            local flushed = Romaji.flush(self._romaji_buf)
            self._romaji_buf = ""
            self:_clearPreedit()
            if flushed ~= "" then
                if self._state == ST_KATAKANA then flushed = Romaji.toKatakana(flushed) end
                InputText.addChars(self, flushed)
            end
            InputText.addChars(self, " ")
            return true
        elseif ch == "q" then
            -- Toggle hiragana ↔ katakana
            local flushed = Romaji.flush(self._romaji_buf)
            self._romaji_buf = ""
            self:_clearPreedit()
            if flushed ~= "" then
                if self._state == ST_KATAKANA then flushed = Romaji.toKatakana(flushed) end
                InputText.addChars(self, flushed)
            end
            self._state = (self._state == ST_KATAKANA) and ST_KANA or ST_KATAKANA
            return true
        elseif ch == "l" then
            -- Disable SKK (ASCII mode)
            local flushed = Romaji.flush(self._romaji_buf)
            self._romaji_buf = ""
            self:_clearPreedit()
            if flushed ~= "" then InputText.addChars(self, flushed) end
            self._skk_enabled = false
            UIManager:show(require("ui/widget/notification"):new{
                text = _("SKK off – press Ctrl+\\ to re-enable"),
                timeout = 2,
            })
            return true
        else
            self:_processRomajiDirect(ch)
            return true
        end
    end

    -- ---- CONV (▽ mode) ----
    if self._state == ST_CONV then
        if ch == " " then
            self:_triggerConversion()
            return true
        elseif ch == "q" then
            -- Commit reading as katakana
            local kata = Romaji.toKatakana(self._reading .. Romaji.flush(self._romaji_buf))
            self._romaji_buf = ""
            self._reading = ""
            self._state = ST_KANA
            self:_commit(kata)
            return true
        else
            self:_processRomajiReading(ch)
            return true
        end
    end

    -- ---- SELECT (▼ mode) ----
    if self._state == ST_SELECT then
        if ch == " " or ch == "n" then
            self:_nextCandidate()
            return true
        elseif ch == "p" then
            self:_prevCandidate()
            return true
        elseif ch == "x" then
            self:_cancelSelection()
            return true
        else
            local n = tonumber(ch)
            if n and n >= 1 and n <= Dict.PAGE_SIZE then
                local idx = self._cand_page + n - 1
                if idx <= #self._candidates then
                    self._cand_idx = idx
                end
                self:_commitCandidate()
                return true
            end
            -- Unknown char: commit current candidate then reprocess in new state
            self:_commitCandidate()
            return self:_processChar(ch)
        end
    end

    return false
end

---------------------------------------------------------------------------
-- Start conversion mode (▽) – used from both onKeyPress (Shift+letter)
---------------------------------------------------------------------------

function SKKInputText:_startConvMode(first_lower_char)
    -- Flush any current kana preedit into committed text
    local flushed = Romaji.flush(self._romaji_buf)
    self._romaji_buf = ""
    self:_clearPreedit()
    if flushed ~= "" then
        if self._state == ST_KATAKANA then flushed = Romaji.toKatakana(flushed) end
        InputText.addChars(self, flushed)
    end
    self._state   = ST_CONV
    self._reading = ""
    self:_processRomajiReading(first_lower_char)
end

---------------------------------------------------------------------------
-- SKK toggle
---------------------------------------------------------------------------

function SKKInputText:_toggleSKK()
    self._skk_enabled = not self._skk_enabled
    if not self._skk_enabled then
        local flushed = Romaji.flush(self._romaji_buf)
        self._romaji_buf = ""
        self:_clearPreedit()
        self:_closeCandidateBar()
        self._state = ST_KANA
        if flushed ~= "" then InputText.addChars(self, flushed) end
    end
end

---------------------------------------------------------------------------
-- Handle non-printable / special keys (shared by all states)
-- Returns true if handled, false to delegate to parent.
---------------------------------------------------------------------------

function SKKInputText:_handleSpecialKey(key, key_str, ctrl)
    local state = self._state

    -- Backspace / Ctrl+H
    if key["Backspace"] or (ctrl and key_str == "H") then
        if self._romaji_buf ~= "" then
            self._romaji_buf = self._romaji_buf:sub(1, -2)
            self:_refreshPreedit()
            return true
        end
        if state == ST_CONV then
            local chars = util.splitToChars(self._reading)
            if #chars > 0 then
                table.remove(chars)
                self._reading = table.concat(chars)
                self:_refreshPreedit()
            else
                self._state = ST_KANA
                self:_clearPreedit()
            end
            return true
        end
        if state == ST_SELECT then
            self:_cancelSelection()
            return true
        end
        return false  -- let parent delete committed char
    end

    -- Enter
    if key["Press"] then
        if state == ST_KANA or state == ST_KATAKANA then
            local flushed = Romaji.flush(self._romaji_buf)
            self._romaji_buf = ""
            self:_clearPreedit()
            if flushed ~= "" then
                if state == ST_KATAKANA then flushed = Romaji.toKatakana(flushed) end
                InputText.addChars(self, flushed)
            end
            return false  -- let parent handle the Enter action
        end
        if state == ST_CONV then
            -- Commit reading as kana
            local reading = self._reading .. Romaji.flush(self._romaji_buf)
            self._romaji_buf = ""
            self._reading = ""
            self._state = ST_KANA
            self:_commit(reading)
            return true
        end
        if state == ST_SELECT then
            self:_commitCandidate()
            return true
        end
    end

    -- Back / Escape
    if key["Back"] then
        if state == ST_CONV or state == ST_SELECT then
            if state == ST_SELECT then self:_closeCandidateBar() end
            self._state      = ST_KANA
            self._reading    = ""
            self._candidates = nil
            self._romaji_buf = ""
            self:_clearPreedit()
            return true
        end
        if self._romaji_buf ~= "" then
            self._romaji_buf = ""
            self:_clearPreedit()
            return true
        end
        return false
    end

    return false
end

---------------------------------------------------------------------------
-- onKeyPress override
---------------------------------------------------------------------------

function SKKInputText:onKeyPress(key)
    local key_str = key.key or ""
    local shift   = key["Shift"]
    local ctrl    = key["Ctrl"] or key["Alt"]

    -- Ctrl+\ : toggle SKK (always active, even when disabled)
    if ctrl and not shift and key_str == "\\" then
        self:_toggleSKK()
        return true
    end

    if not self._skk_enabled then
        return InputText.onKeyPress(self, key)
    end

    -- Shift+letter: start kanji conversion mode.
    -- Must be handled in onKeyPress because TextInput carries no modifier info.
    if shift and not ctrl and #key_str == 1 and key_str:match("[A-Z]") then
        local state = self._state
        if state == ST_KANA or state == ST_KATAKANA then
            self:_startConvMode(key_str:lower())
            -- In SDL mode the corresponding TextInput event ("K") must be suppressed.
            self._skip_textinput_at = Device:isSDL() and time.now() or nil
            return true
        end
        if state == ST_CONV then
            -- Okurigana: look up reading+consonant, enter SELECT if candidates found
            local reading = self._reading .. Romaji.flush(self._romaji_buf)
            self._romaji_buf = key_str:lower()
            if reading ~= "" then
                self._reading = reading
                local cands = Dict.lookup(reading .. key_str:lower())
                if #cands == 0 then cands = Dict.lookup(reading) end
                if #cands > 0 then
                    self._candidates = cands
                    self._cand_idx   = 1
                    self._cand_page  = 1
                    self._state      = ST_SELECT
                end
            end
            self:_refreshPreedit()
            if self._state == ST_SELECT then self:_showCandidateBar() end
            self._skip_textinput_at = Device:isSDL() and time.now() or nil
            return true
        end
    end

    -- Non-printable / special keys
    if self:_handleSpecialKey(key, key_str, ctrl) then
        return true
    end

    -- In non-SDL mode, printable single chars are handled here.
    if not Device:isSDL() and not ctrl and #key_str == 1 then
        local ch = shift and key_str or key_str:lower()
        if self:_processChar(ch) then return true end
    end

    -- Delegate everything else (arrows, Home, End, Ctrl+U, etc.) to parent.
    return InputText.onKeyPress(self, key)
end

---------------------------------------------------------------------------
-- onTextInput override (SDL mode: printable chars arrive here)
---------------------------------------------------------------------------

function SKKInputText:onTextInput(text)
    if not self.focused then return false end

    if not self._skk_enabled then
        return InputText.onTextInput(self, text)
    end

    -- Suppress TextInput that was already handled in onKeyPress (Shift+letter).
    -- Only honor the flag if the keypress just happened (within ~50ms); stale
    -- timestamps from an aborted sequence are ignored so we never eat an
    -- unrelated future character.
    if self._skip_textinput_at then
        local age = time.since(self._skip_textinput_at)
        self._skip_textinput_at = nil
        if age < SKIP_TEXTINPUT_WINDOW then
            return true
        end
    end

    -- Route every received character through the SKK engine.
    for _, ch in ipairs(util.splitToChars(text)) do
        -- Treat uppercase as possible shift-triggered chars. In SDL mode,
        -- shift+letter fires as TextInput("K"), but we already handle that
        -- conversion-start in onKeyPress. What arrives here as uppercase is
        -- text that genuinely should be uppercased (e.g., from a soft keyboard).
        -- In that case just downcase and process through romaji; full-width
        -- uppercase can be handled later.
        local lower_ch = ch:lower()
        if lower_ch ~= ch then
            -- Uppercase letter that wasn't caught in onKeyPress (e.g., direct paste)
            -- Treat as conversion trigger the same way.
            local state = self._state
            if state == ST_KANA or state == ST_KATAKANA then
                self:_startConvMode(lower_ch)
            else
                self:_processChar(lower_ch)
            end
        else
            self:_processChar(ch)
        end
    end
    return true
end

---------------------------------------------------------------------------
-- getText override: strip preedit so callers get only committed text
---------------------------------------------------------------------------

function SKKInputText:getText()
    local pe = self._preedit_chars
    if not pe or #pe == 0 then
        return InputText.getText(self)
    end
    local start = self._preedit_start or 0
    local last  = start + #pe - 1
    local out = {}
    for i = 1, #self.charlist do
        if i < start or i > last then
            out[#out+1] = self.charlist[i]
        end
    end
    return table.concat(out)
end

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

function SKKInputText:onCloseWidget()
    -- Commit any pending composition
    if preeditLen(self) > 0 then
        local reading = self._reading .. Romaji.flush(self._romaji_buf)
        self._romaji_buf = ""
        self._reading = ""
        self:_commit(reading ~= "" and reading or nil)
    end
    self:_closeCandidateBar()
    InputText.onCloseWidget(self)
end

return SKKInputText
