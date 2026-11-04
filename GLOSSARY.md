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
One glass tile representing one Phase. Cards sit in a row at the top of the Panel, each its own piece of glass with a small gap between them — there is deliberately no surface behind them, and they never fuse into one body. Since 2026-09-11 a Card is bare native glass and nothing painted on it: no rim, no shadow, no light of its own. No Card carries any colour, focused or not — the user rejected a tinted focused Card on sight (2026-09-11). Focus is shown by Emphasis.
_Avoid_: tile, pane, box, slab

**Emphasis**:
How the focused Card differs from the others: it stands at full size with its content fully present, while an unfocused Card is smaller and its content quieter. Glass is the same on every Card; the difference is in size and presence, never in colour, rim or light. Changing which Card has Emphasis is instant.
_Avoid_: selection tint, accent, highlight, focus ring, raised, lit

**Arrival**:
A new Card growing out of the Card before it when a Phase is reached — the Action Card out of the Subject Card, the Target Card out of the Action Card. It is a Transition (see Motion): the surface changes size, and what the Card *contains* still appears instantly.
_Avoid_: morph, split, animate in, slide in

**Result**:
One selectable row or grid cell in the Results Slab.
_Avoid_: match, hit, suggestion

**File Result**:
A Result in Subject search that is a file, matched by its name or by what it contains. File Results sit below the app Results, mixed in one list with Clipboard Items and Emoji, and arrive after them; they never push an app Result out of its place.
_Avoid_: file hit, document match, search result

**Last Subject**:
The Subject the user last acted on or sent in as an Incoming Subject, standing as the Subject when the Panel opens again, with the Query empty: a Clipboard Item, an Emoji, a file, a folder or text. Enter acts on it again; Tab opens its Actions; the first keystroke starts a new Query; Backspace with nothing typed takes it away for good. Apps and Built-ins never become the Last Subject. What an Action turns the Subject into (OCR Text, a transcript, a transform's output, a QR Code, a file moved, copied, renamed or zipped) is the Last Subject at once, and stands straight away, the command done. One trashed, or gone since, leaves no Last Subject.
_Avoid_: recent, history, sticky subject, resume

**Passage**:
The part of a file that a File Result matched on: a stretch of text, a page, or a span of time in a recording or video. A file that matched on its name alone has no Passage.
_Avoid_: excerpt, moment, snippet, hit, match location

**Passage Preview**:
The file opened inside the Panel at its Passage, with the matched words highlighted: a PDF at its page, text scrolled to the Passage, a recording playing from where the Passage starts. Shift+Space opens it for a File Result that has a Passage; anything else gets Quick Look.
_Avoid_: own preview, inline preview, viewer, Quick Look

**Update Notice**:
A small glass strip that says a newer Codiclens is waiting: "Codiclens 1.0.3 is available", or "Codiclens 1.0.3 is ready · Restart to update" once it has downloaded on its own. It sits under the Results Slab, or under the Card row when there is no Slab, and is never a Result. ⌘U or a click acts on it. It is the only way Codiclens tells the user about an update; no update window ever opens unless the user asked for it.
_Avoid_: update banner, update row, badge, alert

**Kind**:
What a file is, as a person would say it: a video, a photo, a screenshot, a PDF, a document, a note, a recording, code. Judged from the file itself, never from the Query.
_Avoid_: type, file type, format, category, modality

**Kind Word**:
A word in a Query that asks for a Kind outright — "video", "photo", "screenshot", "billede", "optagelse". A Query with one lists that Kind first, its best guesses even when nothing else stands out, ahead of name matches of any other Kind. English and Danish alike. A screenshot is a picture: "photo", "image" and "billede" ask for photos and screenshots alike; "screenshot" asks for screenshots alone. "folder" and "mappe" ask for folders the same way.
_Avoid_: filter, type word

**Kind Hint**:
A word that may name a Kind or may just be the topic — "notes", "film", "music", "voice". It lifts that Kind a little and never puts it first: "release notes" is not a request for notes.
_Avoid_: weak kind word, soft filter

**Mode**:
What the Results Slab is currently listing, which determines its layout — a list for apps and files, a grid for emoji. Set by the Subject in play.
_Avoid_: view, layout, kind

### Sources of Subjects

**Source**:
A place Subjects come from: Applications, Clipboard History, Emoji, the Built-ins, or a folder the user added. Each one can be switched off in Settings, where it shows how much of it has been read.
_Avoid_: provider, origin, location, scope

**App Index**:
The in-memory list of installed apps that Subject search matches against. Rebuilt in full whenever the filesystem says the installed apps changed.
_Avoid_: Index on its own, cache, database, catalog

**File Index**:
What Codiclens has read from the files in its folder Sources: their names, and what each one says, shows or sounds like. Kept on disk and updated as the files change. File Results come from it.
_Avoid_: Index on its own, library, database, embeddings

**Built-in**:
A Subject that isn't a file on disk — Settings, Clipboard, Emoji, Check for Updates. Appears in Subject search alongside apps.
_Avoid_: internal, system item, virtual subject

**Clipboard History**:
The recorded list of things the user has copied, each one a Clipboard Item.
_Avoid_: pasteboard, buffer

**Clipboard Item**:
One thing the user copied, kept as a snapshot: the text or the pixels as they
were at copy time. A file it was copied from lends its name and nothing else —
Quick Look, Paste, Share and Open in Preview all see the snapshot, and a later
change to that file changes nothing here.
_Avoid_: entry, record, link, reference

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

**Setup**:
The small window a fresh install opens with: take ⌘Space and ⌃⌘Space from macOS, allow the default folder Sources and choose how much of search by meaning to download, grant Paste, open at login. Every step can be skipped and Done always closes it. It returns on reopen until Done has been pressed once, then only from Settings.
_Avoid_: onboarding, welcome screen, wizard, tour

**Focus Handoff**:
Returning macOS activation to the app that was frontmost before the Panel appeared, so a simulated paste lands in the right place.
_Avoid_: focus restore, app switch

**Motion**:
The app's animation vocabulary, in two categories that must not be confused. A
**Transition** carries a change the user caused; there are exactly three curves
and only Panel appearance, Panel dismissal, Slab resizing, the Card row widening as a
Phase is added and a Card's Arrival use them. **Decoration** carries nothing — it is the Loading Ring, it
never tells the user anything, it never delays anything, and it is absent under
Reduce Motion. Everything else changes instantly and on purpose.
_Avoid_: transitions (Transition means one of the three), effects, FX

**Retired words (2026-09-11)**:
**Lamp** and **Border Beam** were the focused Card's static rim light and a
travelling light around a Card's rim. Both existed to make a lone Card read as
expensive without colour or a surface behind it, and both are gone with the
redesign: native glass supplies the edge, and the Emphasis supplies focus.
Do not reintroduce either under a new name. **Selection Tint** — an accent-coloured glass on the focused Card — was proposed and rejected the same day; no surface carries colour.
_Avoid_: lamp, beam, rim light, glow, sweep, comet, halo, selection tint

**Loading Ring**:
The app's own spinner: a constant-length arc, rotating, beside the text in each
of the Panel's two waiting states. Decorative in the strict sense — neither
Vision nor `mdfind` reports progress, so there is nothing for it to measure. It
never fills, and it never appears without text saying what is being waited on.
_Avoid_: progress, progress indicator, activity indicator, throbber

### Sharing

**Share**:
The Action that hands a Subject's content to a macOS sharing service — AirDrop,
Mail, Messages and the rest. The service is the Target. Every Subject that has
content has Share: text, Emoji, a Clipboard Item, a file, a folder. Text that is
a URL is shared as a link, not as text. A file found through Finder is shared by
making it the Subject first (Use as Subject), never by a second Target.
_Avoid_: send, export, share sheet, share menu

**QR Code**:
The Action that turns a text Subject into a QR code image. The image becomes a
new Clipboard Item and stands as the Subject in one move, so everything an image
can have done to it — Paste, Save, Share — is one Tab away. Not a Share Target: a QR
code is a form of the text, not a recipient of it.
_Avoid_: generate QR, QR share, scan code

### Reading text out of images

**OCR**:
The Action that reads the text out of an image Subject. Named for the acronym
deliberately, against Apple's "Recognize Text" — it is the word the user reaches
for. Only an image Subject has it.
_Avoid_: text recognition, scan, extract, read

**OCR Text**:
What OCR produces: the recognised characters, as one string, which becomes a
text Subject in place of the image, standing as a Last Subject stands. An image
with no readable text produces no OCR Text at all — never empty OCR Text.
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

**Renaming**:
Changing a file or folder's name in its own Card. Separate from Editing, which
is text only: Renaming changes what the file is called, never what it contains.
_Avoid_: edit, inline rename
_Avoid_: inline edit, rename, amend

**Rotate**:
Rotate Left and Rotate Right, the two Actions that turn an image Subject a
quarter turn in place — a Clipboard Item's snapshot or an image file on disk,
without asking, as Finder does. The Subject stays and the Panel stays; only the
pixels change. Not Editing: Editing is text.
_Avoid_: edit image, transform (a Transform is a text thing), flip

**Open in Preview**:
The Action that hands an image Subject to Apple's Preview for anything Rotate
cannot do — markup, crop, annotate. Codiclens has no image editor of its own and
Quick Look outside Finder offers none; Preview is the editor.
_Avoid_: markup, annotate, edit in preview

**Path Subject**:
A file or folder named by typing its path. A Query beginning `/` or `~` is a
path and nothing else — it cannot collide with an app name, so it never competes
with the App Index. It resolves to exactly one Subject; a path that does not exist
resolves to none and the Panel shakes.
_Avoid_: file subject, browse, navigate, completion

**Incoming Subject**:
A Subject handed to Codiclens from outside it: a file or folder sent from
Finder's right-click menu, or text selected in another app. The Panel opens on
it standing, as a Last Subject stands: one Card, the Query empty. Enter runs its
default Action, Tab goes to the Action Phase, the first keystroke starts a new
Query, Backspace takes it away. When several files are sent at once, the first becomes the Subject and
the rest are dropped; the Subject Card says how many were sent.
_Avoid_: sent subject, handed subject, dropped file, opened file

### Transcribing audio and video

**Transcribe**:
The Action that turns what an audio or video file Subject says into text, with
the Speech Model the user picked in Codictate. Codiclens asks Codictate's command
line, which hands the file to the running Codictate (starting it hidden if need
be); Codictate runs one File Transcription at a time, so a Transcribe may wait its
turn, and the Subject Card says where it is ("Waiting, 1 ahead", "Transcribing ·
0:42"). The text becomes a text Subject in place of the file and stands, as OCR
Text replaces an image; a file with no speech produces none. Codiclens has no Speech Model of
its own, so without Codictate, or with one too old to speak its command line's
contract, the Action is still there and says where to get it.
_Avoid_: dictate, speech to text, STT
