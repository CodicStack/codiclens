# Codiclens

macOS Spotlight-replacement launcher built with Swift, SwiftUI, and AppKit.

## Build

```bash
Scripts/build-llama.sh   # once, and again whenever its TAG or the patch changes
xcodebuild -project codiclens.xcodeproj -scheme codiclens -configuration Debug build
```

**`Scripts/build-llama.sh` has to have run before the first build.** It fetches
llama.cpp at a pinned release (`TAG` and `COMMIT` in the script; needs `cmake` on
`PATH`), applies `Scripts/llama.cpp-no-logits.patch`, and installs static arm64
libraries with Metal (shader source embedded, compiled at first use) into
`Vendor/llama/`, which is not in git. ~30 s; a no-op when that build is already
there. Without it the build stops at `CLlama/CLlama.h` with
"llama.cpp is not built. Run Scripts/build-llama.sh once". Swift sees llama.cpp
as `import CLlama` through `CLlama/module.modulemap`; only the app's **arm64**
slice links it (`OTHER_LDFLAGS[arch=arm64]`), so an x86_64 slice still links and
search by meaning is simply unsupported there (`MeaningSearch.isSupported`).

The patch stops a non-causal embedding context reserving and clearing a row of
logits per input token: 262,144 floats (1 MiB) each with Gemma's vocabulary, so
2 GiB for one 2,048-token input. Still needed at b11567 (`output_reserve` in
`src/llama-context.cpp` sets `has_logits = true` unconditionally, and `encode`
reserves one output per token).

## Regenerating the emoji index

`codiclens/emoji-index.json` and `codiclens/emoji-data-license.txt` are generated,
not hand-edited. Rebuild them from the repository root:

```bash
swift Scripts/generate-emoji-index.swift
```

It downloads Unicode `emoji-test.txt` and both CLDR annotation files, joins them,
and reports the row count. Expect **1,914 rows, 2,030 skin-tone variants across
330 bases, 0 rows missing keywords** — it exits non-zero if any row comes out
keyword-less or any variant cannot be filed under a base. `--unicode` and
`--cldr` bump the versions; `--cache <dir>` reuses downloads. See
`docs/adr/0005-bundled-emoji-dataset.md`.

## Project Structure

```
codiclens/           # Main app source (Swift)
codiclensTests/      # Unit tests
```

There are two targets, app and unit tests. There is no UI test target.
`codiclens/` is a `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file
needs no `project.pbxproj` edit.

## Tests

**The unit-test host is the app itself, and it starts nothing.**
`AppDelegate.isTestHost` (XCTest's `XCTestConfigurationFilePath` in the
environment, Swift Testing runs included) makes `applicationDidFinishLaunching`
return before the Panel, the hotkeys, the pasteboard recorder or the File Index
exist. Before that, every test run crawled the user's Downloads, Documents and
Desktop into their own `FileIndex.sqlite` and took Cmd+Space from the running
app. `TestHostTests` pins it.

**No test reaches a `.shared` that holds user data.** `CommandCoordinator.init`
and `EmojiSearchVM.init` take the Sources, the File Index search, the app Index,
Emoji Recents and preferences with no default, so a test that forgets one does
not compile; `PanelController` is the one place that hands in the shared ones.
Tests build theirs from `codiclensTests/TestIsolation.swift`:
`CommandCoordinator.isolated(...)`, `throwawayEmojiVM()`, `inertAppIndex`, and
`ThrowawayDefaults` for any `SourceStore` or `EmojiPreferences`. That last one
keeps its values in memory: a real `UserDefaults(suiteName:)` per test leaves a
plist in `~/Library/Preferences` even after `removePersistentDomain`, and over a
thousand had piled up there.

**Search by meaning's model is never downloaded or loaded by default.** The client
and helper tests run the real request loop over `FakeEmbeddingBackend`
(`codiclensTests/EmbeddingTestSupport.swift`), and one real helper process over an
empty models folder. Two suites are off unless asked for:
`TEST_RUNNER_CODICLENS_DOWNLOAD_MODEL_FILES=1` runs the real ~865 MB download into
Application Support, broken off once and resumed (`ModelFilesDownloadTests`), and
`TEST_RUNNER_CODICLENS_EMBEDDING_INTEGRATION=<runs>` embeds text, an image and 30 s
of speech through the real helper and prints latency and memory
(`EmbeddingIntegrationTests`). Run both with `-parallel-testing-enabled NO`: with the
scheme's `parallelizable = YES`, each parallel clone runs every Swift Testing test,
so two downloads race on one folder and two helpers share the GPU.

The meaning pass and the settled search are tested over `KeywordEmbedder`
(`codiclensTests/MeaningTestSupport.swift`: concept words own a dimension, so a test can
say what should match) on real folders, with pictures, WAVs and movies made on the spot
(`TestMedia`); the helper path once over `FakeEmbeddingBackend`. Three more suites need
the model files and are off unless asked for, all with `-parallel-testing-enabled NO`:
`TEST_RUNNER_CODICLENS_MEANING_REAL=1` indexes a temp folder (a Danish lease, an English
recipe, three animal pictures, a `say` recording, a generated video with a spoken
soundtrack, thirty unrelated notes) with the real helpers and wants each Query's file in
the top three (`MeaningRealModelTests`); `TEST_RUNNER_CODICLENS_TIME_MEANING=<s>` crawls
and reads the real Sources into a temp database, embeds up to `<s>` seconds of each kind
and estimates the rest, and times Queries (`MeaningTimingTests`);
`TEST_RUNNER_CODICLENS_MEANING_EVAL=1` is the ship gate (see Search by meaning).
`TEST_RUNNER_CODICLENS_MEASURE_THROUGHPUT=<s>` measures the backfill's speed on text cut from
this repository into files shaped like the real backlog: texts per helper call, files per batch,
and the gentle and full pace through the real batch loop with a warm Query's latency beside each
(`MeaningThroughputTests`). `TEST_RUNNER_CODICLENS_TIME_KEYSTROKES=<database>` times every prefix of a few Queries
against an index already on disk, read-only (`FileIndexKeystrokeTimingTests`).
`TEST_RUNNER_CODICLENS_MEASURE_VECTOR_CACHE=<copy of a FileIndex.sqlite>` seeds a temp vector
cache from a schema-4 index and prints what came over and the disk before and after
(`VectorCacheMeasurementTests`; its doc comment has the read-only `.backup` command).

**Transcribe never needs Codictate under test.** `TranscriptionTests` hands
`SystemEffectRunner` a `/bin/sh` script in a temp folder as the `codictate` client
(NDJSON events, some held back on a FIFO to prove they are read as they arrive, each
error code and exit code, a cancel through a FIFO, `status --json` answers).
`TEST_RUNNER_CODICLENS_TRANSCRIBE=1` finds a real client as the app does, the dev
build included, and transcribes a `say` m4a (`RealCodictateTranscriptionTests`); a
path to a client (`<App>.app/Contents/Resources/app/bin/codictate`) instead of `1`
runs that one, after its `status` check. Either may start that Codictate hidden.

## Rules

- No backwards compatibility hacks. Always migrate to the new solution.
- No timing hacks (asyncAfter, sleep, usleep) as bug fixes. Use event-driven or sequential solutions.
- FloatingPanel uses `.nonactivatingPanel` — never break this contract without restoring previous app focus.
- App scanning must be recursive to find apps in subdirectories (e.g., Adobe apps).
- `NSWorkspace.shared.open()` calls must be async (use `openAsync` helper) to avoid blocking the main thread.
- **Share is a Target list, not a popped system menu.** The sharing service is the
  Target, chosen in the Target Phase like any other. Still built from
  `NSSharingService.sharingServices(forItems:)`, deprecated since macOS 13 in favour of
  `standardShareMenuItem` and still returning the full list on 26. No "Copy Link" and no
  "More…" rows.
- **Plain text is shared as a temporary `.txt` file**, named from its first line, because
  AirDrop refuses a string: `NSSharingService(named: .sendViaAirDrop).canPerform(withItems:
  ["text" as NSString])` is **false**, and an `NSString` payload offers only Mail, Messages,
  Notes, Freeform, Journal and Reminders. **Text that is a URL is shared as an `NSURL`
  instead** — that payload gets AirDrop *and* Add to Reading List.
- **QR Code is an Action, not a Share Target.** A QR code is a form of the text, not a
  recipient of it. Its output becomes a new Clipboard image at the top of history and the
  Subject retargets to it, exactly as OCR retargets to OCR Text. Absent when the text
  exceeds the Core Image encoder's UTF-8 capacity, and never offered on Emoji. Capacity
  follows an actual encoder attempt, not a character-count estimate.
- **Rotate is in place and must not hide the Panel.** Rotate Left / Rotate Right are Final
  Actions on an image Subject that rotate without asking, as Finder does; the Subject stays,
  the Panel stays, and a rotated Clipboard Item is **not** moved to the top of the history.
  Same no-`.hide` rule as OCR. Everything else — markup, crop — is **Open in Preview**. See
  `docs/adr/0011-image-edits-rotate-in-process-everything-else-is-preview.md`. Normal
  one-frame 8-bit PNG and TIFF files rotate in their original format; higher-precision
  sources are rejected rather than reduced to 8-bit. JPEG rotates by changing orientation
  metadata while ImageIO copies its compressed image data losslessly. Multi-frame or
  auxiliary-image sources are rejected so animation, pages, depth data and gain maps are
  never silently discarded.
- **File and folder Actions run most-used first, Move to Trash last:** Open, Quick Look,
  (an image's OCR, Rotate Left, Rotate Right, Open in Preview; audio's and video's
  Transcribe), Reveal in Finder, Share…, Open With…, Paste File, Copy File, Copy Path, Move To…,
  Copy To…, Rename, Compress, Use as Subject, Move to Trash. Quick Look sat below Move
  to Trash in a list of twelve and the user could not find it. What a content type adds
  goes straight after Quick Look (`SubjectAction.contentActions(for:)`). Clipboard Items
  keep their order with Quick Look third, after Paste and Copy; Finder's has it second.
  `FileActionCommandTests` pins all of it.
- **Move To…, Copy To…, Rename and Compress never overwrite, and the Subject follows the
  file.** Each is one `FileOperation` in a `.fileOperation` Effect with no `.hide`, done by
  `EffectRunner` on its own serial queue and answered through `onFileOperation`; the
  Subject retargets to where the result landed (the moved file, the copy, the renamed
  file, the zip) and the Panel stays on that Subject's Actions, as after Rotate or Use as
  Subject. A Move or Copy onto a taken name lands as Finder's "Keep Both" does,
  `name 2.ext`, decided by the move itself failing with "file exists" rather than by a
  look first; moving into the folder it is already in does nothing. Compress is
  `ditto -c -k --sequesterRsrc --keepParent` into a scratch folder, then moved in beside the
  original as `<name>.zip` the same way — `ditto` alone would overwrite. Rename is refused
  on a taken name ("Name already taken") and its editor stays open to try another. A
  failure shakes the Panel and says so in a chip in the Subject Card's corner
  (`fileOperationNote`, which also says "Moving…" and the like while one runs). Move To…
  and Copy To… list recent destinations (in memory), the folder Sources, then Desktop,
  Documents, Downloads and Home; typing filters those and adds the File Index's folders
  below them. None of these is offered on a Clipboard Item or an app: a Clipboard Image's
  stored PNG is not the user's file. Copy File is `.copy(.fileURL)`, the file itself on the
  pasteboard, Final and hiding like Copy; Paste File is `.paste(.fileURL)`, the same
  write followed by Cmd+V into the app the Panel was opened over, like Paste.
- **Rename is the name in an editor on the Subject Card**, prefilled, the name without its
  extension selected as Finder does (a folder's whole name). Enter or ⌘E renames, Escape
  cancels, and the Card takes the Emphasis while it is open because it has the keyboard.
  It is not Editing (`GLOSSARY.md`), which is a text Subject's text.
- **Transcribe is Codictate's, never ours.** A file whose `UTType` conforms to
  `.audiovisualContent` (not an MPEG-2 transport stream: `.ts` is declared one) offers
  it. Codictate's command line is a Rust thin client of the running app (Codictate's
  `docs/CLI.md`, contract version 1, and its ADR-0009): `Transcription` runs
  `<Codictate.app>/Contents/Resources/app/bin/codictate transcribe <file> --json`,
  looked up by bundle id (`app.codictate`, then `app.codictate.canary`; GUI apps do not
  inherit the shell's `PATH`). The client starts Codictate hidden when it is not
  running, and Codictate runs File Transcriptions one at a time, so a call may wait.
  **Compatibility is asked, not guessed:** the first time a client binary is used,
  `Transcription.compatibility(of:)` checks it is a Mach-O (the client before this
  contract was a script, never run) and runs `status --json` once, wanting
  `contractVersion` 1; the answer is kept per path and modification date. A missing
  client, a script, another version, exit 2 or 11 is `.tooOld`; exit 6 is
  `.unavailable`, asked again next time. It is a `.transcribe` Effect with no `.hide`,
  run off the main thread by `EffectRunner`, which reads stdout **line by line as it
  arrives** (never to EOF), ignores event types and fields it does not know, and
  answers through `onTranscriptionProgress` for each `queued`/`progress` and
  `onTranscription` at the end. The transcript (`result.text`), trimmed, becomes a
  text Subject in place of the file, as OCR Text replaces an image. While it runs the
  Subject Card's corner chip (`transcriptionNote`) says where it is, in Codictate's
  own window copy: "Transcribing…" until the first event, then "Waiting, 2 ahead",
  "Next up", "Reading the file · 0:01", "Transcribing · 0:42 · 52:01 of audio". A
  failure shakes and says why, from `error.code` first and the exit code after: "No
  speech found" (empty), "No audio in this file" (`no_audio`, 3), "Can't read this
  file" (`input_unreadable`), "Pick a speech model in Codictate"
  (`model_not_installed`, 4), "Couldn't start Codictate" (`app_unavailable`, 6),
  "Couldn't transcribe" (anything else); `cancelled` (130/143) says nothing. The
  client's stderr line goes to the log (`NSLog`), never to the user. The Action is
  listed without Codictate too: then the first Enter says "Get Codictate to
  transcribe" (no app) or "Update Codictate to transcribe" (no contract-1 client, or
  `contract_mismatch`, 11) with a ⏎ chip, and the next Enter opens
  `Transcription.downloadURL` (codictate.app, whose front page has the download).
  Escape while it runs, leaving the Action Phase, `reset()` and the Panel hiding all
  stop it (`.cancelTranscription`, SIGTERM; the client forwards the cancel to Codictate
  and exits 143, and the generation drops the answer and any late progress). The
  client inherits only `HOME`, `PATH`, `TMPDIR` and a few more, like the embedding
  helper.

### Visual layer

- **`Style.swift` owns every radius, material and tint**, and nothing outside it
  branches on `colorScheme`. A Card needs no branch: bare glass adapts itself.
- **A Card is bare `.glassEffect(.regular)` in a rounded rect — nothing else.** Never add
  a rim, a `.shadow`, a `.clipShape`, a gradient, a specular wash or an inner shadow.
  Lensing, the specular rim and the shadow are the material's own job (WWDC25 219);
  clipping glass cuts its shadow into a grey halo (Apple forum 797806); a fill behind
  glass is banned outright (WWDC25 310). All of them were on the Card until 2026-09-11
  and it read as frosted plastic.
- **Every Card is untinted `.regular` glass, and focus is Emphasis.** The *unfocused* Card
  is inset by `Style.unfocusedCardShrink` — 10pt on each side in **layout**, so a 200pt Card
  is drawn at 180 — with its content at `Style.unfocusedContentOpacity`; the focused one is
  full size, and the change is instant via `.animation(nil, value: focused)`. Never a
  transform: `GlassEffectContainer` builds its glass shapes from layout frames and ignores a
  `.scaleEffect`'s anchor, so glass and content shrank about different anchors and the content
  ended up ~10pt off-centre.
  Never show focus with a tint, a rim, a shadow, a Lamp or a beam — an accent-tinted Card
  was built and rejected on sight (2026-09-11); the app carries no colour.
- **One `GlassEffectContainer` holds all glass** — three Card tiles and the Results Slab
  — with `spacing` **below** the inter-Card gap so nothing merges, and `.glassEffect` on
  the children, never on the container. Cards never fuse — no `glassEffectUnion`: the
  Panel is meant to read as three separate tiles with a gap, not one body (`GLOSSARY.md`,
  **Card**).
- **Arrival is `.glassEffectTransition(.matchedGeometry)` on `Motion.resize`**: a new Card
  grows out of the one before it; its content hard-cuts; `.identity` under Reduce Motion.
- **A Card's glass goes on a `ZStack`, never a `Group`.** A `Group` hands its modifiers
  to each branch inside it, so the glass was the branch's: "Type..." giving way to an app,
  or one Subject to the next (`.id(subject.id)`), took the glass out and put a new one in.
  The first keystroke into the empty Panel does that inside the Slab's arriving animation,
  and the whole Subject Card, content and all, was gone for ~300 ms (2026-10-12). Only the
  window server shows it — an offscreen render draws the Card either way;
  `SubjectCardHoldTests.noCardsGlassIsOnAGroup` pins the shape.
- **`Motion.swift` owns every curve, in two categories.** Three **Transition** curves —
  `entrance`, `resize`, `snappy` — carry a change the user caused; Phase advances, Card
  content swaps and selection movement are instant *on purpose*. **Decoration** is now
  the Loading Ring alone, absent under `Motion.isReduced`; `Motion.isTransparencyReduced`
  is **deleted**, with the beam it existed for. ADR 0003's beam sections are
  history, not guidance.
- **A text Subject gets a monochrome fill in the Card's *content* layer**, never a
  tinted glass. See `docs/adr/0009-cards-are-bare-glass.md` and `GLOSSARY.md`.
- **The Loading Ring is not a progress indicator.** A constant-length 270° arc that
  turns, in both of the Panel's waiting states. Neither Vision nor `mdfind` reports
  progress, so a ring that *fills* would be claiming something the app cannot back.
- **`FloatingPanel.hasShadow` must stay `false`.** AppKit derives a window shadow
  from the content's alpha mask. This Panel's content is transparent glass with soft
  edges, and that derivation traces a ragged wavy contour around it plus a ghost
  second outline. Separation is the content's job: the Results Slab draws its own
  SwiftUI shadow, and a Card's native glass casts its own — never give a Card a
  `.shadow()`.
- **No `.shadow()` on a view that fills its window.** It is clipped by the window
  bounds and renders as a hard band down two edges instead of a falloff. This is why
  `PanelLayout.margin` exists: the Panel is deliberately larger than its content, by
  enough for the entrance animation's 1.04 overshoot *and* `Style.shadowRadius`
  beyond it. Shrink the margin and both artefacts come back. `PanelLayoutTests`
  asserts the relationship.
- **The empty space inside the Panel must not be hit-testable.** The margin and the
  gap between the Slabs belong to the window, and click-outside-to-dismiss depends on
  a click there counting as outside. Three things cooperate:
  `PanelHitRegions` (where the surfaces actually are, reported by the layout),
  `FloatingPanel`'s content view declining to hit-test outside them, and a *local*
  mouse monitor in `PanelController` — the global monitor never sees these clicks,
  because the window is ours.
- **Stroke a rim *after* clipping, not before.** `overlay { strokeBorder }` followed
  by `clipShape` cuts the hairline in half and aliases along the curve.
- **A tint heavy enough to read as a colour stops glass being glass.**
  `.regular.tint(.white.opacity(0.58))` is a white wash over a blur — that is what
  "material" looks like. The blur and specular edge of `.regular` are the effect; a
  tint is only ever a nudge for legibility.
- **A Slab inside a window sized to the worst case must carry a *definite*
  height.** `maxHeight` is flexible, so a Slab given one takes every point the
  Panel reserved for it — which is how the Results Slab came to be a mostly-empty
  pane with the Query field floating under the divider. The Slab hugs
  (`fixedSize(vertical:)`) and the scrolling area inside it is given a definite
  `PanelLayout.resultsAreaHeight(contentHeight:chromeHeight:)`. That also keeps the
  proposal definite all the way down to the `LazyVStack`: hugging a lazy container
  by proposing it an unspecified height makes it build all 1,914 cells to answer,
  so the content heights are **arithmetic** (`EmojiGridView.contentHeight`,
  `PanelLayout.listContentHeight`), not measurements. Where an intrinsic piece of
  furniture has to appear in that arithmetic it is rounded *up* — see
  `PanelLayout.resultsHeaderHeight`. `PanelLayoutTests` pins the sums.
- **The Query field is a bar, not a row.** `PanelLayout.queryFieldHeight` and
  nothing else, pinned along the Slab's bottom edge in every Mode; the Results
  area above it takes all the variable height. It is also the **only** place the
  Query is spelled out — the results header, the empty and searching states and
  the Action and Target Card placeholders all used to repeat it, which put the
  same string on screen twice and wrapped a long Query over three lines. One
  Query on screen at a time; everything else names what it *matched*.
- **"No results" is a claim, and a Mode has to be entitled to it.**
  `CommandCoordinator.canReportNoResults` is that entitlement and
  `isSearchInFlight` is the "Searching…" one. Clipboard, Emoji and Action search
  match in memory, so zero matches is true the instant the key lands and the
  message must not be delayed. In Subject search the row carries a "⌘E use as
  text" `KeyHintChip`, the only way a Query becomes text. Subject search matches
  the app Index, and until the first scan lands the Slab shows the Query bar
  **alone** — no message row,
  which is the shortest Slab there is (`PanelLayout.queryOnlyResultsHeight`).
  Its list below the apps answers each Query a moment after the keystroke, and
  until its **settled pass** has, "No results" is not said either:
  `SubjectSearchVM.hasAnswered` waits for both, and while a newer Query is out
  the previous list stays on screen rather than a claim about a Query nobody has
  answered yet. The keystroke's word answer is not enough: a Passage's last word
  is a prefix, and meaning joins, only in the settled pass, so "budg" found
  nothing on the keystroke and the budget report a moment later — and the Card
  said "No match", the Panel shook, and both changed their minds.
  Target search answers out of process and says "Searching…" instead, and OCR
  — which is not a search at all — says "Reading text…" off
  `CommandCoordinator.isOCRInFlight`. Subject
  Results used to be withheld for 600ms by a debounced visibility flag on top of
  all that, which left "No results" as the only thing the Slab could draw in the
  meantime: every search said no and then changed its mind. A debounce cannot
  fix that, because a debounce is what it was.
- **The Subject Card is never blank in Subject search.** It shows
  `SubjectSearchVM.cardSubject`: the highlighted row, or, while the Query has
  not been answered (`hasAnswered`) and nothing is highlighted, the last thing
  it showed — a row, the text ⌘E stood, or a Last Subject typing ended
  (`holdOnCard`). "No match" only once the Query has been answered with
  nothing; "Type..." with no Query. It never reads `results[selectedIndex]`
  itself: that is empty between a keystroke and its answer, and the Card fell
  to a faint placeholder on bare glass, which read as the Card disappearing.
- **A matched name is marked with an underline, in `highlightedName`.** Weight
  was tried and is no difference at all against a selected row, whose title is
  already bold. The subsequence tier only marks up when the *whole* Query is a
  subsequence of the name, so an Emoji found by its keywords — which have nothing
  to underline in the CLDR name — degrades to plain text instead of marking the
  two characters that happen to line up. A Result's subtitle is marked up only
  where it names the thing; `ResultDisplayItem.highlightsSubtitle` decides, and
  it is false for a derived subtitle like a clipboard entry's relative
  timestamp.
- **Emoji glyphs go through `EmojiRenderer`.** Apple Color Emoji is a bitmap font
  with strikes at 20/26/32/40/48px; an off-strike point size resamples and reads
  soft. The largest strike is 48, so a glyph slot much above 64pt looks soft unless a
  larger strike is added. `EmojiRenderer.image` is cached on the glyph **and** the box
  size — it is called from a view body, and two call sites ask for two sizes.
- **A `ForEach` id has to move when its contents do.** `EmojiSearchVM.Section` hashes
  its whole contents into its id. Every Query produces a section titled "Results", and
  while the id was the title alone a `LazyVStack` was entitled to keep the cells it
  had already built — so a filtered grid went on showing the previous Query's results
  while the Subject Card showed the right one. `ResultDisplayItem.id` is a `String`
  taken from the source for the same reason: it was a `UUID` and one initialiser
  minted a fresh one per call, re-identifying every row on every keystroke. An
  app's row is its path (`path:`), because the Index makes a fresh `Subject` per
  keystroke.
- **The grid and the Subject Card must draw the same glyph.** Both go through the tone
  in force — `EmojiSearchVM.displayed` for a cell, `resolvedSelection` for the Card.
  Toning is presentation only: selection, ordering and identity stay with the base,
  because a variant is never a Result.
- **Emoji Mode builds no `ResultDisplayItem`.** In grid Mode a Result is a cell, and
  `EmojiSearchVM.displayResults` is empty on purpose. The one Emoji row is in Subject
  search's list below the apps (`ResultDisplayItem(emoji:base:)`): the glyph in the
  tone in force, through `EmojiRenderer`, with the base's id.
- **Every picture of a file's contents goes through `Thumbnails`** — Quick Look's
  `QLThumbnailGenerator`, `.thumbnail` representation only. A `Subject`, an
  `ActionTarget` and a `ResultDisplayItem` carry a `thumbnailURL` beside their icon: a
  file's own URL, or a Clipboard Image's stored PNG (`Subject(clipboardItem:imageURL:)`,
  made only where the history is at hand — `CommandCoordinator.clipboardSubject(for:)`
  and the list below the apps in `SubjectSearchVM` — because only the history
  knows the path). `ThumbnailReader` is the one view that asks: it hands its content
  the thumbnail or `nil`, asks from `.task`, so only rows the `LazyVStack` builds ask
  at all, and swaps the thumbnail in when it lands — no fade. `ThumbnailImage` is it
  drawing the icon, then the thumbnail in the icon's slot. Requests are the slot's side
  (`PanelLayout.resultIconSize`; the Subject Card's `Style.cardSide`, 200, whatever
  its Emphasis, so focus moving never misses the cache) at `displayScale`. **A Card's
  request `fills`**: Quick Look answers with a thumbnail that *fits* the size asked, so a
  4:3 photo asked at 200pt came back 200×150 and was upscaled to cover the Card, soft. A
  filling request asks for `side` × the long side over the short one (an image's header
  says it; 16:9 where nothing does; capped at 4:1), so the short side lands at the Card's
  and aspect-fill never upscales; the key stays `side`. A `Thumbnails.Moment` pictures
  one place instead of the start: a PDF page (PDFKit, drawn on white) or a video frame
  (`AVAssetImageGenerator`, ±0.5 s), for a Passage. The cache is
  an `NSCache` checked against the
  file's modification date and size, because Rotate and Preview write in place; a
  view's first frame is the last thumbnail made, so a row rebuilt by a keystroke does
  not flash its icon. Only regular files are asked about — a folder or an app is its
  icon. The Subject Card keys its thumbnail on `subject.id`, which is how a Rotate's
  fresh Subject makes it look at the file again. The Clipboard browser's full-size
  Card preview is not a thumbnail and reads the stored PNG directly.
- **A Subject with a picture fills its Card edge to edge** (`CardPicture`): a file's
  thumbnail once it lands, and the Clipboard browser's stored PNG. Aspect-fill,
  centred, clipped to `Style.pictureShape` — the **picture** is clipped, never the
  glass. It is content laid out in the frame the glass is drawn in, so its inset from
  the glass is 0 and its concentric radius is `cardRadius` (20), at 200pt focused and
  at 180pt unfocused alike: `unfocusedCardShrink` is padding outside both. It steps
  back with the rest of the content. The name sits on its bottom edge in
  `Style.pictureCaption` over `Style.pictureScrim`, a content-layer gradient that is
  part of the picture, never a tint on the glass; a hidden copy of the corner holds the
  chips' place so a long name stops short of them. Everything that is its icon — apps,
  folders, text, Emoji, a file Quick Look cannot draw — keeps the icon-and-name layout.
  Rename keeps the icon-sized thumbnail beside its editor.
- **A File Result that matched inside the file shows its Passage on the Card**
  (`CardPassage`), in the Subject search Phase and, since the Passage travels with the
  chosen Subject (`Subject.passage`, copied by `CommandCoordinator.chosen`), in the Action
  Phase after Tab. A PDF: the matched page is the picture, "page 4" over the name. A
  video: the frame at its second, "at 14:02"; a recording: its picture as ever, and the
  moment. An image: nothing new — its picture is the thing, whatever OCR read. Anything
  else: the excerpt, up to three lines over the name with the literally matched words
  underlined as a row marks them (`underlined(_:marks:)`), on the taller
  `Style.passageScrimHeight`; with no picture, under the name beside a smaller
  `Style.passageIcon`. Found by meaning alone, it has no marks and shows plain. The
  Panel's value is `SubjectPassage`, built from `FileHit.Passage` in one `init` — **which
  has no time span yet**: search by meaning adds it, and its start is the one argument to
  pass there; everything timed below already reads `SubjectPassage.seconds`.
- Deployment target is **26.4**. Liquid Glass is unconditional — no `#available`.
- `ConcentricRectangle` exists and derives nested radii from an enclosing
  `containerShape`, but it is a `Shape` and **not** an `InsettableShape`, so it has no
  `strokeBorder`. Verified against the SDK.

## Architecture: How Components Connect

## Boot Sequence

```
codiclensApp (@main)
  └─ AppDelegate (NSApplicationDelegateAdaptor)
       ├─ Starts LastActiveApp (applicationWillFinishLaunching)
       ├─ Release builds outside /Applications: Move to Applications first
       │  (MoveToApplications; when it moves, nothing below starts)
       ├─ Takes ⌘Space and ⌃⌘Space from macOS if the user chose it
       │  (ShortcutTakeover.takeAtLaunch; handed back in applicationWillTerminate)
       ├─ Registers Cmd+Space and Ctrl+Cmd+Space hotkeys (Carbon EventHotKey)
       ├─ Creates PanelController
       ├─ Registers the "Open in Codiclens" Service, then hands over an
       │  Incoming Subject that arrived before the Panel existed
       ├─ Starts the File Index (FileIndex.shared.start(); stop() on terminate)
       ├─ Handles QLPreviewPanel responder chain
       ├─ In the unit-test host, none of the above (AppDelegate.isTestHost)
       └─ With --embedding-service, none of the above either: the embedding
          helper's request loop (EmbeddingService.start())
```

## Core Components

### PanelController — Window orchestrator
Owns the AppKit half: where the window sits, when it appears and disappears, who has
activation, and which clicks count as outside. Creates and manages:
- **panel** (FloatingPanel) — the *one* window, fixed at `PanelLayout.panelWidth` ×
  `panelHeight`, never resized
- **PanelPresentation** — the two values the SwiftUI content and the controller pass
  between them: `visible` (drives `Motion.panelEntrance`) and `hitRegions`
- **CommandCoordinator** — all business logic
- **QuickLookHelper** — QLPreviewPanel data source/delegate

Wires runner callbacks:
- `onHide` → `hidePanel()` — the animated dismissal
- `onPasteAndHide` → `pasteAndHide()` — `hideImmediately()`, then hands activation
  back, then fires the paste. **Never animated**: a Panel still on screen takes the
  synthesised Cmd+V.
- `onQuickLook` → `showQuickLook()` — activates app, shows QLPreviewPanel
- `onSavePanel` → `showSavePanel()` — NSSavePanel for file export
- `onShowSettings` → `showSettings()` — settings window
- `onOCRText` → `coordinator.receiveOCRText(_:)`
- `onQRCode` → `coordinator.receiveQRCode(_:generation:)`
- `onImageRotation` → `coordinator.receiveImageRotation(...)`
- `onFileOperation` → `coordinator.receiveFileOperation(_:generation:)`
- `onTranscription` → `coordinator.receiveTranscription(_:generation:)`
- `onTranscriptionProgress` → `coordinator.receiveTranscriptionProgress(_:generation:)`
- `onMomentOpen` → `coordinator.receiveMomentOpen(succeeded:generation:)`

These callbacks answer the coordinator across the Effect seam. The runner owns
Vision, image processing, file operations and the `codictate` process, so
`CommandCoordinator` does none of them. Image, file and transcription callback
generation IDs discard answers from a reset Panel session; `hidePanel()` and
`hideImmediately()` also call `coordinator.cancelTranscription()`. The
runner is handed the pasteboard it writes to (`.general` here; a test passes a private
one).

`coordinator.onPhaseChange` is **not** wired. It used to resize the card window; the
window no longer resizes, and the Card row's width is a SwiftUI animation driven by
`coordinator.cardCount`.

Show and hide:
- `showPanel()` calls `coordinator.reset()`, which stands the **Last Subject** if
  there is one (see CommandCoordinator below), centres the *Card row* on the screen
  the mouse is on, renders once at `visible == false`, then flips it inside
  `withAnimation(Motion.entrance)`
- `hidePanel()` drops the observers and hands activation back immediately, and lets
  only the `orderOut` wait for the exit animation's completion. `isShowing` and
  `showGeneration` are what stop a re-show racing a pending completion
- `hideImmediately()` is the no-animation path: paste, save panel, settings, teardown
- Search by meaning's query encoder is held while the Panel is up
  (`QueryEncoderHold`: `FileIndex.shared.holdQueryEncoder()` in `showPanel()` and the
  save panel's Cancel, `releaseQueryEncoder()` in `hidePanel()` and `hideImmediately()`,
  so every hide path), so the first settled search of a session does not wait for the
  model to load. Hold and release alternate, and both do nothing with meaning off or
  unsupported; the test host never builds the controller

Focus lifecycle lives in **FocusHandoff** — `capture`, `restore`, `yield`. Every
`previousApp` read and write in the app is in that one file.

### CommandCoordinator — State machine + execution
Owns four view models, one per search phase:
- **SubjectSearchVM** — Subject search, as two lists that read as one. Up to five
  apps and Built-ins, fuzzy-matched against the app Index on the keystroke and
  always on top. Below them, one list ranked by score mixing File Results (File
  Index), Clipboard Items (text ones, `ClipboardSearchVM.scored`) and Emoji
  (`EmojiSearchVM.scored`) — `SourceSearch` ranks it off the main actor on
  `fuzzyScore`'s scale, files up to 50, Clipboard and Emoji capped at three each,
  no priority between Sources. The one thing ahead of the rest is the settled
  pass's Kind block, which scores below zero (`FileHit.kindScore`): with a Kind
  Word ("video", "billede") the files of that Kind come before every Clipboard
  Item and Emoji, which mix with the rest below it. It **stays on screen while the user types**: word
  matches are asked on every keystroke and replace it in place as they land, and
  once typing pauses (a 120ms Combine debounce) the settled pass asks
  `FileIndex.settledSearcher` once — the word search with the last word a prefix in
  Passages too, and with search by meaning on, meaning fused in — and ranks its files
  with the Clipboard Items and Emoji as the keystroke's are, after which the list does
  not change until the Query does: a word answer for that Query landing later is
  dropped. One keystroke search is out at a time and a Query typed meanwhile replaces
  whatever was waiting (the File Index reader is one locked connection, and "the "
  over a million Passages took 540 ms); the settled pass runs beside it on its own
  connection, so the first of a session waiting for the query encoder holds up no
  keystroke. An answer for a Query typed past is dropped, and only the newest settled
  pass lands: the File Index answers one superseded or cancelled with `[]`, which is
  not an answer. An untouched selection stays on the first row. One moved by hand
  picks its row (by `ResultDisplayItem.id`): under the same Query it follows the
  row through re-ranks; once the Query changes the row is **pinned** — first in
  the whole list, above the apps, selected, listed once, and the list scrolls to
  the top (`pinCount`) — for as long as the new Query matches it. A pinned list
  row the word answer leaves out waits for the settled pass; when it no longer
  matches, the pin goes and the selection is the first row, and the row coming
  back is not pinned again. Moving onto row 0 by hand, clearing the Query, ⌘E,
  a path and the Panel opening again (`forgetPick`) pin nothing. The only thing
  ever above the apps, and only because the user chose it (2026-10-12). `SearchSchedule` is the seam for both moments: `LiveSearchSchedule` in
  the app, `HeldSearchSchedule` in tests, which run them by hand. Each row names
  its Source (`ResultDisplayItem(file:)`, `(clipboardResult:)`, `(emoji:base:)`,
  ids prefixed by Source). A File Result found by what the file says shows its
  Passage on the second line instead of the folder — "page 4 · …the words…", the
  matched words underlined (`ResultDisplayItem.subtitleMarks`) — and keeps the file's
  id. Every Source's switch in `SourceStore` is read on every
  search; folder switches are the File Index's own. See ADR 0012.
- **ActionSearchVM** — context-sensitive actions based on selected subject
- **TargetSearchVM** — file/app targets. The search itself is `FileTargetSearch`:
  the **File Index first** (names, then files that say the Query, under their
  Passage), shown at once while "Searching…" still holds, then the
  priority-folder and system-wide `mdfind`s, run side by
  side, each read line by line and stopped at its `Scope.lineCap`, minus every path
  the File Index already gave, appended below it so nothing on screen moves. Only
  the ranked top 50 get an icon. Their thumbnails are not made here; a row asks
  `Thumbnails` once it is on screen. The next keystroke, and leaving file search,
  cancel it — every `mdfind` it started is terminated. Stages are `OSSignposter` intervals
  under the "Search" category; `FileTargetSearchTimingTests` times them against the
  real index and is skipped unless `TEST_RUNNER_CODICLENS_TIME_FILE_SEARCH=<runs>`
  is set.
- **ClipboardSearchVM** → **ClipboardManager** — clipboard history

Phase state machine:
```
searchingSubject ──Enter──→ executeDefaultAction + hide
       │                      (app/file/folder/text, a Clipboard Item row pastes,
       │                       an Emoji row inserts, or the Last Subject)
       │Tab
       ▼
  pickingAction ──Enter──→ executeAction + hide (final actions)
       │                      or advance to pickingTarget (non-final)
       │Tab (non-final)
       ▼
  pickingTarget ──Enter──→ executeAction + hide

searchingSubject ──"Clipboard"──→ browsingClipboard ──Enter──→ paste item
                                        │Tab
                                        ▼
                                   pickingAction (clipboard-specific)
```

A file becomes a Subject two ways, and neither is a file browser — see
`docs/adr/0008-a-file-can-be-a-subject.md`. A **Path Subject** is a Query
beginning `/` or `~`, resolved by `PathSubject` to exactly one file or folder;
those two prefixes cannot collide with an app name, so none of the Index's
gates move for one. **Use as Subject** is a non-Final Action that promotes a
file-or-app Target into the Subject and lands back on `.pickingAction`. ADR 0012
added a third, the list below the apps: a File Result is a Subject once chosen,
resolved again through `PathSubject.subject(for:)` as Enter or Tab lands
(`CommandCoordinator.chosen`) — a file gone since it was indexed is not acted on.

Rows of the list below the apps act as their own Mode would. A File Result opens
on Enter (a recording or a video that matched at a moment opens in QuickTime there; see
the Panel's own preview below) and Tab gives its file Actions, Share among them. A Clipboard Item pastes
on Enter; an Emoji inserts in the tone in force and becomes recent. Each becomes the
Last Subject, the file included. Shift+Tab from their Actions returns to
Subject search (`isSubjectFromSearch`), not to the Clipboard browser or the grid
they never came from.

OCR returns `[.ocr(url)]` and **no `.hide`** — the OCR Text lands *in* the Panel — and
`EffectRunner` awaits Vision before answering through `onOCRText`. QR Code and Rotate
also run behind the Effect seam and return no `.hide`; their work uses one serial queue
so consecutive rotations reach disk in command order. Move To…, Copy To…, Rename and
Compress return `[.fileOperation(...)]`, likewise without `.hide`, on a second serial
queue. Transcribe returns `[.transcribe(url, generation:)]`, also without `.hide`; the
runner runs `codictate` on a global queue, posts each progress to the main queue
before the answer, and keeps the run so `.cancelTranscription` can stop it. `isOCRInFlight`, `isImageActionInFlight`, `isFileOperationInFlight` and
`isTranscriptionInFlight` gate a second Enter while their respective answer is pending.

Text mode is **⌘E, and nothing else** (`docs/adr/0012-files-in-subject-search-text-mode-is-cmd-e.md`).
Zero app matches is "No results" — offering ⌘E as a hint — never a text Subject.
⌘E in Subject search with a non-empty Query opens the editor with the Query in it,
whether or not anything matched and for a path Query too; saving stands the text
as the only Result (`SubjectSearchVM.standAsText`), so Enter copies it and Tab
opens its Actions. Escape in the editor discards it; Escape on the saved text goes
back to what the Query matched. The next keystroke is a new Query: the text was
written in the editor, not in the Query. `hasAnswered` — the Index landed and the
settled pass of the list below the apps answered this Query — gates only "No
results", the Card's "No match" and the shake. A list landing while text stands is kept for Escape.

**Last Subject** (`GLOSSARY.md`, `docs/adr/0014-incoming-subjects-and-the-wider-last-subject.md`):
Enter or a Final Action on anything but an app or a Built-in makes it `lastSubject`
(`remember(actedOn:)`): a Clipboard Item still in history, an Emoji, a file, a folder,
text (⌘E, OCR Text, a transform's output, a transcript, a count copied). Acting on an
app or a Built-in clears it; Move to Trash clears it. In memory only. Where an Action
turns the Subject into another — Rename, Move To…, Copy To…, Compress, OCR,
Transcribe, a transform, QR Code — the Last Subject follows it there. `reset()`
stands it with the Query empty (`standingSubject`) after looking it up again: a
Clipboard Item in history, a file or folder on disk through `PathSubject.subject(for:)`
(its Passage kept). Gone means none and an empty Panel, no shake. It is not a
Result, so the Slab stays away and `SubjectCardView.subject` reads it from the
coordinator. Enter runs its default action, Tab opens its Actions and Shift+Tab
comes back to it; the first keystroke ends it standing, and the Card keeps it
until the new Query has something to show. ⌘E on standing text edits it, and the
edit is the Last Subject.

**Incoming Subject** (`GLOSSARY.md`): `PanelController` shows the Panel and then
hands it to `receiveIncoming(urls:)` or `receiveIncoming(text:)`. Either drops the
command in progress (`dropCommand()`, the part of `reset()` that is not standing
anything: Phase, editors, Passage Preview, and every answer still out, by
generation) and stands the Subject through the Last Subject's machinery, so Enter,
Tab, Shift+Tab and the first keystroke behave identically. The first URL is resolved by
`PathSubject.subject(for:)`, so a `.app` is an app Subject; nothing resolving leaves
the Panel empty, and whitespace-only text is ignored. Sent in counts as acted on, so
it is `remember`ed: anything but an app is the Last Subject from then on. The
Subject itself is held in `incoming` for this showing only, which is how an app
stands without being remembered; it ends on the next `reset()`, the first keystroke,
or anything else being acted on. `incomingCount` is how many were sent while the
Card is on it (standing, or chosen in the Action and Target Phases), 0 otherwise;
above 1 the Subject Card's corner says "1 of N".

### FloatingPanel — Non-activating NSPanel
```swift
styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]
```
Critical contract: the panel floats over other apps WITHOUT stealing macOS activation. This means the previously active app stays frontmost, which is required for paste simulation (CGEvent Cmd+V targets the frontmost app).

When Quick Look is shown, `NSApp.activate()` breaks this contract. PanelController captures `previousApp` and restores it event-driven before pasting. An Incoming Subject breaks it too, from outside: see below.

### Incoming Subjects — Open With and the Service
How a file, folder or text gets in from another app (`GLOSSARY.md`,
`docs/adr/0014-incoming-subjects-and-the-wider-last-subject.md`). The coordinator's
half is under CommandCoordinator above; this is the AppKit half.

**The plist.** The Info.plist is still generated; `codiclens-Info.plist` at the
repository root is merged into it (`INFOPLIST_FILE`, app target, Debug and Release)
and holds `CFBundleDocumentTypes` and `NSServices`. It sits outside `codiclens/` so
the synchronized group does not copy it into the bundle as a resource.

**Open With is one document type, role Viewer, rank `Alternate`, over a list of broad
types** (`public.text`, `public.image`, `public.composite-content`, `public.folder`
and the rest in the plist), not `public.item` at `None`, which LaunchServices does
not list. Codiclens leaves itself out of its own Open With… Targets
(`ActionTarget.openWithTargets`). Measured on macOS 26 with
`NSWorkspace.urlsForApplications(toOpen:)`, the list Finder's Open With is built from:
- rank `None` is never listed, even on a specific type;
- a claim on `public.item`, `public.data`, `public.content`, `public.directory`,
  `com.apple.package` or a `*` extension is never listed at any rank, so a type
  declared only as `public.data` (an extension no app declares, `.odt`, `.p12`) has
  no Open With ▸ Codiclens;
- `public.folder` at `Alternate` is listed for folders, and Finder stays their default.

The cost of `Alternate`: Codiclens becomes the default app for a type that no other
installed app claims (on the Mac it was measured on, `.pages`, `.numbers` and `.key`
without iWork); across ~95 common extensions no other default changed. Adding a type:
compare `urlsForApplications(toOpen:)` and `urlForApplication(toOpen:)` before and
after `lsregister -f`. LaunchServices leaves out a bundle under `/tmp` (`in-temp-dir`
in `lsregister -dump`) and one never launched (`launch-disabled`), so check with a
build that is neither; unregister it afterwards (`lsregister -u`).

**A file Codiclens itself would open is shown in Quick Look instead.** Opening it
would only send it back in as an Incoming Subject. Before Enter on a file or folder
(a Result, the Last Subject, an Incoming Subject), the Open Action, Finder's Open File
on a Target, or the fallback after QuickTime says no, the coordinator asks
`EffectRunner.opensInCodiclens(_:)`: `SystemEffectRunner` compares the bundle
identifier of `NSWorkspace.urlForApplication(toOpen:)`'s app with its own, so a Debug
and a Release copy both count. When it does, the Effects are the Quick Look Action's,
with no `.hide`, since Quick Look previews from the Panel (a Passage Preview already
open stays open). An app Subject still opens. In tests `RecordingEffectRunner.codiclensOpens`
says which URLs Codiclens opens, and LaunchServices is never asked
(`OpensInCodiclensTests`).

**Everything else comes through one Service, "Open in Codiclens"**: `NSSendFileTypes`
`public.item` (any file, a folder, a `.app`, a package) and `NSSendTypes`
`public.utf8-plain-text` in one entry, so there is never a file "Open in Codiclens"
beside a text one. `NSRequiredContext` is empty so it is on without a trip to
Keyboard Shortcuts. The provider is `IncomingService` (`Incoming.swift`), set as
`NSApp.servicesProvider` in `applicationDidFinishLaunching` after the Panel exists,
followed by `NSUpdateDynamicServices()` so a fresh install's Service shows up. A
request with file URLs is files; text only when there are none.

**Open With arrives as `application(_:open:)`** on `AppDelegate`: SwiftUI's own app
delegate forwards it to the adaptor, and with only a `Settings` scene no window opens
for it. Several files are one call. On a cold launch it comes **before**
`applicationDidFinishLaunching`, so it waits in `pendingIncoming` (the latest only) and
is handed over once the Panel is made. A Service that launches the app is delivered
after `servicesProvider` is set, so it never waits.

**Focus.** Both doors activate Codiclens: LaunchServices activates the app it opens
documents with, and a Service's provider is activated as the message is delivered. By
then `frontmostApplication` can already be Codiclens, and `FocusHandoff.capture` would
have no one to give activation back to. `LastActiveApp` remembers the last app other
than Codiclens to be activated, and `PanelController.showIncoming` captures
`LastActiveApp.source` (the frontmost app unless that is Codiclens) instead. It starts
in `applicationWillFinishLaunching`: on a cold launch the frontmost app is still the
one the user was in then, and Codiclens by `applicationDidFinishLaunching`. The Panel
then stays up with Codiclens active, as with Quick Look, and every hide path hands
activation back through `restore` or `yield`, the paste included. Sent to a Panel
already up, the Subject just stands, and the app captured when it opened stays the
one handed back to. `showIncoming` stands the Subject after `reset()` and before the
first render, so the entrance animates the Subject that was sent.

None of this runs in the unit-test host or the embedding helper.

### CardContainerView — Keyboard input capture
Contains a hidden `TextField` that captures all keyboard input, and the Card row.
**The keyboard lives here and nowhere else** — the Query field in the Results Slab is
display-only. Routes to coordinator:
- Enter → `submit()`, ⌥Enter → `toggleSkinTonePicker()`
- Tab → `advancePhase()` / Shift+Tab → `retreatPhase()`, both unconditional.
  **Shift+Tab does not arrive as `.tab`, and testing for it that way is why it did
  nothing at all for a while.** AppKit gives a back-tab its own control character
  — `NSText.h` spells them `NSTabCharacter = 0x0009` and
  `NSBackTabCharacter = 0x0019` — and SwiftUI passes it straight through, so
  `press.key` is U+0019 and a `press.key == .tab && press.modifiers.contains(.shift)`
  test is false for every Shift+Tab ever pressed. `KeyEquivalent` has no `.backTab`,
  so the scalar literal is the only spelling. Apple documents none of this and
  `KeyPress.characters` — "the characters generated by the pressed key as if no
  modifier key applies" — reads like a promise that the back-tab normalises back
  down to a tab, which is **wrong**: a probe logging both fields recorded
  `key=U+0019 characters=U+0019 modifiers=0x0002[shift]`, against `U+0009` in both
  with no modifiers for a plain Tab. The `.shift` test that remains is not
  redundant — U+0019 is also Ctrl+Y, which would otherwise retreat the Phase.
  Shift+Tab is the inverse of **Tab**, not of Ctrl+L: it is unconditional, so in
  Emoji Mode it leaves the grid rather than walking a cell left.
- Up/Down → `moveUp()` / `moveDown()`
- Left/Right → `moveLeft()` / `moveRight()`, which mean something only in a grid
- Escape → `handleEscape()`, which closes the Panel's own preview first
- **While the Panel's own preview is open** (`coordinator.passagePreview`), the field
  sends Up/Down and Ctrl+J/K (a few lines), Left/Right (a PDF's page, a recording's 5 s)
  and Space (play/pause, or a screenful of text or PDF) to it through
  `PassagePreviewDriver`, and nothing to the list under it. Shift+Space and Escape close
  it, typing closes it and goes on into the Query, Tab and Shift+Tab close it with the
  Phase.
- Cmd+Backspace → `deleteSelectedClipboardItem()` **first**, and only `retreatPhase()`
  when there was no Clipboard Item to delete. In Clipboard Mode it deletes the selected
  Clipboard Item from Clipboard History on the spot — Finder's Cmd+Delete habit, no
  confirmation — and the Panel, the Mode and the Query stay, with the row that took its
  place selected. Never a file. Shift+Tab is unaffected.
- Shift+Space → `triggerQuickLook()`, which previews whatever
  `quickLookContext()` names for the Phase: in Subject search the selected Result
  (a File Result, a Path Subject, an app, a Clipboard Item row through its
  written-out preview) or the standing Last Subject; in the Action Phase the chosen
  Subject; in the Target Phase the selected Target; in Clipboard Mode the selected
  Clipboard Item. An Emoji, text, a Built-in and Emoji Mode have nothing to preview,
  and it does nothing there. The **Quick Look** Action is the same call on Enter.
  A File Result that matched inside its file — the selected Result, or the chosen
  Subject in the Action Phase — opens the Panel's own preview instead (see
  QuickLookHelper below).
  This was `.pickingTarget` and `.browsingClipboard` only, and every other Phase
  answered `nil`, so Shift+Space in Subject search and on a chosen Subject did
  nothing at all
- Ctrl+E / Cmd+E → `toggleTextSubjectEdit()` — **any** text Subject, not just a
  Clipboard Item: OCR Text and a transform's output too. In Subject search it turns
  a non-empty Query into a text Subject; with an empty Query it edits only a text
  Subject already there, such as a standing Last Subject
- Ctrl+J/K → `moveDown()` / `moveUp()`
- Ctrl+H/L → `moveLeft()` / `moveRight()` **first**, and only `retreatPhase()` /
  `advancePhase()` when the horizontal move meant nothing. Routing them straight to
  the Phase took Ctrl+H and Ctrl+L out of Emoji Mode. Both spellings of a
  Control-modified key are accepted, via `ControlKey.letter`.

### View Cards
- **SubjectCardView** — shows app icon/name (a file's picture edge to edge once it lands,
  and where a File Result matched inside it, `CardPassage`), text preview, emoji glyph, or
  clipboard content, plus the corner chips
- **ActionCardView** — shows available actions for selected subject
- **TargetCardView** — shows file/app targets for selected action

Each Card carries a `KeyHintChip` in its bottom-trailing corner while it has the
keyboard, and only where its action has an obvious key.

### PanelView / ResultsListView — the Panel's contents
`PanelView` is the Card row, a real gap, and the Results Slab. The Slab animates in
when there are Results and out when there are not, with `Motion.resize` — except in
Emoji Mode, where the grid is never empty and the Slab is unconditional. A
display-only Query field is pinned along its bottom, because the Subject Card shows
what the Query *matched* rather than what was typed.

The Slab is **sized to its content**, up to `PanelLayout.maxResultsHeight`: ten
matching Emoji make a Slab two grid rows tall, and "No results" plus the Query bar
makes the shortest one there is (`PanelLayout.minResultsHeight`). Growing and
shrinking is the same `Motion.resize`, applied to the Results area's own frame with
`hardCut()` on the content inside it, so the surface springs while the cells cut.
`hitRegions.results` follows because the layout *reports* the Slab's frame — the
space the Panel reserved and the Slab did not use has to dismiss on a click.

### ClipboardHistory / PasteboardWatcher — clipboard capture
Polls `NSPasteboard.general` every 0.5s. Stores up to 100 items as JSON in Application
Support. Images saved as PNG files in `codiclens/images/`. Text previews for Quick Look
in `codiclens/previews/`, and Quick Look's text copies of files in `previews/files/`.
The pasteboard is only ever read on the main thread; the PNG re-encode goes through
`ImageReencoder`, off-main in the app and inline in tests.
A change carrying `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`
(nspasteboard.org; what password managers mark a copied secret with) is not recorded at
all — no text, image or file.

**A Clipboard Item is a snapshot**: the text or the pixels at copy time. `previewURL`
for an image returns the **stored PNG**, never the original file — it used to prefer the
original when it still existed, which had Quick Look showing one file while Paste and
Open in Preview used another. `originalFilePath` is still stored and is now only a
display name; nothing fetches content through it, and there is no re-sync from the
original. Edits saved in Preview, and Rotate, land on the stored PNG, so Paste follows
them. See `docs/adr/0010-a-clipboard-item-is-a-snapshot.md`.

### QuickLookHelper — QLPreviewPanel bridge
Data source and delegate for system Quick Look. Handles keyboard events (j/k navigation, Shift+Space dismiss). Reports dismissal via `onDismiss` callback.

**Quick Look opens and closes once Shift is up** (`whenShiftIsUp`). AppKit plays window
animations in slow motion while Shift is held, and Shift+Space always has it held: the
fade in took ~1.1 s instead of ~0.2 s, and a Shift+Space close was still on screen after
2 s (measured 2026-10-18). The release is a `flagsChanged` event, watched by a local and
a global monitor; `isTransitioning` is true while it waits.

A context is one item, the selected one; up/down and j/k inside Quick Look move the
Panel's selection and ask `quickLookContext()` again, which is how it walks a list.

**Text Quick Look has no previewer for is shown as a `.txt` copy**
(`QuickLookTextCopy`). Quick Look picks a previewer by type, and `.vue`, `.svelte`,
`.astro`, `.prisma`, `.go`, `.rs`, `.env`, `.gitignore` and `Dockerfile` are dynamic
types or plain `public.data` on macOS 26; `.ts` is declared an MPEG-2 transport
stream (`.tsx` is TypeScript only where Xcode is installed). A file whose type is
not `.text` and is dynamic, `public.data` or audio/video is read, and if it is
UTF-8 with no NUL, `QuickLookPreviewItem` hands Quick Look a copy named
`<original>.txt` in `previews/files/<uuid>/`, cut at 256 KB with "(truncated)" in the
title. Every other declared type — images, PDF, documents — is left to Quick Look
and never read. The copy is made when Quick Look first asks for the item, removed
when the item goes, and `FileClipboardStore.init` clears what a quit left behind.

**A third-party `QLPreviewPanel` toolbar is close, fullscreen, title, Share and "Open with
Preview" — that is the whole list**, verified on macOS 26 by screenshotting a throwaway
app. Finder additionally shows Markup and Rotate because those are Finder **Quick Actions**
(Action extensions); there is no public API to host them here and private API was rejected.
Do not try to add them. The toolbar is Apple's and we add no keys inside the panel beyond
the navigation ones above. An image Subject gets Rotate and Open in Preview from the Panel
instead — `docs/adr/0011-image-edits-rotate-in-process-everything-else-is-preview.md`.

**A File Result that matched inside the file gets the Panel's own preview, not Quick
Look** — `QLPreviewPanel` has no public API to highlight a word or start a video at a
second. `PassagePreview` decides, from the Subject's `SubjectPassage`: a PDF with a page is
`PDFView` at that page (`PassagePDFView`), the matched words found on that page's text and
set as `highlightedSelections`, scrolled to on the first layout with a size; text, code
and documents are the text the File Index read (`PassageTextReader`, the indexer's own
reader, so a chunk's offset would point into it), read-only, monospaced for code, the
Passage scrolled to the middle and its matched words underlined on
`Style.passageHighlight` (`PassageTextView`); a recording or video with a moment is
`AVPlayerView` seeking exactly to it and playing (`PassagePlayerView`), stopped when the
view goes. The File Index keeps a snippet, not a place, so `PassageFind` looks for the
excerpt's words in order with any whitespace between them, case ignored (within
`offsetWindow` of `SubjectPassage.textOffset` first, when there is one — `FileHit.Passage`
carries none), falling back to the first matched word alone. A name match, an image (its words came
from OCR), an iWork file (read through its preview PDF), a recording with no moment, and a
Target keep Quick Look.

**It lives in the Panel, in place of the Results Slab**, `PanelLayout.contentWidth` ×
`maxResultsHeight` at every Phase, on `slabSurface()`, its frame the Slab's hit region.
That is the whole reason it needs no activation exception: nothing is a new window, the
keyboard stays in the hidden field, and every document view refuses first responder
(`acceptsFirstResponder` false, text not selectable), so a click scrolls or plays and never
takes the keys. Quick Look's `NSApp.activate` plus `FocusHandoff` is not involved. It is
coordinator state, not an Effect — like the rename editor it changes nothing outside the
Panel — and `PanelController` closes it as the Panel hides, so a video never plays on
behind a hidden Panel.

**Enter on a recording or a video with a moment opens it in QuickTime Player there**
(`.openAtMoment`, with no `.hide`): `QuickTime.open` runs `osascript` off the main thread
(`NSAppleScript` is main-thread only, and the first run waits on macOS asking the user)
with the path and the moment as arguments, never spliced into the script. The app carries
`NSAppleEventsUsageDescription` and the hardened-runtime Apple Events entitlement
(`AUTOMATION_APPLE_EVENTS`). The Card's corner says "Opening at 14:02…" until the answer;
QuickTime coming forward dismisses the Panel, and success sends `.hide` too. Refused, or
QuickTime could not open it: the file opens the ordinary way and the corner says "Opened
from the start". Open on its Actions is the same. A PDF at a page opens normally — Preview
has no reliable page API.

### Settings — General and Sources
`SettingsView` is two tabs. **General** is appearance, Emoji, the App Index refresh and
the Acknowledgements sheet, which shows every bundled licence (`emoji-data-license.txt`,
`digup-license.txt`; both are resources through the synchronised group). **Sources**
(`SourcesSettingsView`) lists every Source (`GLOSSARY.md`) with one switch and two counts,
indexed and total, and nothing else: there is no priority between Sources. For a folder,
total is every row and indexed the rows whose contents are read (or that have none to read),
so the green number catches up as the contents backfill runs. Folders are added
with the open panel and removed with the row's "−" or its context menu, without a
confirmation; removing one drops its File Index rows, never files. `SourcesPage` builds the
rows from `SourceStore` and closures for counts and reading state, so `SourcesPageTests`
runs it on its own `UserDefaults` suite. A row being read — crawled, or with contents
unread while the backfill runs — shows the Loading Ring with "Reading" beside it, never a
`ProgressView`.

Under Folders, **Skip** is what the File Index leaves out inside the folder Sources, all
user-set and kept by `SourceStore` beside the Sources: a checkbox per
`FileIndexRules.SkipGroup` (on = skipped; Caches, node_modules and build output, App bundles
and packages, Git worktrees and Ignored by git on by default; Hidden, Repos, .env files, Keys
and certificates off, because the user wants to find those) and a list of `SkipPattern`s. `.git` and bare-repo
internals belong to the bundles group, so a repo is indexed and its `.git` is not; `.DS_Store`
is a cache. "node_modules and build output" is installed dependencies
(`dependencyFolderNames`), generated code and reports by name wherever they are
(`generatedFolderNames`: `paraglide`, `__generated__`, `.svelte-kit`, `.turbo`, `coverage`,
`.coverage`, `.nyc_output`, `.nuxt`, `.output`, `.vercel`, `.expo`, `.angular`,
`.docusaurus`, `.dart_tool`, `.terraform`, `.wrangler`, `.cxx`) and `build`/`dist`/`out`/
`target`/`_build` beside a project marker. **Git worktrees** skips a folder whose `.git` is a
*file* whose `gitdir:` names `…/worktrees/<name>` (`Entry.isLinkedWorktree`): the same repo
again, file for file — one repo held eighteen of them, ~224k rows. The
main checkout (`.git` a folder) is left to the Repos switch, a submodule (`gitdir:` naming
`modules`) is not a worktree, and a worktree that is itself a Source is read.

**Ignored by git** (`GitIgnored`) skips, names and contents, what git ignores in a repo at or
below a Source: every `.gitignore`, `.git/info/exclude`, the global `core.excludesFile`, and
never a tracked file. On this Mac that was ~900 MB of indexed JSON (one gitignored
`data/…/raw/` alone was 841 MB), `.moon/cache`, `Vendor/`, `supabase/.temp`. **Git is asked,
never imitated** — negation, anchoring and folder-only patterns are its business: a repo the
walk reaches is listed with `git ls-files --others --ignored --exclude-standard --directory
-z` (an ignored folder comes back once, not file by file), and the folders that lists are put
to `git check-ignore`, because `--directory` also names a folder that is merely *full* of
ignored files (`data/` when the pattern is `data/*`). Paths an FSEvents batch brings that have
no row are put to `check-ignore`, one process per repo per batch, so a launch that replays runs
git only for what it brings. A `.gitignore`, `.git/info/exclude` or `.git` that changes lists
its repo again and reconciles it (newly ignored rows go, newly un-ignored files are read);
one in a folder skipped by name or ignored is not news (npm puts them all over
`node_modules`). `git commit`, `checkout` and `gc` send no `.git` event (probed). A new folder
in a repo lists that repo again before it is walked, once a batch. Git's setup outside any
repo — which git, the global excludes file and what it says (`GitIgnored.setupStamp`) — is
kept in the `rules` fingerprint (`FileIndexer.rulesFingerprint`), so a change there crawls
every root at the next launch; it is not noticed mid-session. **`.env` files and keys are
exempt**: they keep to their own switches even where a repo ignores them, so a folder git
ignores is `.descendWithoutIndexing` — no row, walked for those alone — unless both switches
are on, when it is a plain `.skip`. **Only repos at or below a Source count**: a repo *around*
a Source is never asked (a dotfiles repo at `~` ignoring `*` would empty Documents), and an
outer Source's repo does not judge a Source inside it. Repos nest as git has them: each judges
its own files, and a folder the outer one ignores takes a repo inside it along. Git is the
binary `GitIgnored.installedGit` finds by file checks (xcode-select's developer dir, Xcode, the
Command Line Tools, Homebrew), never the `/usr/bin/git` shim, which offers to install the tools
in a dialog; without one the switch does nothing and its row says so. It runs with a minimal
environment, `GIT_CEILING_DIRECTORIES` at the repo's parent and `GIT_OPTIONAL_LOCKS=0`, and
**through files, never pipes**: stdin and stdout are temp files and the run ends at git's
exit. With pipes, a pipe end inherited by a process spawned meanwhile on another thread (the
embedding helper, `mdfind`, another git) held off end-of-file, and two `check-ignore`s holding
each other's pipes hung the parallel test run for good.
`GitIgnoredTests` runs all of it against real `git init` repos.

Measured on the dev machine (2026-10-12, Debug, default Sources), on vs off
(`TEST_RUNNER_CODICLENS_TIME_WITHOUT_GIT_IGNORED=1` runs both timing suites with it off):
28,913 vs 59,927 rows; first crawl 7.5–8.8 s vs 7.8–8.2 s (git is ~95 repos listed, lost in
the noise); launch catch-up 19 ms vs 11 ms; database after the contents backfill **793 MB vs
2.54 GB**, Passages 310k vs 1.02M, `.json` 1,680 files / 109k Passages vs 4,592 / 676k;
backfill 198 s vs 348 s (the two run side by side). Switching it on is a prune (6 s), off a crawl (7 s).
`deleteTree(_:source:)` says `+source`: without it SQLite chose `files_source` and walked the
whole Source per call, and that prune, deleting row by row inside ignored folders, took ten
minutes.
Symlinks and iCloud files not downloaded are always out, not a switch. Patterns: no `/` is a
name glob anywhere (`*`, `?`), a trailing `/` is folders only, any other `/` matches the path
from the Source folder down (`**` = any folders). Nothing skips a Source itself. The writer is
handed `SourceStore.fileIndexRules`, a plain `Sendable` value, never the store. A change
re-applies through `FileIndexer.setRules`: rules that only skip *more* delete rows from the
index alone (no walk); anything that lets more in re-crawls the enabled roots, and the crawl
being a reconcile, that one pass also deletes what is newly skipped and leaves unchanged rows
alone. Measured by `FileIndexTimingTests` on the dev machine: see its doc comment for the
command.

**A launch replays, it does not crawl** (`FileIndexer`). The database's `meta` table keeps
the FSEvents event ID the index has caught up to (stored after every batch `handle` applies),
the `FileIndexRules.fingerprint` the rows were read under, and per root the
`FSEventsCopyUUIDForDevice` volume UUID of a crawl that *finished*. At launch the first
`setSources` returns only the roots a replay cannot vouch for, and the watcher starts at the
stored ID, so FSEvents delivers what changed while the app was not running and then
`historyDone`. **A restart does not make a file new**: rows keep `st_dev`, which macOS
may renumber at each boot, and `isSameVersion` compares it, so after 2026-10-19's reboot
every row was read and embedded again. `meta` keeps per root `device:<path>` =
`<volume UUID>|<st_dev>` (`.volumeUUIDStringKey`, not the FSEvents UUID), and the first
`setSources` (and each `crawl`), before any replay or walk, moves a root's rows on the old
number to the new one in one `UPDATE` when only the number changed, logging
`File Index: <root> is on device <new> now, was <old>`; another volume UUID renumbers
nothing. A root is crawled instead when there is no stored ID (first launch: the
current ID is stored before anything is read), the fingerprint differs (a switch, a pattern,
or a skip list changed in an update), its volume UUID changed or is missing (history
replaced, or a volume FSEvents does not log), or its last crawl never finished — a rules
change that lets more in, or a Source switched off, forgets the root until it is read again.
In-session, `UserDropped`/`KernelDropped`/`EventIdsWrapped` crawl every root and
`MustScanSubDirs` re-reads that subtree (a whole root is a crawl). "Reading" on the Sources
page is a crawl or the contents backfill; a replay never shows it. `FileIndexSchema.version`
is 5: an index from any other version is dropped and read again, never migrated — and its
vectors come back from the vector cache (see Search by meaning), so a bump costs the
minutes of names and contents and no embedding.

**The File Index reads what files say** (the content layer; no ML). Every row gets a
`FileContent` at crawl time, judged from its name alone — screenshot, image, PDF, document,
text, audio, video, code, or nil (folders, archives, fonts). Image, audio and video have no
words (`hasWords`): they are "read" at once, and only the meaning pass looks at them.
The extension is a fast path, never a gate: any file not on `FileContent.binaryExtensions`
is `.code` and read **if it sniffs as text** (a UTF-16 BOM, or a first 8 KB that is valid
UTF-8 with no NUL), so `.tsx`, `.svelte`, dotfiles and extensionless files are read and a
binary is marked `detail = 'not text'`. `.ts` sniffs (UTType calls it MPEG-2). Formats,
system frameworks only (`FileContentReader`): text/code by sniff (`.txt`-like notes also as
Windows-1252); PDF via PDFKit, a Passage per page with ≥ 200 characters, the page number as
its location, sparser pages skipped (the meaning pass embeds their picture); rtf, rtfd,
doc, docx, odt via `NSAttributedString` (never HTML: its importer is WebKit, main-thread
only); html/htm/xhtml by stripping tags; webarchive via its plist; eml/emlx via a small MIME
reader (Subject/From/To/Cc/Date and the text/plain part); xlsx (shared strings), pptx
(slides in order), ods/odp (content.xml) and epub (its XHTML) through `ZipArchive`, a
central-directory reader over Compression's raw DEFLATE; Pages/Keynote/Numbers only through
the `QuickLook/Preview.pdf` they may carry, otherwise `detail = 'no preview'`. Screenshots
(the `kMDItemIsScreenCapture` xattr, a "Screenshot"/"Skærmbillede"/CleanShot name, or a
Screenshots folder) go through `OCR.text(in:)` — the same accurate, language-detecting,
language-correcting Vision request as the OCR Action, Danish included — keyword-only.

Text is cut by `FileChunker`: ~1,800 characters, 200 overlapping, at whitespace, each a
`chunk` segment located by its UTF-16 offset; OCR text is `ocr` segments with no location.
Runs of 120+ base64-ish characters are dropped. A Passage's words are in the `passages` FTS
table (rowid = `segments.id`); `segments.vec_key` is the meaning pass's, its vector's key in the
vector cache. A file is
read a step at a time (`files.state` pending → partial → done, `read_to` counting pages or
chunks): the first 40 with the first pass, the rest 400 at a time after every file's first
step, never past 5,000, nor past 10 MB of a note or 1 MB of code or a sniffed file (past
that it is a program's output); `detail` says why something was cut or skipped. On the dev
machine the three default Sources come to ~310k Passages and a **793 MB** database (names
alone: 22 MB), with Ignored by git on; off, ~1.0M Passages and 2.5 GB, two thirds of it from
gitignored `.json` (see Skip). A size or date change (`FileIndexWriter.update`) deletes the Passages and reads
again; a move keeps them; a Source-only change keeps them; deletes take them (FK cascade on
`segments`, explicit on `passages`).

**Scheduling** (`FileContentScheduler`, on the File Index queue). It starts once a crawl's
names are in, takes batches of 8 from `FileIndexWriter.contentJobs` — every file's first step
before anyone's later steps, then by `FileContent` order (screenshots, PDFs, documents, text,
code last), newest first — reads them at background QoS off the queue (`Task.detached`), and
stores the results back on the queue, dropping any whose file changed meanwhile; each store
starts the next batch, so nothing is timed. Files an FSEvents batch added or changed
(`FileIndexer.handle` returns them) go first, the newest 50 of a burst. Low Power Mode
(`isLowPowerModeEnabled` and `NSProcessInfoPowerStateDidChange`) pauses the backfill and
never the changed files. Progress is the database, so a restart carries on. The reader
(`FileContentReader.read`) is a `FileContentJob` in and a `FileContentResult` out, so it can
move to the helper process.

**Search** (`FileIndexReader.search`) runs the names query as before and a passages query
with the same expression, best bm25 Passage per file (a bare column beside `MIN()`), capped
at `rankingCap` like names. One row per file. Names score on `fuzzyScore` (0–~110); a
content-only hit scores `FileHit.contentScore` (120) plus its rank, below every name match
and above `folderOnlyScore` (200) — DigUp's 3:1 name weight, by band, since two FTS tables
share no bm25. A file that matched by name keeps no Passage. **Not every word is required**
(`requiredWords`): a folder word ("folder", "mappe": `MeaningRanking.folderWords`) never is,
and a function word ("for", "the", "af", "me", "mig"; not a Kind Word, not "file"/"fil") is
not unless it is the last on the keystroke, where it may be the start of a longer word ("for"
of "format"); with nothing else left, all are. In the settled pass a function word last is a
finished word, never a prefix, in names and Passages alike, so it is dropped like the others
("me" no longer finds "meeting"); alone, it is matched whole. A Kind Word is not required
there either, nor "file"/"fil" beside one: the Kind answers it ("pdf invoice" finds a receipt
PDF that never says "pdf"; "screenshot of error" a screenshot whose OCR says "error"), unless
nothing else is left ("image of me", "audio file") or a folder word makes it a word to find
in folder names ("video folder"). There a name the whole Query misses is scored on the
required words, `nameAfterFoldersPenalty` below (`Broken Invoice/invoice.pdf` for "pdf
invoice", whose folder had taken "invoice" and left the name only "pdf"), and the files of
the asked Kind, by name or by Passage, rank ahead of the rest before the cut to the limit, so
sixty notes that say "invoice" cannot push every PDF out. On the keystroke a folder word wins
a folder a tie and nothing more, and a Kind Word is required; the settled pass puts the
folders first (see The settled search). **A name the whole Query misses is scored on what its folders leave**:
"code data intensive systems" finds `Data Intensive Systems/code` at `fuzzyScore("code")` +
`nameAfterFoldersPenalty` (2), a name match, where it had sunk to 200 below 14 files that say
the words. The `FileHit.Passage` excerpt is
FTS5's `snippet()` (10 words, matches between U+0001/U+0002) fetched only for the hits
returned. **In Passages the last word is a prefix only in the settled pass**
(`PassageMatch`): on the keystroke (`FileIndex.search`, also Finder's Target list) Passages
match whole words; `searchSettled` makes the last word a prefix from 3 characters, unless a
space after it says it is finished. Passages have no prefix index, and a prefix merges the
posting list of every word that begins with it: 20–60 ms for "con", "type" or "202" over 1.02M
Passages before a row comes back (`a*` cost 860 ms). FTS5 also evaluates the expression again
for every `snippet()`, posting lists and all, so a prefix is spelled out first as the words of
that Passage that begin with it (`expandingPrefix`, `"faktura" AND ("husleje" OR
"huslejen")`). Before both, "the " cost 548 ms (23 rows × a 23 ms snippet) and "invoice 202"
3.5 s; after, on the same 60k-file / 1.02M-Passage index (2026-10-12, Debug, load average
~230 from other builds): every keystroke of eight typed Queries median 9.0 ms, p90 17 ms,
"the " 14 ms; the slowest single samples (50–146 ms) are each Query's first run, a cold page
cache. The settled pass, prefix included: median 12 ms, p90 59 ms, worst "invoice 202" 163 ms,
on a connection of its own so the keystroke never waits behind it. Measured by
`FileIndexKeystrokeTimingTests` and `FileContentTimingTests`
(`TEST_RUNNER_CODICLENS_TIME_FILE_CONTENTS=<runs>`, real Sources into a temp database).

### Search by meaning — the embedding runtime
EmbeddingGemma 2 (`google/embeddinggemma-2`, Apache 2.0) on llama.cpp with Metal: 768-d,
L2-normalized vectors, stored as float16 (`EmbeddingVector`). **Compute in bf16/fp32 only,
never fp16** — its activations overflow. Wired into the File Index and its settled search
(below), and the Panel calls both (see "What the Panel calls"). Adapted in parts
from DigUp (MIT, `digup-license.txt`); each such file says so in its first line.

- **Apple silicon only.** `MeaningSearch.isSupported` (arm64 and a Metal device) is the
  one gate; on Intel the feature is unavailable and nothing downloads.
- **`ModelFiles`** — ggml-org's Q8_0 GGUFs at one pinned Hugging Face revision: the text
  model (310 MB, all a Query needs) and the mmproj image + audio encoders (555 MB), into
  `~/Library/Application Support/codiclens/models/`, downloaded at launch while the
  feature is on (it is unless the user turned it off), never bundled. A file gets its real name only after its size and SHA-256
  match, so a file there is whole. Resumable (`<name>.resume` holds URLSession resume
  data), observable `state`: `notDownloaded` / `downloading(progress:)` / `verifying` /
  `ready` / `failed(reason)`. Tests inject a `ModelFileDownloader`.
- **`EmbeddingPrompt`** — the model card's prompts: `task: search result | query: …`,
  `task: code retrieval | query: …`, `title: {title or none} | text: …`. Media take none.
  **`ImageBudget`** — soft tokens per picture: photo 140, screenshot 280, PDF page 280,
  video frame 70.
- **`Embedder`** (arm64 only) — llama.cpp in-process, values in and out: texts (batched,
  up to 16 a `llama_process` call), a `CGImage` (decoded upright by `EmbeddingInput`,
  sized by `ImageSizing` as the reference's Pillow does) or 16 kHz mono samples (≤ 30 s;
  `EmbeddingInput.audio` decodes and resamples with AVFoundation). Text-only reserves a
  512-token context, full 2,048.
- **The helper** — the app binary relaunched as `codiclens --embedding-service
  [--text-only] [--models <dir>] [--idle-exit <s>]`. `AppDelegate` returns into
  `EmbeddingService.start()` before anything else, so it has no Panel, hotkeys, File
  Index or clipboard recorder. It loads the model, writes an `EmbeddingServiceHello`, then
  answers JSON lines (`EmbeddingServiceProtocol.swift`: `embedText`, `embedImage`,
  `embedAudio`, `hold`, `shutdown`; vectors as base64 float16; a vector request marked
  `fullSpeed` is answered with App Nap off) until shutdown, stdin EOF
  (the app went away) or its idle exit. Its stdout is the protocol's alone: fd 1 is
  pointed at stderr so nothing else that prints can corrupt a line.
- **`EmbeddingClient`** (actor) — starts the helper on first use, `hold()`s it while the
  Panel is open (the warm **query encoder**: text-only, ~0.25 GB), restarts it after a
  crash without re-asking the request that crashed it, re-sends what crossed a clean idle
  exit, and gives up after three crashes in a row until the next `hold()`. The helper
  inherits only `HOME`, `PATH`, `TMPDIR` and a few more: XCTest's injection variables
  would make it run the test suite again inside itself.
- **Audio** — `EmbeddingInput.audio` reads with `AVAudioFile` and falls back to an
  `AVAssetReader` on the first sound track (`soundtrack`) for what it will not open. On
  macOS 26 `AVAudioFile` does open a `.mov`'s and an `.mp4`'s soundtrack; the fallback is
  for containers it does not. The helper refuses a silent window (RMS below 0.003, about
  −50 dBFS: `EmbeddingError.silent`).

**The meaning pass** (`MeaningScheduler`, on the File Index queue beside the contents pass,
the same shape). Everything with a `FileContent` gets vectors, in the helper (the full model,
~1 GB while it works, gone after its 60 s idle exit; `.utility` QoS):
- **Text**: every Passage the contents pass read (`chunk`, `page`; code, notes, documents,
  PDFs), with the card's document prompt and the file's name as title, cut at 4,000
  characters. Text that is mostly digits gets no vector (keyword search has it). OCR text
  stays keyword-only. **Data and logs get vectors for their first 40 chunks only**
  (`FileContent.isDataOrLog`, beside the other `FileContent` rules: `.json`, `.jsonl`,
  `.ndjson`, `.geojson`, `.csv`, `.tsv`, `.log`, `.err`, `.out`, and a `.txt` in a folder named
  `log`/`logs` at any depth or named `*.log.txt`/`log_*`). Every Passage of theirs is still read
  and found by its words; the rest are simply never handed to the meaning pass: the first step
  stores the file `done`, a later contents step does not flip it back to `partial`, and one left
  `partial` by an older build is finished by an empty step, keeping the later vectors it has.
  They have no vectors, so nothing of the scale counts them. On the dev machine's index
  (2026-10-12, read-only) this took **144,554** of the 217,414 text vectors still waiting off
  the queue (151,827 Passages; the rest mostly digits): `.json` 77,939, `.jsonl` 48,347, `.csv`
  7,833, `.err` 6,694, `.txt` logs 3,687.
- **Pictures** (`image` segments): a screenshot at 280 soft tokens, from the picture, as
  DigUp does; a photo at 140 if its shorter side is at least 256 px (icons and badges are
  not, `detail = 'too small to embed'`).
- **A PDF page under 200 characters** (no Passage) is drawn at 1,400 px and embedded as a
  picture at 280 (`page_image`, located by its page).
- **Recordings**: 30 s windows every 25 s (`audio`, `loc`…`loc_end` in seconds); the tail
  only if it adds 2 s past the window before; silence refused. **Videos**: a frame every 3 s
  (at most 1,200 in all) at 70 tokens, one per shot — a frame within 4 bits of the kept
  one's 8×8 average hash only stretches it — each standing until the next (`frame`); and
  the soundtrack as a recording. Its start is how the Card shows "at 14:02" (and a video's
  frame there), and where the Passage Preview and QuickTime play from.
- **Long files go a step at a time**, like the contents pass: first 30 pages / 40 chunks /
  10 minutes, then 100 pages / 200 chunks / 30 minutes per step after every file's first
  (data and logs: the first step only).
  First-step vectors set each Query's scale; later ones (`segments.later`) are scored on it.
- **Order**: changed files first (FSEvents, the newest 50 of a burst; a text file as soon as
  the contents pass has read it), then the backfill, every file's first step before any
  later one, by `FileContent` — screenshots, photos, PDFs, documents, notes, recordings,
  videos, code last — newest first. A PDF, a recording or a video goes alone; pictures and
  text go 8 or 32 to a batch by the pace (below), and **a batch's texts go to the helper
  together** (`MeaningReader.read(_:with:cache:)`, into the cache, where each file then finds
  them; requests of up to 64): half the waiting files are one chunk, and a request a file left
  each model call a third full. A helper crash on them together has each file ask again alone,
  so only the one at fault gives up.
- **Pace** (`MeaningPace`), decided as each batch starts — nothing polls, so a change takes
  effect at the next batch: **full** on AC power (`IOPSGetProvidingPowerSourceType`) with no
  input for 2 minutes (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, any)`)
  and the Panel closed: 32 files a batch, the batch's Task at `.utility`, App Nap off in the
  app while it is out and in the helper while it answers (`ProcessInfo.beginActivity
  (.userInitiatedAllowingIdleSystemSleep)`, per batch and per request: the Mac and its display
  still sleep as the user set them, and the work stops with them). **Gentle** otherwise —
  battery, the user at the Mac, the Panel open — 8 files a batch at `.background`, App Nap
  allowed. **Low Power Mode pauses the backfill**, never the changed files. The Panel opening
  (`holdQueryEncoder`) also takes the helper off full speed at once, for the rest of a batch
  that is out; the query encoder is a helper of its own, so a Query never queues behind the
  backfill's requests, only shares the GPU with them.
  Measured on the dev machine (2026-10-12, M4 Max, Debug, `MeaningThroughputTests`, **with the
  installed app's own backfill on the same GPU throughout**, so absolute rates are about half):
  texts of 1,700 characters 14 a second one a call, 17–19 at 4–64 (the 2,048-token model call is
  full at 3–4 of them); texts of 700 characters 22 one a call, 35–51 at 4–64. Files per batch on
  the backlog-shaped mix, texts sent together: 1 → 18.4, 8 → 19.0, 16 → 19.2, 32 → 19.7, 64 →
  19.3 vectors a second — the mix is mostly long chunks, which fill a call on their own; the gain
  is the one-chunk files. Gentle against full through the real loop, six 45–60 s runs: gentle
  18.4–19.4, full 17.5–21.3 — no difference beyond the noise here: the test host is not napped
  and the GPU is the limit. What full turns off (App Nap, background priority) is what the
  installed app meets while hidden, which a test cannot reproduce. A warm Query took 24 ms
  (median) with only the installed app's backfill running and 61–73 ms with this one beside it,
  at either pace: gentle does not give the GPU back.
  Progress is `files.vec_state` (pending → partial → done) and `vec_to` (pages, chunks or
  seconds), so a restart carries on. A file waits until the contents pass has read its
  first step (`state != 'pending'`); a later contents step flips a finished file back to
  `partial`. A helper crash on a file gives that file up (`detail`), a helper that will not
  start stops the pass until the switch is thrown again.
- **Fingerprint**: `meta.meaning` = `MeaningPass.fingerprint` (model revision, prompts,
  budgets, windows, steps). Any other one drops every vector and embeds everything again —
  through the vector cache, so only inputs whose key the change touched reach the helper.

**The vector cache** (`VectorCache`, `VectorCache.sqlite` beside the index; ADR 0013) is where
the vectors live: one table, a 16-byte key to 768 float16s, `used` (each key's last day of
use), and `meta`. A key is 16 bytes of
SHA-256 over `VectorCache.fingerprint` and exactly what was embedded: a text's whole prompt,
title included; a photo or screenshot as its file's SHA-256 and budget; a PDF page drawn as a
picture as the file, the page, the 1,400 px and the budget; a video frame as the file, its
stored start and every setting that decides which frame lands there; a window of sound as the
file and its start and end. `MeaningReader` keys every input first (`JobVectors`): hits never
reach the helper, misses are embedded and kept once the step is done (a batch's texts, asked
for together, at once) — what came from a file only if the file still has the size and date
it was hashed at. The same input in two files,
a copy, a move to another Source, is embedded once. The index keeps `vec_key`, never the
vector, and `meta.vector_cache` = `VectorCache.id`: a cache emptied or deleted since makes
`enable()` drop the index's vectors and embed again. Cleared only when
`VectorCache.fingerprint` (model revision, prompt scheme, `inputs` — bump it for any change to
how the helper prepares a picture or a recording) changes, and by "Remove Model and
Vectors…". Its own `version` (2), trivial: version 1, from before `used`, is brought over in
place with every entry used on the upgrade's day; any other is dropped.
**Pruning**: an edit leaves the chunks after it behind, a removed Source its vectors, so the
cache would only grow. An entry is used when it is written, found (`vectors(for:)`, the
meaning pass and the vector files' rebuild) or referenced by the index; `used.day` is days
since 1970 (UTC), written only when it is not already today, in one transaction per call,
in a table of its own so a stamp rewrites small rows and not vector pages. Once a day
(`NSBackgroundActivityScheduler.vectorCachePrune()`: 24 h, 12 h tolerance, background QoS,
repeating; the system holds it back on battery, heat or load; started by `FileIndex.start()`,
so never in the test host) `Worker.pruneVectorCache` runs `VectorCache.pruneIfCaughtUp` on the
File Index's queue: deferred (`.deferred`, the system tries again later) until the Sources
are applied, every file in them has its contents read and its vectors made
(`FileIndexWriter.isCaughtUp`), and the index was not made this session (`isNew`: a schema
bump or a deleted database is being read again to find its vectors in the cache). Then every
key the index references is stamped today, every entry unused for more than
`VectorCache.unusedDays` (30) goes, and `meta.pruned` keeps it to once a day. `VACUUM` (and a
`TRUNCATE` checkpoint, or the rewrite stays in the WAL) runs once the entries pruned since
the last one come to a tenth of those left: entries die one here and one there, so
`incremental_vacuum` gets back only the pages freed whole (40% of 14k scattered rows freed
240 of ~1,140 pages' worth). Logged: entries removed and left, MB on disk before and after.
**Seeding**: an index of schema 4 kept its vectors in `segments.vec`; `FileIndexWriter`
hands them to the cache before dropping it (`VectorCache.seed(fromIndex:)`), under today's
`MeaningPass.fingerprint` only. Text keys come from the stored Passages and name; media keys
hash the file now, if it still has the size and date it had, else it is left to embed again
(`stale`). The one inexact case: a file renamed after it was embedded kept its vectors, so
they land under the new name's title. On the dev machine's index (2026-10-12, 10,324
vectors): all seeded in 2.8 s, none stale, 9,642 distinct inputs.

**The vectors a search scores** (`MeaningVectors`): `FileIndex.vectors` (768 float16s a row,
back to back) and `FileIndex.vector-rows` (24 bytes a row: segment, file, modality, sets the
scale), beside the database and appended to as each batch commits — **never reloaded whole**,
and derived: rebuilt from `segments.vec_key` and the cache whenever they do not match.
A search maps the vectors file read-only (clean file pages: the system takes them back
under pressure, nothing dirty sits in the app) and scores every row, 1,024 rows at a time
converted to float32 and `vDSP_mmul`'d, split across the cores. `segments.vec_key` and the
cache stay the truth: `meta.vector_rows` counts what the files should hold, and a mismatch at
`enable()` (a crash between commit and append) rebuilds them from the two (100k keys looked up
in 0.47 s, Debug). A changed or deleted file's
rows are marked removed in place (`FileIndexWriter.onVectorsRemoved`); a quarter removed
rebuilds; removals while the files are closed set `vector_rows` to −1, so the next `enable()`
rebuilds. Turning search by meaning off unmaps them and keeps both files.

**The settled search** (`FileIndex.searchSettled`, on its own reader connection) embeds the
Query with the warm text-only query encoder, scores every vector, and fuses
(`FileIndexReader.fusedSearch`, `MeaningRanking`, DigUp's, which beat reciprocal-rank fusion
on its evals):
- each cosine minus its modality's (text/image/audio) average, in the pooled standard
  deviation of all of them (floor 0.02); a modality with under 20 rows takes the overall
  average; later steps' rows are scored but left out of the averages and the deviation;
- a file is a candidate if its best segment reaches z ≥ 2.0, or it has ≥ 50% of the Query's
  words (stopwords, Kind Words and folder words out, English and Danish) in its Passages, name
  or folders (the folders only beside a word of its own, so a folder-only match stays at 200) —
  the word search's own content hits have all of them; an any-word query brings 100 more;
- score `max(z, 0) + 2 × coverage^1.5`, +1 when a Kind Word or a Kind Hint names the file's
  Kind (`liftedKinds`); a **lookup** (every word an ID or number: `K7Q2LM`, `#1234`) weighs
  meaning 0.5 and words 4.
- **A Kind Word puts its Kind first** (`GLOSSARY.md`; `MeaningRanking.kindWords`), in any
  Query, English and Danish: video(s)/videoen/videoer; photo, picture, image, billede, foto
  and their forms ask for photos **and** screenshots, screenshot/skærmbillede for screenshots
  alone; pdf(s); recording, optagelse, audio, lyd, lydfil, podcast and their forms. Two of
  them share one block. The block is the Kind's name matches, then the rest of the Kind: with
  a topic ("video of me speaking", "billede af kontrakten") every candidate of the Kind by the
  fused score — every file of it over the gate (`MeaningScores.gated`), not only those among
  the best 200 of every Kind (`meaningCandidates`), which kept 3 of the 36 pictures over the
  gate for "image of me" — filled up to `kindGuesses` (10) with the Kind's best z below the
  gate, each scored with its words like any member: a Kind Word is a request even when nothing
  stands out, and a text with every word of the Query outscored the best video (row 16 for
  "video of me speaking"); the rest of the Kind is no candidate. With a topic only a name
  match on a word of the topic leads the block; one on the Kind Word alone (`image001.png`
  for "image of me") takes its place in it by its score and leaves the ten to the rest.
  Picking the Kind out of the gated files and its best z per file cost 0.3 ms and 1.3 ms
  (Debug, 187k vectors of noise, 3,976 files gated, 3,117 of the Kind;
  `TEST_RUNNER_CODICLENS_TIME_MEANING_SCALE`). A **kind-only Query** (a Kind Word and nothing but "file"/"fil" and determiners:
  "videos", "my videos", "video file", "billeder"; `isKindOnly`) means nothing beyond the
  Kind, and per-modality centring gives "audio-ness" nothing, so none of 91 recordings came in
  for "audio file": its rest is the Kind's newest in the enabled Sources, packaged documents
  included, the block at most `kindOnlyFiles` (25). "image of me" and "video af mig der
  taler" have a topic.
- **A folder word with something else to look for** ("code folder for data intensive
  systems", "video folder"; `asksForFolders`) makes the folders whose name or path match the
  rest the block, by their words alone (folders have no vectors), and no Kind Word beside it
  puts its Kind first. A folder found by its path only joins the block where no folder in it
  is above it (`FileIndexReader.leadingFolders`): `koffeelab-video/src` and ~45 like it had
  filled all 50 rows of "video folder". "folder" alone does nothing.
- **A Kind Hint** (document, note, notat, paper, clip, klip, movie, film, song, sang, music,
  musik, sound, voice, stemme and their forms; `kindHints`) is a word of the Query and only
  lifts its Kind by the +1: "release notes" is not a request for notes.
- **Where it lands** on `fuzzyScore`'s scale: the Kind block at `kindScore + rank` (−100 and
  up, below zero), above every name match of another Kind and every Clipboard Item and Emoji;
  a name match keeps its 0–~110 and no Passage; every other candidate — words, meaning or both
  — is ordered by the fused score into `contentScore + rank` (120…199), the band content
  matches had; a folder-only match that is no candidate keeps 200. So the list below the apps
  is the asked Kind's name matches, the rest of the Kind, name matches of other Kinds, then
  everything else.
- A hit found by meaning carries `FileHit.meaning` (text, image, audio) and points at its
  best segment: the start of its text, its page, or its span in seconds (`Passage.start`,
  `end`; `subtitle` "at 14:02"); a picture found whole has no Passage, or borrows its OCR
  words. **Where the Query's words matched it keeps that Passage**, marks and all, so the
  row, the Card and the preview can mark them: pointing it at meaning's segment instead
  left nearly every File Result unmarked once typing paused. Without meaning on, or before any
  vector, the settled search is the word search with the prefix and the Kind block where it
  can be had without vectors: the Kind's name matches, files of it the words found, a kind-only
  Query's newest and the folders; there are no best guesses.
- It is cancellable: a cancelled Task, or a newer call started while it waited for the
  vector, returns `[]`.

**What the Panel calls**: the settled pass of the list below the apps asks
`FileIndex.shared.settledSearcher` (`@Sendable (String) async -> [FileHit]`,
`searchSettled(query)`, limit 50), handed to `CommandCoordinator` as `searchSettled` beside
the keystroke's `searchFiles` (a test's `CommandCoordinator.isolated` asks `searchFiles` again
unless given one), and puts the answer through `SourceSearch` (see SubjectSearchVM);
`PanelController` holds the query encoder while the Panel is up (`QueryEncoderHold`). A hit's
`Passage.start` becomes `SubjectPassage.seconds`, so a recording or a video found at a moment
shows it on the Card, plays from it in the Passage Preview and opens there in QuickTime.

**Settings**: Sources → "Search by meaning" (`MeaningSettings`, drawn from
`SourcesPage.meaningRow`): one switch, **on unless the user turns it off**: on Apple silicon a
fresh install downloads the model at launch (`FileIndex.start()` → `MeaningSettings.start()`,
never in the test host) and then reads every file, with nobody touching Settings. On downloads
the model (progress from `ModelFiles.state`), then starts the pass; a status line ("Downloading the
model, 42%", "Reading 1,234 of 5,678 files", "Paused in Low Power Mode, …", "Ready, …",
"Needs a Mac with Apple silicon") and the files-read counts; off stops embedding and frees
the vectors, keeping model and vectors on disk; "Remove Model and Vectors…" (one
confirmation) deletes both, the vector cache's entries included. Kept in `UserDefaults` (`codiclens.meaning.enabled`, missing =
on, so only the user's own off is written down); a test's File Index has the switch off
(`MeaningSettings.Switch.off`) and every test's `ModelFiles` downloads through a stub.

**The ship gate**: ≥ 80% top-5 on the user's real Danish and English Queries.
`TEST_RUNNER_CODICLENS_MEANING_EVAL=1` reads `~/Library/Application Support/codiclens/eval/eval.json`
(`[{"query", "expected": [paths], "language"?}]`, written by the user, never by a test), runs
the full settled search against the app's real index and vectors with the real query
encoder, and prints the top-5 rate overall, per language (given, or guessed Danish/English)
and per kind of expected file, the word search's rate beside it, and every miss with what
came instead (`MeaningEvalTests`). Without the file it is skipped and says so.

Measured on the dev machine (2026-10-12, Release, `MeaningTimingTests` with 45 s of each
kind, the three default Sources: 60k files, 776 MB before vectors; load average ~200 from
other builds, so rates are pessimistic): per vector a screenshot 0.61 s (decoding a Retina
PNG at 280 tokens), a photo 0.14 s, a PDF 66 ms (text pages and page pictures), a document
or note 21–32 ms, code 32 ms (≈ 30 Passages a second), a 30 s window of sound 0.17 s, a
video 98 ms a frame or window. What was left after that came to **≈ 3.1 h** of backfill, 2.2 h
of it the 246k Passages of code. A vector took 1.9 KB of database while it was in
`segments.vec`; in the cache it is 1.67 KB (8 KB pages; 2.08 KB on 4 KB ones), plus a 16-byte
key in the index and 1.56 KB in the vector files, so ~300k vectors add ~0.5 GB to the cache
and ~0.47 GB to the vector files. On the dev machine's index with 10,324 vectors: 807.8 MB
before (index and vector files), 803.8 MB after (index, cache and vector files); keeping
`segments.vec` beside the cache would have been 823 MB. A Query: its vector 5–8 ms warm;
cosine over **300k** vectors 5.2 ms, with the scale and each file's best 6.8 ms (172 ms before the scale
was masks and `vDSP`; Debug 39 ms); the fusion's SQL 3–23 ms (most for several common words:
"how to retry with backoff"). The real-model test finds all six of its files first.

## Data Flow: Paste

```
User selects clipboard item → Enter
  → CommandCoordinator.submit()
  → pasteClipboardItem(): writes to NSPasteboard.general
  → onPasteAndHide callback
  → PanelController.pasteAndHide():
      1. Hide the Panel (orderOut, no animation)
      2. If codiclens stole activation (Quick Look was used):
         - Activate previousApp
         - Wait for didActivateApplicationNotification (event-driven)
         - Then fire simulateAction
      3. Else: fire simulateAction immediately
  → simulatePaste(): CGEvent Cmd+V to cgSessionEventTap
```

## Data Flow: App Launch

```
User types query → Enter
  → CommandCoordinator.submit()
  → onHide callback (panel hides FIRST)
  → executeDefaultAction(): openAsync(url)
      → Task { NSWorkspace.shared.open(url, configuration:) }
```

## Key Files

| File | Role |
|------|------|
| `codiclensApp.swift` | @main entry, AppDelegate adaptor |
| `AppDelegate.swift` | Hotkey registration, QLPreviewPanel responder, Open With (`application(_:open:)`) and the Service's registration, and `isTestHost`: the test host starts nothing |
| `Incoming.swift` | How an Incoming Subject gets in: `Incoming` read off a Service's pasteboard, `IncomingService` (the "Open in Codiclens" provider), and `LastActiveApp`, the app it came from |
| `Setup.swift` | Setup's model: its rows (`SetupRow`: Shortcuts, Paste, Open at login; Folders and Meaning slot in), Done, and when it shows (launch, reopen until Done) |
| `SetupView.swift` / `SetupWindow.swift` | Setup's window, and `SetupController`, which wires it to the real Mac for Setup and Settings → General |
| `SystemShortcuts.swift` | `ShortcutTakeover`: ⌘Space and ⌃⌘Space through the private symbolic hotkey call (ADR 0016), behind `SymbolicHotKeys` |
| `LoginItem.swift` / `AccessibilityAccess.swift` | Open at login (`SMAppService.mainApp`) and the Accessibility grant, each behind a protocol so `SetupTests` runs over fakes |
| `MoveToApplications.swift` | The launch alert that moves a copy outside /Applications there (Release only) |
| `codiclens-Info.plist` | Merged into the generated Info.plist: the Open With document types and the Service |
| `PanelController.swift` | The one window: show/hide, focus lifecycle, observers, hit test |
| `PanelView.swift` | The SwiftUI content of the Panel: Card row, gap, Results Slab |
| `PanelLayout.swift` | The Panel's fixed geometry, the margin, and `PanelHitRegions` |
| `FocusHandoff.swift` | Who had activation, and how it is given back |
| `QueryEncoderHold.swift` | Search by meaning's query encoder held while the Panel is up |
| `ControlKey.swift` | Folding a Control-modified key press onto its letter |
| `KeyHintChip.swift` | The keyboard hint in a Card's bottom-trailing corner |
| `CommandCoordinator.swift` | State machine, execution, paste simulation |
| `FloatingPanel.swift` | Non-activating NSPanel subclass |
| `CardContainerView.swift` | Hidden TextField keyboard capture |
| `SubjectSearchVM.swift` | Subject search: apps on the keystroke, the live list below them and its settled pass, and when "No results" is true |
| `SourceSearch.swift` | Ranking the list below the apps: File Results, Clipboard Items and Emoji on one scale, off the main actor |
| `ActionSearchVM.swift` | Context-sensitive action loading |
| `TargetSearchVM.swift` | Target list state; owns and cancels the file search |
| `FileTargetSearch.swift` | One cancellable Finder file search: File Index first, then `mdfind` lookups, ranking, icons |
| `Thumbnails.swift` | Quick Look thumbnails for files, a PDF page or a video frame for a Passage: async, cached per file version, sized to cover a Card, `ThumbnailReader`, the one view that asks, and `ThumbnailImage`, the icon-then-thumbnail view |
| `ClipboardHistory.swift` / `PasteboardWatcher.swift` | Clipboard storage, and the pasteboard poller that feeds it |
| `ClipboardSearchVM.swift` | Clipboard search/filter |
| `QuickLookHelper.swift` | QLPreviewPanel data source/delegate, and the `.txt` copy of text Quick Look cannot draw |
| `SubjectPassage.swift` | A File Result's Passage as it travels with the Subject, which files get the Panel's own preview (`PassagePreview`), and finding the Passage again in the file (`PassageFind`) |
| `PassagePreviewView.swift` | The Panel's own preview: PDF, text and player views, and the driver the hidden field's keys reach them through |
| `QuickTime.swift` | Opening a recording in QuickTime Player at a moment, by `osascript` |
| `Subject.swift` | Subject model (app/file/folder/text/builtIn) |
| `PathSubject.swift` | A Query beginning `/` or `~`, and the one URL→Subject resolver |
| `OCR.swift` | The whole of the app's Vision use: URL → OCR Text, for the OCR Action and for screenshots in the File Index |
| `ImageActions.swift` | QR PNG generation and atomic, orientation-normalizing image rotation |
| `EffectRunner.swift` | Executes system Effects; serializes image and file jobs and returns their answers |
| `FileOperation.swift` | Move, copy, rename and compress on disk: Finder's `name 2.ext` numbering, never overwriting |
| `Transcription.swift` | Finding Codictate's `codictate` client and checking its contract (`status --json`), running one cancellable `transcribe --json`, reading its NDJSON events |
| `SubjectAction.swift` | Action model, text transforms, action handlers |
| `FuzzyMatch.swift` | Fuzzy scoring (exact/prefix/substring/subsequence/levenshtein) |
| `Emoji.swift` | Emoji model, SkinTone, default-tone preference, glyph→NSImage rendering |
| `EmojiIndex.swift` | Bundled emoji dataset: lookup, grouping, skin-tone variants |
| `EmojiSearchVM.swift` | Emoji ranking, grid sections, grid keyboard model |
| `EmojiRecentsStore.swift` | Emoji Recents persistence (Application Support) |
| `EmojiGridView.swift` | Results Slab in grid Mode |
| `Style.swift` | Every radius, material and tint, including the Card's glass shape and the Emphasis constants. The only `colorScheme` branch, and Cards do not use it |
| `Motion.swift` | The three transition curves, the Loading Ring's spin, the Reduce Motion read, entrance/shake/hardCut |
| `LoadingRing.swift` | The app's own spinner, in place of a system `ProgressView` |
| `AppIndex.swift` | The app Index: background scan, atomic swap, lazy icons |
| `AppDirectoryWatcher.swift` | FSEvents watch over the application directories |
| `Source.swift` | `Source` and `SourceStore`: the Sources, their switches and the folder list, in `UserDefaults` |
| `FileIndex.swift` | The File Index: started at launch, `search` on the keystroke and `searchSettled` (words and meaning) from any thread, counts and reading state for Settings, Low Power Mode, search by meaning's wiring |
| `FileIndexStore.swift` | The File Index's SQLite schema, writer (incl. the `meta` catch-up bookkeeping and content jobs) and thread-safe reader (`FileHit`, its Passage, `fusedSearch`) |
| `FileContent.swift` | What a file has to read (`FileContent`, in reading order), chunking, and the job/result values |
| `FileContentReader.swift` | Reading a file's Passages: text sniffing, PDF, documents, mail, zip, OCR — value in, value out |
| `FileContentScheduler.swift` | The contents pass: changed files first, then the backfill, paused in Low Power Mode |
| `FileIndexer.swift` | Crawling a folder Source, applying FSEvents changes, and deciding at launch which roots a replay covers |
| `FileIndexWatcher.swift` | FSEvents watch over the folder Sources |
| `FileIndexRules.swift` | What the File Index leaves out, in one place for the crawl and FSEvents: the skip groups and patterns |
| `GitIgnored.swift` | Asking git what it ignores in the repos inside the Sources, for "Ignored by git" |
| `SQLite.swift` | A thin SQLite connection and statement wrapper |
| `SourcesPage.swift` | The Sources page's rows (switch, counts, reading state), its add/remove/switch controls, and the Skip switches and patterns |
| `SourcesSettingsView.swift` | The Sources tab in Settings, drawn from `SourcesPage` |
| `MeaningSearch.swift` | `isSupported`, and `MeaningRanking`: the per-modality scale, the gates, the fusion (from DigUp), the Query's words, Kind Words, Kind Hints and folder words |
| `MeaningSettings.swift` | Search by meaning's switch (on by default): download, then the pass; its status line |
| `MeaningJobs.swift` | `MeaningPass` (steps, fingerprint), job and result values, and the writer's side: jobs, storing vectors, the fingerprint |
| `MeaningReader.swift` | One step of a file to vectors: text, pictures, PDF pages as pictures, windows of sound, video frames; the cache first (`JobVectors`); a batch's texts together |
| `MeaningScheduler.swift` | The meaning pass: changed files first, then the backfill, at the pace decided per batch |
| `MeaningPace.swift` | How hard the backfill works: full on power with the user away, gentle otherwise, paused in Low Power Mode |
| `MeaningVectors.swift` | The vector files beside the database, appended to, mapped and scored; derived from the cache |
| `VectorCache.swift` | The vector cache: content-addressed keys per input, `VectorCache.sqlite`, last-used days and the daily prune, seeding from a schema-4 index, `FileDigest` |
| `ModelFiles.swift` | The pinned EmbeddingGemma 2 GGUFs: resumable download, SHA-256 check, observable state |
| `EmbeddingVector.swift` | Normalize, cosine, float16 storage; the model card's prompts; `ImageBudget` |
| `EmbeddingInput.swift` | Image files to upright RGB, recordings to 16 kHz mono windows; `EmbeddingError` |
| `ImageSizing.swift` | The reference's image sizing and Pillow bicubic resize (from DigUp) |
| `Embedder.swift` | `EmbeddingBackend`, and EmbeddingGemma 2 on llama.cpp (arm64 only) |
| `EmbeddingServiceProtocol.swift` | The helper's JSON lines: requests, responses, the hello |
| `EmbeddingService.swift` | The helper process (`--embedding-service`) and its request loop with the idle exit |
| `EmbeddingClient.swift` | Starting, holding and restarting the helper, from the app |

## Known issues

Real, unfixed, none urgent.

- **"Opened from the start" is barely seen.** When QuickTime refuses, the file opens the
  ordinary way, and that app coming forward dismisses the Panel the note is on. The
  user is not told why the moment was lost, nor that the switch is in Privacy &
  Security → Automation.

- **A one-letter Target search is still slow, and it is Spotlight.** `mdfind -name a
  -onlyin ~/Documents/` takes ~7s to return its *first* batch on the dev machine
  (Downloads ~0.7s, system-wide ~2.4s), so the line cap cannot help. The File Index
  now answers for the folder Sources first, so the list has rows at once and only
  the files outside the Sources wait for it; "Searching…" stays up until it lands.
  Cancellation means it only costs anything if the user stops typing at one letter.

- **A Subject Card outside a Query Phase shows `selectedSubject`, not
  `subjectVM.cardSubject`.** `SubjectCardView.isQueryPhase` is the
  switch. The two values are only the same while the Query is still the question
  being asked; once a Subject has been *chosen* they diverge, and reading the
  results is how "Use as Subject" left Finder on the Card after promoting a file
  out of it. `retargetedText` solved the same bug for OCR Text and a transform's
  output and was `.text`-only, so a promoted file fell straight through it. The
  name is marked up against the Query only in a Query Phase, for the same reason:
  a chosen Subject's name is not what the Query matched.
- `SubjectCardView.textSubjectEditor` (and the rename field) takes focus from a
  `.task` that yields once first. `.task` alone came up unfocused under a real ⌘E:
  its body started before the text view was in the window, and the assignment was
  dropped (2026-10-18). A synthesised `NSEvent` through `NSApp.sendEvent` never
  shows this; only a posted `CGEvent` does, so test focus with one. Ordering, not a
  delay — but still the weakest link in the focus story.
- `Motion.resizeDuration` and `Motion.resizeTimingFunction` are unused. They are the
  AppKit spelling of `resize`, kept for the next time something animates a window
  frame; nothing does now that the Panel never resizes.
- **Ranking the whole emoji dataset is the remaining per-keystroke cost.**
  `EmojiSearchVM.rank` runs `fuzzyScore` over 1,914 names and ~15,000 keywords on the
  main thread. Measured on this dataset: **26–52 ms per keystroke unoptimised, 6–10 ms
  optimised** (it was 2× worse before `fuzzyScore` learned to reject on the length
  difference before building the Levenshtein matrix). Debug builds feel it; Release
  does not. The next move, if it is ever needed, is to stop allocating a `lowercased()`
  pair per call — the dataset is already lowercase — or to move ranking off the main
  thread. Do not "optimise" it by loosening the scoring: `FuzzyMatchTests` pins the
  tiers, and app search shares the function.
- **`glassEffect` does not rasterise deterministically under `ImageRenderer` in
  Debug.** Two renders of the same Card differ by up to Δ36 on most pixels, a dither;
  in Release the same pair is bit-identical. Any future pixel test has to average
  several renders (six brings the residual under Δ5) or run in Release.
  **As of 2026-10-12 it does not rasterise at all there:** any view carrying
  `.glassEffect` comes back fully transparent from `ImageRenderer` in the test host,
  content included. `SubjectCardPictureTests` renders through an unshown
  `NSHostingView` and `cacheDisplay` instead, which draws the content layer
  deterministically and leaves the glass material out. A whole `PanelView` comes back
  empty that way too: the entrance's `.blur`, even at radius 0, and the Slab's
  `.shadow` each leave nothing of what is under them, so `SubjectCardHoldTests`
  lays the Card row and the Slab's list out without either.
- **Release-configuration tests fail and have nothing to do with the Panel.** Run
  with `-configuration Release SWIFT_ENABLE_TESTABILITY=YES` (Release lacks
  testability, so `@testable import` will not resolve without it), the
  `PasteboardWatcherTests` cases in `ClipboardHistoryTests.swift` abort the test
  host, which marks every suite scheduled after them failed at 0.000s. Every suite
  passes when run on its own, and the whole suite passes in Debug. The documented
  command is the Debug one.
- The Panel's runtime behaviour has not been verified on screen from this environment:
  screen recording is not granted, so no screenshot was possible, and Cmd+Space is
  taken by Spotlight so the hotkey could not be driven either. The geometry and the
  hit-test rule are covered by `PanelLayoutTests`; the show/hide *window* sequence is
  not covered by anything.

### Four deliberate exceptions to the no-timing-hacks rule

All are device, API or lifecycle constraints, not fixes. Do not "clean them up".

- `EmbeddingServiceLoop` arms a one-shot `DispatchSourceTimer` on its request queue
  after each answer — the embedding helper's **idle exit**. The next request cancels
  it; a `hold` (the Panel is open) disarms it. When it fires, nothing has asked for a
  vector in that long, so the helper exits and gives back its ~1 GB. It is a
  process's lifetime, not a wait for something to happen.

- `FocusHandoff.yield` arms a 0.5s `asyncAfter` as the deadline on
  `didActivateApplicationNotification`. The normal path is the notification, which
  cancels it. It exists because an OS notification may never arrive.
- `EffectRunner.keystrokeInterval` is a 10ms `usleep` between synthesised keystrokes,
  off the main thread. `CGEvent.post` has no delivery acknowledgement, and an unpaced
  burst outruns the receiving app's text input system, so characters go missing. It is
  the emulated device having a plausible key rate.
- `NSBackgroundActivityScheduler.vectorCachePrune()` runs the vector cache's prune about
  once a day (24 h, 12 h tolerance, background QoS). It is maintenance the system times
  around battery, heat and load, not a wait for anything: whether it may prune is decided
  by the index's state, and until it is caught up the run defers.
