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
One tile representing one Phase. Cards float directly over the desktop in a row at the top of the Panel — there is deliberately no Slab behind them. The focused Card is brighter and more defined at the edge; no surface in the app carries an accent colour. The ban is on a *static* accent — an accent fill across a Card turned the Panel into a coloured box and a tinted selection fought every app icon beside it. A transient highlight that is gone in a quarter of a second is not one; see Border Beam.
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
The app's animation vocabulary, in two categories that must not be confused. A
**Transition** carries a change the user caused; there are exactly three curves
and only Panel appearance, Panel dismissal and Slab resizing use them.
**Decoration** carries nothing — it is the Border Beam and the Loading Ring, it
never tells the user anything, it never delays anything, and it is absent under
Reduce Motion. Everything else changes instantly and on purpose.
_Avoid_: transitions (Transition means one of the three), effects, FX

**Border Beam**:
A travelling light — a soft bloom at its head with a dissolving trail behind it —
that goes once around a Card's rim when that Card becomes
about something new — a Phase reaching it, a Subject being replaced, a summon. It
belongs to the Card **as a surface** and it means nothing: it is not tied to OCR,
to searching, to loading, or to any other in-flight state, and reading it as one
is the mistake this entry exists to prevent. OCR Text sweeps the Subject Card
because the *Subject changed*, not because OCR finished. It never marks a
selection moving — that stays instant. All three Cards have one; the Slab does
not. Shares a drawing primitive with the Loading Ring and nothing else.
The light is **on the Card**: the core sits just inside the rim, on the Card's own
glass, and the mist spills inward and fades into the Card. That is the correction
that took five attempts, and the reason it took five is worth carrying: for four of
them the beam was masked to the region *outside* the rim, which is the gutter and
then the Panel's transparent margin — the user's **desktop**. So it never
composited against anything the app draws, and whether it could be seen at all was
decided by somebody's wallpaper. Dark appearance over a white desktop measured
Δ10/442: nothing. **"Dark appearance" does not mean "dark ground".**
The line is a thin desaturated rim highlight, and its polarity follows the ground it
now has. In **dark** appearance that is white, which is the reference material
exactly. In **light** appearance the Card's glass is lighter than any highlight, so
the line is a dark cool one — the same polarity as every other edge in that
appearance. The reference material's blue belongs to its Card's *fill*, not to its
rim light, and reading it the other way is what made this a saturated blue line
twice. A permanently lit rim would be the **fixed lamp**, which is a different thing
and has been declined.
_Avoid_: glow, edge blur, border glow, loading animation, spinner, focus ring,
blue beam, accent

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
