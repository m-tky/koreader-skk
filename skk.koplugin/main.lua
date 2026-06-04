-- SKK Japanese input plugin for KOReader.
-- When enabled, replaces InputDialog's inputtext_class with SKKInputText,
-- giving all text input fields SKK-style romaji→kana→kanji conversion.
--
-- Key bindings (while typing in any input field):
--   Ctrl+\        Toggle SKK on/off for this field
--   lowercase     → hiragana (via romaji)
--   q             Hiragana ↔ Katakana mode
--   l             Disable SKK (ASCII pass-through until re-enabled)
--   Shift+letter  Start kanji conversion (▽ mode)
--   Space (▽)     Look up candidates (▼ mode)
--   Space/n (▼)   Next candidate
--   p (▼)         Previous candidate
--   1-9 (▼)       Select candidate directly
--   Enter         Commit
--   Backspace     Delete / cancel conversion
--   x (▼)         Cancel candidate selection

local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

-- Plugin works on all devices:
-- - Physical keyboard / SDL emulator: via SKKInputText (InputDialog.inputtext_class)
-- - Touch/virtual keyboard: via skk_keyboard layout (wrapInputBox)

local Dict = require("skk_dictionary")
local SKKInputText = require("skk_inputtext")

local _meta = require("_meta")
local PLUGIN_VERSION = _meta.version or "0.0.0"
local GITHUB_REPO    = "m-tky/koreader-skk"
local RELEASE_ASSET  = "skk.koplugin.zip"

local SKK = WidgetContainer:extend{
    name = "skk",
    is_doc_only = false,
    _enabled = false,
    _orig_inputtext_class = nil,
}

function SKK:init()
    self.ui.menu:registerToMainMenu(self)
    Dict.loadExtraPathsFromSettings()
    self:_ensureSKKInKeyboardLayouts()
    self:_registerKeyboardLayout()
    -- On SDL emulator (hasKeyboard=true), the virtual keyboard is hidden by
    -- default. Auto-enable it so users can see the 🌐 key without extra setup.
    -- On real touch-only devices (Kindle, Android) this setting is irrelevant.
    if Device:isSDL() and Device:hasKeyboard()
            and not G_reader_settings:isTrue("virtual_keyboard_enabled") then
        G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
        logger.info("SKK: auto-enabled virtual keyboard for SDL emulator")
    end
    self._enabled = G_reader_settings:isTrue("skk_enabled")
    if self._enabled then
        self:_activate()
        UIManager:nextTick(function() Dict.ensureDB() end)
    end
end

-- Register the SKK keyboard layout with VirtualKeyboard and Language
-- without requiring any changes to core KOReader files.
function SKK:_registerKeyboardLayout()
    -- Intercept VirtualKeyboard's require so it loads our plugin-local copy.
    package.preload["ui/data/keyboardlayouts/ja_skk_keyboard"] = function()
        return require("ja_skk_keyboard")
    end
    local ok, VK = pcall(require, "ui/widget/virtualkeyboard")
    if ok and VK then
        VK.lang_to_keyboard_layout["js"] = "ja_skk_keyboard"
        if VK.lang_has_submenu then
            VK.lang_has_submenu["js"] = true
        end
    end
    local ok2, Lang = pcall(require, "ui/language")
    if ok2 and Lang then
        Lang.language_names["js"] = "日本語 SKK"
        Lang.LangMenuTable = nil  -- invalidate cache so new entry appears
    end
    logger.info("SKK: registered 'js' keyboard layout")
end

-- Undo _registerKeyboardLayout (called on plugin unload).
function SKK:_unregisterKeyboardLayout()
    package.preload["ui/data/keyboardlayouts/ja_skk_keyboard"] = nil
    package.loaded["ui/data/keyboardlayouts/ja_skk_keyboard"] = nil
    package.loaded["ja_skk_keyboard"] = nil
    local ok, VK = pcall(require, "ui/widget/virtualkeyboard")
    if ok and VK then
        VK.lang_to_keyboard_layout["js"] = nil
        if VK.lang_has_submenu then
            VK.lang_has_submenu["js"] = nil
        end
    end
    local ok2, Lang = pcall(require, "ui/language")
    if ok2 and Lang then
        Lang.language_names["js"] = nil
        Lang.LangMenuTable = nil
    end
    logger.info("SKK: unregistered 'js' keyboard layout")
end

-- Add "js" to keyboard_layouts if not already present.
-- This makes it visible in the 🌐 key switcher immediately.
function SKK:_ensureSKKInKeyboardLayouts()
    local util_mod = require("util")
    local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    if not util_mod.arrayContains(layouts, "js") then
        -- Insert at position 1 so "sk" appears first in the 🌐 popup.
        -- The popup shows at most 4 layouts; inserting at end risks being hidden.
        table.insert(layouts, 1, "js")
        G_reader_settings:saveSetting("keyboard_layouts", layouts)
        logger.info("SKK: added 'js' to keyboard_layouts (position 1)")
    end
end

function SKK:addToMainMenu(menu_items)
    menu_items.skk = {
        text = _("SKK Japanese Input"),
        sub_item_table = {
            {
                text = _("Enable SKK"),
                checked_func = function() return self._enabled end,
                callback = function()
                    self._enabled = not self._enabled
                    G_reader_settings:saveSetting("skk_enabled", self._enabled)
                    if self._enabled then
                        self:_activate()
                        Dict.ensureDB()
                        UIManager:show(InfoMessage:new{
                            text = _("SKK enabled.\n"..
                                     "Ctrl+\\ toggles SKK per field.\n"..
                                     "Shift+letter → kanji conversion."),
                            timeout = 3,
                        })
                    else
                        self:_deactivate()
                    end
                end,
            },
            {
                text = _("Dictionaries"),
                callback = function() self:_showDictMenu() end,
            },
            {
                text = _("User dictionary"),
                callback = function() self:_showUserDictMenu() end,
            },
            {
                text = _("Virtual keyboard (touch devices)"),
                callback = function() self:_showVKBDMenu() end,
            },
            {
                text = string.format(_("Check for updates  (current: v%s)"), PLUGIN_VERSION),
                callback = function()
                    NetworkMgr:runWhenOnline(function() self:_checkForUpdates() end)
                end,
            },
            {
                text = _("Key bindings"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _(
                            "Ctrl+\\    Toggle SKK on/off\n"..
                            "q         Hiragana ↔ Katakana\n"..
                            "l         Disable SKK (ASCII mode)\n"..
                            "Shift+A-Z Start kanji conversion (▽)\n"..
                            "Space     Convert / next candidate\n"..
                            "Enter     Commit\n"..
                            "Backspace Delete / cancel\n"..
                            "x         Cancel candidate selection\n"..
                            "1-9       Select candidate by number\n"..
                            "n / p     Next / previous candidate"
                        ),
                    })
                end,
            },
        },
    }
end

-- ---- Virtual keyboard (touch) UI ------------------------------

function SKK:_showVKBDMenu()
    local current_layout = G_reader_settings:readSetting("keyboard_layout") or "en"
    local is_skk = (current_layout == "js")

    -- Check if skk is in active layouts list
    local keyboard_layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    local util_mod = require("util")
    local is_enabled = util_mod.arrayContains(keyboard_layouts, "js")

    local vkbd_enabled = G_reader_settings:isTrue("virtual_keyboard_enabled")

    local status_lines = {
        _("SKK virtual keyboard (touch / no-physical-keyboard):"),
        "",
        string.format(_("Current layout: %s"), current_layout),
        string.format(_("SKK in active layouts: %s"), is_enabled and _("Yes ✓") or _("No")),
        string.format(_("Virtual keyboard shown: %s"),
            vkbd_enabled and _("Yes (forced)") or _("Auto (by device type)")),
        "",
        _("On touch-only devices (Kindle, Android) the virtual keyboard"),
        _("appears automatically. On devices with a physical keyboard"),
        _("(emulator) you may need to enable it manually."),
    }

    local buttons = {
        {{
            text = is_enabled
                and _("SKK keyboard layout is active ✓")
                or  _("Activate SKK keyboard layout"),
            callback = function()
                UIManager:close(self._vkbd_dialog)
                self:_activateSKKLayout()
            end,
            enabled = not is_enabled,
        }},
        {{
            text = is_skk
                and _("SKK is current layout ✓")
                or  _("Switch to SKK layout now"),
            callback = function()
                UIManager:close(self._vkbd_dialog)
                self:_switchToSKKLayout()
            end,
            enabled = not is_skk,
        }},
        {{
            text = vkbd_enabled
                and _("Virtual keyboard: forced ON")
                or  _("Force virtual keyboard ON (for emulator)"),
            callback = function()
                UIManager:close(self._vkbd_dialog)
                G_reader_settings:saveSetting("virtual_keyboard_enabled", not vkbd_enabled)
                UIManager:show(InfoMessage:new{
                    text = vkbd_enabled
                        and _("Virtual keyboard set to auto (device default).")
                        or  _("Virtual keyboard forced ON.\nOpen any text field to use it."),
                    timeout = 3,
                })
            end,
        }},
        {{
            text = _("Close"),
            callback = function() UIManager:close(self._vkbd_dialog) end,
        }},
    }

    self._vkbd_dialog = require("ui/widget/buttondialog"):new{
        title = _("SKK Virtual Keyboard"),
        title_align = "center",
        -- Show status as the first (disabled) button rows
        buttons = {
            {{ text = table.concat(status_lines, "\n"), enabled = false }},
        },
    }
    -- Merge remaining buttons
    for _, b in ipairs(buttons) do
        table.insert(self._vkbd_dialog.buttons, b)
    end
    UIManager:show(self._vkbd_dialog)
end

function SKK:_activateSKKLayout()
    local keyboard_layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    local util_mod = require("util")
    if not util_mod.arrayContains(keyboard_layouts, "js") then
        table.insert(keyboard_layouts, 1, "js")
        G_reader_settings:saveSetting("keyboard_layouts", keyboard_layouts)
    end
    UIManager:show(InfoMessage:new{
        text = _("SKK keyboard layout activated.\n"..
                 "It will appear in the 🌐 keyboard switcher.\n\n"..
                 "To use it: open a text field, tap 🌐, select 日本語 SKK."),
        timeout = 4,
    })
end

function SKK:_switchToSKKLayout()
    G_reader_settings:saveSetting("keyboard_layout", "js")
    -- Also add to active list if not there
    self:_activateSKKLayout()
    UIManager:show(InfoMessage:new{
        text = _("Switched to SKK keyboard layout.\n"..
                 "Open a text field to start typing Japanese."),
        timeout = 3,
    })
end

-- ---- Dictionary management UI ----------------------------------

function SKK:_showDictMenu()
    local dict_list = Dict.getDictList()
    local extra_paths = Dict.getExtraPaths()

    -- Build status text
    local lines = {}
    if #dict_list == 0 then
        table.insert(lines, _("No dictionary loaded."))
    else
        for _, d in ipairs(dict_list) do
            local short = d.path:match("[^/]+$") or d.path
            local loaded = Dict.isReady() and "✓ " or "? "
            table.insert(lines, loaded .. "[" .. d.label .. "] " .. short)
        end
    end
    local status_text = table.concat(lines, "\n")

    -- Extra dicts removal buttons (one per extra dict)
    local remove_buttons = {}
    for i, p in ipairs(extra_paths) do
        local short = p:match("[^/]+$") or p
        local idx = i  -- capture
        table.insert(remove_buttons, {
            text = string.format(_("Remove: %s"), short),
            callback = function()
                UIManager:close(self._dict_dialog)
                Dict.removeExtraDict(idx)
                UIManager:show(InfoMessage:new{
                    text = _("Dictionary removed and reloaded."),
                    timeout = 2,
                })
            end,
        })
    end

    local buttons = {
        -- Status row
        {{ text = status_text, enabled = false }},
        -- Add dictionary button
        {{
            text = _("Add dictionary…"),
            callback = function()
                UIManager:close(self._dict_dialog)
                self:_showAddDictDialog()
            end,
        }},
    }

    -- Insert remove buttons (one per row)
    for _, btn in ipairs(remove_buttons) do
        table.insert(buttons, { btn })
    end

    -- Help / path info row
    table.insert(buttons, {{
        text = _("Where to place dictionaries"),
        callback = function()
            local iconv_status = Dict.iconvAvailable()
                and _("iconv: available (EUC-JP auto-convert enabled)")
                or  _("iconv: NOT available (UTF-8 files only)")
            UIManager:show(InfoMessage:new{
                text = string.format(_(
                    "Plugin directory:\n%s\n\n"..
                    "Data directory:\n%s\n\n"..
                    "%s"),
                    Dict.getPluginDir(),
                    Dict.getDataDir(),
                    iconv_status),
            })
        end,
    }})

    -- Close button
    table.insert(buttons, {{
        text = _("Close"),
        callback = function() UIManager:close(self._dict_dialog) end,
    }})

    self._dict_dialog = ButtonDialog:new{
        title = _("SKK Dictionaries"),
        buttons = buttons,
    }
    UIManager:show(self._dict_dialog)
end

function SKK:_showAddDictDialog()
    local hint = string.format(_(
        "Enter the full path to a UTF-8 SKK dictionary file.\n"..
        "Example: %s/my-extra.utf8"),
        Dict.getDataDir())

    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Add Dictionary"),
        description = hint,
        input = "",
        input_hint = _("/path/to/SKK-JISYO.utf8"),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Add"),
                is_enter_default = true,
                callback = function()
                    local path = input_dialog:getInputText()
                    UIManager:close(input_dialog)
                    self:_addDict(path)
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function SKK:_addDict(path)
    path = path:match("^%s*(.-)%s*$")  -- trim
    if path == "" then return end

    if lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = string.format(_("File not found:\n%s"), path),
        })
        return
    end

    -- Dict.addExtraDict handles EUC-JP detection and iconv conversion.
    -- Returns true on success, or an error string on failure.
    local result = Dict.addExtraDict(path)
    if result == true then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Dictionary added:\n%s"), path),
            timeout = 2,
        })
    else
        -- result is an error message string
        UIManager:show(InfoMessage:new{
            text = tostring(result),
        })
    end
end

-- ---- Plugin update ---------------------------------------------

-- Simple semver comparison: "0.3.1" > "0.3.0" → true.
local function isNewer(remote, local_v)
    local function parts(v)
        local a, b, c = v:match("^v?(%d+)%.(%d+)%.(%d+)")
        return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
    end
    local ra, rb, rc = parts(remote)
    local la, lb, lc = parts(local_v)
    if ra ~= la then return ra > la end
    if rb ~= lb then return rb > lb end
    return rc > lc
end

-- Fetch a URL and return body string, or nil + error message.
local function httpGet(url)
    local http       = require("socket.http")
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")
    local body = {}
    socketutil:set_timeout(15)
    local ok, code = http.request{
        url     = url,
        headers = { ["User-Agent"] = "koreader-skk/" .. PLUGIN_VERSION },
        sink    = ltn12.sink.table(body),
    }
    socketutil:reset_timeout()
    if ok and code == 200 then
        return table.concat(body)
    end
    return nil, string.format("HTTP %s", tostring(code))
end

-- Stream a URL straight to disk. Used for the release zip so the dictionary
-- (~6 MB) never lives in RAM. Returns true on success, or nil + error.
local function httpDownload(url, dest_path)
    local http       = require("socket.http")
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")
    local f, ferr = io.open(dest_path, "wb")
    if not f then return nil, ferr end
    socketutil:set_timeout(15, 120)
    local ok, code = http.request{
        url     = url,
        headers = { ["User-Agent"] = "koreader-skk/" .. PLUGIN_VERSION },
        sink    = ltn12.sink.file(f),  -- closes f on completion
    }
    socketutil:reset_timeout()
    if ok and code == 200 then return true end
    return nil, string.format("HTTP %s", tostring(code))
end

local function findReleaseAsset(release_data, asset_name)
    for _, a in ipairs(release_data.assets or {}) do
        if a.name == asset_name then return a.browser_download_url end
    end
end

function SKK:_checkForUpdates()
    local checking = InfoMessage:new{ text = _("Checking for updates…") }
    UIManager:show(checking)
    UIManager:forceRePaint()

    -- Fetch latest release from GitHub API.
    local api_url = string.format(
        "https://api.github.com/repos/%s/releases/latest", GITHUB_REPO)
    local body, err = httpGet(api_url)
    UIManager:close(checking)

    if not body then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Update check failed:\n%s"), err or "unknown error"),
        })
        return
    end

    local ok, data = pcall(require("json").decode, body)
    if not ok or type(data) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Could not parse update information."),
        })
        return
    end

    local remote_tag = (data.tag_name or ""):gsub("^v", "")
    local notes      = data.body or ""

    if not isNewer(remote_tag, PLUGIN_VERSION) then
        UIManager:show(InfoMessage:new{
            text = string.format(_("You are up to date.\nInstalled: v%s"), PLUGIN_VERSION),
            timeout = 3,
        })
        return
    end

    local asset_url = findReleaseAsset(data, RELEASE_ASSET)
    if not asset_url then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Update v%s is available but no %s asset was attached.\nPlease reinstall manually."),
                remote_tag, RELEASE_ASSET),
        })
        return
    end

    -- Truncate release notes for display.
    local display_notes = #notes > 300
        and notes:sub(1, 300) .. "\n…"
        or  notes

    UIManager:show(ConfirmBox:new{
        text = string.format(
            _("Update available!\n\nInstalled: v%s\nAvailable: v%s\n\n%s"),
            PLUGIN_VERSION, remote_tag, display_notes),
        ok_text     = _("Update"),
        cancel_text = _("Later"),
        ok_callback = function()
            self:_downloadUpdate(remote_tag, asset_url)
        end,
    })
end

function SKK:_downloadUpdate(tag, asset_url)
    local plugin_dir  = Dict.getPluginDir()
    local DataStorage = require("datastorage")
    local zip_path    = DataStorage:getDataDir() .. "/cache/skk_update.zip"

    local progress = InfoMessage:new{
        text = string.format(_("Downloading update v%s…"), tag),
    }
    UIManager:show(progress)
    UIManager:forceRePaint()

    local ok, err = httpDownload(asset_url, zip_path)
    if not ok then
        UIManager:close(progress)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Download failed:\n%s"), err or "unknown error"),
        })
        os.remove(zip_path)
        return
    end

    -- Extract zip entries directly into the plugin directory.
    local archiver = require("ffi/archiver")
    local reader = archiver.Reader:new()
    if not reader:open(zip_path) then
        UIManager:close(progress)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not open downloaded archive:\n%s"),
                reader.err or "unknown error"),
        })
        os.remove(zip_path)
        return
    end

    local failed, extracted = {}, 0
    for entry in reader:iterate() do
        -- Only entries packaged under "skk.koplugin/" are written; anything
        -- else is treated as foreign and skipped.
        local rel = entry.path:match("^skk%.koplugin/(.+)$")
        if rel and entry.mode == "file" then
            local content = reader:extractToMemory(entry.path)
            if content then
                local dest = plugin_dir .. "/" .. rel
                local tmp  = dest .. ".tmp"
                local f, ferr = io.open(tmp, "wb")
                if f then
                    f:write(content)
                    f:close()
                    os.rename(tmp, dest)
                    extracted = extracted + 1
                else
                    failed[#failed+1] = rel .. " (write: " .. tostring(ferr) .. ")"
                end
            else
                failed[#failed+1] = rel .. " (extract: " .. tostring(reader.err) .. ")"
            end
        end
    end
    reader:close()
    os.remove(zip_path)

    UIManager:close(progress)

    if extracted == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Update failed: archive contained no plugin files."),
        })
    elseif #failed > 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Update partially failed.\nCould not write:\n%s"),
                table.concat(failed, "\n")),
        })
    else
        UIManager:show(ConfirmBox:new{
            text = string.format(
                _("Update to v%s complete.\nRestart KOReader to apply."), tag),
            ok_text     = _("Restart now"),
            cancel_text = _("Later"),
            ok_callback = function()
                local Event = require("ui/event")
                UIManager:broadcastEvent(Event:new("Restart"))
            end,
        })
    end
end

-- ---- User dictionary management --------------------------------

function SKK:_showUserDictMenu()
    local entries = Dict.getUserDictEntries()

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No user dictionary entries yet.\n"..
                     "Entries are added when you register new words during conversion."),
            timeout = 3,
        })
        return
    end

    local kv_pairs = {}
    for _, e in ipairs(entries) do
        local when = e.last_used
            and os.date("%Y-%m-%d", e.last_used) or "—"
        local key   = e.reading .. "  →  " .. e.candidate
        local value = string.format(_("used %d×  last: %s"), e.use_count, when)
        local reading   = e.reading    -- capture for callback
        local candidate = e.candidate
        kv_pairs[#kv_pairs+1] = {
            key, value,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(
                        _("Delete entry?\n%s → %s"), reading, candidate),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        Dict.deleteUserDictEntry(reading, candidate)
                        UIManager:show(InfoMessage:new{
                            text = _("Entry deleted."), timeout = 2,
                        })
                    end,
                })
            end,
        }
    end

    local page = KeyValuePage:new{
        title = _("User Dictionary"),
        kv_pairs = kv_pairs,
        callback_return = function() end,
        -- Export button in title bar left icon
        title_bar_left_icon = "appbar.save",
        title_bar_left_icon_tap_callback = function()
            local export_path = Dict.getDataDir() .. "/user-dict-export.utf8"
            local ok, err = Dict.exportUserDict(export_path)
            if ok then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Exported to:\n%s"), export_path),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Export failed: %s"), tostring(err)),
                })
            end
        end,
    }
    UIManager:show(page)
end

-- ---- Plugin lifecycle ------------------------------------------

function SKK:_activate()
    if self._orig_inputtext_class then return end
    self._orig_inputtext_class = InputDialog.inputtext_class
    InputDialog.inputtext_class = SKKInputText
    logger.info("SKK: activated")
end

function SKK:_deactivate()
    if not self._orig_inputtext_class then return end
    InputDialog.inputtext_class = self._orig_inputtext_class
    self._orig_inputtext_class = nil
    logger.info("SKK: deactivated")
end

function SKK:onCloseWidget()
    self:_deactivate()
    self:_unregisterKeyboardLayout()
    Dict.close()
end

return SKK
