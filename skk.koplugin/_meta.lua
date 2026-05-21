local _ = require("gettext")
return {
    fullname = _("SKK Japanese Input"),
    version  = "0.3.3",
    description = _([[
SKK (Simple Kana to Kanji) input method for Japanese text.

Enables SKK-style Japanese input in all text input fields.
Romaji is converted to hiragana automatically. Shift+letter
starts kanji conversion mode; Space selects candidates.

A bundled dictionary is included and loaded automatically.
User-registered words are stored in a persistent user dictionary.]]),
}
