---
status: accepted
---

# A Clipboard Item is a snapshot, not a reference to the file it came from

Until today a Clipboard image was two things at once. `ClipboardHistory.previewURL`
returned the **original file on disk** whenever `originalFilePath` still resolved, so Quick
Look showed that file; Paste and Open in Preview used the **stored PNG** written into
Application Support at copy time. Two Actions on one Clipboard Item read two different
files, and nothing said which one the Item *was*. Copy an image, edit the original in
Preview, come back: Quick Look showed the edit and Paste did not.

There are only two coherent models and they are both defensible.

**Follow the file.** A Clipboard Item is a pointer, and every Action re-reads the original
when it is still there. This is what `previewURL` was half-doing.

**Snapshot.** A Clipboard Item is the text or the pixels *as they were at copy time*. The
file it was copied from lends its display name and nothing else.

We chose snapshot, because it is what a clipboard is. A Clipboard Item already survives the
original being renamed, moved or deleted, and half the Items in the history never had an
original at all — a screenshot, a copy out of a browser, OCR Text. Following the file makes
those the exception rather than the rule, and it is the more expensive model to actually
build: it needs the original's modification date recorded at copy time and a re-import on
next use, and there is no hook that would make it feel live. The obvious one — re-import
when Quick Look closes — does not exist: Quick Look closes the moment Preview activates,
which is *before* the user has typed a character, so the save would always be missed.

Snapshot also makes the rule one sentence long, which is why it is in `CONTEXT.md` under
**Clipboard Item** rather than only here.

## Consequences

- **`previewURL` for an image returns the stored PNG.** The `originalFileURL` branch is
  gone. Quick Look, Paste, Share and Open in Preview now all name the same file, which is
  the whole point.
- **`originalFilePath` stays stored, and is now only a name.** `Subject` reads it for the
  path it shows on the Card. It must never again be used to *fetch* content.
- **Editing through Quick Look lands on the snapshot, and that is the feature.** Quick
  Look's "Open with Preview" opens whatever `previewURL` handed it — now the stored PNG —
  so a markup or a crop saved in Preview is what the next Paste pastes. Under the old
  behaviour the edit landed on the original and Paste ignored it.
- **Rotate edits the stored PNG in place**, for the same reason, and leaves the original
  untouched. See `docs/adr/0011-image-edits-rotate-in-process-everything-else-is-preview.md`.
- **A Clipboard Item does not go stale and does not need invalidating.** No modification
  date, no re-import, no filesystem watch on a hundred originals.
