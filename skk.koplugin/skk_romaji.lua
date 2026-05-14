-- Romaji to hiragana conversion for SKK input.
-- Implements a prefix-table DFA: accumulate romaji chars until a
-- complete kana is recognised, then emit it.

local util = require("util")

local M = {}

-- Complete kana lookup: romaji_string → hiragana_string
local KANA = {
    -- Vowels
    ["a"]="あ", ["i"]="い", ["u"]="う", ["e"]="え", ["o"]="お",
    -- K
    ["ka"]="か", ["ki"]="き", ["ku"]="く", ["ke"]="け", ["ko"]="こ",
    ["kya"]="きゃ", ["kyi"]="きぃ", ["kyu"]="きゅ", ["kye"]="きぇ", ["kyo"]="きょ",
    -- G
    ["ga"]="が", ["gi"]="ぎ", ["gu"]="ぐ", ["ge"]="げ", ["go"]="ご",
    ["gya"]="ぎゃ", ["gyi"]="ぎぃ", ["gyu"]="ぎゅ", ["gye"]="ぎぇ", ["gyo"]="ぎょ",
    -- S
    ["sa"]="さ", ["si"]="し", ["su"]="す", ["se"]="せ", ["so"]="そ",
    ["shi"]="し", ["sha"]="しゃ", ["shu"]="しゅ", ["she"]="しぇ", ["sho"]="しょ",
    ["sya"]="しゃ", ["syi"]="しぃ", ["syu"]="しゅ", ["sye"]="しぇ", ["syo"]="しょ",
    -- Z
    ["za"]="ざ", ["zi"]="じ", ["zu"]="ず", ["ze"]="ぜ", ["zo"]="ぞ",
    ["ji"]="じ",
    ["ja"]="じゃ", ["ju"]="じゅ", ["je"]="じぇ", ["jo"]="じょ",
    ["zya"]="じゃ", ["zyi"]="じぃ", ["zyu"]="じゅ", ["zye"]="じぇ", ["zyo"]="じょ",
    -- T
    ["ta"]="た", ["ti"]="ち", ["tu"]="つ", ["te"]="て", ["to"]="と",
    ["chi"]="ち", ["cha"]="ちゃ", ["chu"]="ちゅ", ["che"]="ちぇ", ["cho"]="ちょ",
    ["tchi"]="っち", ["ttsu"]="っつ",
    ["tsu"]="つ",
    ["tya"]="ちゃ", ["tyi"]="ちぃ", ["tyu"]="ちゅ", ["tye"]="ちぇ", ["tyo"]="ちょ",
    ["tha"]="てゃ", ["thi"]="てぃ", ["thu"]="てゅ", ["the"]="てぇ", ["tho"]="てょ",
    ["twa"]="とぁ", ["twi"]="とぃ", ["twu"]="とぅ", ["twe"]="とぇ", ["two"]="とぉ",
    -- D
    ["da"]="だ", ["di"]="ぢ", ["du"]="づ", ["de"]="で", ["do"]="ど",
    ["dya"]="ぢゃ", ["dyi"]="ぢぃ", ["dyu"]="ぢゅ", ["dye"]="ぢぇ", ["dyo"]="ぢょ",
    ["dha"]="でゃ", ["dhi"]="でぃ", ["dhu"]="でゅ", ["dhe"]="でぇ", ["dho"]="でょ",
    ["dwa"]="どぁ", ["dwi"]="どぃ", ["dwu"]="どぅ", ["dwe"]="どぇ", ["dwo"]="どぉ",
    -- N
    ["na"]="な", ["ni"]="に", ["nu"]="ぬ", ["ne"]="ね", ["no"]="の",
    ["nya"]="にゃ", ["nyi"]="にぃ", ["nyu"]="にゅ", ["nye"]="にぇ", ["nyo"]="にょ",
    ["nn"]="ん",
    -- H
    ["ha"]="は", ["hi"]="ひ", ["hu"]="ふ", ["he"]="へ", ["ho"]="ほ",
    ["fu"]="ふ",
    ["fa"]="ふぁ", ["fi"]="ふぃ", ["fe"]="ふぇ", ["fo"]="ふぉ",
    ["hya"]="ひゃ", ["hyi"]="ひぃ", ["hyu"]="ひゅ", ["hye"]="ひぇ", ["hyo"]="ひょ",
    -- B
    ["ba"]="ば", ["bi"]="び", ["bu"]="ぶ", ["be"]="べ", ["bo"]="ぼ",
    ["bya"]="びゃ", ["byi"]="びぃ", ["byu"]="びゅ", ["bye"]="びぇ", ["byo"]="びょ",
    -- P
    ["pa"]="ぱ", ["pi"]="ぴ", ["pu"]="ぷ", ["pe"]="ぺ", ["po"]="ぽ",
    ["pya"]="ぴゃ", ["pyi"]="ぴぃ", ["pyu"]="ぴゅ", ["pye"]="ぴぇ", ["pyo"]="ぴょ",
    -- M
    ["ma"]="ま", ["mi"]="み", ["mu"]="む", ["me"]="め", ["mo"]="も",
    ["mya"]="みゃ", ["myi"]="みぃ", ["myu"]="みゅ", ["mye"]="みぇ", ["myo"]="みょ",
    -- Y
    ["ya"]="や", ["yi"]="い", ["yu"]="ゆ", ["ye"]="いぇ", ["yo"]="よ",
    -- R
    ["ra"]="ら", ["ri"]="り", ["ru"]="る", ["re"]="れ", ["ro"]="ろ",
    ["rya"]="りゃ", ["ryi"]="りぃ", ["ryu"]="りゅ", ["rye"]="りぇ", ["ryo"]="りょ",
    -- W
    ["wa"]="わ", ["wi"]="ゐ", ["wu"]="う", ["we"]="ゑ", ["wo"]="を",
    -- V (using combining)
    ["va"]="ヴぁ", ["vi"]="ヴぃ", ["vu"]="ヴ", ["ve"]="ヴぇ", ["vo"]="ヴぉ",
    -- Small kana (x prefix)
    ["xa"]="ぁ", ["xi"]="ぃ", ["xu"]="ぅ", ["xe"]="ぇ", ["xo"]="ぉ",
    ["xya"]="ゃ", ["xyu"]="ゅ", ["xyo"]="ょ",
    ["xtu"]="っ", ["xtsu"]="っ", ["xn"]="ん", ["xwa"]="ゎ",
    -- SKK z-sequences (special punctuation)
    ["z,"]="、", ["z."]="。", ["zh"]="←", ["zj"]="↓",
    ["zk"]="↑", ["zl"]="→", ["z/"]="・", ["z-"]="〜",
    ["z["]="「", ["z]"]="」", ["z("]="【", ["z)"]="】",
    ["z "]="　",  -- full-width space
}

-- Build a set of all valid romaji prefixes for fast prefix testing
local PREFIXES = {}
for seq in pairs(KANA) do
    for len = 1, #seq - 1 do
        PREFIXES[seq:sub(1, len)] = true
    end
    PREFIXES[seq] = true  -- full match is also a prefix
end

local VOWELS = { a=true, i=true, u=true, e=true, o=true }

-- Consonants that may double to produce っ
local DOUBLERS = {
    b=true, c=true, d=true, f=true, g=true, h=true, j=true, k=true,
    m=true, p=true, r=true, s=true, t=true, v=true, w=true, z=true,
}

-- Process one new character added to the romaji accumulation buffer.
-- Returns: committed (string|nil), new_buf (string)
-- • committed: kana string to insert into the text (nil = nothing yet)
-- • new_buf:   updated accumulation buffer
function M.processChar(buf, char)
    local try = buf .. char

    -- Exact match → emit kana, clear buffer
    if KANA[try] then
        return KANA[try], ""
    end

    -- Valid prefix → keep accumulating
    if PREFIXES[try] then
        return nil, try
    end

    -- Special n rule: buf=="n" and char is a consonant (not y, not another n, not vowel)
    if buf == "n" and not VOWELS[char] and char ~= "y" and char ~= "n" then
        -- emit ん, then restart processing char
        local c2, b2 = M.processChar("", char)
        return "ん" .. (c2 or ""), b2
    end

    -- Double-consonant rule: same consonant twice → っ + keep one copy.
    -- Fires for single-char buf (e.g. "k"+"k" → っ+k).
    if #buf == 1 and DOUBLERS[buf] and char == buf then
        return "っ", char
    end

    -- Doubled-consonant buffer: buf was a prefix (e.g. "tt" from "ttsu" prefix),
    -- but try is invalid.  Resolve as っ + processChar(buf[1], char).
    -- E.g. "tt"+"i" → っ + processChar("t","i") = っ + ち
    if #buf == 2 then
        local b1, b2c = buf:sub(1,1), buf:sub(2,2)
        if b1 == b2c and DOUBLERS[b1] then
            local c2, nb = M.processChar(b1, char)
            return "っ" .. (c2 or ""), nb
        end
    end

    -- No match and not a valid prefix: flush buf as ASCII, restart with char
    if #buf > 0 then
        local c2, b2 = M.processChar("", char)
        return buf .. (c2 or ""), b2
    end

    -- Single char with no match → accumulate (handles z-sequences etc.)
    return nil, char
end

-- Flush any remaining romaji buffer (e.g. on Enter or commit).
-- Returns the string to emit (may be empty string).
function M.flush(buf)
    if buf == "" then return "" end
    if buf == "n" then return "ん" end
    if KANA[buf] then return KANA[buf] end
    return buf  -- emit as ASCII
end

-- Convert a hiragana string to katakana.
local _hira_chars = {
    "ぁ","あ","ぃ","い","ぅ","う","ぇ","え","ぉ","お",
    "か","が","き","ぎ","く","ぐ","け","げ","こ","ご",
    "さ","ざ","し","じ","す","ず","せ","ぜ","そ","ぞ",
    "た","だ","ち","ぢ","っ","つ","づ","て","で","と",
    "ど","な","に","ぬ","ね","の","は","ば","ぱ","ひ",
    "び","ぴ","ふ","ぶ","ぷ","へ","べ","ぺ","ほ","ぼ",
    "ぽ","ま","み","む","め","も","ゃ","や","ゅ","ゆ",
    "ょ","よ","ら","り","る","れ","ろ","ゎ","わ","ゐ",
    "ゑ","を","ん","ゔ",
}
local _kata_chars = {
    "ァ","ア","ィ","イ","ゥ","ウ","ェ","エ","ォ","オ",
    "カ","ガ","キ","ギ","ク","グ","ケ","ゲ","コ","ゴ",
    "サ","ザ","シ","ジ","ス","ズ","セ","ゼ","ソ","ゾ",
    "タ","ダ","チ","ヂ","ッ","ツ","ヅ","テ","デ","ト",
    "ド","ナ","ニ","ヌ","ネ","ノ","ハ","バ","パ","ヒ",
    "ビ","ピ","フ","ブ","プ","ヘ","ベ","ペ","ホ","ボ",
    "ポ","マ","ミ","ム","メ","モ","ャ","ヤ","ュ","ユ",
    "ョ","ヨ","ラ","リ","ル","レ","ロ","ヮ","ワ","ヰ",
    "ヱ","ヲ","ン","ヴ",
}
local _h2k = {}
for i, h in ipairs(_hira_chars) do
    _h2k[h] = _kata_chars[i]
end

function M.toKatakana(text)
    local chars = util.splitToChars(text)
    for i, ch in ipairs(chars) do
        chars[i] = _h2k[ch] or ch
    end
    return table.concat(chars)
end

return M
