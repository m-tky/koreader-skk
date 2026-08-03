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

-- Non-letter suffixes recognised by SKK's z punctuation sequences.
-- Everything else that is not a lowercase ASCII letter is committed as a
-- literal immediately, keeping input behaviour in sync with the layout.
local Z_SYMBOL_SUFFIXES = {
    [","]=true, ["."]=true, ["/"]=true, ["-"]=true,
    ["["]=true, ["]"]=true, ["("]=true, [")"]=true,
}

-- ----------------------------------------------------------------
-- Persistent global state
-- ----------------------------------------------------------------
_G._skk_vkbd_state = _G._skk_vkbd_state or {}
local S = _G._skk_vkbd_state
S.page     = S.page     or 1
S.mode     = S.mode     or "kana"
S.ib       = S.ib       or nil
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
        -- the mode label and mode-specific punctuation are re-evaluated.
        package.loaded["ui/data/keyboardlayouts/ja_skk_keyboard"] = nil
        package.loaded["ja_skk_keyboard"] = nil
        ib.keyboard:setKeyboardLayout("js")
    end)
end

-- ----------------------------------------------------------------
-- Always-visible number row. Candidate selection uses the same 1–9 keys, so
-- entering SELECT mode does not need a keyboard rebuild.
-- ----------------------------------------------------------------
local function genFirstRow()
    return {
        {"!","1","！","、"}, {"@","2","＠","。"},
        {"#","3","＃","ー"}, {"$","4","＄","・"},
        {"%","5","％","「"}, {"^","6","＾","」"},
        {"&","7","＆","？"}, {"*","8","＊","！"},
        {"(","9","（","〜"}, {")","0","）","…"},
    }
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
        return
    end
    logger.info("SKK vkbd: installing wrappers, mode=", S.mode)
    inputbox._skk_vkbd_wrapped = true

    -- Preserve in-progress composition across rebuilds
    inputbox._skk_mode         = inputbox._skk_mode         or S.mode
    inputbox._skk_state        = inputbox._skk_state        or "direct"
    inputbox._skk_romaji_buf   = inputbox._skk_romaji_buf   or ""
    inputbox._skk_reading      = inputbox._skk_reading      or ""
    -- Okurigana tracking in SELECT (see skk_inputtext.lua for details).
    if inputbox._skk_okuri_active == nil then inputbox._skk_okuri_active = false end
    inputbox._skk_okuri_kana   = inputbox._skk_okuri_kana   or ""
    if inputbox._skk_hint_len == nil then inputbox._skk_hint_len = 0 end
    if inputbox._skk_cand_idx == nil then inputbox._skk_cand_idx = 1 end
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

    -- Forward declarations: showCandBar's callbacks close over commitText and
    -- refreshPreedit, which are defined further down. Lua locals don't hoist,
    -- so without these forward `local`s the callbacks would resolve them as
    -- (nil) globals and crash on tap-to-select / tap-next-page.
    local commitText
    local refreshPreedit

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
                on_next_page = function()
                    local ib = S.ib
                    if not (ib and ib._skk_cands) then return end
                    local all = ib._skk_cands
                    local max_page = math.ceil(#all / CANDS_PER_PAGE)
                    if S.page >= max_page then return end
                    S.page = S.page + 1
                    ib._skk_cand_idx = (S.page - 1) * CANDS_PER_PAGE + 1
                    refreshPreedit(ib)
                    showCandBar(all, ib._skk_cand_idx, S.page)
                end,
                on_prev_page = function()
                    local ib = S.ib
                    if not (ib and ib._skk_cands) then return end
                    if S.page <= 1 then return end
                    S.page = S.page - 1
                    ib._skk_cand_idx = (S.page - 1) * CANDS_PER_PAGE + 1
                    refreshPreedit(ib)
                    showCandBar(ib._skk_cands, ib._skk_cand_idx, S.page)
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
        -- Prevent InputDialog from closing the keyboard when the user taps the
        -- candidate bar above it (InputDialog treats any tap outside the
        -- keyboard frame as a dismiss gesture).
        if ib.parent then ib.parent.deny_keyboard_hiding = true end
        showCandBar(ib._skk_cands, ib._skk_cand_idx, S.page)
    end

    local function exitSelectMode(ib)
        S.page   = 1
        if ib.parent then ib.parent.deny_keyboard_hiding = false end
        hideCandBar()
    end

    commitText = function(ib, text)
        -- Track usage when committing a dictionary candidate (SELECT state).
        if ib._skk_state == "select" and ib._skk_reading and ib._skk_reading ~= ""
                and text and text ~= "" and Dict then
            Dict.register(ib._skk_reading, text)
        end
        -- Okurigana handling. SKK-JISYO.L stores okurigana candidates as bare
        -- kanji (e.g. /食/), so after committing the kanji we still owe the
        -- okurigana. `okuri_kana` holds kana already completed in SELECT;
        -- those go into the document together with the kanji. A leftover
        -- consonant in `_skk_romaji_buf` (e.g. user committed by index before
        -- typing the vowel) is preserved as preedit awaiting the vowel.
        local saved_buf  = ib._skk_romaji_buf
        local okuri_kana = ib._skk_okuri_kana or ""
        delHint(ib)
        ib._skk_state         = "direct"
        ib._skk_reading       = ""
        ib._skk_cands         = nil
        ib._skk_cand_idx      = 1
        ib._skk_romaji_buf    = ""
        ib._skk_okuri_active  = false
        ib._skk_okuri_kana    = ""
        exitSelectMode(ib)
        local committed_text = (text or "") .. okuri_kana
        if committed_text ~= "" then ib.addChars:raw_method_call(committed_text) end
        if saved_buf ~= "" then
            local flushed = flushRomaji(saved_buf)
            if flushed ~= saved_buf then
                ib.addChars:raw_method_call(flushed)
            else
                ib._skk_romaji_buf = saved_buf
                putHint(ib, saved_buf)
            end
        end
    end

    local function cancelAll(ib)
        delHint(ib)
        ib._skk_state         = "direct"
        ib._skk_reading       = ""
        ib._skk_cands         = nil
        ib._skk_cand_idx      = 1
        ib._skk_romaji_buf    = ""
        ib._skk_okuri_active  = false
        ib._skk_okuri_kana    = ""
        exitSelectMode(ib)
    end

    refreshPreedit = function(ib)
        local state = ib._skk_state
        local buf   = ib._skk_romaji_buf
        if state == "direct" then
            putHint(ib, buf)
        elseif state == "conv" then
            putHint(ib, "▽"..ib._skk_reading..buf)
        elseif state == "select" then
            local cands = ib._skk_cands
            if cands and #cands > 0 then
                local sel       = cands[ib._skk_cand_idx] or ""
                local okuri_k   = ib._skk_okuri_kana or ""
                local okuri     = ""
                if okuri_k ~= "" or buf ~= "" then
                    okuri = "*" .. okuri_k .. buf
                end
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

    local function commitDirectLiteral(ib, char)
        local flushed = flushRomaji(ib._skk_romaji_buf)
        ib._skk_romaji_buf = ""
        delHint(ib)
        if flushed ~= "" then
            local out = ib._skk_mode == "katakana" and toKatakana(flushed) or flushed
            ib.addChars:raw_method_call(out)
        end
        ib.addChars:raw_method_call(char)
    end

    local function isRomajiInput(buf, char)
        if #char == 1 and char:match("[a-z]") then return true end
        if buf == "n" and char == "'" then return true end
        return buf == "z" and Z_SYMBOL_SUFFIXES[char] == true
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
                if n == 0 then return end
                if ib._skk_cand_idx >= n then
                    -- ddskk: advancing past the last candidate opens the
                    -- register-new-word prompt for the current reading.
                    local reading = (ib._skk_reading or "") .. (ib._skk_okuri_kana or "")
                    cancelAll(ib)
                    showRegisterPrompt(ib, reading)
                    return
                end
                ib._skk_cand_idx = ib._skk_cand_idx + 1
                local pg = math.ceil(ib._skk_cand_idx / CANDS_PER_PAGE)
                if pg ~= S.page then S.page = pg end
                refreshPreedit(ib)
                showCandBar(cands, ib._skk_cand_idx, S.page)
                return
            elseif char == "x" then
                cancelAll(ib); return
            elseif char == "\n" then
                commitText(ib, cands[ib._skk_cand_idx] or ""); return
            elseif char == "q" then
                -- ddskk: q in SELECT commits the reading (with okurigana) as
                -- katakana, discarding the candidate kanji. We do NOT call
                -- Dict.register here — the user explicitly chose to throw
                -- the lookup result away.
                local kata = toKatakana((ib._skk_reading or "")
                    .. (ib._skk_okuri_kana or ""))
                delHint(ib)
                ib._skk_state         = "direct"
                ib._skk_reading       = ""
                ib._skk_cands         = nil
                ib._skk_cand_idx      = 1
                ib._skk_romaji_buf    = ""
                ib._skk_okuri_active  = false
                ib._skk_okuri_kana    = ""
                exitSelectMode(ib)
                if kata ~= "" then ib.addChars:raw_method_call(kata) end
                return
            end
            local n = tonumber(char)
            if n and n >= 1 and n <= CANDS_PER_PAGE then
                local idx = (S.page-1)*CANDS_PER_PAGE + n
                if cands[idx] then
                    ib._skk_cand_idx = idx
                    commitText(ib, cands[idx]); return
                end
            end
            -- Okurigana continuation: accept only when the new char actually
            -- progresses the romaji (produces kana or extends the prefix).
            -- Letters like q/l that would just flush the buffer raw fall
            -- through to the auto-commit-and-reprocess path below.
            if ib._skk_okuri_active and #char == 1 and char:match("[a-z]") then
                local orig_buf = ib._skk_romaji_buf
                local committed, new_buf = processChar(orig_buf, char)
                local commits_kana   = committed and committed ~= "" and committed ~= orig_buf
                local extends_prefix = #new_buf > #orig_buf
                if commits_kana or extends_prefix then
                    ib._skk_romaji_buf = new_buf
                    if commits_kana then
                        ib._skk_okuri_kana = (ib._skk_okuri_kana or "") .. committed
                    end
                    refreshPreedit(ib)
                    showCandBar(cands, ib._skk_cand_idx, S.page)
                    return
                end
                -- else: fall through to auto-commit + reprocess
            end
            -- Other chars (non-okurigana SELECT, or punctuation): commit
            -- then reprocess.
            local sel = cands[ib._skk_cand_idx] or ""
            commitText(ib, sel)
            wrappedAddChars(ib, char); return
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
                        ib._skk_state="select"; S.page=1
                        ib._skk_okuri_active = true
                        ib._skk_okuri_kana   = ""
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
            if ib._skk_romaji_buf == "z" then
                processRomajiDirect(ib, char); return
            end
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
        -- Keep SKK's `zl` → right-arrow sequence reachable; bare `l` still
        -- switches to ASCII mode as usual.
        if char=="l" and ib._skk_romaji_buf ~= "z" then
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
        -- Only lowercase letters and SKK's n'/z-prefixed sequences belong in
        -- the romaji DFA. Everything else is literal and commits immediately.
        if not isRomajiInput(ib._skk_romaji_buf, char) then
            commitDirectLiteral(ib, char); return
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
Number row: 1–0 normally; 1–9 select candidates in SELECT

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

    -- Row layer model: { ⇧, Normal, ⇧+⌥, ⌥ }.
    -- Normal/Shift follow QWERTY. ⌥ contains frequent Japanese and ASCII
    -- punctuation without duplicates; ⇧+⌥ contains full-width/rare symbols.
    keys = (function()
        local ascii = S.mode == "ascii"
        local row2_layer3 = {"１","２","３","４","５","６","７","８","９","０"}
        local row3_layer3 = {"－","＿","＋","＝","／","￥","：","；","，","．"}
        local row4_layer3 = {"々","〆","〒","※","☆","★","゜"}
        local row2_symbol = {"-","_","+","=","/","\\","'","\"","<",">"}
        local row3_symbol = {"『","』","【","】","（","）","［","］","〈","〉"}
        local row4_symbol = {"~","`","|","{","}","[","]"}
        -- Row 5 column 5: punctuation key next to space.
        local row5_punc = ascii
            and {",",".","゛","?"}
            or  {"、","。","゛","?"}

        local row2_keys = {
            {"Q","q",row2_layer3[1],row2_symbol[1]},{"W","w",row2_layer3[2],row2_symbol[2]},
            {"E","e",row2_layer3[3],row2_symbol[3]},{"R","r",row2_layer3[4],row2_symbol[4]},
            {"T","t",row2_layer3[5],row2_symbol[5]},{"Y","y",row2_layer3[6],row2_symbol[6]},
            {"U","u",row2_layer3[7],row2_symbol[7]},{"I","i",row2_layer3[8],row2_symbol[8]},
            {"O","o",row2_layer3[9],row2_symbol[9]},{"P","p",row2_layer3[10],row2_symbol[10]},
        }
        local row3_keys = {
            {"A","a",row3_layer3[1],row3_symbol[1]},{"S","s",row3_layer3[2],row3_symbol[2]},
            {"D","d",row3_layer3[3],row3_symbol[3]},{"F","f",row3_layer3[4],row3_symbol[4]},
            {"G","g",row3_layer3[5],row3_symbol[5]},{"H","h",row3_layer3[6],row3_symbol[6]},
            {"J","j",row3_layer3[7],row3_symbol[7]},{"K","k",row3_layer3[8],row3_symbol[8]},
            {"L","l",row3_layer3[9],row3_symbol[9]},
            {":",";",row3_layer3[10],row3_symbol[10]},
        }
        local row4_keys = {
            -- Empty-string key fields make VirtualKey treat shift as releasable
            -- (releasable = key == ""), so a single tap behaves like upstream:
            -- one-shot for normal letters, capslock on long-press.
            {"","","","", label="⇧", width=1.5},
            {"Z","z",row4_layer3[1],row4_symbol[1]},{"X","x",row4_layer3[2],row4_symbol[2]},
            {"C","c",row4_layer3[3],row4_symbol[3]},{"V","v",row4_layer3[4],row4_symbol[4]},
            {"B","b",row4_layer3[5],row4_symbol[5]},{"N","n",row4_layer3[6],row4_symbol[6]},
            {"M","m",row4_layer3[7],row4_symbol[7]},
            {label="\238\157\173", width=1.5},
        }
        local row5_keys = {
            {label="⌥", bold=true, width=1.5},
            {label="🌐"},
            {SKK_MODE,SKK_MODE,SKK_MODE,SKK_MODE,
             label=S.mode=="kana" and "あ" or S.mode=="katakana" and "ア" or "A",
             bold=true},
            {" "," "," "," ", label="_", width=2.0},
            row5_punc,
            {label="←"},
            {label="→"},
            {label="\226\174\160", "\n","\n","\n","\n", bold=true, width=1.5},
        }
        return { genFirstRow(), row2_keys, row3_keys, row4_keys, row5_keys }
    end)(),
}
