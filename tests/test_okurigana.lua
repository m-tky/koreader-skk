-- Unit tests for SKKInputText:_commitCandidate okurigana handling.
--
-- The okurigana romaji buffer (e.g. "i", "g", "n") preserved across a candidate
-- commit must be:
--   - flushed to kana and committed when it is a complete romaji ("i" → い,
--     "a" → あ, single "n" → ん, "ka" → か)
--   - retained as preedit when it is a partial consonant awaiting a vowel
--     ("g", "k", "z", "ky" prefix, …)
--
-- The bug fixed by this test was: every saved buf was stuffed back into
-- preedit raw, producing 脱i instead of 脱い for `NuI`.

-- ---- Stubs --------------------------------------------------------------

-- Split UTF-8 string into characters; needed by _setPreedit/_clearPreedit.
local function splitToChars(str)
    local chars = {}
    local i = 1
    while i <= #str do
        local b = str:byte(i)
        local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        chars[#chars + 1] = str:sub(i, i + len - 1)
        i = i + len
    end
    return chars
end

package.loaded["util"] = { splitToChars = splitToChars }

package.loaded["device"] = { isSDL = function() return false end }

package.loaded["ui/uimanager"] = {
    show = function() end, close = function() end,
    forceRePaint = function() end, nextTick = function() end,
    broadcastEvent = function() end,
}

package.loaded["ui/time"] = {
    now    = function() return 0 end,
    since  = function() return math.huge end,
    ms     = function(n) return n end,
}

package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })

package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

package.loaded["skk_dictionary"] = {
    PAGE_SIZE = 9,
    register = function() end,
    lookup   = function() return {} end,
}

-- Candidate bar: stub every method as a no-op.
package.loaded["skk_candidate_bar"] = setmetatable({}, {
    __index = function() return function() end end,
})

-- InputText parent class. addChars appends to the instance's charlist AND
-- to a global emit log so tests can assert exactly what was committed.
local emit_log = {}
local InputText = {}
function InputText:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function InputText.addChars(self, text)
    emit_log[#emit_log + 1] = text
    for _, ch in ipairs(splitToChars(text)) do
        self.charlist[#self.charlist + 1] = ch
    end
    self.charpos = #self.charlist + 1
end
function InputText:initTextBox() end
function InputText:onKeyPress() return false end
function InputText:onTextInput() return false end
function InputText:getText() return table.concat(self.charlist) end
package.loaded["ui/widget/inputtext"] = InputText

-- ---- Load module under test ---------------------------------------------

local script_dir = arg and arg[0]:match("^(.*)/") or "."
package.path = script_dir .. "/../skk.koplugin/?.lua;" .. package.path
local SKKInputText = require("skk_inputtext")

-- The candidate bar helpers reach into Device.screen / CandidateBar widgets
-- that aren't worth replicating in stubs. Override on the class so every
-- test instance gets a no-op (we still assert state via fields, not UI).
SKKInputText._showCandidateBar = function() end
SKKInputText._closeCandidateBar = function() end

-- ---- Tiny test framework -------------------------------------------------

local pass, fail = 0, 0
local function eq(got, expected, label)
    if got == expected then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write(string.format("FAIL %s: got %s, expected %s\n",
            label, tostring(got), tostring(expected)))
    end
end
local function deep_eq(got, expected, label)
    if #got ~= #expected then
        fail = fail + 1
        io.stderr:write(string.format("FAIL %s: length got %d, expected %d (got=%s expected=%s)\n",
            label, #got, #expected, table.concat(got, ","), table.concat(expected, ",")))
        return
    end
    for i, v in ipairs(expected) do
        if got[i] ~= v then
            fail = fail + 1
            io.stderr:write(string.format("FAIL %s [%d]: got %q, expected %q\n",
                label, i, tostring(got[i]), tostring(v)))
            return
        end
    end
    pass = pass + 1
end

-- Build an SKKInputText instance pre-positioned in SELECT state with the
-- given reading / candidate / okurigana buffer, ready for _commitCandidate.
local function newInSelect(reading, cand, saved_buf)
    emit_log = {}
    local inst = setmetatable({
        charlist        = {},
        charpos         = 1,
        focused         = true,
        is_text_edited  = false,
        _skk_enabled    = true,
        _state          = "select",
        _reading        = reading,
        _candidates     = { cand },
        _cand_idx       = 1,
        _cand_page      = 1,
        _romaji_buf     = saved_buf,
        _preedit_start  = nil,
        _preedit_chars  = nil,
    }, { __index = SKKInputText })
    return inst
end

-- ---- Tests ---------------------------------------------------------------

-- Case 1: no okurigana buffer. Plain candidate commit.
do
    local ib = newInSelect("かんじ", "漢字", "")
    ib:_commitCandidate()
    deep_eq(emit_log, { "漢字" },          "empty buf: emits only the kanji")
    eq(ib._romaji_buf, "",                 "empty buf: romaji_buf cleared")
    eq(ib._preedit_chars, nil,             "empty buf: no preedit left")
    eq(ib._state, "kana",                  "empty buf: state back to KANA")
end

-- Case 2: vowel okurigana ("i"). Should be flushed to い and committed.
-- Reproduces the original `NuI` → 脱i bug.
do
    local ib = newInSelect("ぬ", "脱", "i")
    ib:_commitCandidate()
    deep_eq(emit_log, { "脱", "い" },      "vowel buf: emits kanji then kana")
    eq(ib._romaji_buf, "",                 "vowel buf: romaji_buf cleared")
    eq(ib._preedit_chars, nil,             "vowel buf: no preedit left")
end

-- Case 3: vowel okurigana ("a"). Same path.
do
    local ib = newInSelect("おも", "重", "a")
    ib:_commitCandidate()
    deep_eq(emit_log, { "重", "あ" },      "vowel a: emits kanji then kana")
    eq(ib._romaji_buf, "",                 "vowel a: romaji_buf cleared")
end

-- Case 4: single "n" → ん.
do
    local ib = newInSelect("み", "見", "n")
    ib:_commitCandidate()
    deep_eq(emit_log, { "見", "ん" },      "single n: emits kanji then ん")
    eq(ib._romaji_buf, "",                 "single n: romaji_buf cleared")
end

-- Case 5: consonant ("g"). Should stay as preedit awaiting a vowel.
-- The kanji is committed, then "g" is added as preedit text (so the user sees
-- where the next vowel will land). emit_log has both entries because
-- _setPreedit calls InputText.addChars internally.
do
    local ib = newInSelect("ぬ", "脱", "g")
    ib:_commitCandidate()
    deep_eq(emit_log, { "脱", "g" },       "consonant g: emits kanji then preedit")
    eq(ib._romaji_buf, "g",                "consonant g: buf retained")
    eq(ib._preedit_chars and #ib._preedit_chars or 0, 1,
        "consonant g: preedit holds one char")
end

-- Case 6: consonant ("k").
do
    local ib = newInSelect("か", "書", "k")
    ib:_commitCandidate()
    deep_eq(emit_log, { "書", "k" },       "consonant k: emits kanji then preedit")
    eq(ib._romaji_buf, "k",                "consonant k: buf retained")
end

-- Case 7: digraph prefix ("ky" — not in KANA table, not the single-n case).
-- Stays as preedit awaiting the vowel that completes きゃ/きゅ/きょ.
do
    local ib = newInSelect("お", "起", "ky")
    ib:_commitCandidate()
    deep_eq(emit_log, { "起", "ky" },      "ky prefix: emits kanji then preedit")
    eq(ib._romaji_buf, "ky",               "ky prefix: buf retained")
end

-- ---- Okurigana progression in SELECT (NuGu, TaBeru) ---------------------

-- Helper: build an SKKInputText positioned in okurigana-mode SELECT, ready
-- to receive the vowel(s) that complete the okurigana.
local function newOkuriSelect(reading, cand, romaji_buf)
    emit_log = {}
    local inst = setmetatable({
        charlist        = {},
        charpos         = 1,
        focused         = true,
        is_text_edited  = false,
        _skk_enabled    = true,
        _state          = "select",
        _reading        = reading,
        _candidates     = { cand },
        _cand_idx       = 1,
        _cand_page      = 1,
        _romaji_buf     = romaji_buf,
        _okuri_active   = true,
        _okuri_kana     = "",
        _preedit_start  = nil,
        _preedit_chars  = nil,
    }, { __index = SKKInputText })
    return inst
end

-- Case 8: NuGu — the canonical bug. After typing Nu (→ ぬ in CONV) then G
-- (→ SELECT 脱*g), typing `u` must NOT auto-commit. It should complete the
-- okurigana romaji "gu" to ぐ, stay in SELECT, and update the preedit to
-- ▼脱*ぐ.
do
    local ib = newOkuriSelect("ぬ", "脱", "g")
    local consumed = ib:_processChar("u")
    eq(consumed, true,                     "NuGu: u is consumed by SELECT handler")
    eq(ib._state, "select",                "NuGu: stays in SELECT")
    eq(ib._romaji_buf, "",                 "NuGu: romaji_buf consumed")
    eq(ib._okuri_kana, "ぐ",               "NuGu: okuri_kana now ぐ")
    -- Nothing committed to the document yet — the candidate is still being
    -- chosen. (addChars may be called by _refreshPreedit; we just assert no
    -- kanji has been emitted.)
    local emitted_kanji = false
    for _, t in ipairs(emit_log) do if t == "脱" then emitted_kanji = true end end
    eq(emitted_kanji, false,               "NuGu: no kanji committed yet")
end

-- Case 9: NuGu then Enter (via _commitCandidate). Final emit is 脱ぐ.
do
    local ib = newOkuriSelect("ぬ", "脱", "g")
    ib:_processChar("u")
    emit_log = {}  -- focus on the commit step
    ib:_commitCandidate()
    deep_eq(emit_log, { "脱ぐ" },          "NuGu+commit: emits 脱ぐ as a unit")
    eq(ib._romaji_buf, "",                 "NuGu+commit: romaji_buf cleared")
    eq(ib._okuri_kana, "",                 "NuGu+commit: okuri_kana cleared")
    eq(ib._okuri_active, false,            "NuGu+commit: okuri_active cleared")
end

-- Case 10: TaBeru — multi-kana okurigana. After TaB → SELECT 食*b, the user
-- types e, r, u; the okurigana accumulates as べる, candidate stays selectable.
do
    local ib = newOkuriSelect("た", "食", "b")
    ib:_processChar("e")
    eq(ib._okuri_kana, "べ",               "TaBe: okuri_kana is べ")
    eq(ib._romaji_buf, "",                 "TaBe: romaji_buf consumed")
    eq(ib._state, "select",                "TaBe: still in SELECT")
    ib:_processChar("r")
    eq(ib._okuri_kana, "べ",               "TaBer: okuri_kana unchanged")
    eq(ib._romaji_buf, "r",                "TaBer: r awaiting vowel")
    ib:_processChar("u")
    eq(ib._okuri_kana, "べる",             "TaBeru: okuri_kana is べる")
    eq(ib._romaji_buf, "",                 "TaBeru: romaji_buf consumed")
    eq(ib._state, "select",                "TaBeru: still in SELECT")
    emit_log = {}
    ib:_commitCandidate()
    deep_eq(emit_log, { "食べる" },        "TaBeru+commit: emits 食べる")
end

-- Case 11: Space cycles candidates even when okurigana is in progress.
do
    local ib = newOkuriSelect("ぬ", "脱", "g")
    ib._candidates = { "脱", "抜" }  -- two candidates for navigation test
    ib:_processChar(" ")
    eq(ib._cand_idx, 2,                    "Space in okurigana SELECT: next candidate")
    eq(ib._state, "select",                "Space in okurigana SELECT: still SELECT")
    eq(ib._romaji_buf, "g",                "Space in okurigana SELECT: buf unchanged")
end

-- Case 12: x cancels selection back to CONV, clears okurigana state.
do
    local ib = newOkuriSelect("ぬ", "脱", "g")
    ib._okuri_kana = "ぐ"
    ib:_processChar("x")
    eq(ib._state, "conv",                  "x in okurigana SELECT: back to CONV")
    eq(ib._okuri_kana, "",                 "x in okurigana SELECT: okuri_kana cleared")
    eq(ib._okuri_active, false,            "x in okurigana SELECT: okuri_active cleared")
    eq(ib._reading, "ぬ",                  "x in okurigana SELECT: reading preserved")
end

-- Case 13: in NON-okurigana SELECT (entered via Space lookup, not Shift),
-- letters still auto-commit and reprocess (preserves the chained-input
-- convenience for plain noun-like conversions).
do
    emit_log = {}
    local ib = setmetatable({
        charlist = {}, charpos = 1, focused = true, is_text_edited = false,
        _skk_enabled = true,
        _state = "select",
        _reading = "かんじ", _candidates = { "漢字" }, _cand_idx = 1, _cand_page = 1,
        _romaji_buf = "", _okuri_active = false, _okuri_kana = "",
    }, { __index = SKKInputText })
    ib:_processChar("k")
    eq(ib._state, "kana",                  "plain SELECT + k: state KANA")
    eq(ib._romaji_buf, "k",                "plain SELECT + k: k buffered for next kana")
    local emitted_kanji = false
    for _, t in ipairs(emit_log) do if t == "漢字" then emitted_kanji = true end end
    eq(emitted_kanji, true,                "plain SELECT + k: 漢字 was committed")
end

-- ---- Edge case fixes (issues #1-#6) -------------------------------------

local function newPlainSelect(reading, cand)
    emit_log = {}
    return setmetatable({
        charlist = {}, charpos = 1, focused = true, is_text_edited = false,
        _skk_enabled = true,
        _state = "select",
        _reading = reading, _candidates = { cand }, _cand_idx = 1, _cand_page = 1,
        _romaji_buf = "", _okuri_active = false, _okuri_kana = "",
    }, { __index = SKKInputText })
end

-- #2: okurigana SELECT + q routes to the SELECT-q katakana commit (not into
-- the okurigana continuation branch), so the raw "g" never contaminates
-- okuri_kana. The committed text is the katakana form of the reading.
do
    local ib = newOkuriSelect("ぬ", "脱", "g")
    ib:_processChar("q")
    eq(ib._okuri_kana, "",                 "okurigana+q: okuri_kana stays clean")
    deep_eq(emit_log, { "ヌ" },            "okurigana+q: ヌ committed (q never reached okurigana branch)")
    eq(ib._state, "kana",                  "okurigana+q: back to KANA after katakana commit")
end

-- #6: q in SELECT commits the reading as katakana (no Dict.register).
do
    local ib = newPlainSelect("かんじ", "漢字")
    ib:_processChar("q")
    deep_eq(emit_log, { "カンジ" },        "SELECT+q: commits reading as katakana")
    eq(ib._state, "kana",                  "SELECT+q: state back to KANA")
    eq(ib._candidates, nil,                "SELECT+q: candidates cleared")
end

-- #6 with okurigana: q commits reading+okuri_kana as katakana.
do
    local ib = newOkuriSelect("ぬ", "脱", "")
    ib._okuri_kana = "ぐ"
    ib:_processChar("q")
    deep_eq(emit_log, { "ヌグ" },          "okurigana SELECT+q: ヌグ committed")
end

-- #3: nextCandidate at last candidate transitions to register prompt.
-- We stub _showRegisterPrompt to a recorder and verify it's called.
do
    local ib = newPlainSelect("じゃがいも", "ジャガイモ")
    ib._cand_idx = 1  -- already at the only candidate (which is also last)
    local prompted_with = nil
    ib._showRegisterPrompt = function(self, reading) prompted_with = reading end
    ib:_nextCandidate()
    eq(prompted_with, "じゃがいも",        "next at end: shows register prompt")
    eq(ib._candidates, nil,                "next at end: candidates cleared")
end

-- #4: progressive backspace — first pops romaji_buf, then okuri_kana, then cancels.
do
    local ib = newOkuriSelect("ぬ", "脱", "")
    ib._okuri_kana = "ぐ"
    ib._romaji_buf = "r"  -- pretend mid-multi-kana okurigana
    -- Step 1: backspace pops romaji_buf
    ib:_handleSpecialKey({ Backspace = true }, "", false)
    eq(ib._romaji_buf, "",                 "BS step 1: romaji_buf popped")
    eq(ib._okuri_kana, "ぐ",               "BS step 1: okuri_kana preserved")
    eq(ib._state, "select",                "BS step 1: still SELECT")
    -- Step 2: backspace pops okuri_kana
    ib:_handleSpecialKey({ Backspace = true }, "", false)
    eq(ib._okuri_kana, "",                 "BS step 2: okuri_kana popped")
    eq(ib._state, "select",                "BS step 2: still SELECT")
    -- Step 3: backspace cancels selection
    ib:_handleSpecialKey({ Backspace = true }, "", false)
    eq(ib._state, "conv",                  "BS step 3: cancelled to CONV")
end

-- #5: _startConvMode clears any stale okuri_active / okuri_kana.
do
    local ib = setmetatable({
        charlist = {}, charpos = 1, focused = true, is_text_edited = false,
        _skk_enabled = true,
        _state = "kana",
        _romaji_buf = "", _reading = "",
        _okuri_active = true,  -- stale leftover from somewhere
        _okuri_kana   = "ぐ",
    }, { __index = SKKInputText })
    ib:_startConvMode("k")
    eq(ib._okuri_active, false,            "startConv: okuri_active cleared")
    eq(ib._okuri_kana, "",                 "startConv: okuri_kana cleared")
    eq(ib._state, "conv",                  "startConv: state CONV")
    eq(ib._romaji_buf, "k",                "startConv: romaji_buf starts with k")
end

-- #1: SELECT + Shift+letter commits the candidate, then starts a new ▽ word.
-- We exercise the onKeyPress shift branch via a synthetic key event.
do
    local ib = newPlainSelect("かんじ", "漢字")
    ib._skip_textinput_at = nil  -- ensure flag would be settable
    local key = { Shift = true, key = "K" }
    ib:onKeyPress(key)
    -- 漢字 was committed, then we entered CONV with "k" in romaji_buf.
    local emitted_kanji = false
    for _, t in ipairs(emit_log) do if t == "漢字" then emitted_kanji = true end end
    eq(emitted_kanji, true,                "SELECT+Shift: 漢字 committed")
    eq(ib._state, "conv",                  "SELECT+Shift: now in CONV")
    eq(ib._romaji_buf, "k",                "SELECT+Shift: romaji_buf starts with k")
end

-- #7: Abbrev mode (/) — type "/", then letters, then Space looks up the
-- ASCII reading. Enter without Space commits the literal abbrev.
do
    -- '/' in KANA enters ABBREV with empty buffer.
    local ib = setmetatable({
        charlist = {}, charpos = 1, focused = true, is_text_edited = false,
        _skk_enabled = true,
        _state = "kana",
        _romaji_buf = "", _reading = "",
        _okuri_active = false, _okuri_kana = "",
        _preedit_chars = nil, _preedit_start = nil,
    }, { __index = SKKInputText })
    emit_log = {}
    ib:_processChar("/")
    eq(ib._state, "abbrev",                "abbrev: / enters ABBREV state")
    ib:_processChar("e")
    ib:_processChar("t")
    ib:_processChar("c")
    eq(ib._reading, "etc",                 "abbrev: chars appended literally")
    eq(ib._state, "abbrev",                "abbrev: still in ABBREV")
    -- Enter commits the literal abbrev.
    emit_log = {}
    ib:_handleSpecialKey({ Press = true }, "", false)
    deep_eq(emit_log, { "etc" },           "abbrev: Enter commits literal")
    eq(ib._state, "kana",                  "abbrev: back to KANA after Enter")
end

-- #7: Abbrev Backspace pops chars, then goes back to KANA.
do
    local ib = setmetatable({
        charlist = {}, charpos = 1, focused = true, is_text_edited = false,
        _skk_enabled = true,
        _state = "abbrev",
        _romaji_buf = "", _reading = "ab",
        _okuri_active = false, _okuri_kana = "",
        _preedit_chars = nil, _preedit_start = nil,
    }, { __index = SKKInputText })
    ib:_handleSpecialKey({ Backspace = true }, "", false)
    eq(ib._reading, "a",                   "abbrev BS: pops one char")
    eq(ib._state, "abbrev",                "abbrev BS: still ABBREV")
    ib:_handleSpecialKey({ Backspace = true }, "", false)
    eq(ib._reading, "",                    "abbrev BS: empty reading")
    eq(ib._state, "kana",                  "abbrev BS: back to KANA")
end

-- ---- Summary ------------------------------------------------------------

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
