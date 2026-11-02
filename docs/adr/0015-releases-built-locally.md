---
status: accepted
---

# Releases are built, signed and published from the maintainer's Mac, not CI

`Scripts/release.sh` runs on the maintainer's Mac and does the whole release there: build, Developer ID signing, notarization of the app and the DMG, the Sparkle EdDSA signature, the appcast, and the GitHub Release. There is no release workflow in GitHub Actions. The repository is public, and a release needs the Developer ID certificate, a notary credential and the Sparkle private key. On CI those three would be repository secrets reachable by any workflow change that lands on `main`, and the Sparkle key in particular can push an update to every installed copy. Codiclens is one platform with one maintainer, so CI buys little here: no second platform to build and no second person to release.

## Considered options

- **GitHub Actions on tag push**, as Codictate does. Rejected: it puts all three signing secrets on a public repo's CI for no gain on a single-platform app.
- **Hybrid** (build locally, publish from CI). Rejected: it splits a short pipeline across two places and still needs the Sparkle key wherever the appcast is generated.

## Consequences

- Only the maintainer's Mac can cut a release. The Sparkle key lives in its login Keychain, backed up in the password manager (see the Sparkle research on `research/sparkle`).
- The script builds and notarizes everything locally before it commits, tags or pushes, so a failed notarization leaves no orphan tag and no half-published release.
- CI may still run tests on pull requests; it just never signs or publishes.
