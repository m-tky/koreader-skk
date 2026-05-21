-- SKK dictionary loader.
--
-- Dictionary search order:
--   1. Bundled SKK-JISYO.utf8 in the plugin directory  (works out of the box)
--   2. User-placed UTF-8 file in <koreader-data>/skk/
--   3. System EUC-JP file in standard locations, converted via iconv
--      (iconv is available on Linux desktop; NOT on Kindle/Kobo)
--
-- Extra dictionaries can be added at runtime via addExtraDict().
-- All dictionaries are merged into a single Lua table on first lookup.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

M.PAGE_SIZE = 9

local _dict       = nil   -- merged table: reading → { candidate, ... }
local _extra_paths = {}   -- user-added dictionary paths (persisted to settings)

-- Resolve the directory containing this source file (used for bundled dict).
local function getPluginDir()
    local src = debug.getinfo(1, "S").source
    if src:find("^@") then
        return src:gsub("^@(.*)/[^/]*$", "%1")
    end
    return "."
end

local _plugin_dir = getPluginDir()

local function getUserCacheDir()
    return DataStorage:getDataDir() .. "/skk"
end

local function getUserCacheFile()
    return getUserCacheDir() .. "/SKK-JISYO.utf8"
end

-- ----------------------------------------------------------------
-- iconv availability (checked once, cached)
-- ----------------------------------------------------------------

-- Standard locations for system EUC-JP dictionaries (Linux desktop).
-- Checked with lfs.attributes — no shell spawn required.
local EUC_SEARCH_PATHS = {
    "/usr/share/skk/SKK-JISYO.L",
    "/usr/local/share/skk/SKK-JISYO.L",
    "/usr/share/skk/SKK-JISYO.M",
    "/usr/local/share/skk/SKK-JISYO.M",
    "/usr/share/skk/SKK-JISYO.S",
}

local _iconv_checked = false
local _iconv_ok      = false

local function iconvAvailable()
    if _iconv_checked then return _iconv_ok end
    _iconv_checked = true
    -- Check common binary locations first (no process spawn needed).
    -- On Kindle/Kobo iconv doesn't exist, so this returns quickly.
    for _, p in ipairs({"/usr/bin/iconv", "/usr/local/bin/iconv", "/bin/iconv"}) do
        if lfs.attributes(p, "mode") == "file" then
            _iconv_ok = true
            return true
        end
    end
    -- Fallback for PATH-only installs (e.g. Homebrew on macOS).
    local fh = io.popen("iconv --version 2>/dev/null")
    if fh then
        local line = fh:read("*l")
        fh:close()
        _iconv_ok = (line ~= nil and line ~= "")
    end
    return _iconv_ok
end

-- Convert src (EUC-JP) to dst (UTF-8) via the iconv shell command.
-- Returns dst path on success, nil on failure.
local function convertEucToUtf8(src, dst)
    if not iconvAvailable() then
        logger.warn("SKK: iconv not available on this platform; cannot convert EUC-JP dictionaries")
        return nil
    end
    local cache_dir = getUserCacheDir()
    lfs.mkdir(cache_dir)
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        logger.warn("SKK: cannot create cache dir", cache_dir)
        return nil
    end
    dst = dst or (cache_dir .. "/" .. (src:match("[^/]+$") or "dict") .. ".utf8")
    logger.info("SKK: converting", src, "→ UTF-8 →", dst)
    local cmd = string.format(
        "iconv -f EUC-JP -t UTF-8 %q > %q 2>/dev/null", src, dst)
    if os.execute(cmd) == 0 and lfs.attributes(dst, "mode") == "file" then
        logger.info("SKK: conversion succeeded")
        return dst
    end
    os.remove(dst)
    logger.warn("SKK: iconv conversion failed for", src)
    return nil
end

-- ----------------------------------------------------------------
-- Base dictionary search
-- ----------------------------------------------------------------

local function findBaseDict()
    -- 1. Bundled UTF-8 dictionary (ships inside the plugin directory)
    local bundled = _plugin_dir .. "/SKK-JISYO.utf8"
    if lfs.attributes(bundled, "mode") == "file" then
        return bundled
    end

    -- 2. User-placed UTF-8 file in the koreader data dir
    local cache = getUserCacheFile()
    if lfs.attributes(cache, "mode") == "file" then return cache end
    local cache_dir = getUserCacheDir()
    for _, f in ipairs({"SKK-JISYO.utf8", "SKK-JISYO.L.utf8", "jisyo.utf8"}) do
        local p = cache_dir .. "/" .. f
        if lfs.attributes(p, "mode") == "file" then return p end
    end

    -- 3. System EUC-JP dictionary → convert via iconv (Linux desktop only)
    for _, src in ipairs(EUC_SEARCH_PATHS) do
        if lfs.attributes(src, "mode") == "file" then
            local converted = convertEucToUtf8(src, cache)
            if converted then return converted end
        end
    end

    return nil
end

-- ----------------------------------------------------------------
-- Parsing
-- ----------------------------------------------------------------

local function stripAnnotation(c)
    return ((c:match("^([^;]+)") or c):match("^%s*(.-)%s*$"))
end

local function parseCandidates(value_str)
    local cands = {}
    for c in value_str:gmatch("/([^/]+)") do
        local s = stripAnnotation(c)
        if s ~= "" then table.insert(cands, s) end
    end
    return cands
end

-- Merge one UTF-8 dictionary file into `tbl`. Returns entry count added.
local function mergeFile(path, tbl)
    local f = io.open(path, "r")
    if not f then
        logger.warn("SKK: cannot open", path)
        return 0
    end
    local count = 0
    for line in f:lines() do
        if line:sub(1, 1) ~= ";" and line ~= "" then
            local reading, value = line:match("^(%S+)%s+(/[^%s].-)%s*$")
            if reading and value then
                local cands = parseCandidates(value)
                if #cands > 0 then
                    if _dict[reading] then
                        for _, c in ipairs(cands) do
                            table.insert(_dict[reading], c)
                        end
                    else
                        _dict[reading] = cands
                    end
                    count = count + 1
                end
            end
        end
    end
    f:close()
    return count
end

local function loadDict()
    if _dict then return true end

    local base = findBaseDict()
    _dict = {}
    local total = 0

    if base then
        logger.info("SKK: loading base dictionary", base)
        total = total + mergeFile(base, _dict)
    else
        logger.warn("SKK: no base dictionary; place SKK-JISYO.utf8 in", _plugin_dir,
            "or", getUserCacheDir())
    end

    for _, p in ipairs(_extra_paths) do
        if lfs.attributes(p, "mode") == "file" then
            logger.info("SKK: loading extra dictionary", p)
            total = total + mergeFile(p, _dict)
        else
            logger.warn("SKK: extra dictionary not found:", p)
        end
    end

    if total > 0 then
        logger.info(string.format("SKK: loaded %d entries total", total))
    else
        logger.warn("SKK: no entries loaded")
    end
    return total > 0
end

-- ----------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------

function M.lookup(reading)
    if not _dict then loadDict() end
    return _dict[reading] or {}
end

function M.isLoaded()
    return _dict ~= nil and next(_dict) ~= nil
end

function M.ensureLoaded()
    if not _dict then loadDict() end
end

-- Register an additional UTF-8 dictionary path and reload.
-- If path appears to be EUC-JP, auto-convert if iconv is available.
-- Returns true on success, or a string error message on failure.
function M.addExtraDict(path)
    for _, p in ipairs(_extra_paths) do
        if p == path then return true end  -- already loaded
    end

    -- Auto-convert EUC-JP if needed
    if lfs.attributes(path, "mode") == "file" then
        local f = io.open(path, "r")
        if f then
            local sample = f:read(512) or ""
            f:close()
            if sample:find("[\xA1-\xFE]") then
                -- Likely EUC-JP
                if not iconvAvailable() then
                    return "EUC-JP辞書の変換にはiconvが必要ですが、\nこのデバイスでは利用できません。\nPCでUTF-8に変換してから追加してください。"
                end
                local converted = convertEucToUtf8(path)
                if not converted then
                    return "EUC-JP→UTF-8変換に失敗しました。"
                end
                path = converted
                -- Check if we already have this converted path
                for _, p in ipairs(_extra_paths) do
                    if p == path then return true end
                end
            end
        end
    end

    table.insert(_extra_paths, path)
    _dict = nil  -- force reload
    loadDict()
    G_reader_settings:saveSetting("skk_extra_dicts", _extra_paths)
    return true
end

-- Remove an extra dictionary by 1-based index and reload.
function M.removeExtraDict(idx)
    if idx < 1 or idx > #_extra_paths then return false end
    table.remove(_extra_paths, idx)
    _dict = nil
    loadDict()
    G_reader_settings:saveSetting("skk_extra_dicts", _extra_paths)
    return true
end

-- Load persisted extra paths from settings (call once from plugin :init()).
function M.loadExtraPathsFromSettings()
    local saved = G_reader_settings:readSetting("skk_extra_dicts")
    if type(saved) == "table" then
        _extra_paths = saved
    end
end

function M.getDictList()
    local result = {}
    local base = findBaseDict()
    if base then
        table.insert(result, { path = base, label = "base" })
    end
    for i, p in ipairs(_extra_paths) do
        table.insert(result, { path = p, label = string.format("extra #%d", i) })
    end
    return result
end

function M.getExtraPaths()   return _extra_paths end
function M.getPluginDir()    return _plugin_dir  end
function M.getUserCacheDir() return getUserCacheDir() end
function M.iconvAvailable()  return iconvAvailable() end

return M
