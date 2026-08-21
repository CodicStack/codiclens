---
status: accepted
---

# The app Index is a directory scan, refreshed by FSEvents

The Index is built by recursively scanning five known application directories, and rebuilt **in full** whenever FSEvents reports a change in any of them. There is also a manual refresh in Settings. Previously it was built once in `init` and never refreshed, so newly installed apps were invisible until relaunch.

## Considered options

- **Spotlight (`mdfind kind:application`)** instead of a directory scan. It would find apps outside the five directories, and `TargetSearchVM` already shells out to `mdfind`, so the precedent exists. Rejected: it returns hundreds of helper, framework-embedded, and XPC `.app` bundles that need their own filtering pass, and ranking should be ours. The reported bug was staleness, not coverage.
- **Rescan when the Panel opens.** Rejected: taxes the hottest path in the app.
- **Periodic timer.** Rejected: a timing hack, and this project doesn't use those.
- **`NSWorkspace.didLaunchApplicationNotification`.** Rejected: misses apps installed but never launched.

## Consequences

- Rebuild is a full replace, off the main thread, swapped in atomically. Additive merging would leave uninstalled apps in search, and launching one fails silently.
- A rebuild that lands mid-search swaps the Index but leaves visible Results untouched until the next keystroke. Reshuffling results under the user's fingers can move the selected row out from under Enter and launch the wrong app.
- App icons are resolved lazily when a Subject is displayed, not during the scan. Roughly five Subjects are ever on screen; eager loading made every rebuild pay for ~200 unseen `NSWorkspace.icon` lookups, and it was the main cost in the original synchronous `init` scan.
