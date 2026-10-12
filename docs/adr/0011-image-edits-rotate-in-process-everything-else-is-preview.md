---
status: accepted
---

# Rotate happens in process; every other image edit is Preview's job

An image Subject — a Clipboard Item's snapshot or an image file on disk — gets **Rotate
Left**, **Rotate Right** and **Open in Preview**, and nothing else. There is no Action named
"Markup", and there will not be one.

The reason is that the surface people expect it on does not exist for us. A third-party
`QLPreviewPanel` on macOS 26 draws a toolbar of exactly five things: close, fullscreen, the
title, **Share**, and **Open with Preview**. Verified by building a throwaway app and
screenshotting it, not inferred. Finder's Quick Look shows Markup and Rotate on top of those
because they are **Quick Actions** — Action extensions the Finder hosts — and there is no
public API for another app to host them inline. The private route was considered and
rejected: this app already carries one private-API dependency (ADR 0006, the symbolic
hotkey) and that one buys a feature with no public equivalent at all. Markup has a public
equivalent one keystroke away, called Preview.

Rotate is different from markup and crop in a way that matters: it is a one-line CoreGraphics
operation with no UI, no canvas, no tool palette and no decisions to collect. It is cheap
enough to do in process and keyboard-native enough to be worth it — quarter-turning a
screenshot without leaving the Panel is the case that comes up. Finder is the precedent for
the semantics: it rotates **in place**, without asking, and does not ask where to put the
result. So do we. Everything Rotate cannot do — markup, crop, annotate, resize — is
**Open in Preview**, which is also why that Action was added to image files and not only to
Clipboard Items.

Rotate is **Final and returns no `.hide`**, which is the same rule OCR established in
ADR 0007: the result lands *in* the Panel, so the Panel has to still be there. The Subject
stays the same Subject and the Panel stays open; only the pixels change. A Clipboard Item
that is rotated is **not** moved to the top of the history either — rotating is not copying,
and reordering the history would lose the user's place in a list they are looking at.

The Quick Look toolbar is **Apple's**, and we add no keys inside the panel. `QuickLookHelper`
already intercepts j/k and Shift+Space; a Rotate key there would put a second, invisible
keyboard grammar inside a window we do not draw, whose only discoverable affordances are
Apple's five buttons.

## Consequences

- **Rotate mutates the stored PNG for a Clipboard Item** and the file on disk for an image
  file. For a Clipboard Item that is the snapshot and therefore the only copy the app has —
  see `docs/adr/0010-a-clipboard-item-is-a-snapshot.md`.
- **A rotating Action that returns `.hide` is a bug, not a variation.** Same wording, same
  reason, as OCR in ADR 0007.
- **Rotate is not Editing.** Editing is the text-Subject Action on the Card
  (`GLOSSARY.md`). An image Subject has no editor and Codiclens ships none.
- **Don't reach for `QLPreviewPanel` customisation again.** The toolbar list above is the
  whole of it; treat a request for inline Markup as a request for Open in Preview.
- The two rotations are two Actions rather than one Action with a Target. A direction is not
  a recipient, and the grammar's Target Phase is for Subjects.
