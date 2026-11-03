# Minimum macOS for Codiclens

Ticket: [#3](https://github.com/CodicStack/codiclens/issues/3). Researched 2026-11-02 with Xcode 26.4.1 (17E202), macOS 26.4 SDK, on macOS 26.6.2.

## Answer

- **Nothing in the code needs 26.1 to 26.4.** Codiclens builds clean at `MACOSX_DEPLOYMENT_TARGET = 26.0`: app and tests, zero availability errors or warnings, no `#available` added. The finished binary says `minos 26.0`, and `LSMinimumSystemVersion` comes out as `26.0`.
- **One behaviour may: the glass backdrop.** macOS 26.4 fixed a SwiftUI bug where glass in a non-opaque window stopped updating what it shows from behind while the window was inactive. The Panel is exactly that kind of window. Users on 26.0 to 26.3 may see glass showing an old picture of what's behind it. Nobody has checked this on a real 26.0 to 26.3 system.
- **Recommendation: 26.0, after one check on a 26.0 to 26.3 VM** (see [Check before lowering](#check-before-lowering)). If the glass looks stale there, stay at 26.4, because there is no code workaround that keeps the Panel non-activating.
- **Code changes for 26.0:** none in Swift. Two build settings and two docs, listed in [Changes for 26.0](#changes-for-260).

The 26.4 target came with the initial commit (`b6e1fdc`, 2026-05-08). Nothing in the repo records a reason for it. ADR 0002 and AGENTS.md just say "26.4, so no `#available`".

## How it was checked

1. **Build at 26.0.** In a worktree, `MACOSX_DEPLOYMENT_TARGET` was set to 26.0 in all four build configurations, and llama.cpp was rebuilt with `CMAKE_OSX_DEPLOYMENT_TARGET=26.0`. Then `xcodebuild build-for-testing` ran with its own `-derivedDataPath`. Result: `** TEST BUILD SUCCEEDED **`. No `is only available in macOS 26.x` diagnostic, and no warning about availability or deployment versions. `otool -l` on `codiclens` and `codiclens.debug.dylib` shows `minos 26.0, sdk 26.4`.
   For Swift, the compiler treats any use of an API newer than the deployment target, without a check, as an error. So a clean build proves the code calls nothing that needs 26.1 or later. That covers Objective-C APIs too, because Swift sees them through the Clang importer.
2. **Search the SDK for 26.1 to 26.4 symbols.** The SwiftUI, SwiftUICore and AppKit `.swiftinterface` files in the 26.4 SDK list these as newer than 26.0:
   - `GlassButtonStyle.init(_:)` (26.1)
   - `View.task(name:executorPreference:…)` (26.4)
   - `accessibilityReduceHighlightingEffects` (26.4)
   - a few underscored internals

   Codiclens uses none of them (grep found no `GlassButtonStyle`, `.buttonStyle(.glass…)`, `.task(name:` or `executorPreference`). The new `.task(name:)` overloads are `@_alwaysEmitIntoClient` and include their own `if #available(… 26.4 …)`, so the ordinary `.task {}` calls can't pull in 26.4 even by accident.
3. **Check llama.cpp.** `ggml-metal` checks the OS at run time with `@available(macOS 10.12 …)` and `@available(macOS 15.0 …)` only. Nothing checks for 26.x. The build script pins 26.4 only to match the app (`Scripts/build-llama.sh:54`, "The deployment target is the app's").

## macOS 26 APIs in use (all 26.0)

| API | Where | Introduced (macOS) | Source |
|---|---|---|---|
| `Glass`, `.regular`, `.tint(_:)`, `.interactive()` | `codiclens/Style.swift` (145, 343-344) | 26.0 | [Glass](https://developer.apple.com/documentation/swiftui/glass); SDK `SwiftUICore.swiftinterface` |
| `View.glassEffect(_:in:)` | `Style.swift` (353, 396); `codiclensTests/SubjectCardPictureTests.swift` | 26.0 | [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) |
| `GlassEffectContainer` | `codiclens/PanelView.swift:52`; `codiclensTests/SubjectCardHoldTests.swift` | 26.0 | [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) |
| `View.glassEffectID(_:in:)` | `Style.swift:397` | 26.0 | [glassEffectID(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)) |
| `View.glassEffectTransition(_:)`, `.matchedGeometry`, `.identity` | `Style.swift:401` | 26.0 | [glassEffectTransition(_:)](https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:)) |

The "Introduced" column was read from Apple's documentation data (`developer.apple.com/tutorials/data/documentation/swiftui/<symbol>.json`, `platforms[macOS].introducedAt`) and matches the SDK's `@available(… macOS 26.0 …)`. For comparison, the same lookup gives 26.1 for `GlassButtonStyle.init(_:)`, which Codiclens doesn't use. `ConcentricRectangle` (26.0) shows up only in comments.

No `#available` or `@available(macOS …)` exists anywhere in `codiclens/` or `codiclensTests/`. The only `@available` is `@available(*, unavailable)` on an `init(coder:)` in `PassagePreviewView.swift:213`. With nothing gated, there are no fallbacks either: everything above runs the same on 26.0.

## What a 26.0 to 26.3 user may lose

**Live glass backdrop while the app is inactive. Unverified, and the one real risk.** From the [macOS Tahoe 26.4 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes), under SwiftUI, Resolved Issues:

> Fixed: On macOS, a non-opaque window that hosts glass content will correctly update the backdrop content behind the glass even if the window is inactive. (166828089) (FB21375029)

The Panel is a borderless `NSPanel`, `.nonactivatingPanel`, `isOpaque = false`, `backgroundColor = .clear`, holding SwiftUI glass (`codiclens/FloatingPanel.swift:24-48`). Because it is non-activating, Codiclens is never the active app while the Panel is up, and that is on purpose (AGENTS.md rules). The release note doesn't say whether "inactive" means "not key" or "app not active". The Panel is key but its app isn't active, so it may match either one.

The likely symptom is that the glass keeps refracting an old picture of what's behind the Panel, for example a video that has moved on or a window that has scrolled since. The fix is in the OS, so building against the 26.4 SDK doesn't bring it to older systems. Making the app active would work around it, but that breaks the `.nonactivatingPanel` contract and the synthesised Cmd+V into the app underneath.

**Other OS fixes in 26.1 to 26.4.** The [26.1](https://developer.apple.com/documentation/macos-release-notes/macos-26_1-release-notes), [26.2](https://developer.apple.com/documentation/macos-release-notes/macos-26_2-release-notes) and [26.3](https://developer.apple.com/documentation/macos-release-notes/macos-26_3-release-notes) notes list nothing in areas Codiclens touches: no AppKit panels, Quick Look, sharing, pasteboard, hot keys, SQLite or glass. The one AppKit item (the window resize pointer not following corner shape, known in 26.3, fixed in 26.4) doesn't matter here, because the Panel is never resized. The 26.1 SwiftUI fix (`navigationLinkIndicatorVisibility`) is unused.

**Observations measured on 26.x.** AGENTS.md and the ADRs record several things measured on "macOS 26": the share-service list, the Open With lists, `QLPreviewPanel`'s toolbar, and `AVAudioFile` opening a `.mov`'s soundtrack. Those come from whatever 26.x machine was used, and nobody has re-checked them on 26.0. They are behaviour notes, not API requirements. ADR 0006's private hot-key API, verified on 26.5.1, is superseded and removed, so it doesn't matter here.

## Check before lowering

On a 26.0 VM (or 26.3, which still has the bug; VirtualBuddy or UTM with an Apple restore image), install a 26.0-target build and:

1. Play a video, or scroll a busy window, behind where the Panel opens. Summon the Panel and watch whether the glass keeps refracting the moving content.
2. Do the same with Codiclens's Settings window frontmost, then with another app frontmost. That covers both meanings of "inactive".
3. Open a Card (`GlassEffectContainer` merge plus `glassEffectID` arrival) and check that the morph looks the same as on 26.4.

If step 1 or 2 shows a frozen backdrop, keep 26.4 and record that in ADR 0002 as the reason.

## Changes for 26.0

1. `codiclens.xcodeproj/project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET = 26.4` becomes `26.0`, four times (app and tests, Debug and Release).
2. `Scripts/build-llama.sh:54`: `-DCMAKE_OSX_DEPLOYMENT_TARGET=26.4` becomes `26.0`. Without this, the link gives 157 warnings like `ld: warning: object file (…libllamacpp.a[…]) was built for newer 'macOS' version (26.4) than being linked (26.0)`. That was measured by linking the 26.0 app against the 26.4 `Vendor/llama`. Also, the script's `STAMP` is the tag plus the patch hash and leaves out the deployment target. So an existing `Vendor/llama` counts as "already built" and is not rebuilt. Either add the target to `STAMP` or delete `Vendor/llama` once.
3. `docs/adr/0002-liquid-glass-over-hand-rolled.md` and `AGENTS.md:423`: "Deployment target is 26.4" becomes 26.0. "No `#available`" still holds, because everything used is 26.0.

No Swift source changes.
