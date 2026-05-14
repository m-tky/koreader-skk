local _ = require("gettext")
return {
    fullname = _("SKK Japanese Input"),
    description = _([[
SKK (Simple Kana to Kanji) input method for Japanese text.

Enables SKK-style Japanese input in all text input fields.
Romaji is converted to hiragana automatically. Shift+letter
starts kanji conversion mode; Space selects candidates.

Requires an SKK dictionary (e.g. SKK-JISYO.L in UTF-8) placed at:
  <koreader data dir>/data/skk/SKK-JISYO.utf8

Or the plugin will try to convert a system EUC-JP dictionary automatically.]]),
}
