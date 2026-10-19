---
status: accepted
---

# Incoming Subjects come through Open With and a Service, and the Last Subject is anything but an app

A thing found in Finder, or text selected in another app, can be handed to Codiclens as an
**Incoming Subject**: the Panel opens with it standing, one Card, the Query empty, as a Last
Subject stands. Enter runs its default Action, Tab goes to the Action Phase, the first
keystroke starts a new Query. Sent while the Panel is mid-command, it drops that command and
stands. Several files sent at once: the first is the Subject, the rest are dropped, and the
Subject Card says how many came.

**Files arrive through Finder's own Open With menu.** Codiclens declares itself a Viewer at
rank `Alternate` for 21 broad types (text, composite content, images, audiovisual content,
archives, folders and the like). Neither the lowest rank, `None`, nor a claim on `public.item`,
`public.data` or `public.content` is ever listed in Open With on macOS 26, measured with
`urlsForApplications(toOpen:)`, so `Alternate` over named types is the only way in. The
cost is deliberate: Codiclens is listed in nearly every file's Open With menu and in Get
Info's "Open with", and it **becomes the default app for a type no other installed app
claims** (`.pages`, `.numbers` and `.key` on a Mac without iWork). Open on a file whose
default app is Codiclens shows Quick Look instead, so it never hands the file back to
itself. That is where the user wants it, one level from the top of the right-click menu.

**Everything Open With cannot reach comes through a Service, "Open in Codiclens"**: text
selected in any app, and whatever Open With does not list Codiclens for (a `.app`, a `.pkg`,
a type no installed app declares). A `.app` arrives as an app Subject, as if found in search; any other
package as a file.

Rejected: **a Service alone.** It covers everything with one mechanism, but sits under
Quick Actions or Services, a level deeper than Open With, and the user asked for Open With.
**A Finder Sync extension.** The only way to a top-level menu item, but only in folders it
watches, as a separate target the user has to switch on.

## The Last Subject widens

The Last Subject was a Clipboard Item or an Emoji, and acting on anything else ended it. An
Incoming file that did not come back on the next hotkey made the feature feel one-shot, so
the rule is now one rule for every way a Subject is found: **the Subject last acted on, or
sent in, is the Last Subject**, whatever it is, except an app or a Built-in. A file opened
from search, a folder from a path, text typed with ⌘E, OCR Text and Incoming text all
qualify. Apps stay out: launching Safari and finding Safari standing on every hotkey is
noise, not memory.

## Consequences

- Sent in counts as acted on: a file sent from Finder and dismissed with Escape still
  stands next time.
- A file Last Subject is checked as the Panel opens, as a Clipboard Item is looked up again:
  gone means no Last Subject and an empty Panel, no shake. Rename and Move by Codiclens follow
  the file; Move to Trash ends it.
- Still in memory only. A Last Subject that survived a restart would be yesterday's file
  standing for no reason.
- Text that was a secret can now stand on screen: Incoming and typed text carry no
  concealed flag the way a password manager's copy does. Accepted: memory only, and the user
  sent it.
