---
status: accepted
---

# Disabling the system emoji hotkey via private CoreGraphics API

Codiclens binds Ctrl+Cmd+Space to its emoji picker. To make that key actually reach us, we call the **private** CoreGraphics function `CGSSetSymbolicHotKeyEnabled(50, false)`, where symbolic hotkey **50 is `ShowHideCharacterPalette`**. Detection uses the sibling `CGSIsSymbolicHotKeyEnabled(50)`.

This is recorded because calling private API is the kind of thing a future reader will want to delete on sight. Three findings, all verified against a running macOS 26.5.1, make it the only option that works:

1. **There is no System Settings row for "Show Emoji & Symbols."** The Keyboard settings pane's own definition file — `DefaultShortcutsTable.xml` inside `KeyboardSettings.appex` — enumerates every category and row the UI can render, and no row exists for the Character Palette anywhere in it. Spotlight has a checkbox the user can clear; the emoji picker does not. Advice of the form "go disable it in Keyboard Shortcuts" is a dead end, and at least one competitor's documentation gives exactly that wrong instruction.
2. **`RegisterEventHotKey` gives us nothing to detect the conflict with.** A compiled probe registering Ctrl+Cmd+Space while the system hotkey was live returned `OSStatus 0` — not `eventHotKeyExistsErr`. Registration silently succeeds and WindowServer consumes the keystroke before our handler runs. Checking the return code would report success while the feature is dead.
3. **This is what shipping launchers do.** Static inspection of the installed Raycast binary shows it dynamically imports `CGSIsSymbolicHotKeyEnabled`, `CGSSetSymbolicHotKeyEnabled`, and `CGSGetSymbolicHotKeyValue`, and exposes the behaviour as a setup toggle for both Spotlight and the emoji picker.

Apple's archived documentation lists ⌃⌘Space as "Apple reserved."

## Consequences

- **Mac App Store distribution becomes impossible** without dropping this. Acceptable: Codiclens is directly distributed. If that ever changes, this feature is the thing to cut.
- **Off by default.** We do not seize a system shortcut on first launch. The user opts in from Settings.
- **Revert is a first-class path**, not a cleanup afterthought. Turning the preference off calls `CGSSetSymbolicHotKeyEnabled(50, true)`. A user who disables this must get their system emoji picker back.
- **The disable is re-asserted at every launch** when the preference is on, because an OS update or another app can re-enable it. Assert, never assume.
- Symbols are resolved dynamically and every call is error-checked, so a future macOS that removes them degrades to "emoji hotkey unavailable" rather than crashing.
