--[[--
SKK (Simple Kana to Kanji) keyboard layout for KOReader's VirtualKeyboard.

Candidate selection:
  Row 1 in SELECT mode → shows "1"–"9" number keys for direct selection.
  A floating candidate bar appears above the keyboard showing all candidates.
  Inline preedit shows only the current candidate: ▼漢字 (or ▼食*b for okurigana).
  Space cycles candidates; Enter commits; x cancels.

Modes (あ/A key bottom row):
  あ – romaji → hiragana (default)
  ア – romaji → katakana
  A  – ASCII pass-through
]]

local Device    = require("device")
local UIManager = require("ui/uimanager")
local SKKCandidateBar = require("skk_candidate_bar")
local logger          = require("logger")
local util            = require("util")
local _               = require("gettext")

-- ----------------------------------------------------------------
-- SKK engine modules — shipped together with this keyboard layout in
-- skk.koplugin, so no fallback is needed.
-- ----------------------------------------------------------------
local Romaji = require("skk_romaji")
local Dict   = require("skk_dictionary")

local processChar  = Romaji.processChar
local flushRomaji  = Romaji.flush
local toKatakana   = Romaji.toKatakana

-- ----------------------------------------------------------------
-- Special key token
-- ----------------------------------------------------------------
local SKK_MODE = "SKK_MODE"

-- ----------------------------------------------------------------
-- Persistent global state
-- ----------------------------------------------------------------
_G._skk_vkbd_state = _G._skk_vkbd_state or {}
local S = _G._skk_vkbd_state
S.cands    = S.cands    or {}
S.page     = S.page     or 1
S.mode     = S.mode     or "kana"
S.ib       = S.ib       or nil
S.select   = S.select   or false   -- true while in SELECT mode
S.bar      = S.bar      or nil     -- SKKCandidateBar widget (survives rebuildKeyboard)

local CANDS_PER_PAGE = Dict.PAGE_SIZE

-- ----------------------------------------------------------------
-- Keyboard rebuild (mode changes only)
-- ----------------------------------------------------------------
local function rebuildKeyboard()
    local ib = S.ib
    if not (ib and ib.keyboard) then return end
    UIManager:nextTick(function()
        -- Clear both the VirtualKeyboard require path and the plugin module so
        -- genFirstRow() is re-evaluated with the current S.select / S.mode state.
        package.loaded["ui/data/keyboardlayouts/ja_skk_keyboard"] = nil
        package.loaded["ja_skk_keyboard"] = nil
        ib.keyboard:setKeyboardLayout("js")
    end)
end

-- ----------------------------------------------------------------
-- Row 1 generator:
--   SELECT mode → number keys "1"–"9" for direct candidate selection
--   normal mode → mode indicator + Japanese punctuation
-- ----------------------------------------------------------------
local function genFirstRow()
    local mode = S.mode or "kana"
    local lbl  = mode=="kana" and "あ" or mode=="katakana" and "ア" or "A"

    if S.select then
        -- Number keys for candidate selection
        return {
            {"1","1","1","1"}, {"2","2","2","2"}, {"3","3","3","3"},
            {"4","4","4","4"}, {"5","5","5","5"}, {"6","6","6","6"},
            {"7","7","7","7"}, {"8","8","8","8"}, {"9","9","9","9"},
            {"x","x","x","x", label="✕"},   -- cancel selection
        }
    else
        return {
            {SKK_MODE,SKK_MODE,SKK_MODE,SKK_MODE, label=lbl, bold=true},
            {"、","、","、","、"}, {"。","。","。","。"}, {"・","・","・","・"},
            {"「","「","「","「"}, {"」","」","」","」"}, {"ー","ー","ー","ー"},
            {"〜","〜","〜","〜"}, {"？","？","？","？"}, {"！","！","！","！"},
        }
    end
end

-- ----------------------------------------------------------------
-- wrapInputBox
-- ----------------------------------------------------------------
local function wrapInputBox(inputbox)
    S.ib = inputbox
    if inputbox._skk_mode and inputbox._skk_mode ~= S.mode then
        S.mode = inputbox._skk_mode
    elseif not inputbox._skk_mode then
        inputbox._skk_mode = S.mode
    end

    if inputbox._skk_vkbd_wrapped then
        logger.info("SKK vkbd: already wrapped, skipping re-install")
        -- Restore select-mode row if rebuilding mid-composition
        if inputbox._skk_state == "select" then
            S.select = true
            if inputbox._skk_cands and #S.cands == 0 then
                S.cands = inputbox._skk_cands
            end
        end
        return
    end
    logger.info("SKK vkbd: installing wrappers, mode=", S.mode)
    inputbox._skk_vkbd_wrapped = true

    -- Preserve in-progress composition across rebuilds
    inputbox._skk_mode       = inputbox._skk_mode       or S.mode
    inputbox._skk_state      = inputbox._skk_state      or "direct"
    inputbox._skk_romaji_buf = inputbox._skk_romaji_buf or ""
    inputbox._skk_reading    = inputbox._skk_reading    or ""
    if inputbox._skk_hint_len == nil then inputbox._skk_hint_len = 0 end
    if inputbox._skk_cand_idx == nil then inputbox._skk_cand_idx = 1 end
    if inputbox._skk_state == "select" then
        S.select = true
        if inputbox._skk_cands and #S.cands == 0 then
            S.cands = inputbox._skk_cands
        end
    end

    Dict.ensureDB()

    -- ---- Helpers -----------------------------------------------

    local function delHint(ib)
        for _ = 1, ib._skk_hint_len do ib.delChar:raw_method_call() end
        ib._skk_hint_len = 0
    end

    local function putHint(ib, text)
        delHint(ib)
        if text and text ~= "" then
            local chars = util.splitToChars(text)
            ib._skk_hint_len = #chars
            ib.addChars:raw_method_call(text)
        end
    end

    -- Floating candidate bar (shown above the virtual keyboard in SELECT mode).
    -- S.bar is used instead of a wrapInputBox-local so it survives the
    -- unwrap+rewrap cycle that rebuildKeyboard() triggers via init().

    local function showCandBar(cands, cand_idx, page)
        local page_start = (page - 1) * CANDS_PER_PAGE + 1
        if not S.bar then
            S.bar = SKKCandidateBar:new{
                candidates  = cands,
                current_idx = cand_idx,
                page_start  = page_start,
                on_select   = function(abs_idx)
                    local ib = S.ib
                    if not (ib and ib._skk_cands and ib._skk_cands[abs_idx]) then return end
                    ib._skk_cand_idx = abs_idx
                    commitText(ib, ib._skk_cands[abs_idx])
                end,
            }
            -- Position just above the virtual keyboard.
            local Screen = Device.screen
            local kbd_h  = (S.ib and S.ib.keyboard and S.ib.keyboard.dimen)
                           and S.ib.keyboard.dimen.h or 0
            local bar_h  = S.bar:getSize().h
            local y      = math.max(0, Screen:getHeight() - kbd_h - bar_h)
            S.bar:showAt(y)
        else
            S.bar:update(cands, cand_idx, page_start)
        end
    end

    local function hideCandBar()
        if S.bar then
            UIManager:close(S.bar, "ui")
            S.bar = nil
        end
    end

    local function enterSelectMode(ib)
        S.select = true
        showCandBar(ib._skk_cands, ib._skk_cand_idx, S.page)
    end

    local function exitSelectMode(ib)
        S.select = false
        S.cands  = {}
        S.page   = 1
        hideCandBar()
    end

    local function commitText(ib, text)
        -- Track usage when committing a dictionary candidate (SELECT state).
        if ib._skk_state == "select" and ib._skk_reading and ib._skk_reading ~= ""
                and text and text ~= "" and Dict then
            Dict.register(ib._skk_reading, text)
        end
        -- Preserve okurigana consonant (e.g. "b" from TaB): SKK-JISYO.L stores
        -- okurigana candidates as bare kanji (e.g. /食/), so after committing the
        -- kanji the user still needs to type the vowel to complete the okurigana.
        local saved_buf = ib._skk_romaji_buf
        delHint(ib)
        ib._skk_state      = "direct"
        ib._skk_reading    = ""
        ib._skk_cands      = nil
        ib._skk_cand_idx   = 1
        ib._skk_romaji_buf = saved_buf
        exitSelectMode(ib)
        rebuildKeyboard()  -- restore row 1 to punctuation
        if text and text ~= "" then ib.addChars:raw_method_call(text) end
        if saved_buf ~= "" then putHint(ib, saved_buf) end
    end

    local function cancelAll(ib)
        delHint(ib)
        ib._skk_state      = "direct"
        ib._skk_reading    = ""
        ib._skk_cands      = nil
        ib._skk_cand_idx   = 1
        ib._skk_romaji_buf = ""
        exitSelectMode(ib)
        rebuildKeyboard()
    end

    local function refreshPreedit(ib)
        local state = ib._skk_state
        local buf   = ib._skk_romaji_buf
        if state == "direct" then
            putHint(ib, buf)
        elseif state == "conv" then
            putHint(ib, "▽"..ib._skk_reading..buf)
        elseif state == "select" then
            local cands = ib._skk_cands
            if cands and #cands > 0 then
                local sel   = cands[ib._skk_cand_idx] or ""
                local okuri = buf ~= "" and ("*"..buf) or ""
                putHint(ib, "▼"..sel..okuri)
            end
        end
    end

    local function startConvMode(ib, first_lower)
        local flushed = flushRomaji(ib._skk_romaji_buf)
        ib._skk_romaji_buf = ""
        delHint(ib)
        if flushed ~= "" then
            ib.addChars:raw_method_call(
                ib._skk_mode == "katakana" and toKatakana(flushed) or flushed)
        end
        ib._skk_state   = "conv"
        ib._skk_reading = ""
        local committed, new_buf = processChar("", first_lower)
        ib._skk_romaji_buf = new_buf
        if committed and committed ~= "" then ib._skk_reading = committed end
        refreshPreedit(ib)
    end

    local function showRegisterPrompt(ib, reading)
        cancelAll(ib)
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
                            ib.addChars:raw_method_call(kanji)
                        end
                    end,
                },
            }},
        }
        UIManager:show(reg_dialog)
    end

    local function triggerConversion(ib)
        local flushed = flushRomaji(ib._skk_romaji_buf)
        ib._skk_romaji_buf = ""
        local query = ib._skk_reading..flushed
        if query == "" then cancelAll(ib); return end
        ib._skk_reading = query
        if not Dict.isReady() then
            UIManager:show(require("ui/widget/notification"):new{
                text = Dict.isBuilding()
                    and _("SKK: dictionary still preparing…")
                    or  _("SKK: dictionary unavailable."),
                timeout = 2,
            })
            refreshPreedit(ib)
            return
        end
        local cands = Dict.lookup(query)
        if #cands == 0 then showRegisterPrompt(ib, query); return end
        ib._skk_cands    = cands
        ib._skk_cand_idx = 1
        ib._skk_state    = "select"
        S.cands = cands
        S.page  = 1
        refreshPreedit(ib)
        enterSelectMode(ib)
    end

    -- ---- Romaji helpers ----------------------------------------

    local function processRomajiDirect(ib, ch)
        local committed, new_buf = processChar(ib._skk_romaji_buf, ch)
        ib._skk_romaji_buf = new_buf
        if committed and committed ~= "" then
            delHint(ib)
            local out = ib._skk_mode=="katakana" and toKatakana(committed) or committed
            ib.addChars:raw_method_call(out)
            if new_buf ~= "" then putHint(ib, new_buf) end
        else
            putHint(ib, new_buf)
        end
    end

    local function processRomajiReading(ib, ch)
        local committed, new_buf = processChar(ib._skk_romaji_buf, ch)
        ib._skk_romaji_buf = new_buf
        if committed and committed ~= "" then ib._skk_reading = ib._skk_reading..committed end
        refreshPreedit(ib)
    end

    -- ---- wrappedAddChars ---------------------------------------

    local function wrappedAddChars(ib, char)
        S.ib = ib
        logger.dbg("SKK vkbd:", char, "state=", ib._skk_state, "mode=", ib._skk_mode)

        if char == SKK_MODE then
            local flushed = flushRomaji(ib._skk_romaji_buf)
            ib._skk_romaji_buf = ""; delHint(ib)
            if flushed ~= "" then ib.addChars:raw_method_call(flushed) end
            if ib._skk_mode=="kana"     then ib._skk_mode="katakana"
            elseif ib._skk_mode=="katakana" then ib._skk_mode="ascii"
            else                             ib._skk_mode="kana" end
            S.mode = ib._skk_mode; rebuildKeyboard(); return
        end

        if ib._skk_mode == "ascii" then
            delHint(ib); ib.addChars:raw_method_call(char); return
        end

        local state    = ib._skk_state
        local is_upper = (#char==1 and char:match("[A-Z]") ~= nil)

        -- ▼ SELECT state
        if state == "select" then
            local cands = ib._skk_cands or {}
            if char == " " then
                local n = #cands
                ib._skk_cand_idx = n==0 and 1 or (ib._skk_cand_idx % n) + 1
                local pg = math.ceil(ib._skk_cand_idx / CANDS_PER_PAGE)
                if pg ~= S.page then S.page = pg end
                refreshPreedit(ib)
                showCandBar(cands, ib._skk_cand_idx, S.page)
                return
            elseif char == "x" then
                cancelAll(ib); return
            elseif char == "\n" then
                commitText(ib, cands[ib._skk_cand_idx] or ""); return
            else
                local n = tonumber(char)
                if n and n >= 1 and n <= CANDS_PER_PAGE then
                    local idx = (S.page-1)*CANDS_PER_PAGE + n
                    if cands[idx] then
                        ib._skk_cand_idx = idx
                        commitText(ib, cands[idx]); return
                    end
                end
                -- other chars: commit then reprocess
                local sel = cands[ib._skk_cand_idx] or ""
                commitText(ib, sel)
                wrappedAddChars(ib, char); return
            end
        end

        -- ▽ CONV state
        if state == "conv" then
            if char == " " then
                triggerConversion(ib); return
            elseif char == "\n" then
                local reading = ib._skk_reading..flushRomaji(ib._skk_romaji_buf)
                ib._skk_romaji_buf=""; ib._skk_reading=""; ib._skk_state="direct"
                commitText(ib, reading); return
            elseif char == "q" then
                local kata = toKatakana(ib._skk_reading..flushRomaji(ib._skk_romaji_buf))
                ib._skk_romaji_buf=""; ib._skk_reading=""; ib._skk_state="direct"
                commitText(ib, kata); return
            elseif is_upper then
                if ib.keyboard and ib.keyboard.shiftmode then ib.keyboard:setLayer("Shift") end
                local reading = ib._skk_reading..flushRomaji(ib._skk_romaji_buf)
                ib._skk_romaji_buf = char:lower()
                if reading ~= "" then
                    ib._skk_reading = reading
                    local cands = Dict.lookup(reading..char:lower())
                    if #cands == 0 then cands = Dict.lookup(reading) end
                    if #cands > 0 then
                        ib._skk_cands=cands; ib._skk_cand_idx=1
                        ib._skk_state="select"; S.cands=cands; S.page=1
                        refreshPreedit(ib); enterSelectMode(ib); return
                    end
                end
                refreshPreedit(ib); return
            else
                processRomajiReading(ib, char); return
            end
        end

        -- DIRECT state
        if is_upper then
            if ib.keyboard and ib.keyboard.shiftmode then ib.keyboard:setLayer("Shift") end
            startConvMode(ib, char:lower())
            return
        end
        if char==" " then
            local flushed=flushRomaji(ib._skk_romaji_buf)
            ib._skk_romaji_buf=""; delHint(ib)
            if flushed~="" then
                ib.addChars:raw_method_call(ib._skk_mode=="katakana" and toKatakana(flushed) or flushed) end
            ib.addChars:raw_method_call(" "); return
        end
        if char=="q" then
            local flushed=flushRomaji(ib._skk_romaji_buf)
            ib._skk_romaji_buf=""; delHint(ib)
            if flushed~="" then
                ib.addChars:raw_method_call(ib._skk_mode=="katakana" and toKatakana(flushed) or flushed) end
            ib._skk_mode=ib._skk_mode=="katakana" and "kana" or "katakana"
            S.mode=ib._skk_mode; rebuildKeyboard(); return
        end
        if char=="l" then
            local flushed=flushRomaji(ib._skk_romaji_buf)
            ib._skk_romaji_buf=""; delHint(ib)
            if flushed~="" then ib.addChars:raw_method_call(flushed) end
            ib._skk_mode="ascii"; S.mode="ascii"; rebuildKeyboard(); return
        end
        if char=="\n" then
            local flushed=flushRomaji(ib._skk_romaji_buf)
            ib._skk_romaji_buf=""; delHint(ib)
            if flushed~="" then
                ib.addChars:raw_method_call(ib._skk_mode=="katakana" and toKatakana(flushed) or flushed) end
            ib.addChars:raw_method_call("\n"); return
        end
        processRomajiDirect(ib, char)
    end

    -- ---- wrappedDelChar ----------------------------------------

    local function wrappedDelChar(ib)
        S.ib = ib
        local state = ib._skk_state
        if state == "select" then
            cancelAll(ib); return
        end
        local buf = ib._skk_romaji_buf
        if buf ~= "" then
            ib._skk_romaji_buf=buf:sub(1,-2); refreshPreedit(ib); return
        end
        if state == "conv" then
            local chars = util.splitToChars(ib._skk_reading)
            if #chars > 0 then
                table.remove(chars); ib._skk_reading=table.concat(chars)
                refreshPreedit(ib)
            else
                cancelAll(ib)
            end
            return
        end
        ib.delChar:raw_method_call()
    end

    local function commitAndClear(ib)
        if ib._skk_hint_len>0 or ib._skk_romaji_buf~="" or ib._skk_state~="direct" then
            local out=""
            if ib._skk_state=="select" then
                out=(ib._skk_cands and ib._skk_cands[ib._skk_cand_idx]) or ""
            elseif ib._skk_state=="conv" then
                out=ib._skk_reading..flushRomaji(ib._skk_romaji_buf)
            elseif ib._skk_romaji_buf~="" then
                out=flushRomaji(ib._skk_romaji_buf)
            end
            cancelAll(ib)
            if out~="" then ib.addChars:raw_method_call(out) end
        end
        hideCandBar()  -- close bar on any navigation / keyboard-close event
    end

    -- ---- Install wrappers --------------------------------------
    local wrappers = {}
    table.insert(wrappers, util.wrapMethod(inputbox, "addChars", wrappedAddChars, nil))
    table.insert(wrappers, util.wrapMethod(inputbox, "delChar",  wrappedDelChar,  nil))
    for _, m in ipairs({"leftChar","rightChar","upLine","downLine",
                         "goToStart","goToEnd","goToStartOfLine","goToEndOfLine",
                         "unfocus","onCloseKeyboard",
                         "onTapTextBox","onHoldTextBox","onSwipeTextBox",
                         "onSwitchingKeyboardLayout"}) do
        if inputbox[m] then
            table.insert(wrappers, util.wrapMethod(inputbox, m, nil, commitAndClear))
        end
    end

    return function()
        if inputbox._skk_vkbd_wrapped then
            for _, w in ipairs(wrappers) do w:revert() end
            inputbox._skk_vkbd_wrapped = nil
        end
    end
end

-- ----------------------------------------------------------------
-- Keyboard layout
-- ----------------------------------------------------------------
return {
    min_layer = 1,
    max_layer = 4,
    shiftmode_keys  = { ["⇧"] = true },
    symbolmode_keys = { ["⌥"] = true },
    utf8mode_keys   = { ["🌐"] = true },

    genMenuItems = function(self)
        return {
            {
                text = _("SKK input — key bindings"),
                help_text = _([[
Row 1 (normal): mode key (あ/ア/A) + Japanese punctuation
Row 1 (SELECT): 1–9 number keys for direct candidate selection

Shift layer → kanji conversion ▽
Space → convert/next candidate; Enter → commit
Backspace → delete/cancel; x → cancel selection
q → toggle hiragana/katakana; l → ASCII mode
あ/A key (bottom) → cycle あ→ア→A]]),
                keep_menu_open = true, callback = function() end,
            },
        }
    end,

    wrapInputBox = wrapInputBox,

    keys = {
        genFirstRow(),
        -- Row 2 (Layer1=⇧, Layer2=Normal, Layer3=⇧+⌥, Layer4=⌥)
        {
            {"Q","q","!","1"},{"W","w","？","2"},{"E","e","、","3"},
            {"R","r","。","4"},{"T","t","「","5"},{"Y","y","」","6"},
            {"U","u","・","7"},{"I","i","…","8"},{"O","o","〜","9"},{"P","p","〇","0"},
        },
        -- Row 3
        {
            {"A","a","＠","@"},{"S","s","＃","#"},{"D","d","＄","$"},
            {"F","f","％","%"},{"G","g","＾","^"},{"H","h","＆","&"},
            {"J","j","＊","*"},{"K","k","（","("},{"L","l","）",")"},
            {".",":","：","。"},
        },
        -- Row 4
        {
            {label="⇧", width=1.5},
            {"Z","z","ー","-"},{"X","x","＿","_"},{"C","c","＋","+"},
            {"V","v","＝","="},{"B","b","／","/"},{"N","n","￥","\\"},
            {"M","m","、",","},
            {label="\238\157\173", width=1.5},
        },
        -- Row 5
        {
            {label="⌥", bold=true, width=1.5},
            {label="🌐"},
            {SKK_MODE,SKK_MODE,SKK_MODE,SKK_MODE,
             label=S.mode=="kana" and "あ" or S.mode=="katakana" and "ア" or "A",
             bold=true},
            {" "," "," "," ", label="_", width=2.0},
            {".",",","、","。"},
            {label="←"},
            {label="→"},
            {label="\226\174\160", "\n","\n","\n","\n", bold=true, width=1.5},
        },
    },
}
