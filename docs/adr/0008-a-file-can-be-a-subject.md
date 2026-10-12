---
status: superseded in part by ADR-0012 (files in Subject search)
---

# A file can be a Subject, two ways, and neither is a file browser

`SubjectKind` has had `.file(contentType:)` and `.folder` cases, and `SubjectAction` has had a list of Actions for them, since before this decision — and nothing in the app ever constructed one. Files reached the app only as **Targets**: found by `mdfind`, chosen after an Action, consumed by that Action, never acted on in their own right. OCR is what exposed the hole, because "OCR this image" needs the image to be a Subject.

We filled it two ways and deliberately did **not** fill it the obvious third way.

**Path typing.** A Query beginning `/` or `~` is a **Path Subject**: it resolves to exactly one file or folder, and that is the single Result. A path that does not resolve produces no Result and the Panel shakes.

**Use as Subject.** A non-Final Action available on any Target that is a file or an app. Picking the Target retargets the Subject to it and lands on the Action Phase. This is the search-driven route: you find the file through Finder's `mdfind` Target search, then promote it.

**Rejected: files ranked alongside apps in Subject search.** This is what Spotlight does and it is the answer a reader will expect. It breaks three things that are each written down elsewhere. Text Mode fires on *zero app matches* — a result-dependent condition that a second, out-of-process source of results makes incoherent. `canReportNoResults` gates the "No results" claim on `SubjectSearchVM.isIndexReady`, one gate for one source; a second asynchronous source needs a second gate, and the last time this Slab had two conditions deciding what it could say, every search said "No results" and then changed its mind. And it puts a subprocess on the keystroke path. The `/` and `~` prefixes exist precisely because they *cannot* collide with an app name, so a Path Subject never competes with the Index and none of the three gates move.

**Rejected: a completion list.** Typing `~/Down` could list the directory's contents. That is a file browser — a new Mode, a directory read per keystroke, its own arrow-key and scroll semantics, and a new `PanelLayout` height. A Path Subject is one function: string → `URL` → `UTType` → `Subject`.

**Rejected: drag-and-drop.** Not available. The Panel is `.nonactivatingPanel`, summoned by a hotkey and dismissed on a click outside it; it is not a surface you can drag onto.

## Consequences

- **`~/Downloads` resolves to a `.folder` Subject, it does not list.** Enter opens it in Finder, which is what `defaultEffects` already does for `.folder`. "List its contents" is the rejected completion list under another name.
- **`UTType` is resolved at Subject construction**, because `.file(contentType:)` carries it and the OCR Action is gated on `conforms(to: .image)`.
- **"Use as Subject" is general, not Finder-only.** Any file-or-app Target can be promoted. One rule beats a special case, and it means the Action appears in Target lists that were built for something else.
- Promoting from `pickingTarget` takes the Card row from three Cards to two. The Card row's width is already a SwiftUI animation on `cardCount`, so this needs nothing new.
- `.file` and `.folder` stop being dead branches, which means their Action lists in `SubjectAction.builtIn(for:)` are now reachable and, for the first time, worth testing.
