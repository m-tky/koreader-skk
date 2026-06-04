-- Unit tests for the SKK numeric-variable substitution (#0..#5).
--
-- SKK dictionaries collapse digit runs in the reading to a single "#" so that
-- a single entry covers "だい5", "だい123", etc. At display we expand #N
-- tokens in each candidate using the format selector:
--   #0 arabic, #1 kanji per-digit, #2 kanji positional, #3 zenkaku, #5 daiji.

-- ---- Stubs ---------------------------------------------------------------

package.loaded["util"] = { splitToChars = function(s)
    local out = {}
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        out[#out+1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return out
end }

-- Dict pulls in sqlite/libkoreader-lfs/etc.; replace those with no-ops so we
-- can require the module and reach into its tested helpers without booting
-- a real database.
package.loaded["datastorage"]            = { getDataDir = function() return "/tmp" end }
package.loaded["ui/widget/infomessage"]  = setmetatable({}, { __index = function() return function() end end })
package.loaded["ui/uimanager"]           = {
    show = function() end, close = function() end,
    forceRePaint = function() end, nextTick = function() end,
}
package.loaded["libs/libkoreader-lfs"]   = { attributes = function() return nil end, mkdir = function() end }
package.loaded["logger"]                 = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}
package.loaded["gettext"]                = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["lua-ljsqlite3/init"]     = { open = function() return nil end }
package.loaded["ffi/MD5"]                = { sumFile = function() return "" end }

local script_dir = arg and arg[0]:match("^(.*)/") or "."
package.path = script_dir .. "/../skk.koplugin/?.lua;" .. package.path
local Dict = require("skk_dictionary")

-- ---- Test framework ------------------------------------------------------

local pass, fail = 0, 0
local function eq(got, expected, label)
    if got == expected then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write(string.format("FAIL %s: got %q, expected %q\n",
            label, tostring(got), tostring(expected)))
    end
end

-- ---- extractNumbers ------------------------------------------------------

do
    local sub, nums = Dict._extractNumbers("だい5")
    eq(sub, "だい#",                       "extract: single digit")
    eq(#nums, 1,                           "extract: 1 number captured")
    eq(nums[1], "5",                       "extract: nums[1]=5")
end

do
    local sub, nums = Dict._extractNumbers("だい123")
    eq(sub, "だい#",                       "extract: multi-digit run")
    eq(nums[1], "123",                     "extract: captured as 123")
end

do
    local sub, nums = Dict._extractNumbers("ぺーじ5の3")
    eq(sub, "ぺーじ#の#",                  "extract: two separate runs")
    eq(nums[1], "5",                       "extract: first num")
    eq(nums[2], "3",                       "extract: second num")
end

do
    local sub, nums = Dict._extractNumbers("かんじ")
    eq(sub, "かんじ",                      "extract: no digits → unchanged")
    eq(#nums, 0,                           "extract: zero numbers")
end

-- ---- expandNumberToken ---------------------------------------------------

eq(Dict._expandNumberToken("5",   "0"), "5",     "#0: arabic")
eq(Dict._expandNumberToken("12",  "0"), "12",    "#0: multi-digit arabic")
eq(Dict._expandNumberToken("5",   "1"), "五",    "#1: kanji per-digit (single)")
eq(Dict._expandNumberToken("12",  "1"), "一二",  "#1: kanji per-digit (two)")
eq(Dict._expandNumberToken("5",   "2"), "五",    "#2: positional 5")
eq(Dict._expandNumberToken("10",  "2"), "十",    "#2: positional 10")
eq(Dict._expandNumberToken("12",  "2"), "十二",  "#2: positional 12")
eq(Dict._expandNumberToken("100", "2"), "百",    "#2: positional 100")
eq(Dict._expandNumberToken("123", "2"), "百二十三", "#2: positional 123")
eq(Dict._expandNumberToken("1234","2"), "千二百三十四", "#2: positional 1234")
eq(Dict._expandNumberToken("12345","2"), "一万二千三百四十五", "#2: positional 12345")
eq(Dict._expandNumberToken("5",   "3"), "５",    "#3: zenkaku")
eq(Dict._expandNumberToken("12",  "3"), "１２",  "#3: zenkaku multi-digit")
eq(Dict._expandNumberToken("5",   "5"), "伍",    "#5: daiji 5")
eq(Dict._expandNumberToken("12",  "5"), "拾弐",  "#5: daiji 12")
eq(Dict._expandNumberToken("5",   "9"), "#9",    "unknown format: token preserved")

-- ---- substituteCandidate -------------------------------------------------

eq(Dict._substituteCandidate("第#1巻",   {"5"}),       "第五巻",        "candidate: 第#1巻")
eq(Dict._substituteCandidate("第#0",     {"5"}),       "第5",           "candidate: 第#0")
eq(Dict._substituteCandidate("第#3章",   {"5"}),       "第５章",        "candidate: 第#3章")
eq(Dict._substituteCandidate("第#2巻",   {"12"}),      "第十二巻",      "candidate: positional kanji")
eq(Dict._substituteCandidate("p#0の#1",  {"5", "3"}),  "p5の三",        "candidate: two tokens consumed positionally")
eq(Dict._substituteCandidate("plain",    {"5"}),       "plain",         "candidate: no token → unchanged")
eq(Dict._substituteCandidate("#1",       {}),          "#1",            "candidate: not enough numbers → leave token")

-- ---- Summary ------------------------------------------------------------

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
