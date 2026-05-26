-- Unit tests for skk_romaji.lua
-- Runs with plain Lua (no KOReader runtime needed).

-- Minimal stub for util.splitToChars (UTF-8 character splitter)
package.loaded["util"] = {
    splitToChars = function(str)
        local chars = {}
        local i = 1
        while i <= #str do
            local b = str:byte(i)
            local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
            chars[#chars + 1] = str:sub(i, i + len - 1)
            i = i + len
        end
        return chars
    end,
}

-- Load module under test (path relative to repo root)
local script_dir = arg and arg[0]:match("^(.*)/") or "."
package.path = script_dir .. "/../skk.koplugin/?.lua;" .. package.path
local R = require("skk_romaji")

-- ----------------------------------------------------------------
-- Minimal test framework
-- ----------------------------------------------------------------
local pass, fail = 0, 0

local function eq(got, expected, label)
    if got == expected then
        pass = pass + 1
    else
        fail = fail + 1
        io.write(string.format("FAIL  %s\n      expected %q\n      got      %q\n",
            label, tostring(expected), tostring(got)))
    end
end

-- processChar helper: feed a whole string char-by-char, return committed output
local function feed(str)
    local buf, out = "", ""
    for i = 1, #str do
        local committed, new_buf = R.processChar(buf, str:sub(i, i))
        if committed then out = out .. committed end
        buf = new_buf
    end
    out = out .. R.flush(buf)
    return out
end

-- ----------------------------------------------------------------
-- processChar: basic vowels
-- ----------------------------------------------------------------
eq(feed("a"), "あ", "a → あ")
eq(feed("i"), "い", "i → い")
eq(feed("u"), "う", "u → う")
eq(feed("e"), "え", "e → え")
eq(feed("o"), "お", "o → お")

-- ----------------------------------------------------------------
-- processChar: consonant + vowel
-- ----------------------------------------------------------------
eq(feed("ka"), "か", "ka → か")
eq(feed("ki"), "き", "ki → き")
eq(feed("ku"), "く", "ku → く")
eq(feed("ke"), "け", "ke → け")
eq(feed("ko"), "こ", "ko → こ")
eq(feed("sa"), "さ", "sa → さ")
eq(feed("shi"), "し", "shi → し")
eq(feed("si"),  "し", "si → し")
eq(feed("chi"), "ち", "chi → ち")
eq(feed("tsu"), "つ", "tsu → つ")
eq(feed("fu"),  "ふ", "fu → ふ")

-- ----------------------------------------------------------------
-- processChar: double consonant → っ
-- ----------------------------------------------------------------
eq(feed("kka"),  "っか", "kka → っか")
eq(feed("tta"),  "った", "tta → った")
eq(feed("ssa"),  "っさ", "ssa → っさ")
eq(feed("ppa"),  "っぱ", "ppa → っぱ")
eq(feed("ttsu"), "っつ", "ttsu → っつ")

-- ----------------------------------------------------------------
-- processChar: n rules
-- ----------------------------------------------------------------
eq(feed("na"),  "な",   "na → な")
eq(feed("ni"),  "に",   "ni → に")
eq(feed("nn"),  "ん",   "nn → ん")
eq(feed("nka"), "んか", "nka → んか (n before consonant)")
eq(feed("nna"),  "んあ", "nna → んあ  (nn=ん then a=あ)")
eq(feed("nnna"), "んな", "nnna → んな (nn=ん then na=な)")
eq(feed("nya"), "にゃ", "nya → にゃ (ny not a standalone n)")
eq(feed("n'"),    "ん",   "n' → ん (apostrophe commits n)")
eq(feed("n'a"),   "んあ", "n'a → んあ")
eq(feed("kan'i"), "かんい", "kan'i → かんい")

-- ----------------------------------------------------------------
-- processChar: z-sequences
-- ----------------------------------------------------------------
eq(feed("z,"), "、", "z, → 、")
eq(feed("z."), "。", "z. → 。")
eq(feed("z-"), "〜", "z- → 〜")
eq(feed("z/"), "・", "z/ → ・")
eq(feed("z["), "「", "z[ → 「")
eq(feed("z]"), "」", "z] → 」")

-- ----------------------------------------------------------------
-- processChar: x-prefix (small kana)
-- ----------------------------------------------------------------
eq(feed("xa"),   "ぁ", "xa → ぁ")
eq(feed("xtu"),  "っ", "xtu → っ")
eq(feed("xtsu"), "っ", "xtsu → っ")

-- ----------------------------------------------------------------
-- processChar: multi-char sequences
-- ----------------------------------------------------------------
eq(feed("nihongo"), "にほんご", "nihongo → にほんご")
eq(feed("taberu"),  "たべる",   "taberu → たべる")
eq(feed("kkya"),  "っきゃ",   "kkya → っきゃ")
eq(feed("kkkya"), "っっきゃ", "kkkya → っっきゃ (k+k=っ twice, then kya)")

-- ----------------------------------------------------------------
-- flush
-- ----------------------------------------------------------------
eq(R.flush(""),  "",  "flush empty → empty")
eq(R.flush("n"), "ん", "flush n → ん")
eq(R.flush("k"), "k",  "flush k → k (incomplete, emit as ASCII)")

-- ----------------------------------------------------------------
-- toKatakana
-- ----------------------------------------------------------------
eq(R.toKatakana("あいうえお"), "アイウエオ", "toKatakana vowels")
eq(R.toKatakana("かきくけこ"), "カキクケコ", "toKatakana k-row")
eq(R.toKatakana("さしすせそ"), "サシスセソ", "toKatakana s-row")
eq(R.toKatakana("にほんご"),   "ニホンゴ",   "toKatakana nihongo")
eq(R.toKatakana("っ"),         "ッ",         "toKatakana っ → ッ")
eq(R.toKatakana("hello"),      "hello",      "toKatakana ASCII passthrough")

-- ----------------------------------------------------------------
-- Summary
-- ----------------------------------------------------------------
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
