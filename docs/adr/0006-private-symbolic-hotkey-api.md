---
status: superseded by 0016
---

# Disabling the system emoji hotkey via private CoreGraphics API

> **Revived by [ADR 0016](0016-codiclens-takes-both-system-shortcuts.md)** (2026-11-02): Setup now offers the takeover for ⌃⌘Space and ⌘Space, ticked. The note below records why it was removed the first time.
>
> **Superseded.** The takeover was built and then removed unused. Codiclens now
> registers Ctrl+Cmd+Space with `RegisterEventHotKey` and nothing else: whoever
> holds the shortcut at the OS level holds it. The private symbols, the
> preference and the Settings toggle are all gone.
>
> Why: the takeover was off by default (see the Consequences below), so the
> shipping behaviour was already "macOS wins" — the code carried Mac App Store
> risk and a hand-back path for a feature nobody had switched on. A user who
> wants Codiclens to answer ⌃⌘Space can free the shortcut themselves, and the
> first one to ask had already done so.
>
> The findings below are still accurate and are the reason Settings explains the
> conflict rather than offering to resolve it. If the takeover is ever wanted
> back, this is the record of how it worked.

Codiclens binds Ctrl+Cmd+Space to its emoji picker. To make that key actually reach us, we call the **private** CoreGraphics function `CGSSetSymbolicHotKeyEnabled(50, false)`, where symbolic hotkey **50 is `ShowHideCharacterPalette`**. Detection uses the sibling `CGSIsSymbolicHotKeyEnabled(50)`.

This is recorded because calling private API is the kind of thing a future reader will want to delete on sight. Three findings, all verified against a running macOS 26.5.1, make it the only option that works:

1. **There is no System Settings row for "Show Emoji & Symbols."** The Keyboard settings pane's own definition file — `DefaultShortcutsTable.xml` inside `KeyboardSettings.appex` — enumerates every category and row the UI can render, and no row exists for the Character Palette anywhere in it. Spotlight has a checkbox the user can clear; the emoji picker does not. Advice of the form "go disable it in Keyboard Shortcuts" is a dead end, and at least one competitor's documentation gives exactly that wrong instruction.
2. **`RegisterEventHotKey` gives us nothing to detect the conflict with.** A compiled probe registering Ctrl+Cmd+Space while the system hotkey was live returned `OSStatus 0` — not `eventHotKeyExistsErr`. Registration silently succeeds and WindowServer consumes the keystroke before our handler runs. Checking the return code would report success while the feature is dead.
3. **This is what shipping launchers do.** Raycast offers the same toggle for Spotlight and the emoji picker in its setup.

Apple's archived documentation lists ⌃⌘Space as "Apple reserved."

## Consequences

- **Mac App Store distribution becomes impossible** without dropping this. Acceptable: Codiclens is directly distributed. If that ever changes, this feature is the thing to cut.
- **Off by default.** We do not seize a system shortcut on first launch. The user opts in from Settings.
- **Revert is a first-class path**, not a cleanup afterthought. Turning the preference off calls `CGSSetSymbolicHotKeyEnabled(50, true)`. A user who disables this must get their system emoji picker back.
- **The disable is re-asserted at every launch** when the preference is on, because an OS update or another app can re-enable it. Assert, never assume.
- Symbols are resolved dynamically and every call is error-checked, so a future macOS that removes them degrades to "emoji hotkey unavailable" rather than crashing.
