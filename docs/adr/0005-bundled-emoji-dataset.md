---
status: accepted
---

# Emoji data is generated at build time and bundled

Codiclens ships a generated `emoji-index.json` (~1,914 rows, 127–240 KB) produced by joining Unicode 17.0 `emoji-test.txt` with CLDR 48 `annotations/en.xml` and `annotationsDerived/en.xml`. A generator script lives in the repo so bumping to a future Emoji version is one command.

This is recorded because "surely macOS has an API for this" is the first thing anyone will ask. It does not. The macOS 26.4 SDK was searched exhaustively: `Unicode.Scalar.Properties` gives names and `isEmoji`/`isEmojiModifierBase` flags but no keywords (so "hot" or "lit" would never find 🔥), no names for ZWJ sequences (👨‍👩‍👧‍👦 has no "family" string anywhere), and no way to enumerate. Apple's own data is private SPI in `CoreEmoji.framework` — undocumented binary format and copyrighted.

`NSApp.orderFrontCharacterPalette` was tested directly and is a **silent no-op** when called from an inactive `.accessory` app with a non-activating panel. It only works after `NSApp.activate()`, runs out-of-process, and provides no callback telling us what the user picked.

## Consequences

- CLDR data is Unicode-3.0 licensed (MIT-style, fine for a closed-source app) but the copyright notice must ship — an acknowledgements section in Settings.
- Skin-tone variants (2,030 further rows) live in a side table keyed by base emoji and never appear as Results. They are looked up by string, never synthesised: in a ZWJ sequence the modifier goes after the *base* scalar mid-string, and some Emoji 17 sequences take two independent tones.
- Generating rather than vendoring an existing dataset keeps us pinned to the Unicode version macOS 26.4's font actually renders.
- Symbols (arrows, math, currency) are explicitly out of scope. They have no CLDR keyword equivalent, so search terms would have to be hand-authored.
