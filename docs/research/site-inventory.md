# Codictate site inventory for the Codiclens site

Research for [#7](https://github.com/CodicStack/codiclens/issues/7), part of the 1.0 map [#2](https://github.com/CodicStack/codiclens/issues/2).

**Source:** the local checkout `codictate-project/codicate-releases` (remote `EmilLykke/codictate-releases`, private), read at commit `f894b16`. File paths below are relative to that repo unless they say otherwise. Every keep/adapt/drop call comes from reading the file and its import graph. The graph was built by grepping `@/<path>` imports across `src/`, leaving tests out.

**Standing decisions this inventory follows (from #2):** new repo `CodicStack/codiclens-site`, hosted on Vercel at `codiclens.codicstack.com` with DNS on Cloudflare. Keep home, releases, privacy, terms and support. Drop benchmarks, blog, iOS and models. Keep PostHog and Vercel Analytics. Feedback goes to GitHub Issues with no support-form backend. Stable channel only. Apple Silicon only. The home page gets a demo video slot.

**Codiclens facts used here** (from the `codiclens` repo): the app sets `INFOPLIST_KEY_LSUIElement = YES` (`codiclens.xcodeproj/project.pbxproj:343,398`), so it has no Dock icon. No `NSStatusItem` appears in `codiclens/`, so it has no menu bar item either. It is summoned by a hotkey into a floating Panel (`GLOSSARY.md`). The current deployment target is `MACOSX_DEPLOYMENT_TARGET = 26.4`; the real minimum is still waiting on #3. Releases will live on `CodicStack/codiclens`, which is **private** today (`gh repo view`).

---

## Summary

| Verdict | Count | What |
| --- | --- | --- |
| Keep as-is | 15 | `(main)/layout.tsx`, `providers.tsx`, `globals.css`, `JsonLd`, `PageHeader`, `MarkdownReleaseNotes` (plus its lightbox and `prose.css`), `Theme` (one-line key rename only), `lib/client/use-hydrated`, `styles/theme.css`, `styles/README.md`, `eslint.config.mjs`, `postcss.config.mjs`, `tsconfig.json`, `AGENTS.md`, glass and tray chrome art in `public/images` |
| Adapt | 34 | home page, releases (page and interactive), support page, privacy, terms, not-found, root layout, `llms.txt`, sitemap, robots, `icon.png`, `MainHeader`, `MainFooter`, `Brand`, `HeroDownload`, `HeroStage`, `GetStartedCta`, `GitHubStarsBadge`, `Glass`, `ValuePropSection`, `VideoFacade`, `PostHogProvider`, `InstallGuide` with `data/install-phases` (optional), `lib/analytics`, `get-all-releases`, `get-latest-release`, `get-star-count`, `repo-urls`, `site-url`, `og-image`, `styles/base.css`, `next.config.ts`, `package.json`, `CLAUDE.md` |
| Drop | 36 | 9 routes and files (`about` (recommended; see Open questions), `benchmarks/*`, `blog/*`, `ios`, `models/*`, `staging/benchmarks-v2`, `support-form.tsx`, `api/issues`, `glass-example.html`). 15 component folders (the 9 bench-only ones, `AppStoreButton`, `BenchmarksSection`, `CapabilitiesSection`, `DictionarySection`, `NativeShowcase`, `InstallSectionLinks`). 4 lib modules (`benchmark-results`, `blog`, `is-canary-release`, `nav-download-for-user-agent`). 8 more: `scripts/`, `_benchmarks/`, `_posts/`, `public/brand`, `public/blog`, `public/install`, Next starter SVGs, the `blog-writing-guide` skill |

The counts are headline items, with a folder counting as one. Small rows in the tables (the OG image file, lockfiles, `.env.example`, README, single public images) are left out of the counts.

**The big couplings, in short:**

1. **Benchmarks and blog are wired into shared code, not just their own routes.** The home page, `sitemap.xml`, `llms.txt`, header, footer, `not-found.tsx`, the about page and `next.config.ts` all import from or link to them. Every `*.test.ts` in the repo is benchmark code. Details in [Coupling: deleting benchmarks, blog, models, iOS](#coupling-deleting-benchmarks-blog-models-ios).
2. **The root layout calls `headers()` for User-Agent sniffing.** It does this to choose a Mac or Windows download, and it makes every route dynamic. A Mac-only site doesn't need it.
3. **Windows and canary logic is spread through `lib/github-releases`, the releases page, `HeroDownload`, `GetStartedCta` and the header.**
4. **The App Store link is in `repo-urls.ts`, `AppStoreButton` (used by the hero and the closing CTA), the footer and the JSON-LD.**
5. **`CapabilitiesSection` is commented out on the home page but cannot be deleted whole.** `HeroStage`, `DictionarySection` and `NativeShowcase` import its `desktop.ts` and `CapabilitiesOrbDisplay.tsx`.
6. **The repo owner `EmilLykke/codictate` is hard-coded five times outside `repo-urls.ts`.**
7. **The current privacy page says "no analytics"** and does not mention the site's own PostHog and Vercel Analytics. #2 requires the Codiclens one to disclose both.
8. **While `CodicStack/codiclens` is private, the site cannot serve downloads.** The API needs a token, and `browser_download_url` 404s for anonymous visitors.

---

## Routes: `src/app/(main)/`

| Route | File(s) | Verdict | Notes |
| --- | --- | --- | --- |
| `/` | `page.tsx` | **Adapt** | Section outline under [Home page structure](#home-page-structure). Remove the `BenchmarksSection`, `DictionarySection` and `NativeShowcase` imports and the commented `CapabilitiesSection` import. Remove `headers()` and `inferDesktopOsFromUserAgent`. Remove the hard-coded `REPO_URL` and `KOFI_URL` (lines 45-46) and the Codictate YouTube default `DEMO_VIDEO_EMBED_DEFAULT` (line 49). New JSON-LD (see [JSON-LD](#json-ld-softwareapplication)). Keep `revalidate = 300`. |
| `/releases` | `releases/page.tsx`, `releases/releases-interactive.tsx` | **Adapt** | Remove the canary handling: `versionLabel` strips `-canary`, plus `canaryIteration`, `releaseChannel` "canary", the stable-twin body dedupe (`stableBodyByVersion`), and the `pickInstaller` `canary-`/`stable-` filename prefix. Remove `isWindowsInstaller` and the Windows button. Keep `.dmg` only. Sparkle's `appcast.xml`, `.zip` and `.delta` assets are already hidden, because only `.dmg`/`.exe`/Windows `.zip` names are surfaced. `ReleaseChannelBrowser` already hides its filter row when only one channel has releases (`filters.length > 1`), so with stable only it collapses on its own. It can be deleted for simplicity. Cards have no per-version anchor (only `release-notes-<numeric id>`). Add `id={tagName}` if Sparkle's release-notes link should deep-link here (#4/#9 decide). Retitle the metadata from "Codictate Releases and Changelog (Mac, Windows)". |
| `/support` | `support/page.tsx` | **Adapt** | Make it a static page that links to GitHub Issues on `CodicStack/codiclens`: new bug, feature and question (issue templates are #12's job). Say what to include: macOS version, Codiclens version, Mac model. The current lede, "lands directly in the GitHub tracker, no account needed", is no longer true because GitHub needs an account. Rewrite it. |
| `/support` form | `support/support-form.tsx` (676 lines) | **Drop** | Posts to `/api/issues`. #2 says no backend. It is also the only user of `motion` outside the dropped mocks. |
| `/privacy` | `privacy/page.tsx` | **Adapt (rewrite)** | Keep the layout (the `Article` helper, `PageHeader`). Every word of the copy is Codictate's: audio, Whisper and Parakeet, "no analytics". It never mentions the site's PostHog and Vercel Analytics. The Codiclens text waits on #4 (what a Sparkle check sends) and #5 (what the model download fetches). It must cover the site's PostHog (EU, proxied, see below) and Vercel Web Analytics. The contact is `mailto:emillykkeg@gmail.com`. |
| `/terms` | `terms/page.tsx` | **Adapt** | Same structure. Change the product name. Rewrite "On-device processing". Rewrite "Third-party components", which currently names OpenAI Whisper and NVIDIA Parakeet; for Codiclens it should list the meaning-search model, Sparkle and other vendored code per #5. Same contact email. |
| `/about` | `about/page.tsx` | **Drop (recommended)** | Not in #2's keep list. Its four articles are Codictate's story, and it links `/models`, `/ios`, `/blog/nvidia-parakeet-tdt-v3` and `/benchmarks`, all dropped. The header and footer link to it. See Open questions. |
| `/benchmarks`, `/benchmarks/[slug]`, `/benchmarks/methodology` | `benchmarks/**` | **Drop** | See the coupling section. |
| `/blog`, `/blog/[slug]` | `blog/**` (including `blog/layout.tsx`) | **Drop** | |
| `/ios` | `ios/page.tsx` | **Drop** | Has its own JSON-LD and the `ios_page` analytics surface. |
| `/models`, `/models/[slug]` | `models/**` | **Drop** | |
| `/staging/benchmarks-v2` | `staging/benchmarks-v2/page.tsx` | **Drop** | Gated by `CODICTATE_BENCHMARK_V2_STAGING`. |
| layout | `(main)/layout.tsx` | **Keep** | Children plus `MainFooter`. |

## Routes and files: `src/app/`

| File | Verdict | Notes |
| --- | --- | --- |
| `layout.tsx` | **Adapt** | `metadataBase: new URL("https://codictate.app")` is hard-coded; use `SITE_URL`. The title, description and 16 keywords all say "Mac & Windows", "iPhone", "dictation". Drop the Iceland and Iceberg fonts unless the new wordmark uses them; keep Inter and Inter Tight. **Remove `headers()` and the UA download picking** (`inferDesktopOsFromUserAgent`, `pickNavPrimaryDownloadForOs`, `releaseDownloadUrls` with `winSetupZipUrl`/`winExeUrl`). The `headers` docs say a Request-time API "will opt a route into dynamic rendering" (`node_modules/next/dist/docs/01-app/03-api-reference/04-functions/headers.md:48`). In the root layout that applies to every page. Pass `MainHeader` the DMG URL. Keep `<Analytics />`, `ThemeScript`, `Providers` and `data-theme="dark"`. |
| `providers.tsx` | **Keep** | Wraps `PostHogProvider`. |
| `not-found.tsx` | **Adapt** | Links `/blog` and `/benchmarks`. Replace them with Releases and Support. |
| `robots.ts` | **Adapt** | Has its own copy of the `codictate.app` fallback. Import `SITE_URL` from `lib/site-url`. |
| `sitemap.xml/route.ts` | **Adapt** | Imports `getUniqueBenchmarkRuns`, `getModelGuides` and `getAllBlogPosts`. Home `lastmod` takes the benchmark date. Reduce it to `/`, `/releases`, `/support`, `/privacy` and `/terms`, with the `COPY_UPDATED` dates reset. Keep the `latest()` helper and the release `publishedAt` hook. |
| `llms.txt/route.ts` | **Adapt** | Has its own `FALLBACK_BASE_URL = "https://codictate.app"`. Imports the same three data readers. The whole blockquote and body are Codictate copy. Keep the `renderSection` and `oneLine` scaffolding, and rewrite the H1, summary and link lists for Codiclens. The `CLAUDE.md` "LLM discovery" section describes this file and needs the same edit. |
| `api/issues/route.ts` | **Drop** | The support backend. Uses `GITHUB_SUPPORT_TOKEN`. Its footer says "Submitted via codictate.com/support", the wrong domain even for Codictate. |
| `globals.css` | **Keep** | Imports Tailwind, `material-symbols/sharp.css`, `theme.css` and `base.css`. |
| `icon.png` | **Adapt** | The Codictate favicon. Export a PNG from `codiclens/codiclens-icon.icon` (Icon Composer format, not usable directly). |
| `glass-example.html` | **Drop** | Unreferenced markup pasted from a third party (`title="Download VoiceOS"`). |

## Components: `src/components/`

Who imports each one comes from the import graph. "Bench-only" means only benchmark pages import it.

| Folder | Imported by | Verdict | Notes |
| --- | --- | --- | --- |
| `MainHeader` | root layout | **Adapt** | `NAV_LINKS` holds `/about`, `/benchmarks`, `/support`, `/releases` and `/blog`; for Codiclens that becomes Releases and Support, and maybe GitHub. Remove the client-side UA re-pick (`pickNavPrimaryDownloadForUrls(..., navigator.userAgent)`), which is only there for Windows. The Download button always goes to the DMG, falling back to `RELEASES_URL`. Keep the `notch-bar` island, the mobile drawer, scroll lock and Esc handling. Uses `WordmarkCodictate`. |
| `MainFooter` | `(main)/layout` | **Adapt** | `REPO`, `KOFI`, `PERSONAL_SITE` and `LINKEDIN` are hard-coded. The Product column lists `/ios`, the App Store, Benchmarks, Speech models, How we measure and Blog, all dropped. The Project column has `CONTRIBUTING.md`, `SECURITY.md` and `LICENSE`; those links break unless #12 adds the files to `CodicStack/codiclens`. Change the tagline ("On-device dictation for Mac and Windows") and the copyright ("Codictate"). Consider a "Works with Codictate" link (Transcribe goes through Codictate's command line, `GLOSSARY.md:243`). |
| `Brand` (`WordmarkCodictate`) | header, footer | **Adapt** | A "C" in Iceberg plus "odictate" in Iceland, via the `.wordmark-codictate` classes in `base.css:244-256`. Codiclens needs its own wordmark. If it reuses the split-C treatment, keep both brand fonts; if not, drop them from `layout.tsx`. |
| `GitHubStarsBadge` | `MainHeader` | **Adapt** | The `aria-label` hard-codes "Codictate on GitHub". The repo comes in as a prop from `repo-urls`. Stars read `CodicStack/codiclens` through `get-star-count`. While that repo is private, an anonymous fetch returns 404 and the badge renders without a number, which is a graceful fallback. |
| `HeroDownload` | home | **Adapt** | `auto-detect` mode picks Mac or Windows and puts `AppStoreButton` beside the primary. It also has a "Also available for Windows" link. `full` mode, which home does not use, has a `brew install emillykke/tap/codictate` copy box and a Windows `alert()`; delete it, since Homebrew is out of scope in #2. For Codiclens: one "Download for Mac" button straight to the DMG, a line saying "Apple Silicon · macOS <min> or later" (min from #3), and "Latest vX.Y.Z · All releases". Intel Macs cannot be told apart by User-Agent, because Safari and Chrome report "Intel Mac OS X" on Apple Silicon too, so the Apple Silicon note has to be visible text, not detection. |
| `HeroStage` | home | **Adapt (rebuild content, keep the frame)** | The frame is reusable: a faded-mask wallpaper band (`FADE_UP`), the Dock layer and stacked strips as an in-flow grid row, a GSAP loop with scoped refs, and a static frame under reduced motion. The content is all dictation: `CapabilitiesOrbDisplay`, the Slack, Mail and Cursor composers, Danish to English text and Wispr Flow copy. For Codiclens, replace the orb and strips with a mock glass Panel (Query, then Subject, Action and Target Cards, then the Results Slab). Leave the Codiclens icon out of the mock Dock, because the app has no Dock icon. |
| `VideoFacade` (`DemoVideoSection`) | home | **Adapt** | A YouTube facade: the poster comes from `i.ytimg.com` (maxres, falling back to hq), and the iframe loads on click. `title` and `aria-label` say "Codictate demo". This is the demo slot from #2. If no URL is set, render a placeholder instead of falling back to Codictate's video. A self-hosted MP4 would need a `<video>` branch, because `youTubeVideoId()` returns null and today the panel just goes blank. |
| `GetStartedCta` | home | **Adapt** | Mac DMG and `AppStoreButton`, then Windows (with an `alert()`), "Star on GitHub" and "Support on Ko-fi". Keep Mac and Star; drop App Store and Windows. Ko-fi is the user's call. |
| `ValuePropSection` | home | **Adapt** | Three text columns; the copy is dictation-specific ("Press, speak, done", "Local and private", "Free and open source"). Swap the copy and keep the layout. |
| `Glass` (`GlassSurface`, `GlassMacDock`, `GlassMacTray`, `glass-surface.css`) | hero, dictionary, showcase, capabilities | **Adapt** | `GlassSurface` is the liquid-glass shell (an SVG displacement filter, `backdrop-filter`, `mask-composite`). It is the natural base for a mock Codiclens Panel and Slab. `GlassMacDock` lists Slack, Notes, Notion, Cursor, Firefox, **Codictate** (`/brand/mac-dock-icon.png`), Mail and cmux; remove Codictate. `GlassMacTray` holds a Codictate tray icon (`images/codictate-tray.svg`), and `glass-surface.css:152-160` has `.cdt-tray-codictate-icon` GSAP hooks; drop the tray, since Codiclens has no status item. The `cdt-` class prefix can stay. |
| `CapabilitiesSection` | `desktop.ts` and `CapabilitiesOrbDisplay.tsx` are imported by `HeroStage`, `DictionarySection` and `NativeShowcase`; `CapabilitiesSection.tsx` itself appears only as a comment on home | **Drop, but move `desktop.ts` first** | `desktop.ts` exports `DESKTOP_WALLPAPER` and `WALLPAPER_SCRIM`, which every mock desktop needs. Move it next to `Glass` before deleting the folder. `CapabilitiesOrbDisplay` (the dictation orb, uses `motion`) goes. `MockSlackWindow`, `MockMailWindow`, `MockCursorWindow` and `MockTrayDropdown` go too. |
| `DictionarySection` | home | **Drop** | Codictate's dictionary feature. Its pattern is the template for Codiclens feature sections, so copy it before deleting: a ScrollTrigger-driven mock window on the wallpaper, word-state classes injected by the timeline, and legibility with no JS. It uses `motion` via `MockDictionaryWindow` and `/blog/authors/emil.jpg` via `MockDictSlackWindow`. |
| `NativeShowcase` | home | **Drop** | "Where it sits when you are not using it": menu bar and Dock cards. Codiclens is `LSUIElement` with no status item, so there is nothing to show. |
| `BenchmarksSection` | home | **Drop** | Reads `head-to-head-by-language`. |
| `AppStoreButton` | `HeroDownload`, `GetStartedCta`, `ios` | **Drop** | |
| `InstallGuide` + `src/data/install-phases.ts` | **nothing** (orphaned) | **Adapt (optional) or drop** | A slide walkthrough (troubleshoot, permissions, ready, download, Gatekeeper) over `public/install/Step*.png`. All of it is Codictate: Input Monitoring, Microphone, `xattr -cr /Applications/Codictate.app`. If Codiclens ships notarized, the Gatekeeper `xattr` phase is unnecessary. The component (phase tabs, prev/next, copyable code block) could carry #10's install steps: drag to Applications, first-run permissions, taking ⌘Space from Spotlight. Needs new screenshots. |
| `InstallSectionLinks` | nothing (orphaned) | **Drop** | Links to `INSTALL.md`. |
| `JsonLd` | home, ios, blog post | **Keep** | Escapes `<` in the payload. |
| `PageHeader` | every subpage and the 404 | **Keep** | |
| `MarkdownReleaseNotes` (+ `MarkdownLightboxImage`, `prose.css`) | releases, blog post | **Keep** | `react-markdown` + `remark-gfm` + `rehype-raw` render GitHub release bodies. `rehype-raw` passes raw HTML through; release bodies are first-party, so that is acceptable. |
| `Providers` (`PostHogProvider`) | `providers.tsx` | **Adapt** | `api_host: '/codictate-ph'` matches the `next.config.ts` rewrites; rename both to `/codiclens-ph` or something neutral. `ui_host: 'https://eu.posthog.com'` is hard-coded, so `NEXT_PUBLIC_POSTHOG_HOST` is **never read at runtime**: it only appears in `next.config.ts` `env`. Either wire it in or drop it. `defaults: '2026-01-30'`; the key is cast `as string` with no guard, so an unset key still calls `init`. |
| `Theme` (`ThemeScript`, `ThemeToggle`, `theme-storage`) | root layout, header | **Keep (rename key)** | Dark by default, the OS preference ignored by design, a `?theme=` override for screenshots. `THEME_STORAGE_KEY = "codictate-theme"`: rename it. It is harmless either way, since a different origin gets different storage. |
| `Lightbox` (`LightboxImage`) | `benchmarks/[slug]` only | **Drop** | Release notes use their own `MarkdownLightboxImage`. |
| `AggregateGlanceTable`, `BenchmarkDetailTables`, `HeadToHeadLanguageChart`, `ModelResultsTable`, `SortableGlanceTable`, `ViewSwitch`, `Tooltip` | bench-only | **Drop** | `Tooltip` is used only by benchmark tables. |
| `ModelGuideTable` | models pages | **Drop** | |

## `src/lib/`

| Module | Verdict | Notes |
| --- | --- | --- |
| `repo-urls.ts` | **Adapt** | `GITHUB_REPO_OWNER = "EmilLykke"` becomes `"CodicStack"`, and `GITHUB_REPO_NAME` becomes `"codiclens"`. Delete `APP_STORE_URL`. Make this the single source for `REPO_URL`, which is duplicated today in `(main)/page.tsx:45`, `MainFooter.tsx:8`, `about/page.tsx`, `support-form.tsx:239`, and composed in `layout.tsx`. `KOFI_URL` is duplicated in `page.tsx` and `MainFooter`. |
| `site-url.ts` | **Adapt** | Fallback `"https://codictate.app"` becomes `"https://codiclens.codicstack.com"`. Make `robots.ts`, `llms.txt` and `layout.tsx` `metadataBase` use it; they each have their own copy today. |
| `og-image.ts` | **Adapt** | `/og-image.jpg` (1200x630, made from `public/brand/homepage-hero-2026-09.png`), and the `alt` is Codictate's hero line. Needs a new Codiclens image. Its note still applies: every page that sets `openGraph` must list the image itself, because Next merges metadata shallowly. |
| `analytics/capture-site-cta.ts` | **Adapt** | Event `site_cta_click` with a `surface` union: `"hero" \| "nav" \| "footer" \| "get_started" \| "install_section" \| "releases_page" \| "install_guide" \| "home_demo" \| "ios_page"`. Remove `ios_page` and `install_section`, and drop `install_guide` unless `InstallGuide` is revived. The action names `download_win_exe`, `download_app_store`, `copy_brew_cmd` and `support_kofi` go with their buttons. |
| `client/use-hydrated.ts` | **Keep** | Used by the header, the theme toggle and the lightboxes. |
| `github-releases/get-all-releases.ts` | **Adapt** | Generic. Paginates `/releases?per_page=100`, skips drafts and unpublished ones, keeps only uploaded assets. Change `User-Agent: "Codictate-Releases-Site"` and maybe rename the types (`CodictateRelease`). Repo comes from `repo-urls`. |
| `github-releases/get-latest-release.ts` | **Adapt** | Drop `winSetupZip`, `winExe`, `isWindowsZipFilename` and `pickZipByFilenameMatch`. Keep `dmg`, `tagName` and `publishedAt`. It skips `draft \|\| prerelease`, then canary by name. Stable only means that canary check can go, while the `prerelease` skip stays. `pickAsset(".dmg", preferStable)` prefers a filename containing "stable"; with one DMG per release it picks that one. If the release script uploads more than one `.dmg`, make the match exact (e.g. `Codiclens-<ver>.dmg`) rather than first-match. Same `User-Agent` string. |
| `github-releases/get-star-count.ts` | **Adapt** | `User-Agent` only. |
| `github-releases/is-canary-release.ts` | **Drop** | Used by `get-latest-release` and the releases page; remove those call sites too. |
| `github-releases/nav-download-for-user-agent.ts` | **Drop** | Only exists for the Mac/Windows choice. Its importers are the root layout, home, `MainHeader` and `HeroDownload`. |
| `benchmark-results/` (36 files, incl. `v2-contract/` mirror) | **Drop** | All the benchmark logic and most of the repo's tests. |
| `blog/posts.ts` | **Drop** | The only user of `gray-matter`. |

## `src/styles/`, `src/data/`

| File | Verdict | Notes |
| --- | --- | --- |
| `styles/theme.css` | **Keep** | Semantic tokens with `@theme static` and light/dark palettes. Accent is near-white in dark (`--p-accent: hsl(0 0% 97%)`, line 160) and near-black in light (line 200), so it is monochrome with no brand hue to recolor. Only the header comment says "Codictate design tokens". |
| `styles/base.css` | **Adapt** | Primitives (`shell`, `section`, `btn-primary`, `card`, `panel-soft`, `notch-bar`, `nav-active`) stay. `.wordmark-codictate` (lines 244-256) gets replaced by the new wordmark. |
| `styles/README.md` | **Keep** | Still accurate: no `dark:` variants, tokens only, two sanctioned stylesheets. |
| `data/install-phases.ts` | With `InstallGuide` | See above. |

## `public/`

Each file was checked with a grep of its basename across `src/` and `_posts/`.

| Path | Verdict | Notes |
| --- | --- | --- |
| `og-image.jpg` | **Adapt** | Replace it with a Codiclens 1200x630. |
| `images/wallpaper-better.webp` (hero), `images/wallpaper-better.png` (`desktop.ts`) | **Keep** | Needed if the mock desktop stays. |
| `images/{slack.webp,notes.png,notion.webp,cursor.webp,firefox.png,mail.png,cmux.png}` | **Keep** | Mock Dock icons. They are third-party app icons, the same exposure Codictate already has. |
| `images/{apple.logo,wifi,battery.75percent,siri,switch.2}.svg`, `notion-tray.png`, `cursor-tray.png` | **Keep if the tray is kept** | `GlassMacTray` only. |
| `images/codictate-tray.svg`, `brand/mac-dock-icon.png` | **Drop** | Codictate icons inside the mocks. |
| `images/fiddy.jpg`, `blog/authors/emil.jpg` | **Drop** | Slack mock avatars. `emil.jpg` lives under `blog/` but is used by `MockSlackWindow`/`MockDictSlackWindow`, so deleting `public/blog/` alone would break those mocks if they were kept. |
| `images/{logo.png,grain.jpg,apple.intelligence.svg}` | **Drop** | Unreferenced. |
| `brand/*` (21 tracked files) | **Drop** | Codictate screenshots. Only `homepage-hero-2026-09.png` is referenced, and only as the OG image's source note. |
| `install/*` (22 PNGs) | **Drop** (or replace) | Codictate install screenshots for the orphaned `InstallGuide`; `Step8.png` is unreferenced even there. |
| `blog/benchmarks/*` | **Drop** | Referenced by `benchmarks.ts` and posts. |
| `file.svg`, `globe.svg`, `next.svg`, `vercel.svg`, `window.svg` | **Drop** | create-next-app leftovers, unreferenced. |

## Root files, scripts, data

| Item | Verdict | Notes |
| --- | --- | --- |
| `next.config.ts` | **Adapt** | The `images.remotePatterns` entry `raw.githubusercontent.com/EmilLykke/codictate/main/benchmarks/results/**` goes. Keep `i.ytimg.com` for the video poster. The PostHog rewrites `/codictate-ph/static/:path*` → `eu-assets.i.posthog.com` and `/codictate-ph/:path*` → `eu.i.posthog.com` get renamed in step with `PostHogProvider`. Keep `skipTrailingSlashRedirect: true`; PostHog's proxy needs it. The `env` block passes `NEXT_PUBLIC_POSTHOG_KEY` and `_HOST`; the `NEXT_PUBLIC_` prefix already inlines them, so the block is redundant. |
| `package.json` | **Adapt** | Rename from `codictate-releases`. Remove `generate:benchmarks`. `"test": "bun test"` has nothing left to run, because every test is benchmark code (`src/lib/benchmark-results/**/*.test.ts`, `scripts/*.test.ts`); remove it or add tests. Dependencies: **drop** `gray-matter` (blog only) and `motion` (used only by the support form, `CapabilitiesOrbDisplay` and `MockDictionaryWindow`, all dropped; keep it if new mocks use it). **Keep** `next 16.2.6`, `react`/`react-dom 19.2.6`, `@posthog/react`, `posthog-js 1.372.10`, `@vercel/analytics`, `react-markdown`, `remark-gfm`, `rehype-raw`, `material-symbols`, and `gsap` + `@gsap/react` (`HeroStage`, plus ScrollTrigger for feature sections). Dev deps unchanged. |
| `bun.lock` **and** `package-lock.json` | **Adapt: keep one** | Both are committed. Vercel picks the package manager "by looking at the lock file" ([Vercel: Package Managers](https://vercel.com/docs/package-managers)) but does not document which wins when two are present. Keep one, or pin it with `packageManager` / Corepack. |
| `tsconfig.json`, `eslint.config.mjs`, `postcss.config.mjs` | **Keep** | Generic. `tsconfig.tsbuildinfo` and `next-env.d.ts` are gitignored. |
| `.env.example` | **Adapt** | See [Env vars](#env-vars-and-vercel-settings-for-the-fork). |
| `AGENTS.md` | **Keep** | The Next 16 warning block. |
| `CLAUDE.md` | **Adapt** | Remove the "Benchmark v2 staging reader" section and its rules. Rewrite "LLM discovery", which mentions `_posts/` and `_benchmarks/`. Keep the line about `rtk proxy` for `tsc`/`eslint`. |
| `README.md` | **Adapt** | It is still the create-next-app boilerplate. |
| `scripts/` (`generate-benchmarks.ts`, `v2-record-reconciliation.ts`, tests) | **Drop** | Benchmark ingest. |
| `_benchmarks/` (435 tracked files), `_posts/` (14 posts) | **Drop** | |
| `.claude/skills`, `.agents/skills`, `skills-lock.json` | **Adapt** | Drop `blog-writing-guide` (the only entry in `skills-lock.json`). The rest (frontend-design, framer-motion, gsap-*, data-fetching) are generic; keep them if wanted. |
| `.env.local` | **Not copied** | Gitignored (`.env*`). It holds a live `GITHUB_SUPPORT_TOKEN`, which the fork must not carry. |

---

## Coupling: deleting benchmarks, blog, models, iOS

Everything that stops compiling or links to a 404 once those routes and their libraries are gone:

| Where | What breaks |
| --- | --- |
| `src/app/(main)/page.tsx` | `import { BenchmarksSection }`. |
| `src/app/sitemap.xml/route.ts` | Imports `getUniqueBenchmarkRuns`, `getModelGuides`, `getAllBlogPosts`. Home `lastmod` uses `benchmarkLastMod`. Lists `/ios`, `/blog*`, `/benchmarks*`, `/models*`. |
| `src/app/llms.txt/route.ts` | The same three imports. Its Documentation section is all blog, benchmark and model links. |
| `MainHeader` `NAV_LINKS` | `/benchmarks`, `/blog` (and `/about`). |
| `MainFooter` `COLUMNS` | `/ios`, App Store, `/benchmarks`, `/models`, `/benchmarks/methodology`, `/blog`. |
| `not-found.tsx` | `/blog`, `/benchmarks`. |
| `about/page.tsx` | `/models`, `/ios`, `/blog/nvidia-parakeet-tdt-v3`, `/benchmarks`. |
| `next.config.ts` | The benchmark `remotePatterns` entry (dead, not breaking). |
| `public/blog/benchmarks/*` | Referenced from `benchmarks.ts`. |
| `public/blog/authors/emil.jpg` | Used by the Slack mocks, not the blog. |
| Components | `AggregateGlanceTable`, `BenchmarkDetailTables`, `HeadToHeadLanguageChart`, `ModelResultsTable`, `ModelGuideTable`, `SortableGlanceTable`, `Tooltip`, `ViewSwitch`, `Lightbox` have no importers left. |
| Tests / scripts | Every test is benchmark code, so `bun test` finds nothing. Also `generate:benchmarks` and `scripts/`. |
| Deps | `gray-matter`. |
| iOS specifically | `APP_STORE_URL` in `repo-urls.ts`, `AppStoreButton` (in `HeroDownload` and `GetStartedCta`), footer, home JSON-LD `downloadUrl` and `sameAs`, `operatingSystem: "macOS, Windows, iOS"`, the `ios_page` analytics surface. |
| Windows specifically | `get-latest-release` (`winSetupZip`, `winExe`), `nav-download-for-user-agent`, `layout.tsx` (`releaseDownloadUrls`), `MainHeader` (client UA re-pick), `HeroDownload` and `GetStartedCta` (`alert()` on a missing `.exe`), the releases page (`isWindowsInstaller`, the Windows button), metadata titles and keywords. |
| Canary specifically | `is-canary-release.ts`, `get-latest-release` (canary filter), releases page (`versionLabel`, `canaryIteration`, `releaseChannel`, twin dedupe, `canary-` prefix in `pickInstaller`), `releases-interactive.tsx` (`CHANNEL_FILTERS`, `CHANNEL_LABEL`, `text-warning` pill). |

Suggested order for the build ticket: delete the routes and libraries, then fix the eight shared files above. `tsc` will list anything missed. Per `CLAUDE.md`, run `tsc` and `eslint` through `rtk proxy` and check the exit code.

---

## Home page structure

Codictate's `/` today (`src/app/(main)/page.tsx`), top to bottom, with a Codiclens mapping for #10:

| # | Section (id) | What it is | Components | Codiclens mapping |
| --- | --- | --- | --- | --- |
| 0 | JSON-LD | `SoftwareApplication` script | `JsonLd` | Keep, new fields (below). |
| - | Header (layout) | Sticky glass "notch" island: wordmark, nav, theme toggle, stars badge, Download; a drawer on mobile | `MainHeader` | Same, with nav = Releases, Support (+ GitHub). |
| 1 | `#intro` hero | `min-h-[calc(100svh-var(--header-h))]`, two grid rows. Row 1: H1 "Your voice, your privacy." and lede "Any language. Any application. Anytime.", then `HeroDownload` (OS-picked primary, App Store pill, "Also available for…" link). Row 2: `HeroStage`, a faded wallpaper band with the glass Dock, the orb, and Slack/Mail/Cursor composer strips looping on GSAP (reduced motion gets a static frame) | `HeroDownload`, `HeroStage`, `Glass` | H1 and lede for a keyboard launcher. One DMG button plus an Apple Silicon / min-macOS line plus "Latest vX · All releases". `HeroStage` keeps its frame and swaps the orb and strips for a mock glass Panel running Query → Subject → Action → Target. |
| 2 | `#demo` | H2 "See it work.", lede, then a 16:9 YouTube facade | `DemoVideoSection` | **The demo video slot** (#2). Takes a URL from `NEXT_PUBLIC_DEMO_VIDEO_URL`, with a placeholder until the user's video exists. |
| - | (commented out) | `CapabilitiesSection` | - | - |
| 3 | Dictionary | Scroll-triggered GSAP mock: a misheard word becomes the dictionary entry | `DictionarySection` | The pattern for feature sections: Subject → Action → Target, search by meaning, Clipboard, Emoji, file Actions, Transcribe via Codictate (#10's list). |
| 4 | `#benchmarks` | "Measured, not claimed.": 5 language accuracy figures, then "See the full benchmarks" | `BenchmarksSection` | Drop. A natural slot for **Requirements + install** (drag to Applications, permissions, ⌘Space from Spotlight, uninstall/reset), possibly through `InstallGuide`. |
| 5 | `#blends-in` | "Where it sits when you are not using it.": menu bar card and Dock card | `NativeShowcase` | Drop; Codiclens has no Dock or menu bar presence. |
| 6 | Value props | "Dictation that stays out of your way.": three text columns | `ValuePropSection` | Keep the layout with new claims (e.g. on-device, keyboard-first, open source Apache-2.0). |
| 7 | `#get-started` | `panel-soft` closing CTA: H2, lede (mentions Apache 2.0), Mac DMG + App Store, then Windows · Star on GitHub · Ko-fi | `GetStartedCta` | DMG + "Star on GitHub" (+ Ko-fi?). |
| - | Footer (layout) | Wordmark + tagline, then Product / Project / Maker columns, then © line + Privacy/Terms | `MainFooter` | Same shape, new links (see the `MainFooter` row). |

Shared rhythm: every section is `section > shell`, with an `h2.text-display-lg` and a `p.text-lead.text-ink-muted.max-w-reading`.

## JSON-LD `SoftwareApplication`

Current fields (`page.tsx:61-81`) and what Codiclens should send:

| Field | Codictate | Codiclens |
| --- | --- | --- |
| `name` | Codictate | Codiclens |
| `description` | dictation copy | new |
| `url`, `image` | `absoluteUrl("/")`, OG image | same helpers |
| `applicationCategory` | `UtilitiesApplication` | `UtilitiesApplication` |
| `operatingSystem` | `"macOS, Windows, iOS"` | `"macOS <min> or later"` (from #3) |
| (new) `processorRequirements` | none | `"arm64"` (Apple Silicon only) |
| `isAccessibleForFree`, `offers` (price 0 USD) | yes | same |
| `downloadUrl` | `[RELEASES_URL, APP_STORE_URL]` | `[RELEASES_URL]` (or the DMG URL) |
| `softwareVersion` | latest stable tag without `v` | same |
| `author` | Person "Emil Lykke Grann" | same (or the CodicStack Organization) |
| `sameAs` | repo + App Store | `https://github.com/CodicStack/codiclens` |
| (new) `license` | none | `https://www.apache.org/licenses/LICENSE-2.0` (pending #5) |

The comment about not inventing a rating or review count still applies.

---

## Env vars and Vercel settings for the fork

Every `process.env` read, from grepping `src/`, `scripts/` and `next.config.ts`:

| Variable | Read in | Fork |
| --- | --- | --- |
| `NEXT_PUBLIC_POSTHOG_KEY` | `PostHogProvider.tsx:7`, `next.config.ts` | **Set** (Production + Preview). Same or new PostHog project: see Open questions. |
| `NEXT_PUBLIC_POSTHOG_HOST` | `next.config.ts` only, **never at runtime** | Drop, or wire it into `api_host`/`ui_host`. Today the EU host is hard-coded. |
| `NEXT_PUBLIC_SITE_URL` | `site-url.ts`, `robots.ts`, `llms.txt` (not in `.env.example`) | **Set** `https://codiclens.codicstack.com` for Production, and change the code fallbacks to match so Previews get correct canonicals. |
| `GITHUB_TOKEN` | `get-all-releases`, `get-latest-release`, `get-star-count`, `scripts/generate-benchmarks` | Optional once `CodicStack/codiclens` is public; it raises the 60/h anonymous rate limit, and fetches are cached `revalidate: 300`. **Required to render anything while the repo is private**, and even then visitors cannot download private assets. Use a fine-grained, read-only token scoped to `CodicStack/codiclens` (Contents: read). |
| `NEXT_PUBLIC_DEMO_VIDEO_URL` | `page.tsx:53` | Optional; the demo slot. Remove the Codictate YouTube default in code. |
| `GITHUB_SUPPORT_TOKEN` | `api/issues` | **Drop.** |
| `CODICTATE_BENCHMARK_V2_STAGING`, `_V2_DIR`, `_V2_ROOT` | `v2-staging.ts` | **Drop.** |
| `CODICTATE_STT_BENCHMARK_URL`, `_ASSET_BASE_URL`, `_LOCAL_PATH` | `stt-benchmarks.ts` | **Drop.** |
| `GH_TOKEN` | `scripts/generate-benchmarks.ts` | **Drop.** |
| `NODE_ENV` | `PostHogProvider` (debug in dev) | Automatic. |

Vercel project setup:

- **Project** linked to `CodicStack/codiclens-site`. The Vercel GitHub app needs access to the CodicStack org. Framework preset Next.js, build `next build`, production branch `main`. There is no `vercel.json` today and none is needed.
- **Package manager:** keep one lockfile (see above).
- **Domain:** add `codiclens.codicstack.com` in Vercel, then point the Cloudflare DNS record at the target Vercel shows. That step is the separate DNS ticket in #2's "Not yet specified".
- **Web Analytics:** toggle it on per project. "Navigate to Analytics … click the Enable button", which "will add new routes (scoped at `/_vercel/insights/*` …)" ([Vercel: Web Analytics quickstart](https://vercel.com/docs/analytics/quickstart)). `<Analytics />` is already in the root layout.
- **Env vars** as in the table: `NEXT_PUBLIC_POSTHOG_KEY` and `NEXT_PUBLIC_SITE_URL` required, `GITHUB_TOKEN` and `NEXT_PUBLIC_DEMO_VIDEO_URL` optional. `NEXT_PUBLIC_*` values are inlined at build time, so changing them needs a redeploy.
- **PostHog proxy:** the rewrites in `next.config.ts` (renamed path) plus `skipTrailingSlashRedirect`. Nothing to set in Vercel.

## How to create the repo

#2 says "forked from". A GitHub **fork** of the private `EmilLykke/codictate-releases` would be a bad fit. GitHub's docs say "private repository forks are private", "You cannot change the visibility of a fork by itself", and when the upstream is deleted "its private forks are also deleted" ([GitHub: permissions and visibility of forks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/about-permissions-and-visibility-of-forks)). It would also carry `_benchmarks/` (435 files), `_posts/`, every Codictate screenshot in history, and an upstream link back to Codictate. **Recommendation:** create `CodicStack/codiclens-site` as a new repo, seeded from a copy of the working tree at a known commit (e.g. `f894b16`), with the drops applied in the first commits and no upstream history.

## Open questions for the user

1. **About page:** drop it (recommended; it is all Codictate story and not in #2's keep list), or write a short Codiclens one?
2. **PostHog project:** a separate Codiclens project (clean dashboards, its own key) or the Codictate project filtered by host? It is the same EU region either way.
3. **Ko-fi, personal site, LinkedIn** in the footer and closing CTA: keep them for Codiclens?
4. **Install walkthrough:** revive the orphaned `InstallGuide` slider for #10's install steps, or use plain numbered steps on the home page?
5. **Release-notes deep links:** add a per-version anchor on `/releases` if #4/#9 want Sparkle's notes link to point at the site.
