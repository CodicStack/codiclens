# Handoff — emoji, app index, glass & motion

Branch: `feat/emoji-index-glass-motion` (5 commits ahead of `main`, tree clean, build green).

This is the state of a four-feature push: **emoji picker**, **app index refresh**, **better glass**, **animations**. Two of the four are done and committed. Two are not started. Everything below is either finished, specified, or explicitly flagged as broken — nothing is half-written.

---

## Where things actually stand

| Feature | State |
|---|---|
| App index refresh | **Done, committed, tested.** |
| Emoji picker | **Done, committed, tested** — but deliberately unstyled. |
| Better glass | **Not started.** Fully specified below. |
| Animations | **Not started.** Fully specified below. |
| Settings | **Done, committed** — the surface all of the above hangs off. |

### Commits

```
3388436  feat: rebuild Settings around the controls the new features need
601cbe2  feat: add an emoji picker
089313e  feat: refresh the app index when applications change on disk
972dfe0  docs: ADR for disabling the system emoji hotkey via private API
7443240  docs: add domain glossary and ADRs for the next four features
```

### Why the emoji grid looks bad

Because it was told to. The emoji agent's brief said: build a plain `LazyVGrid`, don't invest in appearance, don't create style constants — the glass/motion workstream replaces all of it. That was efficient and it was also a mistake in ordering: it left two workstreams of invisible plumbing and nothing to look at. **If picking this up fresh, do the glass and motion work first.**

---

## Read these before touching anything

- **`CONTEXT.md`** — the glossary. Non-negotiable vocabulary: **Panel** is the one real window; **Slab** is one of the two visually separate glass surfaces inside it; **Card** is a tile in the Card Slab; **Mode** is what the Results Slab is listing; **Index** is the in-memory app list.
- **`docs/adr/0001`–`0006`** — the six decisions, each recording what was rejected and why. They exist so nobody re-litigates "why isn't the results list its own window?" or "surely macOS has an emoji API?"
- **`AGENTS.md`** — hard rules. Chief among them: **no timing hacks.** No `asyncAfter`, `sleep`, `usleep` as a fix. Event-driven or sequential only.

---

## What's done

### App index refresh (`089313e`)

New `AppIndex.swift` and `AppDirectoryWatcher.swift`.

- Scan is **277 apps in 260 ms**, off the main thread. It previously ran synchronously inside `SubjectSearchVM.init`.
- FSEvents watcher over the five app directories, **1.0 s native latency** for coalescing — a stream parameter, not a delay. Uses `kFSEventStreamCreateFlagWatchRoot`, which is what makes a missing `~/Applications` work: creating it later is itself an event.
- Rebuilds are **full replaces**, built on a background queue and swapped atomically. Additive merging would leave uninstalled apps in search.
- **Mid-search rule:** a rebuild that lands while results are on screen swaps the Index but leaves the visible results alone until the next keystroke. Re-running live can move the selected row out from under Enter and launch the wrong app. *First population is the one exemption* — before the first scan there is no Index, so the visible row is a fallback nobody chose. The reasoning is commented at `SubjectSearchVM.swift:58-76`; don't "simplify" it into observing `apps` unconditionally.
- **Icons resolve lazily.** The Index stores paths only; an icon is fetched when a match becomes a Subject — top five at most, path-keyed cache, pruned on rebuild. Rebuild cost went from ~277 icon lookups (143 ms) to zero.

Entry point for the UI: `AppIndex.shared.refresh()` / `.isRefreshing`, both `@MainActor`.

**Known wart:** `AppIndex.current`, a mutable static, exists only because `CommandCoordinator.swift:23` hardcodes `SubjectSearchVM()`. An `index:` parameter on `CommandCoordinator.init` deletes it.

### Emoji picker (`601cbe2`)

`Emoji.swift`, `EmojiIndex.swift`, `EmojiSearchVM.swift`, `EmojiRecentsStore.swift`, `EmojiGridView.swift`, `Scripts/generate-emoji-index.swift`, plus the bundled `emoji-index.json`.

- **1,914 emoji, 0 missing keywords, 2,030 skin-tone variants across 330 bases**, 226 KB. Generated from Unicode 17.0 + CLDR 48 by `swift Scripts/generate-emoji-index.swift`. The generator exits non-zero if any row comes out keyword-less.
- Reachable two ways: type `emoji` (a Built-in beside Settings and Clipboard), or **Ctrl+Cmd+Space**.
- Enter pastes, Tab offers Copy, **⌥Enter** overrides skin tone for one use. Recents rank first; the grid falls back to categories so it is never empty.
- 68 new tests. Full suite: **172 passing**.

Three dataset traps the generator had to solve, all worth knowing before regenerating:
1. Stripping VS16 *and* tones for the CLDR lookup collapses all six variants onto one key, so `annotationsDerived` overwrites every base name with "thumbs up: dark skin tone". Two distinct keys are needed.
2. Keycaps `#️⃣`/`*️⃣` carry a literal `#`, so splitting `emoji-test.txt` lines on every `#` silently loses them. That was the 1913-vs-1914 gap.
3. 🤝's two-tone forms are `U+1FAF1 <tone> ZWJ U+1FAF2 <tone>` — stripping tones lands on a non-row. Resolved by CLDR name, not by shape.

### Settings (`3388436`)

A grouped `Form`, 460×560, resizable. Appearance / Emoji (hotkey takeover + default skin tone) / Applications (refresh) / Acknowledgements + Quit.

---

## Not started — the whole visual design

Both remaining features are one workstream, because they are the same files and the same design language. Everything here was decided in a long design session; treat it as spec, not suggestion.

### Single Panel, two Slabs (ADR-0001)

Today there are two real `NSPanel`s. Collapse to **one** borderless, transparent, non-activating `NSPanel`, sized once to maximum extent and never resized. Two Slabs drawn inside it with real empty space between.

**The two-Slab look is a hard requirement.** Card Slab on top, real gap, Results Slab below, each with its own edges and shadow. The unified single-surface look of Spotlight and Raycast was explicitly rejected. Do not merge them.

Consequences:
- `hasShadow = false` on the Panel; each Slab draws its own SwiftUI shadow.
- The empty gap belongs to the Panel — make it non-hit-testing so click-outside-to-dismiss still works.
- Delete the `DispatchQueue.main.asyncAfter(.now() + 0.25)` around `PanelController.swift:156`. It exists only because of the second window, and must not be replaced with another delay.
- The `.nonactivatingPanel` contract must survive — it is what makes paste simulation work.

### Liquid Glass, in one place (ADR-0002)

Deployment target is **26.4**, so `.glassEffect` / `GlassEffectContainer` are available unconditionally. No `#available` anywhere.

The same material recipe is currently copy-pasted in **four** files — `AppTheme.swift` (`ThemedGlass`), `SubjectCardView.swift`, `ActionCardView.swift`, `TargetCardView.swift` — with drifting radii. Replace with one `Style.swift` exposing three tiers: `surface` (a Slab), `raised` (focused Card), `recessed` (unfocused Card, Result rows). No view outside `Style.swift` may hold a raw radius, colour, shadow, or `colorScheme` branch.

**Both appearances must be excellent — the theme picker stays.** Treat light and dark **asymmetrically**: light needs a stronger material and a defined rim or it washes out; dark leans on the shadow. The current dark treatment (`Color.black.opacity(0.92)` over a material) is effectively opaque and is exactly the "looks solid, not like glass" complaint. Delete it.

Geometry (current values are 32pt card / 28pt panel and `shadow(.black.opacity(0.12), radius: 8, y: 4)` — both a large part of why it reads generic):

| | |
|---|---|
| Slab radius | **20** |
| Card radius | **14** (non-concentric, outer larger — Apple's convention) |
| Padding / gap | **12** / **12** |
| Shadow | radius **24**, y **8**, opacity **0.28** dark / **0.18** light |
| Slab rim | 1px hairline |
| Focused Card | accent-tinted fill + accent stroke — tint is the selection signal, not a system focus ring |

Refine on visual merit, but do not copy another app's proportions.

### Motion — restraint is the point (ADR-0003)

Exactly **three** curves in one `Motion.swift`: `entrance` (Panel show/hide), `resize` (Slab size), `snappy` (scroll-to-selection). Everything references one of the three; nothing declares its own.

**Only those three things animate.** Phase advances, Card content swaps, and selection-highlight movement are **instant, deliberately**. An animated highlight lags the keypress; an animated card swap delays information the user asked for. This restraint *is* the design.

**Show (~100 ms)** — blur, fade and scale simultaneously, measured frame-by-frame from the reference app:
- opacity 0 → 100% in ~33 ms
- Gaussian blur heavy → 0 over ~85 ms
- scale 0.90 → **overshoot 1.04 at ~50 ms** → settles 1.00 at ~85–100 ms
- ≈ `.spring(duration: 0.16, bounce: 0.28)`. No translation, anchored centre.

**Hide (~110–130 ms)** — one frame of scale *up* to ~1.02, an anticipation kick, then opacity decays while blur ramps back in. The kick is small and it matters.

**Slab resize** — Card count changes spring the Slab wider with `resize`; Card content hard-cuts. Today a `spring(0.15, 0.8)` on content fights a `CAMediaTimingFunction` 0.12 s window resize. One window fixes that.

Optional: `glassEffectID` morphing so the glass stretches as a Card appears. Try it, keep it only if clearly better.

**Reduce Motion** — honour `accessibilityReduceMotion`; all three collapse to a cross-fade in one place. Plus a persisted "animations enabled" preference, default true, surfaced in Settings.

**Shake** — short horizontal shake on no-match. Today a no-match silently becomes a text Subject, which is confusing.

### The Results Slab

- **Mode-aware** — a branch already exists in `SearchView.swift`. List for apps/files/clipboard, **8-column grid** for emoji. One component, one glass recipe, one keyboard model.
- **Animates in when Results exist, out when they don't**, using `resize`. Exception: **always present in emoji Mode**, because the grid is never empty.
- **Result count header** — exists, needs restyling.
- **Visible query field pinned to the bottom of the Results Slab.** Display-only; keyboard capture stays in the hidden `TextField` in `CardContainerView`. With 1,914 emoji you must see what you typed, and it fixes a real ambiguity where the Subject Card shows a matched app name rather than the literal Query.
- **Restyle `EmojiGridView`.** Constraints, from measurement: glyph at a **32pt** Apple Color Emoji strike (bitmap font — off-strike sizes resample visibly soft), in an **explicit 40×40 cell frame** (emoji line height is 42pt vs the system font's 37.7, so intrinsic sizing makes cells inconsistent).

---

## Known broken

### 1. The app does not terminate cleanly — **regression, confirmed**

`codiclensUITests/testLaunchPerformance`:
- on `main`: **passes in 13.8 s**, launch average 0.410 s
- on this branch: **fails after 84 s** — `Failed to terminate com.codiclens.debug`

This matters beyond the test: Codiclens runs as a background accessory app, and one that won't die on quit is a real bug. It also appears to be triggering runaway system `spindump` processes.

Introduced by `089313e` or `601cbe2`. Suspects, unverified:
1. `AppDirectoryWatcher` — FSEvents stream on a run loop. Check it is stopped, invalidated **and** released on termination, and that teardown doesn't live only in a `deinit` that never runs (`AppIndex.shared` is a singleton and never deinits).
2. `AppIndex` — in-flight background scan or a retain cycle.
3. `AppDelegate` — the second Carbon hotkey, or the `dlsym` work in `EmojiHotKeyController.applyAtLaunch()`.
4. `EmojiIndex` — 226 KB JSON parsed at launch.

**Diagnose it properly:** reproduce, then `sample <pid>` or `spindump` the hung process and read the main-thread backtrace. Do not guess, and do not fix it with a timeout.

### 2. Emoji hotkey is off until you turn it on — *by design*

Verified: no preference exists, and symbolic hotkey 50 is still enabled, so macOS owns ⌃⌘Space. Per ADR-0006 the takeover is **off by default** — seizing a system-wide shortcut unprompted isn't ours to do. Settings → Emoji → *Use ⌃⌘Space for Codiclens*.

### 3. Not verified by eye

Nothing in this branch has been visually reviewed in a running app. Build and tests are green; that is all that is known.

---

## Environment notes

- **Debug builds are `com.codiclens.debug`**, Release stays `com.codiclens`. Done so the app you use and the app under test hold separate TCC grants instead of re-prompting every time you switch. Side effect: the Debug build has its own `UserDefaults` domain and won't see your real settings. Clipboard history is shared — that path is hardcoded to `codiclens/`.
- **`/Applications/Codiclens.app` no longer exists.** Both copies were removed while chasing the permission prompts. The only build is the Debug one in DerivedData.
- Accessibility and PostEvent grants for both bundle IDs were reset with `tccutil`; three stale `com.codiclens` entries were cleared.
- The project uses `PBXFileSystemSynchronizedRootGroup`, so new `.swift` files and bundled resources are picked up **without** editing `project.pbxproj`.
- Signing teams are inconsistent: app and unit tests are `L256GR2793`, the UITest target is `HHNPP7C8GB`. Not causing problems yet; will bite on a clean checkout.

---

## Suggested order from here

1. **Fix termination.** It's a real bug and it makes everything else unpleasant to test.
2. **Glass and motion**, as one workstream. This is the largest remaining chunk — bigger than the index and emoji work combined — and it's the only thing that changes what the app looks like.
3. **Cleanups:** delete `AppIndex.current` by adding an `index:` parameter to `CommandCoordinator.init`; wire the animations toggle into Settings once `Motion.swift` exists.
