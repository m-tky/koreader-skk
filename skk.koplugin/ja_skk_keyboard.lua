--[[--
SKK (Simple Kana to Kanji) keyboard layout for KOReader's VirtualKeyboard.

Candidate selection:
  Row 1 in SELECT mode → shows "1"–"9" number keys for direct selection.
  The selected candidate and alternatives are shown as inline preedit:
    ▼漢字 [2:幹事 3:監事 4:感じ…]
  Space cycles candidates; Enter commits; x cancels.

Modes (あ/A key bottom row):
  あ – romaji → hiragana (default)
  ア – romaji → katakana
  A  – ASCII pass-through
]]

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local util            = require("util")
local _               = require("gettext")

-- ----------------------------------------------------------------
-- Load SKK engine modules from the plugin (optional)
-- ----------------------------------------------------------------
local Romaji, Dict
do
    local ok, r = pcall(require, "skk_romaji")
    if ok then Romaji = r else
        logger.warn("ja_skk_keyboard: skk_romaji not found – install skk.koplugin")
    end
    local ok2, d = pcall(require, "skk_dictionary")
    if ok2 then Dict = d end
end

-- ----------------------------------------------------------------
-- Minimal inline romaji (fallback)
-- ----------------------------------------------------------------
local KANA_INLINE = {
    a="あ",i="い",u="う",e="え",o="お",
    ka="か",ki="き",ku="く",ke="け",ko="こ",
    ga="が",gi="ぎ",gu="ぐ",ge="げ",go="ご",
    sa="さ",si="し",su="す",se="せ",so="そ",shi="し",
    sha="しゃ",shu="しゅ",sho="しょ",
    za="ざ",zi="じ",zu="ず",ze="ぜ",zo="ぞ",ji="じ",
    ja="じゃ",ju="じゅ",jo="じょ",
    ta="た",ti="ち",tu="つ",te="て",to="と",
    chi="ち",tsu="つ",cha="ちゃ",chu="ちゅ",cho="ちょ",
    da="だ",di="ぢ",du="づ",de="で",["do"]="ど",
    na="な",ni="に",nu="ぬ",ne="ね",no="の",
    nya="にゃ",nyu="にゅ",nyo="にょ",nn="ん",
    ha="は",hi="ひ",hu="ふ",he="へ",ho="ほ",fu="ふ",
    hya="ひゃ",hyu="ひゅ",hyo="ひょ",
    ba="ば",bi="び",bu="ぶ",be="べ",bo="ぼ",
    pa="ぱ",pi="ぴ",pu="ぷ",pe="ぺ",po="ぽ",
    ma="ま",mi="み",mu="む",me="め",mo="も",
    mya="みゃ",myu="みゅ",myo="みょ",
    ya="や",yu="ゆ",yo="よ",
    ra="ら",ri="り",ru="る",re="れ",ro="ろ",
    rya="りゃ",ryu="りゅ",ryo="りょ",
    wa="わ",wi="ゐ",we="ゑ",wo="を",
    xa="ぁ",xi="ぃ",xu="ぅ",xe="ぇ",xo="ぉ",xtu="っ",xtsu="っ",xn="ん",
    ["z,"]="、",["z."]="。",["zh"]="←",["zj"]="↓",
    ["zk"]="↑",["zl"]="→",["z/"]="・",["z-"]="〜",
    ["z["]="「",["z]"]="」",
}
local PREFIXES_INLINE, DOUBLERS = {}, {b=1,c=1,d=1,f=1,g=1,h=1,j=1,k=1,m=1,p=1,r=1,s=1,t=1,v=1,w=1,z=1}
for seq in pairs(KANA_INLINE) do
    for l = 1, #seq-1 do PREFIXES_INLINE[seq:sub(1,l)] = true end
    PREFIXES_INLINE[seq] = true
end

local function processChar_inline(buf, ch)
    local try = buf..ch
    if KANA_INLINE[try] then return KANA_INLINE[try],"" end
    if PREFIXES_INLINE[try] then return nil,try end
    local V={a=1,i=1,u=1,e=1,o=1}
    if buf=="n" and not V[ch] and ch~="y" and ch~="n" then
        local c,b=processChar_inline("",ch); return "ん"..(c or ""),b end
    if #buf==1 and DOUBLERS[buf] and ch==buf then return "っ",ch end
    if #buf==2 then
        local b1,b2=buf:sub(1,1),buf:sub(2,2)
        if b1==b2 and DOUBLERS[b1] then local c,nb=processChar_inline(b1,ch); return "っ"..(c or ""),nb end
    end
    if #buf>0 then local c,b=processChar_inline("",ch); return buf..(c or ""),b end
    return nil,ch
end
local function flush_inline(buf)
    if buf=="" then return "" end; if buf=="n" then return "ん" end
    return KANA_INLINE[buf] or buf
end

local function processChar(buf,ch)
    if Romaji then return Romaji.processChar(buf,ch) end; return processChar_inline(buf,ch) end
local function flushRomaji(buf)
    if Romaji then return Romaji.flush(buf) end; return flush_inline(buf) end
local function toKatakana(str)
    if Romaji then return Romaji.toKatakana(str) end; return str end

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

local CANDS_PER_PAGE = 9   -- number keys 1-9

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

    if Dict then Dict.ensureLoaded() end

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

    -- Build inline hint: "▼漢字 [2:幹事 3:監事…]"
    local HINT_MAX_ALTS = 4  -- keep hint short enough to avoid line wrapping
    local function candidateHint(cands, cand_idx, page)
        local sel = cands[cand_idx] or ""
        local start = (page-1)*CANDS_PER_PAGE + 1
        local page_end = math.min(start+CANDS_PER_PAGE-1, #cands)
        local parts = {"▼"..sel.." ["}
        local shown = 0
        local truncated = false
        for i = start, page_end do
            if i ~= cand_idx then
                if shown >= HINT_MAX_ALTS then truncated = true; break end
                local n = i - start + 1
                table.insert(parts, tostring(n)..":"..cands[i].." ")
                shown = shown + 1
            end
        end
        if truncated or #cands > page_end then table.insert(parts, "…") end
        table.insert(parts, "]")
        return table.concat(parts)
    end

    local function enterSelectMode(ib)
        S.select = true
        rebuildKeyboard()  -- show number keys in row 1
    end

    local function exitSelectMode(ib)
        S.select = false
        S.cands  = {}
        S.page   = 1
    end

    local function commitText(ib, text)
        delHint(ib)
        ib._skk_state      = "direct"
        ib._skk_reading    = ""
        ib._skk_cands      = nil
        ib._skk_cand_idx   = 1
        ib._skk_romaji_buf = ""
        exitSelectMode(ib)
        rebuildKeyboard()  -- restore row 1 to punctuation
        if text and text ~= "" then ib.addChars:raw_method_call(text) end
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
                putHint(ib, candidateHint(cands, ib._skk_cand_idx, S.page))
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

    local function triggerConversion(ib)
        local flushed = flushRomaji(ib._skk_romaji_buf)
        ib._skk_romaji_buf = ""
        local query = ib._skk_reading..flushed
        if query == "" then cancelAll(ib); return end
        ib._skk_reading = query
        local cands = Dict and Dict.lookup(query) or {}
        if #cands == 0 then refreshPreedit(ib); return end
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
                    local cands = Dict and (Dict.lookup(reading..char:lower()) or Dict.lookup(reading)) or {}
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
            {label="⌥", bold=true},
            {label="🌐"},
            {SKK_MODE,SKK_MODE,SKK_MODE,SKK_MODE,
             label=S.mode=="kana" and "あ" or S.mode=="katakana" and "ア" or "A",
             bold=true},
            {" "," "," "," ", label="_", width=2.0},
            {".",",","、","。"},
            {label="←"},
            {label="→"},
            {label="\226\174\160", "\n","\n","\n","\n", bold=true},
        },
    },
}
