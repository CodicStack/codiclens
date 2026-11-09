# Releasing Codiclens

A release is one command on the maintainer's Mac: `Scripts/release.sh`. It builds, signs and notarizes the app, makes the DMG and the signed Sparkle appcast, then commits, tags, pushes and publishes the GitHub release. There is no release CI, on purpose: [ADR 0015](adr/0015-releases-built-locally.md) explains why.

The script never touches `/Applications` and does nothing on the site. The site's `/appcast.xml` passes on the newest release's `appcast.xml` as it is, and its releases page reads the GitHub releases, so publishing the release is all it takes.

## One-time setup

You need these once per Mac. The script checks every one of them before it builds and stops with a message naming what is missing.

### Tools

- Xcode 26.4 or later and cmake (`brew install cmake`), as for any build.
- The GitHub CLI, signed in with access to `CodicStack/codiclens`: `gh auth login`.

### Developer ID certificate

The **Developer ID Application** certificate for team `L256GR2793` must be in the login keychain. Check with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If it's missing, add it in Xcode › Settings › Accounts › Manage Certificates, or import the `.p12` from the password manager.

### Notarization profile

The script notarizes with a notarytool keychain profile named `codiclens`, made from an App Store Connect API key.

1. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api), Users and Access › Integrations › App Store Connect API, create a team key with the **Developer** role. Note the Key ID and the Issuer ID, and download `AuthKey_<KEYID>.p8`. Apple lets you download it only once.
2. Store the profile:

   ```bash
   xcrun notarytool store-credentials codiclens \
     --key ~/Downloads/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-ID>
   ```

3. Check it: `xcrun notarytool history --keychain-profile codiclens` lists past submissions (none at first) without an error.
4. Put the `.p8` and both IDs in the password manager, then delete the downloaded file.

### Sparkle signing key

Every update and the appcast itself are signed with an EdDSA key that lives in the login keychain under the account `codiclens`. The app carries the matching public key as the `SPARKLE_PUBLIC_ED_KEY` build setting, which feeds `SUPublicEDKey`. Until the real key exists that setting holds an all-zero placeholder, and the script refuses to release with it.

Sparkle's tools come with the Swift package. Fetch them into the folder the script uses:

```bash
xcodebuild -resolvePackageDependencies -project codiclens.xcodeproj -scheme codiclens \
  -clonedSourcePackagesDirPath build/release/SourcePackages
SPARKLE_BIN=build/release/SourcePackages/artifacts/sparkle/Sparkle/bin
```

1. Generate the key once: `$SPARKLE_BIN/generate_keys --account codiclens`. It prints the public key.
2. Replace the placeholder `SPARKLE_PUBLIC_ED_KEY` in `codiclens.xcodeproj/project.pbxproj` (the app target's Debug and Release) with that public key, and commit it. It is public and safe in git.
3. Back up the private key: `$SPARKLE_BIN/generate_keys --account codiclens -x sparkle-codiclens.key`, paste the file's contents into a secure note in the password manager, then delete the file. It must never go in the repo, on Vercel or in GitHub secrets.
4. On a new Mac, restore it with `$SPARKLE_BIN/generate_keys --account codiclens -f sparkle-codiclens.key` and delete the file again.

`$SPARKLE_BIN/generate_keys --account codiclens -p` prints the public key of the stored key; it never makes a new one. The first time `generate_appcast` or `sign_update` uses the key, macOS asks whether they may: choose Always Allow.

If the key is ever lost, the next release can be signed with a new key: installs accept it because the DMG is Developer ID signed, after up to 20 days and without notes for that one update. If it leaks, rotate the same way at once. Losing the key and the Developer ID team together means users have to download the app again.

## Cutting a release

1. Make sure everything for the release is merged to `main` and pushed, and the notes are under `## Unreleased` in [CHANGELOG.md](../CHANGELOG.md) (see [The changelog](#the-changelog)).
2. Do a dry run:

   ```bash
   Scripts/release.sh --dry-run
   ```

3. Open the DMG it made (`build/release/vX.Y.Z/Codiclens-X.Y.Z.dmg`) and check it if you like. To try the app, copy it somewhere outside `/Applications`.
4. Release:

   ```bash
   Scripts/release.sh
   ```

   The finished steps of the dry run are reused, so this mostly commits, tags and publishes.

### Choosing the version

- `Scripts/release.sh` releases the next patch version: after `v1.0.3` comes `1.0.4`. With no tag yet it releases `1.0.0`.
- `Scripts/release.sh 1.1.0` releases a version you name, for a minor or major bump.
- A version at or below the last tag, here or on origin, is refused.

The version goes into the project as both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (`X.Y.Z`), so building a tag reproduces its version, and Sparkle can match each notes section to the installed build.

### Options

- `--dry-run` does everything up to and including the appcast: build, notarize the app, make, sign and notarize the DMG, write the appcast. It doesn't touch git (no version bump, changelog edit, commit, tag or push) and publishes nothing. Use it to test the pipeline or to get a DMG for a manual install.
- `--skip-tests` skips the unit-test run. Use it when you've just run them.

### What it checks first

Before anything builds, the script stops with a message if:

- the branch isn't `main`, the working tree has changes, or `main` isn't in sync with `origin/main`;
- the version isn't above the last tag, or its tag already exists;
- `## Unreleased` in `CHANGELOG.md` is missing or empty, or its notes break the style below;
- the Developer ID identity, the `codiclens` notarytool profile or the Sparkle key is missing;
- `SPARKLE_PUBLIC_ED_KEY` is still the placeholder or doesn't match the key in the keychain;
- the unit tests fail (unless `--skip-tests`).

### What it does

Everything goes into `build/release/vX.Y.Z/`, with logs in `logs/`:

1. Writes the release notes (see below).
2. Builds llama.cpp (`Scripts/build-llama.sh`).
3. Archives the Release build, arm64 only.
4. Exports it signed with Developer ID, and checks the version, the architecture, the Sparkle key and the signatures of the app and Sparkle's helpers.
5. Notarizes the app and staples it.
6. Makes `Codiclens-X.Y.Z.dmg` (the app and an Applications link, APFS, lzfse) and signs it.
7. Notarizes and staples the DMG, and checks Gatekeeper accepts it.
8. Writes the appcast: the previous release's `appcast.xml` plus the new item, no deltas, notes embedded, signed. The new item's full release notes link is `https://codiclens.codicstack.com/releases#vX.Y.Z`.
9. Commits "Release vX.Y.Z" (the project's version and the changelog), tags `vX.Y.Z` and pushes both.
10. Creates the GitHub release as a draft, uploads the DMG and `appcast.xml`, then publishes it. The latest release, and so the site's feed, only moves once both files are there.
11. Removes the build's app copies (the archive's, the export's and the build product) so they stop showing up in Spotlight and Open With. The DMG, the dSYMs, the appcast, the notes and the logs stay.

A dry run stops after step 8. A failure before step 9 leaves no commit, no tag and nothing public.

### When something fails

Fix the cause and run the same command again; the script prints it. Each finished step leaves a marker in `build/release/vX.Y.Z/.done/` and is skipped on the rerun, so a failed notarization costs one more submission, not a rebuild. Apple's notarization log is saved under `logs/` when a submission is rejected.

- The notes and the appcast carry the release date. When a rerun happens on a later day, both are made again.
- The folder is reused only for the commit it was built from. After a new commit the script tells you to start over with `rm -rf build/release/vX.Y.Z`.
- After the release commit, a rerun only tags, pushes and publishes. Run it with no version (or the same one) while that commit is `HEAD`.
- To redo a single step, delete its marker in `.done/` (and the markers after it).

## The changelog

[CHANGELOG.md](../CHANGELOG.md) is written by hand. While you work, add notes under `## Unreleased`. When you release, the script:

- renames `## Unreleased` to `## X.Y.Z (YYYY-MM-DD)` and adds a fresh, empty `## Unreleased` above it (this lands in the release commit);
- uses that section's markdown as the GitHub release body, which the site's releases page shows;
- renders the newest five versions' sections to HTML with GitHub's markdown API and embeds them in the appcast item, each headed "X.Y.Z · D Mon YYYY". Sparkle's dialog hides the version that's installed and everything older, so people see what changed since their version.

The changelog starts with the 1.0.0 notes under `## Unreleased`; the first release turns them into `## 1.0.0`.

### Notes style

A few plain sentences per release, written for people who use the app:

- Say what changed for them: "Search by meaning finds photos faster." Not how it was done.
- No subheadings, ticket numbers or internal names. One short list is fine when a release has several separate changes.
- No em dashes.
- Keep it self-contained: no images or other remote content, because Sparkle's dialog doesn't load it.

The script refuses notes with a subheading, a ticket number like `#41` or an em dash.

The notes step has a fixture test: `Scripts/tests/release-notes.sh`.
