# Sparkle 2 with GitHub Releases

Research for [#4](https://github.com/CodicStack/codiclens/issues/4), map [#2](https://github.com/CodicStack/codiclens/issues/2). Researched 2026-11-02.

Sources: Sparkle docs at sparkle-project.org (repo `sparkle-project/sparkle-project.github.io` @ `6524f21`), Sparkle source at tag
[`2.10.1`](https://github.com/sparkle-project/Sparkle/tree/2.10.1) (branch `2.x` @ `14fdbf2`), Apple's notarization docs, GitHub's
release docs. Source links below point at the `2.10.1` tag. Where these notes say "source", the claim was checked in the code, not
only in the docs.

Facts about Codiclens used below (checked 2026-11-02): `LSUIElement = YES`, not sandboxed (`ENABLE_APP_SANDBOX = NO`), hardened
runtime on, `MACOSX_DEPLOYMENT_TARGET = 26.4`, bundle id `com.codiclens`, team `L256GR2793`. The installed 1.0 is Developer ID
signed, `CFBundleVersion = 1`, about 16 MB, and still **universal** (`x86_64 arm64`).

## Recommendations at a glance

| Question | Recommendation |
|---|---|
| Sparkle version | **2.10.1** (2026-10-25), SPM, "Up to Next Major". Tahoe UI arrived in 2.8.0; 2.9 adds signed feeds and markdown. |
| Where the appcast lives | Built by the release script with `generate_appcast`, uploaded as asset `appcast.xml` on each GitHub release. `SUFeedURL = https://codiclens.codicstack.com/appcast.xml`, a site route that proxies `releases/latest/download/appcast.xml` byte for byte. |
| Notes for several versions | Sparkle only shows **one** item's notes (the newest one it offers). So the release script embeds *cumulative* HTML notes in the newest item, one `<section data-sparkle-version="…">` per release, and CSS hides the installed version and older. |
| `releaseNotesLink` vs `description` | Embedded `<description>` (HTML). No extra request, and it is covered by the feed signature. `fullReleaseNotesLink` points at `https://codiclens.codicstack.com/releases`. |
| Appcast history | Keep the `generate_appcast` default (3 items). The dialog does not need older items. |
| EdDSA key | `generate_keys --account codiclens` once, on the release Mac. The key stays in the login Keychain. Export it once with `-x` into the password manager, then delete the file. |
| Key loss | Recoverable: ship the next update signed with a new key. Old installs accept it through the Developer ID-signed DMG fallback. With a signed feed they wait up to 20 days and see no notes for that one update. Losing the key *and* the Developer ID at once is not recoverable in-app. |
| Hardening | `SUVerifyUpdateBeforeExtraction = YES` and `SURequireSignedFeed = YES`. |
| Signing Sparkle's helpers | Let `xcodebuild -exportArchive` (method `developer-id`) do it. No `--deep`. Don't enable any XPC service (we're not sandboxed). Leave the services in the framework. |
| Notarization | Round 1: app (Xcode's notarized export, already in use), stapled. Round 2: signed DMG via `notarytool`, stapled. Run `generate_appcast` **after** stapling the DMG. |
| Delta updates | No. `--maximum-deltas 0`. |
| Archive format | The same DMG users download: APFS, lzfse (`ULFO`), Developer ID signed, notarized and stapled, with no license agreement and no password. |
| What a check sends | One GET of the appcast to Vercel, with IP, `User-Agent: Codiclens/<version> Sparkle/2.10.1` and stock HTTP headers. No query string, no IDs. A download is one GET to GitHub with the same UA. Details [below](#5-what-an-update-check-sends-and-to-whom). |

## 1. Where the appcast lives, and how several versions' notes appear

### What Sparkle actually shows

The ticket assumes a feed holding several items is what gives "notes for several versions". It doesn't. Sparkle picks one item,
the best update for this install, and shows only that item's notes:

- The update driver downloads `updateItem.releaseNotesURL` for that single item
  ([`SPUUpdateDriver.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUpdateDriver.m), `_releaseNotesDriver`).
- If the item has no `releaseNotesLink`, the alert loads that item's `<description>` instead
  ([`SUUpdateAlert.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUUpdateAlert.m):
  "If there's no release notes URL, just stick the contents of the description into the release notes view").

So a feed holding only the newest item and a feed holding twenty give the same dialog. To show "what changed since *your*
version", the newest item's notes must hold every recent version. Sparkle has a feature for exactly this:

> "When displaying HTML release notes, Sparkle 2.5 and later automatically adds a `sparkle-installed-version` class to certain
> elements, based on the user's currently installed app version. [...] Sparkle looks for elements with a `sparkle-version` data
> attribute whose value exactly matches the installed app's `CFBundleVersion`."
> ([Publishing: adapting HTML release notes](https://sparkle-project.org/documentation/publishing/#adapting-release-notes-based-on-currently-installed-version))

The source confirms this works for embedded HTML too. `SUWKWebView` gets `installedVersion:_host.version` and injects the
class-adding user script whatever HTML it loads
([`SUWKWebView.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUWKWebView.m), `makeUserScriptForExposingCurrentRelease`).
The one exception is the Downloader XPC service's legacy WebView, which we won't use. The version string may contain only
`[a-zA-Z0-9._- ]`.

Markdown notes (`sparkle:format="markdown"`, 2.9+) don't get this class. Trimming them needs delegate code
(`standardUserDriverWillShowReleaseNotesText:…`). **Use HTML.**

### Recommended notes shape

The release script builds one HTML fragment per release. It holds the newest N releases (say 10), newest first, each from its
GitHub release body. `gh api markdown -f mode=gfm -f text=…` renders GitHub's markdown, so no extra dependency is needed:

```html
<style>
  .sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }
</style>
<section data-sparkle-version="1.3.0"><h2>Codiclens 1.3.0</h2>…</section>
<section data-sparkle-version="1.2.1"><h2>Codiclens 1.2.1</h2>…</section>
<section data-sparkle-version="1.2.0"><h2>Codiclens 1.2.0</h2>…</section>
```

A user on 1.2.0 sees 1.3.0 and 1.2.1. A user whose version isn't in the list sees all of it.

`data-sparkle-version` must equal the **`CFBundleVersion`** of the installed build. The simplest rule is for the release script to
set `CFBundleVersion` to the semver itself (`1.3.0`). That is a valid bundle version, Sparkle compares it correctly, and the
script can map every past tag to its build number without stored state. If a separate counter is preferred, the script must
record it somewhere it can read back later (for example a hidden `<!-- build: 42 -->` line in each release body). **Recommend
`CFBundleVersion = X.Y.Z`.**

Embed the fragment, not a link. Put `Codiclens-1.3.0.html` next to `Codiclens-1.3.0.dmg` and `generate_appcast` uses it. It
embeds HTML automatically when the file has no `DOCTYPE` or `body`; `--embed-release-notes` forces it
([`generate_appcast/main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_appcast/main.swift)). Embedding
means no second request, and the notes are covered by the feed signature (section 3). With a signed feed, Sparkle also blocks
external references in the notes view: `allowsLoadingExternalReferences` is true only when signing validation is *skipped*
([`SUUpdateAlert.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUUpdateAlert.m)). So keep the notes
self-contained: no remote images or fonts.

Also pass `--full-release-notes-url https://codiclens.codicstack.com/releases`. `sparkle:fullReleaseNotesLink` is what the
"you're up to date" alert offers as version history
([Publishing: full release notes](https://sparkle-project.org/documentation/publishing/#full-release-notes)). Pass
`--link https://codiclens.codicstack.com` too, for the "visit website" fallback.

### Appcast history

`generate_appcast` reads the existing feed in the folder, keeps existing items (even when their archives aren't local), and
trims to `--maximum-versions` per branch. The default is 3, and `0` keeps everything
([`main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_appcast/main.swift) `DEFAULT_MAX_VERSIONS_PER_BRANCH_IN_FEED = 3`;
[`Appcast.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_appcast/Appcast.swift)). Older items only matter
for branches (a different minimum OS, say). Each item carries its own cumulative notes, so long histories just bloat the feed.
**Keep the default.**

The release script's appcast step, in order:

1. `gh release download --pattern appcast.xml` from the current latest release into an empty `updates/` folder. Skip this on the
   very first release.
2. Copy in the final, stapled `Codiclens-X.Y.Z.dmg` and `Codiclens-X.Y.Z.html`.
3. Run `generate_appcast --account codiclens --download-url-prefix https://github.com/CodicStack/codiclens/releases/download/vX.Y.Z/ --full-release-notes-url … --link … --maximum-deltas 0 updates/`.
   The prefix applies only to new items, and old items keep their URLs. `generate_appcast` fills in `sparkle:minimumSystemVersion`
   from `LSMinimumSystemVersion` (26.4). It adds `sparkle:hardwareRequirements arm64` by itself only when the binary is arm64-only
   ([`ArchiveItem.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_appcast/ArchiveItem.swift)). Today's
   binary is universal, so that only kicks in once the Apple-silicon-only build lands.
4. Create the GitHub release as a **draft**, upload the DMG and `appcast.xml`, then publish. `releases/latest` only flips when the
   release is published, so no client ever sees a feed whose DMG isn't uploaded yet. GitHub: "The latest release is the most
   recent non-prerelease, non-draft release", and `make_latest` "Defaults to true for newly published releases"
   ([REST: releases](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)).

### Where the feed URL points

`SUFeedURL` is baked into every build that ships. Changing it later takes a transition release, and the old builds out there keep
asking the old URL. The options:

| Option | Verdict |
|---|---|
| A. `SUFeedURL = https://github.com/CodicStack/codiclens/releases/latest/download/appcast.xml` (GitHub documents this pattern: "`/releases/latest/download/asset-name.zip`", [Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)) | Works, and it shows multi-version notes just as well (see above). But it ties every install forever to the org and repo name, and every check goes to GitHub with the user's IP. |
| B. Site route that *builds* the feed from the GitHub Releases API | **No.** The feed needs `sparkle:edSignature` and `length` for each archive, and a signed feed needs a signature over the whole file. Both need the private key, which must never be on Vercel. The release script would have to publish signatures for the site to copy, which moves the hard part without removing it. It also adds GitHub API rate limits and site deploys to the update path. |
| **C. Site route that *proxies* the release asset** | **Recommended.** `SUFeedURL = https://codiclens.codicstack.com/appcast.xml`. A Next.js route handler (`src/app/appcast.xml/route.ts`, same pattern as the existing `sitemap.xml/route.ts`) fetches `…/releases/latest/download/appcast.xml` server-side and returns the bytes **unchanged**, or the signature breaks. Headers: `Content-Type: application/rss+xml`, `Cache-Control: public, s-maxage=300, stale-while-revalidate=3600`. Pass `ETag` and `Last-Modified` through so revalidations can get 304s. The domain is ours forever, GitHub still hosts the bytes, the site holds no secrets, and GitHub never sees a checking user's IP. |

Sparkle follows redirects for the feed. It sets no redirect delegate on the session, and `NSURLSession` follows by default. So
option A's 302 to `release-assets.githubusercontent.com` works, and so would a redirect from the site. A proxy is still better
than a redirect, for the privacy reason above. Keep `/appcast.xml` out of any analytics middleware matcher. A route handler isn't
counted by Vercel Analytics or PostHog in any case.

## 2. EdDSA keys

Setup ([Documentation: EdDSA signatures](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures)):

- Run `bin/generate_keys --account codiclens` once on the release Mac. Sparkle says: "We recommend using different accounts for
  different organizations" ([`generate_keys/main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_keys/main.swift)).
  It stores a generic-password item (service `https://sparkle-project.org`, label "Private key for signing Sparkle updates") in
  the **login Keychain**. The item is not marked synchronizable, so it does **not** go to iCloud Keychain. `generate_keys -p`
  reprints the public key.
- Put the printed public key in `SUPublicEDKey` (Info.plist). It's public and fine to commit.
- `generate_appcast` and `sign_update` then need `--account codiclens`. CI could later pipe the key in with
  `--ed-key-file -` from a secret. Not needed now, since releases run locally.

Backup: Sparkle warns the keys "will be erased if your keychain or system is erased. You can use the `-x private-key-file` and
`-f private-key-file` options to export and import the keys." **Do this once:** `generate_keys --account codiclens -x
sparkle-codiclens.key`, store the contents as a secret note in the password manager, and delete the file. Never put it in the
repo, on Vercel, or in GitHub secrets unless releases move to CI. Restore on a new Mac with `-f`.

If the key is lost
([Documentation: rotating signing keys](https://sparkle-project.org/documentation/#rotating-signing-keys)):

> "if you both code-sign your application with Apple's Developer ID program and include a public EdDSA key for signing your update
> archive, Sparkle allows rotating keys by issuing a new update that changes either your Apple code signing certificate or your
> EdDSA keys (but not both). For applications that opt into enabling SUVerifyUpdateBeforeExtraction, changing your EdDSA keys can
> only be done if the update archive is a Developer ID code signed disk image (dmg)."

In the source, when EdDSA validation fails, the validator falls back to checking that the archive is Developer ID signed by the
same team as the host. It then requires the new app's key to verify the archive, so the following update works with the new key
([`SUUpdateValidator.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUUpdateValidator.m)).

Recovery steps: make a new key, put the new `SUPublicEDKey` in the next build, sign it with the new key, and ship it as the usual
Developer ID-signed DMG. With `SURequireSignedFeed`, old installs reject the newly signed feed until
`SUSignedFeedFailureExpirationInterval` (default 1728000 s, 20 days) has passed since the first failure. After that they offer the
update anyway, without notes ([Customization: security settings](https://sparkle-project.org/documentation/customization/#security-settings)).
So the worst case is a 20-day delay and one update without notes. Renewing the Developer ID certificate is not a "change" here.
Our designated requirement pins the team (`certificate leaf[subject.OU] = L256GR2793`, checked with `codesign -d -r-`), not the
certificate. If the EdDSA key and the team are lost together, in-app updates stop and users must re-download from the site.

If the key **leaks**: that is worse than losing it. The rotation rule means a holder of the key could sign an archive made with a
*different* Developer ID. They would still need to control the feed (GitHub or Vercel). With a signed feed, controlling the feed
alone isn't enough. Rotate at once, the same way as after a loss.

## 3. Signing and notarizing Sparkle inside a non-sandboxed Developer ID app

What ships inside `Sparkle.framework/Versions/B/`: `Autoupdate`, `Updater.app`, and `XPCServices/Installer.xpc` and
`Downloader.xpc` ([Sandboxing: code signing](https://sparkle-project.org/documentation/sandboxing/#code-signing)).

- **Don't enable the XPC services.** They exist for sandboxed apps. `SUEnableInstallerLauncherService`: "Do not enable this XPC
  Service if your application is not sandboxed" ([Customization: sandboxing settings](https://sparkle-project.org/documentation/customization/#sandboxing-settings)).
  Skip the sandbox entitlements as well.
- **Leave the services in the bundle.** Removing them is optional ("to save space") and needs a build-phase script plus a
  re-sign ([Sandboxing: removing XPC services](https://sparkle-project.org/documentation/sandboxing/#removing-xpc-services)). It
  isn't worth a moving part for a few hundred KB.
- **Let Xcode's export sign everything.** "Using Xcode's Archive Organizer will ensure Sparkle's helper tools are code signed
  properly for distribution. In automated environments, this process can be done using `xcodebuild archive` and
  `xcodebuild -exportArchive`" ([Documentation: distributing your app](https://sparkle-project.org/documentation/#4-distributing-your-app)).
  On export, Xcode "does re-sign these services and helpers, preserves the Hardened Runtime, and strips
  `com.apple.security.get-task-allow` entitlements". A plain "Code Sign on Copy" does *not* re-sign the helpers. This is the
  `archive` → `-exportArchive` (method `developer-id`) flow Codiclens already uses.
- **No `--deep`.** "please do not add `--deep` to `OTHER_CODE_SIGN_FLAGS` or from custom build scripts when signing your
  application."
- If a manual re-sign is ever needed, Sparkle's documented order, inside-out, each with `-o runtime`, is: `Installer.xpc`,
  `Downloader.xpc` (with `--preserve-metadata=entitlements`), `Autoupdate`, `Updater.app`, then `Sparkle.framework`. Add
  `--timestamp` for notarization.
- **Verify in the release script:** `codesign --verify --deep --strict --verbose=2 Codiclens.app`, plus `codesign -dvv` on each
  of the four helpers (expect `Authority=Developer ID Application: … (L256GR2793)`, `flags=…(runtime)`, and a `Timestamp=`). Then
  `spctl -a -t exec -vv Codiclens.app` and `spctl -a -t open --context context:primary-signature -vv Codiclens-X.Y.Z.dmg`.
- Debug builds: library validation can refuse to load Sparkle into an ad-hoc-signed app. Sign Debug with Apple Development (as
  now) ([Documentation: step 1](https://sparkle-project.org/documentation/#1-add-the-sparkle-framework-to-your-project)).

Notarization (Apple, [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)):

- "The notary service generates a ticket for the top-level file that you specify, as well as for each nested file." So
  notarizing the DMG covers the app inside it too.
- Stapling: "To attach a ticket to your app, bundle, disk image, or flat installer package, use the `stapler` tool". "While you
  can notarize a ZIP archive, you can't staple to it directly."
- Without a stapled ticket, Gatekeeper "finds the ticket online". Stapling "ensures that Gatekeeper can find the ticket even when a
  network connection isn't available."

**Recommended order** (two rounds, a minute or two each):

1. `xcodebuild archive`, then `-exportArchive` / `-exportNotarizedApp` (Xcode notarizes **and staples the app**; this works today).
2. `hdiutil create -fs APFS -format ULFO -srcfolder <dir with Codiclens.app + /Applications symlink> Codiclens-X.Y.Z.dmg`.
3. `codesign -s "Developer ID Application: … (L256GR2793)" --timestamp Codiclens-X.Y.Z.dmg`. A signed DMG is required for key
   rotation (section 2).
4. `xcrun notarytool submit Codiclens-X.Y.Z.dmg --keychain-profile codiclens-profile --wait`, then `xcrun stapler staple` on the
   DMG. The profile doesn't exist yet: the release-script ticket must run `notarytool store-credentials` once.
5. **Then** `generate_appcast`. Stapling changes the DMG's bytes, so the EdDSA signature and `length` must be computed over the
   final file.

Why staple the app too: whether it is dragged out of the DMG or extracted by Sparkle, the app then carries its own ticket for
offline first launch. Sparkle removes quarantine from the bundle it installs
([`SUPlainInstaller.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Autoupdate/SUPlainInstaller.m) "Release our new app
from quarantine"). A stapled ticket still costs nothing.

## 4. Delta updates and archive format

**Delta updates: no.** Deltas save bandwidth on large apps ([Delta updates](https://sparkle-project.org/documentation/delta-updates/)).
Codiclens is about 16 MB, and the DMG is smaller. Deltas would need the old archives kept locally for `generate_appcast` to diff
against, plus one extra `.delta` asset per previous version on every GitHub release. Sparkle falls back to the full archive if a
delta fails anyway. Pass `--maximum-deltas 0` so it's explicit. Revisit only if the bundle grows past about 100 MB (for example by
bundling a model).

**Archive: the same DMG users download.** Sparkle supports dmg, zip, tar and aar ([Publishing](https://sparkle-project.org/documentation/publishing/)).
DMG wins here for four reasons:

- One artifact, one notarization, one upload.
- It can be stapled, and a zip can't.
- A Developer ID-signed DMG is the *only* archive that allows EdDSA key rotation once `SUVerifyUpdateBeforeExtraction` is on.
- Sparkle's docs recommend it: "APFS formatted images that use lzfse compression are recommended for decent decompression speed".
  That is `-fs APFS -format ULFO`. Apple: "Avoid heavily compressed disk images."

Don't add a license agreement or a password to the DMG. The app inside must keep the name `Codiclens.app` ("Put a copy of your
.app (with the same name as the version it's replacing)"). Zip's only advantage is faster extraction, which doesn't matter at
16 MB.

## 5. What an update check sends and to whom

This section feeds the privacy policy. It assumes the setup above: system profiling off (the default), no `feedParameters`
delegate, notes embedded, feed proxied by the site.

**When.** By default automatic checks are off until Sparkle asks on the **second** launch. If the user agrees, it checks once per
`SUScheduledCheckInterval`, which defaults to 86400 s (24 h) with a 1-hour minimum. Manual "Check for Updates…" checks run on
demand. The prompt also offers automatic download ([Customization](https://sparkle-project.org/documentation/customization/):
`SUEnableAutomaticChecks`, `SUScheduledCheckInterval`). **Recommend keeping the default prompt.** Don't set
`SUEnableAutomaticChecks`.

**Request 1, the update check** (always):

- `GET https://codiclens.codicstack.com/appcast.xml`, no query string. Sparkle appends parameters only for system profiling or a
  delegate, and we use neither ([`SPUUpdater.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUpdater.m) `parameterizedFeedURL`).
- `User-Agent: Codiclens/<CFBundleShortVersionString> Sparkle/2.10.1`
  ([`SPUUserAgent+Private.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUserAgent%2BPrivate.m),
  `SUHost.displayVersion`).
- `Accept: application/rss+xml,*/*;q=0.1`, plus `NSURLSession`'s stock headers (`Accept-Language`, `Accept-Encoding`).
  Background checks may send `If-None-Match` / `If-Modified-Since` to revalidate the cached feed
  ([`SUAppcastDriver.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUAppcastDriver.m)). Those carry the
  feed's ETag, which is the same for everyone.
- Received by **Vercel** (the site's host), which sees the IP address and the headers above. Vercel then fetches the asset from
  GitHub itself, so GitHub sees Vercel, not the user.

**Request 2, the download** (only when an update exists and the user installs it, or automatic download is on):

- `GET https://github.com/CodicStack/codiclens/releases/download/vX.Y.Z/Codiclens-X.Y.Z.dmg`, which redirects to
  `release-assets.githubusercontent.com`, with the same User-Agent.
- Received by **GitHub**, which sees the IP and headers. GitHub counts it in the asset's public `download_count`, an aggregate
  number with no personal data.

**Not sent:**

- No release-notes request: the notes are embedded, and a signed feed blocks external references in the notes view.
- No system profile. `SUEnableSystemProfiling` defaults to `NO`. Even when on, it would send OS version, CPU, model, RAM, app
  name and version, and language, at most once a week ([System profiling](https://sparkle-project.org/documentation/system-profiling/)).
  We leave it off.
- No identifiers. The phased-rollout group ID `SUUpdateGroupIdentifier` "is not transmitted to servers"
  ([Publishing: phased rollouts](https://sparkle-project.org/documentation/publishing/#phased-group-rollouts)). We don't use
  phased rollouts in any case.
- No cookies, since neither host sets any on these responses.

**Stored locally** in the app's user defaults (`com.codiclens`): `SULastCheckTime`, `SUEnableAutomaticChecks`,
`SUAutomaticallyUpdate`, `SUSkippedVersion` and related keys, `SUHasLaunchedBefore`
([`SUConstants.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUConstants.m)).

**Outside Sparkle:** macOS's own Gatekeeper may contact Apple about the notarization ticket the first time the updated app opens.
That is OS behavior, and the stapled ticket makes it unnecessary.

Suggested privacy-policy wording: *"If you allow it, Codiclens checks for updates once a day by downloading a small file from
codiclens.codicstack.com (hosted by Vercel). The request includes your IP address and the app's name and version, nothing else.
When you install an update, it is downloaded from GitHub, which also sees your IP address."*

## 6. Swift Package setup and minimum version

Versions ([CHANGELOG](https://github.com/sparkle-project/Sparkle/blob/2.10.1/CHANGELOG)):

| Version | What it brings |
|---|---|
| 2.7.1 | "Fix release notes constraints when compiled with macOS 26 SDK" |
| 2.7.3 | `SUVerifyUpdateBeforeExtraction` |
| 2.8.0 (2025-09-16) | "UI modernization and macOS Tahoe support": modernized update alert and release notes UI, Tahoe app icon fix |
| 2.9.0 | Signed feeds, markdown notes, `sparkle:hardwareRequirements`, Xcode 26.4 warning fixes |
| 2.10.0 | Minimum deployment target raised to macOS 12, CocoaPods support dropped |
| 2.10.1 (2026-10-25) | Current latest |

The README asks for "Latest major Xcode (stable or beta, whichever is latest) and one major version less". Xcode 26.4.1 fits.
**Minimum for macOS 26: 2.8.0. Minimum for this plan: 2.9.0, for signed feeds. Use 2.10.1.**

Setup ([Documentation: step 1](https://sparkle-project.org/documentation/#1-add-the-sparkle-framework-to-your-project);
[`Package.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Package.swift) is a binary target:
`Sparkle-for-Swift-Package-Manager.zip` with a checksum):

1. Xcode: File › Add Package Dependencies…, enter `https://github.com/sparkle-project/Sparkle`, choose "Up to Next Major Version"
   from 2.10.1, and add the `Sparkle` product to the `codiclens` target. Commit `Package.resolved`.
2. Info.plist keys go in `codiclens-Info.plist`, the file merged into the generated one (`INFOPLIST_KEY_*` only covers Apple's
   keys):
   - `SUFeedURL` = `https://codiclens.codicstack.com/appcast.xml`
   - `SUPublicEDKey` = the output of `generate_keys`
   - `SUVerifyUpdateBeforeExtraction` = `YES`
   - `SURequireSignedFeed` = `YES`

   Leave out `SUEnableAutomaticChecks` (keep the second-launch prompt), `SUEnableSystemProfiling`, and all `SUEnable*Service`
   keys.
3. Code ([Programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/)): keep one
   `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)` alive for the app's
   lifetime. Add a "Check for Updates…" item that calls `checkForUpdates(_:)`, enabled from `updater.canCheckForUpdates`. Add
   Settings toggles bound to `updater.automaticallyChecksForUpdates` and `updater.automaticallyDownloadsUpdates`
   ([Preferences UI](https://sparkle-project.org/documentation/preferences-ui/)). Don't start the updater in Debug
   (`startingUpdater: false` under `#if DEBUG`), so dev builds (`com.codiclens.debug`) never check.
4. **`LSUIElement` matters.** For dockless apps, Sparkle "will not let a scheduled update alert steal focus from another
   application or window that may be currently active -- with the one exception of when your application just launched", and
   "Background (dockless) running apps may receive a log warning about scheduling update checks and not implementing gentle
   reminders. At minimum, this method needs to be implemented" ([Gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/)).
   So implement `supportsGentleScheduledUpdateReminders` returning `true`. Optionally, show an "Update available" mark in
   Codiclens's own UI from `standardUserDriverWillHandleShowingUpdate`. That suits the never-steal-focus spirit.
5. Release tooling: Xcode puts the tools in `…/SourcePackages/artifacts/sparkle/Sparkle/bin/`. For a reproducible script, download
   the pinned `Sparkle-2.10.1.tar.xz` release asset instead (version-matched to the package) and use its `bin/generate_appcast`,
   `sign_update` and `generate_keys`.

What the stock dialog gives us with this setup (from [`SUUpdateAlert.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUUpdateAlert.m)):

- The notes box: on by default, `SUShowReleaseNotes = YES`.
- The "Automatically download and install updates in the future" checkbox, shown while `allowsAutomaticUpdates` is true. That is
  the default once automatic checks are allowed.
- The Skip This Version, Remind Me Later and Install Update buttons. Skip and Later are hidden for critical updates. Later is also
  hidden while automatic checks are off ("Reminding user later doesn't make sense when automatic update checks are off"), so
  users who decline the second-launch prompt see no Remind Me Later. For a downloaded update, Later reads "Install on Quit".

## Notes for build tickets

- **Release script:** set `CFBundleVersion = X.Y.Z`, the notes HTML, the two-round notarization, `generate_appcast` after
  stapling, then draft, upload and publish. It also needs a one-time `notarytool store-credentials` and `generate_keys` plus a
  password-manager backup.
- **Site:** add the `appcast.xml` route handler (proxy, unchanged bytes, ETag passthrough, 5-minute edge cache). The `/releases`
  page is the `fullReleaseNotesLink` target. The privacy page gets the wording above.
- **App:** the SPM dependency, Info.plist keys, the updater controller, gentle-reminder support, the menu item and Settings
  toggles. The first Sparkle build must have `CFBundleVersion` > `1` to be offered over the current install. That doesn't matter
  for the user's own install, which gets one manual swap.
- Decide alongside the Apple-silicon-only build ticket: once the binary is arm64-only, `generate_appcast` adds
  `sparkle:hardwareRequirements arm64` by itself.
