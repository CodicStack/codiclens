---
status: accepted
---

# Codiclens takes ⌘Space and ⌃⌘Space from macOS, with the user's say-so in Setup

Codiclens has no Dock icon and no menu bar icon, so ⌘Space is the way in. macOS ships holding it for Spotlight (symbolic hotkey 64) and holding ⌃⌘Space for Emoji & Symbols (50). `RegisterEventHotKey` reports success either way and WindowServer eats the keystroke, so on a fresh Mac the app looks dead (ADR 0006's finding). Setup therefore offers two checkboxes, both ticked: "Use ⌘Space for Codiclens (replaces Spotlight)" and "Open emoji with ⌃⌘Space (replaces Emoji & Symbols)". They call the private `CGSSetSymbolicHotKeyEnabled(64 / 50, false)`, as Raycast does. This reverses ADR 0006's supersession and extends it to Spotlight.

## Considered options

- **Instructions, a deep link into Keyboard Shortcuts and a looping recording** for Spotlight. Rejected: it works only for Spotlight (Emoji & Symbols has no Settings row, ADR 0006), the recording ages with every redesign of the pane, and one click beats a trip into System Settings. It stays as the fallback when the private call fails.
- **A shortcut recorder** so users keep Spotlight. Rejected for 1.0. A user who keeps Spotlight still gets in by reopening the app, which opens the Panel.
- **Leave both to macOS** (ADR 0006's superseded state). Rejected: the app looks broken on first launch.

## Consequences

- Taken at every launch while the setting is on, handed back in `applicationWillTerminate`. Quitting or trashing the app gives the user Spotlight and Emoji & Symbols back; after a crash the next launch takes them again.
- Settings → General has a toggle for each, which hands the shortcut back.
- Symbols are resolved dynamically and every call is error-checked. If a macOS release removes them, the ⌘Space row in Setup falls back to instructions and a deep link to Keyboard Shortcuts.
- Mac App Store distribution stays ruled out, as it already is by direct distribution.
