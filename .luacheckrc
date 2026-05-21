-- luacheck configuration for skk.koplugin
-- KOReader plugins run in a LuaJIT (Lua 5.1) environment with a number of
-- globals injected by the runtime.  We suppress "undefined global" warnings
-- (113) so that require()'d KOReader modules don't flood the output.
-- Syntax errors and other high-value warnings are still reported.

std = "lua51"

-- KOReader runtime globals (not reachable via require)
globals = {
    "G_reader_settings",
}

-- Ignore:
--   111 - setting undefined global  (KOReader modules set globals)
--   112 - mutating undefined global
--   113 - accessing undefined global (KOReader modules, require() results)
--   212 - unused argument            (common in KOReader callback signatures)
ignore = { "111", "112", "113", "212" }

-- Per-file overrides
files["tests/test_romaji.lua"] = {
    -- Test file defines its own globals and uses 'arg'
    globals = { "arg" },
    ignore  = { "111", "112", "113", "211", "212" },
}
