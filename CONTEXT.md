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
One glass tile representing one Phase. Cards sit in a row at the top of the Panel, each its own piece of glass with a small gap between them — there is deliberately no surface behind them, and they never fuse into one body. Since 2026-09-11 a Card is bare native glass and nothing painted on it: no rim, no shadow, no light of its own. The one thing that distinguishes Cards is the Selection Tint on the focused one.
_Avoid_: tile, pane, box, slab

**Selection Tint**:
The colour the focused Card's glass takes on — the user's system accent colour, in the glass itself rather than as a fill on top of it. The unfocused Cards are untinted. This is the only colour any surface in the app carries, and it means one thing: this Card holds the keyboard. Replaces the "no accent colour" rule that stood from 2026-08 to 2026-09-11; that rule was written against a *fill* across a Card, and is what led to the Lamp and the Border Beam trying to signal focus without colour.
_Avoid_: accent, highlight, fill, glass tint (the grey material tint that made the Cards read as frosted plastic — gone, and not this)

**Arrival**:
A new Card growing out of the Card before it when a Phase is reached — the Action Card out of the Subject Card, the Target Card out of the Action Card. It is a Transition (see Motion): the surface changes size, and what the Card *contains* still appears instantly.
_Avoid_: morph, split, animate in, slide in

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
The app's animation vocabulary, in two categories that must not be confused. A
**Transition** carries a change the user caused; there are exactly three curves
and only Panel appearance, Panel dismissal, Slab resizing and a Card's Arrival use them.
**Decoration** carries nothing — it is the Loading Ring, it
never tells the user anything, it never delays anything, and it is absent under
Reduce Motion. Everything else changes instantly and on purpose.
_Avoid_: transitions (Transition means one of the three), effects, FX

**Retired words (2026-09-11)**:
**Lamp** and **Border Beam** were the focused Card's static rim light and a
travelling light around a Card's rim. Both existed to make a lone Card read as
expensive without colour or a surface behind it, and both are gone with the
redesign: native glass supplies the edge, and the Selection Tint supplies focus.
Do not reintroduce either under a new name.
_Avoid_: lamp, beam, rim light, glow, sweep, comet, halo

**Loading Ring**:
The app's own spinner: a constant-length arc, rotating, beside the text in each
of the Panel's two waiting states. Decorative in the strict sense — neither
Vision nor `mdfind` reports progress, so there is nothing for it to measure. It
never fills, and it never appears without text saying what is being waited on.
_Avoid_: progress, progress indicator, activity indicator, throbber

### Reading text out of images

**OCR**:
The Action that reads the text out of an image Subject. Named for the acronym
deliberately, against Apple's "Recognize Text" — it is the word the user reaches
for. Only an image Subject has it.
_Avoid_: text recognition, scan, extract, read

**OCR Text**:
What OCR produces: the recognised characters, as one string, which becomes a
text Subject in place of the image. An image with no readable text produces no
OCR Text at all — never empty OCR Text.
_Avoid_: transcript, recognised text, output

**Use as Subject**:
The Action that promotes a Target into the Subject, so a thing found while
looking for something else can be acted on in its own right. Always lands on the
Action Phase, never executes anything.
_Avoid_: make subject, promote, pick, choose

**Editing**:
Changing a text Subject's text in its own Card. Any text Subject can be edited —
a Clipboard Item, OCR Text, or the output of a transform. Not a Clipboard
capability; a text Subject capability.
_Avoid_: inline edit, rename, amend

**Path Subject**:
A file or folder named by typing its path. A Query beginning `/` or `~` is a
path and nothing else — it cannot collide with an app name, so it never competes
with the Index. It resolves to exactly one Subject; a path that does not exist
resolves to none and the Panel shakes.
_Avoid_: file subject, browse, navigate, completion
