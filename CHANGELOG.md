# Changelog

What changed in each release of Codiclens. Notes for the next release go under Unreleased: a few plain sentences, written for people who use the app. [docs/RELEASING.md](docs/RELEASING.md) has the convention.

## Unreleased

## 1.0.3 (2026-11-07)

- The Left and Right arrows move between cards when you haven't typed anything, like Ctrl+H and Ctrl+L, so in the clipboard history Right opens the selected item's actions and Left goes back. Once you've typed, they move the cursor as before. Ctrl+Left and Ctrl+Right always work like Ctrl+H and Ctrl+L, unless macOS uses them to switch Spaces.
- Clipboard items have a new Save To… action. Pick a folder from the same list Copy To uses, and the image or text is saved there as a new file, which becomes the subject so you can open or share it right away. The item stays in your clipboard history, and nothing already in the folder is replaced.

## 1.0.2 (2026-11-04)

- After Transcribe, OCR, QR Code, a text change, Move To, Copy To, Rename or Compress, the panel goes back to the first card with the result as the new subject, ready for Enter or Tab. Enter on text pastes it, so a transcript or OCR text goes straight into the app you were in.
- When the panel opens on something you used last time, Backspace clears it without typing first.

## 1.0.1 (2026-11-03)

- Maintenance release to verify signed updates from v1.0.0. App behavior is unchanged.

## 1.0.0 (2026-11-03)

The first public release. Press ⌘Space to open apps, files and folders, find files by name, by what they say or by what they show, and reach your clipboard history and emoji from one panel. Setup on first launch lets you choose the shortcuts, the folders to index and how much of search by meaning to download, and every step is optional. Codiclens now updates itself: it checks once a day and tells you in the panel when a new version is ready.
