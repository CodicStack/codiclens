# Codiclens

A keyboard-driven macOS launcher. You summon a floating panel, name a **Subject**, optionally choose an **Action** and a **Target**, and press Enter. This file is the shared vocabulary — the words we use for the things in this app, and the words we deliberately don't.

## Language

### The command grammar

**Subject**:
The thing a command acts on — an app, a file, a folder, a piece of text, a clipboard entry, an emoji, or a Built-in. Always the first thing chosen.
_Avoid_: item, entry, target (Target means something else here)

**Action**:
What to do with a Subject. Which Actions exist depends on the Subject's kind.
_Avoid_: command, verb, operation

**Target**:
The second Subject some Actions need — the app in "Open With", the recipient in "Share". Only Actions that are not Final have one.
_Avoid_: destination, argument, parameter

**Final Action**:
An Action that executes immediately on Enter rather than asking for a Target.
_Avoid_: terminal action, leaf action

**Phase**:
Which step of the grammar the user is currently on. The panel shows one Card per completed or in-progress Phase.
_Avoid_: step, stage, state, screen

**Query**:
The literal text the user has typed. Distinct from the Subject it matched — typing `saf` yields the Subject "Safari" but the Query is still `saf`.
_Avoid_: search text, input, term

### What's on screen

**Panel**:
The single floating window Codiclens draws into. Non-activating: it never takes macOS activation away from the app underneath.
_Avoid_: window, HUD, overlay

**Slab**:
A glass surface inside the Panel. There is one — the Results Slab, below the Cards, with a real gap above it. It looks like a second window and is not: the Panel is a single window, and the gap is empty space inside it.
_Avoid_: panel, pane, tray, sheet

**Card**:
One tile representing one Phase. Cards float directly over the desktop in a row at the top of the Panel — there is deliberately no Slab behind them. The focused Card is brighter and more defined at the edge; there is no accent colour anywhere in the app.
_Avoid_: tile, pane, box

**Result**:
One selectable row or grid cell in the Results Slab.
_Avoid_: match, hit, suggestion

**Mode**:
What the Results Slab is currently listing, which determines its layout — a list for apps and files, a grid for emoji. Set by the Subject in play.
_Avoid_: view, layout, kind

### Sources of Subjects

**Index**:
The in-memory list of installed apps that Subject search matches against. Rebuilt in full whenever the filesystem says the installed apps changed.
_Avoid_: cache, database, catalog

**Built-in**:
A Subject that isn't a file on disk — Settings, Clipboard, Emoji. Appears in Subject search alongside apps.
_Avoid_: internal, system item, virtual subject

**Clipboard History**:
The recorded list of things the user has copied, each one a Clipboard Item.
_Avoid_: pasteboard, buffer

**Emoji**:
A single Unicode emoji together with its name and search keywords. Symbols are explicitly out of scope.
_Avoid_: glyph, character, icon (Icon means an app's artwork)

**Skin Tone**:
A Fitzpatrick variant of an Emoji. Users have one default; individual uses can override it. Variants never appear as separate Results.
_Avoid_: modifier, variant, tone

**Recents**:
Recently used Emoji, ranked above everything else when the Query is empty. Per-Mode — Emoji Recents are unrelated to app ranking.
_Avoid_: history (Clipboard History means something else), favorites, frequently used

### Behaviour

**Focus Handoff**:
Returning macOS activation to the app that was frontmost before the Panel appeared, so a simulated paste lands in the right place.
_Avoid_: focus restore, app switch

**Motion**:
The app's animation vocabulary. Only three curves exist, and only Panel appearance, Panel dismissal, and Slab resizing use them. Everything else changes instantly and on purpose.
_Avoid_: transitions, effects, FX
