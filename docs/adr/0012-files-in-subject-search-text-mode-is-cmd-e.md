---
status: accepted
---

# Files appear in Subject search, and Text Mode is Cmd+E

ADR 0008 rejected ranking files alongside apps in Subject search, for three reasons: automatic Text Mode fires on zero app matches, `canReportNoResults` has one gate for one source, and it puts a subprocess on the keystroke path. We now want files to show up as you type, matched by name and by meaning, so each reason is answered instead of avoided.

**File Results come from a File Index, not a subprocess.** The File Index is our own on-disk store of names and EmbeddingGemma 2 vectors, kept up to date by a helper process. The keystroke path reads it in-process; nothing is spawned per key.

**Everything else sits below the app Results, updates live, and never moves them.** Up to five app Results are on top and arrive on the keystroke, exactly as before. Below them is one list ranked by score that mixes File Results, Clipboard Items and Emoji, each row marked with its Source. That list stays on screen while the user types: word matches update it on every keystroke, and meaning results join and re-rank it once typing pauses for about 120 ms, after which it is settled. Rows below the apps may move while typing goes on; the apps never do. A selection the user moved by hand stays on the same item while it is still in the list.

Revised 2026-10-12. The first version had the list land once per pause and withdrawn on every keystroke, so nothing below the apps ever moved. In use, that flashed the whole list away and back on every short pause; the user preferred a list that stays and re-ranks.

**Automatic Text Mode is gone. Cmd+E turns the Query into a text Subject.** Cmd+E already meant "edit this as text" on every text Subject, and pressed on a Query it opens the editor with the Query in it. With nothing triggering on zero matches, there is no condition left that a late, second source can make incoherent, and "No results" waits on nothing new. "No results" offers ⌘E as a hint.

## Considered Options

- **Keep automatic Text Mode, firing when neither apps nor File Results match.** Rejected: the condition would have to wait for the slower source, which is the "No results, then it changes its mind" bug again.
- **A permanent "Use as text" row at the bottom.** Rejected: one more row on every Query, for something a key does.
- **Apps and files in one ranked list.** Rejected: apps must stay first, and a late file outranking an app would move the row under the user's Enter.
- **The list below the apps lands once per pause and is withdrawn on every keystroke.** Built first, then dropped: the list flashed away and back on every short pause.
- **Sections per Source (Clipboard, Emoji, Files) instead of one mixed list.** Rejected: the user preferred one list, with each row showing its Source.

## Consequences

- Path Subjects (`/`, `~`) and Use as Subject from ADR 0008 stand unchanged.
- Typing a sentence and pressing Enter no longer reaches Search Web; it is Cmd+E, then Tab.
- `SubjectSearchVM.isIndexReady` stops gating Text Mode, because there is no automatic Text Mode left to gate.
