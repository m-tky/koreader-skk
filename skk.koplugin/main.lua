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
--   1-7 (▼)       Select candidate directly
--   Enter         Commit
--   Backspace     Delete / cancel conversion
--   x (▼)         Cancel candidate selection

local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

-- Plugin works on all devices:
-- - Physical keyboard / SDL emulator: via SKKInputText (InputDialog.inputtext_class)
-- - Touch/virtual keyboard: via skk_keyboard layout (wrapInputBox)

local Dict = require("skk_dictionary")
local SKKInputText = require("skk_inputtext")

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
        UIManager:nextTick(function() Dict.ensureLoaded() end)
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
                        Dict.ensureLoaded()
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
                text = _("Virtual keyboard (touch devices)"),
                callback = function() self:_showVKBDMenu() end,
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
                            "1-7       Select candidate by number\n"..
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
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
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
            local loaded = Dict.isLoaded() and "✓ " or "? "
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
                    "Bundled directory:\n%s\n\n"..
                    "User directory:\n%s\n\n"..
                    "%s"),
                    Dict.getPluginDir(),
                    Dict.getUserCacheDir(),
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
        Dict.getUserCacheDir())

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
end

return SKK
