# skk.koplugin — SKK Japanese Input for KOReader

A [KOReader](https://github.com/koreader/koreader) plugin that brings
[SKK](https://ja.wikipedia.org/wiki/SKK) (Simple Kana to Kanji) style Japanese
input to every text field in KOReader.

Works on **all KOReader platforms**:

| Platform | Input method |
|---|---|
| Kindle, Android, PocketBook (touch only) | Virtual keyboard (🌐 → 日本語 SKK) |
| SDL emulator / devices with a physical keyboard | Physical keys via SKKInputText |

---

## Features

- Romaji → hiragana → kanji conversion in SKK style
- Bundled dictionary (`SKK-JISYO.L` converted to UTF-8, ~5.9 MB)
- Add extra dictionaries from settings (EUC-JP files auto-converted with iconv)
- Touch-friendly virtual keyboard with Japanese punctuation row
- Candidate cycling with wrap-around; direct selection by number keys (1–9)
- Hiragana / Katakana / ASCII mode switching
- Zero core KOReader file modifications — install as a drop-in plugin

---

## Installation

1. Copy the `skk.koplugin/` folder into your KOReader `plugins/` directory.
2. Start KOReader.
3. Open **Menu → Tools → SKK Japanese Input → Enable SKK**.
4. For the touch virtual keyboard, open any text field and tap the **🌐** globe
   key; select **日本語 SKK** from the layout list.

The plugin registers the SKK keyboard layout automatically on first load, so the
🌐 menu entry appears without restarting KOReader.

---

## Physical keyboard / SDL emulator

When the plugin is enabled, every `InputDialog` text field uses `SKKInputText`.
On the SDL emulator (Linux / macOS / Windows desktop build) the virtual keyboard
is automatically shown so you can see the current mode.

### Key bindings

| Key | Action |
|---|---|
| `a`–`z` | Type romaji → committed as hiragana (or katakana / ASCII) |
| `Shift`+letter | Start kanji-conversion mode ▽ |
| `Space` (in ▽) | Look up candidates → ▼ mode |
| `Space` / `n` (in ▼) | Next candidate (wraps around) |
| `p` (in ▼) | Previous candidate |
| `1`–`7` (in ▼) | Select candidate by number |
| `Enter` | Commit current composition |
| `Backspace` | Delete character / cancel conversion |
| `x` (in ▼) | Cancel candidate selection |
| `q` | Toggle hiragana ↔ katakana mode |
| `l` | Switch to ASCII pass-through mode |
| `Ctrl`+`\` | Toggle SKK on/off for this field |

---

## Virtual keyboard (touch)

The SKK keyboard has 5 rows. Row 1 adapts to the current state:

- **Normal mode** — mode indicator (あ / ア / A) + Japanese punctuation
- **SELECT mode** — number keys 1–9 for direct candidate selection

Row 5 (bottom) includes cursor-left / cursor-right keys and the Enter key.

### Mode key (あ / ア / A key, bottom row and row 1)

Tap the mode key to cycle: **あ** (hiragana) → **ア** (katakana) → **A** (ASCII)

### Converting to kanji

1. Tap a **shifted letter** (e.g. Shift + K) to enter ▽ mode.
2. Type the reading in romaji.
3. Tap **Space** — the first candidate appears as inline preedit:
   `▼漢字 [2:幹事 3:監事…]`
4. Continue tapping **Space** to cycle, or tap a **number key** to select
   directly.
5. Tap **Enter** to commit, or **✕** (or Backspace) to cancel.

---

## Dictionaries

The bundled `SKK-JISYO.utf8` is derived from
[SKK-JISYO.L](https://github.com/skk-dev/dict) (GPL-2.0+).

To add extra dictionaries:

1. **Menu → Tools → SKK Japanese Input → Dictionaries → Add dictionary…**
2. Enter the full path to a UTF-8 or EUC-JP SKK dictionary file.  
   EUC-JP files are auto-converted with `iconv` when available
   (Linux/macOS desktop; **not** available on Kindle).

Recommended user dictionary locations:

- `/mnt/us/koreader/cache/skk/` (Kindle)
- `<koreader_dir>/cache/skk/` (other devices)

---

## Romaji conversion table (selection)

| Romaji | Kana | Romaji | Kana |
|---|---|---|---|
| a / i / u / e / o | あいうえお | ka ki ku ke ko | かきくけこ |
| sa si/shi su se so | さしすせそ | ta ti/chi tu/tsu te to | たちつてと |
| na ni nu ne no | なにぬねの | ha hi fu he ho | はひふへほ |
| ma mi mu me mo | まみむめも | ya yu yo | やゆよ |
| ra ri ru re ro | らりるれろ | wa wi we wo | わゐゑを |
| ga gi gu ge go | がぎぐげご | za zi/ji zu ze zo | ざじずぜぞ |
| da di du de do | だぢづでど | ba bi bu be bo | ばびぶべぼ |
| pa pi pu pe po | ぱぴぷぺぽ | nn / n+consonant | ん |
| z, / z. | 、。 | z[ / z] | 「」 |
| z- | 〜 | z/ | ・ |

Double a consonant before a vowel for sokuon: `kk` → っk (e.g. `kka` → っか).

---

## Building from source

This plugin requires no build step — it is pure Lua.  
The bundled dictionary is already in UTF-8 and is loaded at runtime.

To regenerate `SKK-JISYO.utf8` from the upstream EUC-JP source:

```bash
iconv -f euc-jp -t utf-8 SKK-JISYO.L > SKK-JISYO.utf8
```

---

## License

- Plugin code: MIT License  
- Bundled dictionary (`SKK-JISYO.utf8`): GPL-2.0-or-later (from [skk-dev/dict](https://github.com/skk-dev/dict))
