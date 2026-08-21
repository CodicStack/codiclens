---
status: accepted
---

# An Action that takes time stays behind the Effect seam

Every Action before OCR was synchronous: `CommandCoordinator.submit()` decides, returns `[Effect]`, and the runner performs them in the same turn. OCR is `async` — `RecognizeTextRequest.perform(on:)` is awaited. We kept the seam rather than the shape: the coordinator returns `.ocr(URL)` and knows nothing about Vision, `EffectRunner` does the awaiting, and the text comes back through a callback that retargets the Subject.

The alternative — and the one that reads as obviously simpler at the call site — is for the coordinator to spawn its own `Task`, await Vision inline, and set the phase when it lands. That is why this is written down: someone will look at the extra Effect case plus the callback and try to collapse it.

Collapsing it costs the test story. The reason `CommandCoordinator` is reachable from a test at all is that it contains no code that touches the world — no `NSPasteboard`, no `NSWorkspace`, no `CGEvent`, no `FileManager`. A test hands it a fake `EffectRunner` and asserts on the `[Effect]` it returned. Awaiting Vision inside the coordinator puts an image, a real Vision model and a real machine into every test of "OCR retargets the Subject to its OCR Text". With the seam, the fake runner answers with a canned string and Vision never runs in a test.

`.savePanel` is the precedent: an Effect the runner answers rather than merely performs. OCR is the second, and the shape now has two users, which is the point at which it is a pattern.

## Consequences

- **The Panel must not dismiss.** Every other Final Action returns `.hide` first. OCR returns no `.hide` at all — the result lands *in* the Panel, so the Panel has to still be there. An OCR Effect that hides is a bug, not a variation.
- **There is a moment with no answer yet**, which is new for an Action. It is reported the way Target search already reports one: an in-flight flag beside `isSearchInFlight`, and a row in the Slab. See ADR 0003's amendment for the spinner.
- **A second Enter during the wait must do nothing.** The in-flight flag gates it. Two OCR runs racing to retarget the same Subject would have the loser overwrite the winner.
- The URL is what crosses the seam, never image bytes — see `.ocr(URL)` in `Effect`. Loading the image in the coordinator would be file I/O on the wrong side of the line.
- **A read is not an effect.** `PathSubject` calls `FileManager` and is called from the coordinator, which looks like a violation of the rule above and is not. The seam exists to keep *side effects* — things that change the world, or that need a real machine to answer — out of the phase machine. Asking what a URL already is changes nothing and answers synchronously, so it needs no Effect and no fake. The line is: if it mutates, or if it takes time, it crosses the seam. Resolving a path does neither.
