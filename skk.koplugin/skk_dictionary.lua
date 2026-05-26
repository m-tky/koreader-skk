-- SKK dictionary — SQLite backend.
--
-- The bundled SKK-JISYO.utf8 is the source of truth.
-- On first use (or when the source file changes), it is converted to a
-- SQLite database stored in <koreader-data>/skk/SKK-JISYO.db.
-- Subsequent startups open the DB instantly with no parsing overhead.
--
-- Change detection (two-stage):
--   1. lfs size+mtime check  (free, one syscall)
--   2. MD5 hash              (only when size/mtime differ)
--
-- The user_dict table in the same DB records registered words and their
-- use counts.  It is never dropped during a dict rebuild.

local DataStorage = require("datastorage")
local InfoMessage  = require("ui/widget/infomessage")
local UIManager    = require("ui/uimanager")
local lfs          = require("libs/libkoreader-lfs")
local logger       = require("logger")
local _            = require("gettext")

local SQ3 = require("lua-ljsqlite3/init")
local md5 = require("ffi/md5")

local M = {}

M.PAGE_SIZE = 9

-- ----------------------------------------------------------------
-- Paths
-- ----------------------------------------------------------------

local function getPluginDir()
    local src = debug.getinfo(1, "S").source
    if src:find("^@") then return src:gsub("^@(.*)/[^/]*$", "%1") end
    return "."
end

local _plugin_dir  = getPluginDir()
local _utf8_path   = _plugin_dir .. "/SKK-JISYO.utf8"

local function getDataDir()  return DataStorage:getDataDir() .. "/skk" end
local function getDBPath()   return getDataDir() .. "/SKK-JISYO.db" end

-- ----------------------------------------------------------------
-- Connection
-- ----------------------------------------------------------------

local _conn       = nil   -- persistent SQLite connection (nil while building)
local _building   = false -- true while async build is running

local function openConn()
    if _conn then return end
    local ok, c = pcall(SQ3.open, getDBPath())
    if ok then _conn = c else logger.err("SKK: cannot open DB:", c) end
end

local function closeConn()
    if _conn then _conn:close(); _conn = nil end
end

-- ----------------------------------------------------------------
-- Schema
-- ----------------------------------------------------------------

local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS dict (
        reading    TEXT PRIMARY KEY,
        candidates TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS user_dict (
        reading    TEXT    NOT NULL,
        candidate  TEXT    NOT NULL,
        use_count  INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_used  INTEGER,
        PRIMARY KEY (reading, candidate)
    );
    CREATE INDEX IF NOT EXISTS idx_user_reading ON user_dict(reading);
    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    PRAGMA user_version = 1;
]]

local function initSchema(conn)
    conn:exec(SCHEMA)
end

-- ----------------------------------------------------------------
-- Parsing helpers (shared with build and addExtraDict)
-- ----------------------------------------------------------------

local function stripAnnotation(c)
    return ((c:match("^([^;]+)") or c):match("^%s*(.-)%s*$"))
end

local function parseLine(line)
    if line:sub(1, 1) == ";" or line == "" then return nil end
    local reading, value = line:match("^(%S+)%s+(/[^%s].-)%s*$")
    if not (reading and value) then return nil end
    local cands = {}
    for c in value:gmatch("/([^/]+)") do
        local s = stripAnnotation(c)
        if s ~= "" then table.insert(cands, s) end
    end
    if #cands == 0 then return nil end
    return reading, cands
end

-- ----------------------------------------------------------------
-- Build: convert .utf8 → dict table (coroutine-friendly)
-- ----------------------------------------------------------------

-- Insert base dictionary rows.  SKK-JISYO files have unique readings per
-- file, so INSERT OR REPLACE is safe and fast.
local function buildBaseDict(conn, utf8_path)
    conn:exec("DROP TABLE IF EXISTS dict;")
    conn:exec("CREATE TABLE dict (reading TEXT PRIMARY KEY, candidates TEXT NOT NULL);")
    conn:exec("BEGIN;")
    local stmt = conn:prepare("INSERT OR REPLACE INTO dict VALUES (?, ?);")
    local count = 0
    for line in io.lines(utf8_path) do
        local reading, cands = parseLine(line)
        if reading then
            stmt:reset():bind(reading, table.concat(cands, "|")):step()
            count = count + 1
            if count % 1000 == 0 then coroutine.yield() end
        end
    end
    conn:exec("COMMIT;")
    return count
end

-- Merge an extra dictionary into the existing dict table.
-- For readings already present, candidates are merged with deduplication.
local function mergeExtraDict(conn, utf8_path)
    local stmt_sel = conn:prepare("SELECT candidates FROM dict WHERE reading=?")
    local stmt_ins = conn:prepare("INSERT INTO dict VALUES (?, ?)")
    local stmt_upd = conn:prepare("UPDATE dict SET candidates=? WHERE reading=?")
    conn:exec("BEGIN;")
    local count = 0
    for line in io.lines(utf8_path) do
        local reading, new_cands = parseLine(line)
        if reading then
            local row = stmt_sel:reset():bind(reading):step()
            if row then
                local seen, merged = {}, {}
                for c in row[1]:gmatch("[^|]+") do
                    if not seen[c] then merged[#merged+1] = c; seen[c] = true end
                end
                for _, c in ipairs(new_cands) do
                    if not seen[c] then merged[#merged+1] = c; seen[c] = true end
                end
                stmt_upd:reset():bind(table.concat(merged, "|"), reading):step()
            else
                stmt_ins:reset():bind(reading, table.concat(new_cands, "|")):step()
            end
            count = count + 1
            if count % 500 == 0 then coroutine.yield() end
        end
    end
    conn:exec("COMMIT;")
    return count
end

-- Write source metadata to the meta table.
local function saveMeta(conn, utf8_path, hash)
    local attr = lfs.attributes(utf8_path) or {}
    local set  = conn:prepare(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
    set:reset():bind("source_path",  utf8_path):step()
    set:reset():bind("source_hash",  hash or ""):step()
    set:reset():bind("source_mtime", tostring(attr.modification or 0)):step()
    set:reset():bind("source_size",  tostring(attr.size or 0)):step()
end

-- Run the full build in a coroutine, showing a progress message.
-- extra_paths is an array of additional .utf8 paths to merge.
-- on_done() is called after the connection is (re-)opened.
local function asyncBuild(utf8_path, extra_paths, on_done)
    if _building then return end
    _building = true
    closeConn()

    local db_path = getDBPath()
    lfs.mkdir(getDataDir())

    -- Open a temporary connection for building (separate from _conn).
    local build_conn = SQ3.open(db_path)
    initSchema(build_conn)

    local msg = InfoMessage:new{ text = _("SKK: converting dictionary…") }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local co = coroutine.create(function()
        buildBaseDict(build_conn, utf8_path)
        for _, p in ipairs(extra_paths or {}) do
            if lfs.attributes(p, "mode") == "file" then
                mergeExtraDict(build_conn, p)
            end
        end
        local hash = md5.sumFile(utf8_path) or ""
        saveMeta(build_conn, utf8_path, hash)
        build_conn:close()
    end)

    local function step()
        local ok, err = coroutine.resume(co)
        if not ok then
            logger.err("SKK: dict build error:", err)
            build_conn:close()
            _building = false
            UIManager:close(msg)
            return
        end
        if coroutine.status(co) ~= "dead" then
            UIManager:nextTick(step)
        else
            _building = false
            UIManager:close(msg)
            openConn()
            if on_done then on_done() end
        end
    end
    UIManager:nextTick(step)
end

-- ----------------------------------------------------------------
-- Change detection
-- ----------------------------------------------------------------

local function metaValue(conn, key)
    local row = conn:prepare("SELECT value FROM meta WHERE key=?")
                    :reset():bind(key):step()
    return row and row[1] or nil
end

-- Returns true when the DB needs to be (re-)built.
local function needsRebuild(utf8_path)
    local db_path = getDBPath()
    if lfs.attributes(db_path, "mode") ~= "file" then return true end

    -- Fast path: compare size + mtime without reading the file.
    local attr = lfs.attributes(utf8_path)
    if not attr then return false end  -- source missing, keep existing DB

    local ok, conn = pcall(SQ3.open, db_path)
    if not ok then return true end

    local stored_mtime = metaValue(conn, "source_mtime")
    local stored_size  = metaValue(conn, "source_size")

    if tostring(attr.modification) == stored_mtime
            and tostring(attr.size) == stored_size then
        conn:close()
        return false
    end

    -- Slow path: verify with MD5 to avoid false positives from file copies.
    local current_hash = md5.sumFile(utf8_path) or ""
    local stored_hash  = metaValue(conn, "source_hash") or ""

    if current_hash == stored_hash then
        -- Content unchanged; update mtime/size so we skip MD5 next time.
        local set = conn:prepare(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
        set:reset():bind("source_mtime", tostring(attr.modification)):step()
        set:reset():bind("source_size",  tostring(attr.size)):step()
        conn:close()
        return false
    end

    conn:close()
    return true
end

-- ----------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------

local _extra_paths = {}

-- Ensure the database is open and up to date.
-- If a rebuild is needed it runs asynchronously; lookup() returns {}
-- in the meantime (keyboard still works for romaji input).
function M.ensureDB(on_done)
    if _building then return end
    if lfs.attributes(_utf8_path, "mode") ~= "file" then
        logger.warn("SKK: source dictionary not found:", _utf8_path)
        return
    end
    if needsRebuild(_utf8_path) then
        asyncBuild(_utf8_path, _extra_paths, on_done)
    else
        openConn()
        if on_done then on_done() end
    end
end

function M.isReady()
    return _conn ~= nil
end

function M.isBuilding()
    return _building
end

function M.lookup(reading)
    if not _conn then return {} end
    local results, seen = {}, {}
    -- User dict first, sorted by use frequency then recency.
    local ustmt = _conn:prepare(
        "SELECT candidate FROM user_dict WHERE reading=?"..
        " ORDER BY use_count DESC, last_used DESC")
    ustmt:reset():bind(reading)
    local row = ustmt:step()
    while row do
        results[#results+1] = row[1]; seen[row[1]] = true
        row = ustmt:step()
    end
    -- Main dict, deduplicating against user dict results.
    local mrow = _conn:prepare("SELECT candidates FROM dict WHERE reading=?")
                      :reset():bind(reading):step()
    if mrow then
        for c in mrow[1]:gmatch("[^|]+") do
            if not seen[c] then results[#results+1] = c; seen[c] = true end
        end
    end
    return results
end

-- Register or increment a user word.
function M.register(reading, kanji)
    if not _conn then return end
    local now = os.time()
    _conn:prepare([[
        INSERT INTO user_dict (reading, candidate, use_count, created_at, last_used)
        VALUES (?, ?, 1, ?, ?)
        ON CONFLICT(reading, candidate) DO UPDATE
        SET use_count = use_count + 1, last_used = excluded.last_used
    ]]):reset():bind(reading, kanji, now, now):step()
end

-- Return all user dict entries as {reading, candidate, use_count, last_used}.
function M.getUserDictEntries()
    if not _conn then return {} end
    local rows = _conn:exec(
        "SELECT reading, candidate, use_count, last_used"..
        " FROM user_dict ORDER BY last_used DESC, reading")
    local entries = {}
    if rows and rows.reading then
        for i = 1, #rows.reading do
            entries[#entries+1] = {
                reading   = rows.reading[i],
                candidate = rows.candidate[i],
                use_count = tonumber(rows.use_count[i]) or 0,
                last_used = tonumber(rows.last_used[i]),
            }
        end
    end
    return entries
end

function M.deleteUserDictEntry(reading, candidate)
    if not _conn then return end
    _conn:prepare("DELETE FROM user_dict WHERE reading=? AND candidate=?")
         :reset():bind(reading, candidate):step()
end

-- Export user dict to an SKK-format UTF-8 file.
function M.exportUserDict(path)
    if not _conn then return false, "dictionary not ready" end
    local rows = _conn:exec(
        "SELECT reading, candidate FROM user_dict ORDER BY reading")
    if not rows or not rows.reading then return false, "no entries" end
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(";; SKK user dictionary (exported)\n")
    -- Group by reading for compact output.
    local groups = {}
    for i = 1, #rows.reading do
        local r = rows.reading[i]
        if not groups[r] then groups[r] = {} end
        groups[r][#groups[r]+1] = rows.candidate[i]
    end
    local readings = {}
    for r in pairs(groups) do readings[#readings+1] = r end
    table.sort(readings)
    for _, r in ipairs(readings) do
        f:write(r .. " /" .. table.concat(groups[r], "/") .. "/\n")
    end
    f:close()
    return true
end

-- ----------------------------------------------------------------
-- Extra dictionaries
-- ----------------------------------------------------------------

function M.loadExtraPathsFromSettings()
    local saved = G_reader_settings:readSetting("skk_extra_dicts")
    if type(saved) == "table" then _extra_paths = saved end
end

function M.getExtraPaths() return _extra_paths end

-- Detect file encoding by sampling.
-- Returns "utf8", "eucjp", or "unknown".
-- Strategy:
--   1. Look for an SKK coding declaration in the first ~512 bytes.
--   2. Otherwise scan up to 64 KB and check whether it is valid UTF-8.
--      Invalid UTF-8 with bytes in the EUC-JP range → "eucjp".
local function detectEncoding(path)
    local f = io.open(path, "rb")
    if not f then return "unknown" end
    local head = f:read(512) or ""
    -- SKK files typically start with: ;; -*- coding: utf-8 -*-
    local coding = head:lower():match("coding:%s*([%w%-_]+)")
    if coding then
        f:close()
        if coding:find("utf") then return "utf8" end
        if coding:find("euc") then return "eucjp" end
    end
    -- UTF-8 validity scan over a larger sample.
    local sample = head .. (f:read(64 * 1024) or "")
    f:close()
    local i, n, has_high = 1, #sample, false
    while i <= n do
        local b = sample:byte(i)
        if b < 0x80 then
            i = i + 1
        else
            has_high = true
            local need
            if     b >= 0xC2 and b <= 0xDF then need = 1
            elseif b >= 0xE0 and b <= 0xEF then need = 2
            elseif b >= 0xF0 and b <= 0xF4 then need = 3
            else return "eucjp" end  -- invalid UTF-8 lead byte
            if i + need > n then break end  -- truncated, treat as valid
            for j = 1, need do
                local cb = sample:byte(i + j)
                if cb < 0x80 or cb > 0xBF then return "eucjp" end
            end
            i = i + need + 1
        end
    end
    return has_high and "utf8" or "utf8"  -- pure ASCII counts as UTF-8
end

function M.addExtraDict(path)
    -- Dedup against the user-supplied path (covers re-add of UTF-8 files).
    for _, p in ipairs(_extra_paths) do if p == path then return true end end

    -- Auto-convert EUC-JP if needed (reuse iconv logic).
    if lfs.attributes(path, "mode") == "file" then
        if detectEncoding(path) == "eucjp" then
            if not M.iconvAvailable() then
                return _("EUC-JP dictionaries need iconv to convert,\n"..
                         "but iconv is not available on this device.\n"..
                         "Please convert the file to UTF-8 on a PC first.")
            end
            local converted = M._convertEucToUtf8(path)
            if not converted then
                return _("EUC-JP → UTF-8 conversion failed.")
            end
            path = converted
        end
    end

    -- Dedup against the converted path (covers re-add of the same EUC-JP source).
    for _, p in ipairs(_extra_paths) do if p == path then return true end end

    _extra_paths[#_extra_paths+1] = path
    G_reader_settings:saveSetting("skk_extra_dicts", _extra_paths)
    -- Rebuild to incorporate the new dict.
    asyncBuild(_utf8_path, _extra_paths)
    return true
end

function M.removeExtraDict(idx)
    if idx < 1 or idx > #_extra_paths then return false end
    table.remove(_extra_paths, idx)
    G_reader_settings:saveSetting("skk_extra_dicts", _extra_paths)
    asyncBuild(_utf8_path, _extra_paths)
    return true
end

-- ----------------------------------------------------------------
-- Dictionary list (for UI)
-- ----------------------------------------------------------------

function M.getDictList()
    local result = {}
    if lfs.attributes(_utf8_path, "mode") == "file" then
        result[#result+1] = { path = _utf8_path, label = "base" }
    end
    for i, p in ipairs(_extra_paths) do
        result[#result+1] = { path = p, label = string.format("extra #%d", i) }
    end
    return result
end

-- ----------------------------------------------------------------
-- iconv support (unchanged from previous version)
-- ----------------------------------------------------------------

local _iconv_checked, _iconv_ok = false, false

function M.iconvAvailable()
    if _iconv_checked then return _iconv_ok end
    _iconv_checked = true
    for _, p in ipairs({"/usr/bin/iconv", "/usr/local/bin/iconv", "/bin/iconv"}) do
        if lfs.attributes(p, "mode") == "file" then
            _iconv_ok = true; return true
        end
    end
    local fh = io.popen("iconv --version 2>/dev/null")
    if fh then
        local line = fh:read("*l"); fh:close()
        _iconv_ok = (line ~= nil and line ~= "")
    end
    return _iconv_ok
end

-- POSIX-shell-safe single-quote escape: 'a'b' → 'a'\''b'.
local function shellEscape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M._convertEucToUtf8(src)
    if not M.iconvAvailable() then return nil end
    local cache_dir = getDataDir()
    lfs.mkdir(cache_dir)
    local dst = cache_dir .. "/" .. (src:match("[^/]+$") or "dict") .. ".utf8"
    logger.info("SKK: converting", src, "→", dst)
    local cmd = "iconv -f EUC-JP -t UTF-8 " .. shellEscape(src)
        .. " > " .. shellEscape(dst) .. " 2>/dev/null"
    if os.execute(cmd) == 0 and lfs.attributes(dst, "mode") == "file" then
        return dst
    end
    os.remove(dst)
    return nil
end

-- ----------------------------------------------------------------
-- Accessors used by main.lua / UI
-- ----------------------------------------------------------------

function M.getPluginDir()    return _plugin_dir end
function M.getDataDir()      return getDataDir() end

-- Called by plugin:onCloseWidget() to release the DB connection.
function M.close()
    closeConn()
end

return M
