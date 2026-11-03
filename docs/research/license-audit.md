# License audit for open-sourcing Codiclens

Research for [#5](https://github.com/CodicStack/codiclens/issues/5), map [#2](https://github.com/CodicStack/codiclens/issues/2).
Done 2026-11-02 against `main` at `bf4a1fa` plus the local `Vendor/` build (llama.cpp `b11567`). Not legal advice:
the items under "Needs a human decision" are exactly that.

## Answer

**Yes, Codiclens can ship as Apache-2.0.** Every third-party piece that ends up in the source tree or the app is under a
permissive license (MIT, BSD-2-Clause, zlib, Unicode-3.0, MIT-CMU, public domain / Unlicense / MIT-0), and all of
those are compatible with Apache-2.0. None asks for source disclosure or for patches to be published. What they ask
for is attribution: keep their copyright and permission notice with every copy, which for the app means in the bundle
and shown in Acknowledgements.

Two things block going public, and neither is about the Apache-2.0 choice itself:

1. **`.agents/skills/xcode-skills/bundled/` is Apple's text** (exported from Xcode by `xcrun agent skills export`,
   per its `bootstrap.sh` and README: "requires macOS and Xcode 27 beta"). The Xcode and Apple SDKs Agreement forbids
   uploading, hosting or redistributing Apple Software in whole or in part (section 2.7), and pre-release
   documentation is Apple Confidential (section 3.2). The wrapper skill (`mikker/xcode-apple-skills`) has no license
   at all, so it is all-rights-reserved. Remove the whole skill (`.agents/skills/xcode-skills/`,
   `.claude/skills/xcode-skills`, its `skills-lock.json` entry) from the tree **and from history** before the repo
   goes public. The map already plans a history rewrite for binaries; add these paths to it.
2. **The app ships llama.cpp without its license.** `libllamacpp.a` is linked statically (the committed
   `Codiclens.app/Contents/MacOS/codiclens` contains ggml symbols), but Acknowledgements lists only the emoji data and
   DigUp. llama.cpp's MIT license, and the notices of the code it compiles in (below), must ship in the bundle. This
   is true today for the private builds too, and it applies to every `Codiclens.app` in git history, which the
   planned rewrite removes anyway.

The embedding model is not bundled: the app downloads it from Hugging Face on the user's Mac. Its terms (Apache-2.0)
do not bind the repo's license. Crediting it is courtesy and clarity, not an obligation.

## Component table

| Component | Where it lives | License (primary source) | Apache-2.0 compatible | Obligations |
|---|---|---|---|---|
| Codiclens own code | whole repo | to be Apache-2.0 | n/a | LICENSE + NOTICE at repo root and in the app |
| llama.cpp / ggml `b11567` (`972b5fc`) | fetched at build, static in the binary | MIT, "Copyright (c) 2023-2026 The ggml authors" ([LICENSE at b11567](https://github.com/ggml-org/llama.cpp/blob/b11567/LICENSE)) | yes | Notice in the app; credit in NOTICE |
| `Scripts/llama.cpp-no-logits.patch` | repo | Patch to MIT code; header credits DigUp (MIT) | yes | No patch disclosure duty (MIT has none); already published as source anyway |
| Code compiled into `libllamacpp.a` from llama.cpp's tree | binary only | see "Inside libllamacpp.a" | yes | Their notices in the app |
| DigUp (Abdur Rahim) | adapted in ~17 Swift files, the build script, the patch | MIT, "Copyright (c) 2026 Abdur Rahim" ([LICENSE](https://github.com/ARahim3/DigUp/blob/main/LICENSE)) | yes | Keep notice (done: `codiclens/digup-license.txt`, shown in Acknowledgements); its file list is out of date |
| Pillow `Resample.c` (bicubic) | ported in `codiclens/ImageSizing.swift` ("Ported from mtmd's copy of it"); also in llama.cpp's `tools/mtmd/mtmd-image.cpp` | MIT-CMU, Secret Labs AB / Fredrik Lundh / Jeffrey A. Clark ([LICENSE](https://github.com/python-pillow/Pillow/blob/main/LICENSE)) | yes | Notice "in all copies" and in supporting documentation; credit in NOTICE |
| Unicode Emoji 17.0 `emoji-test.txt`, CLDR 48 annotations | generated into `codiclens/emoji-index.json` | Unicode-3.0 ([unicode.org/license.txt](https://www.unicode.org/license.txt), [CLDR LICENSE](https://github.com/unicode-org/cldr/blob/release-48/LICENSE)) | yes | Notice with the data (done: `emoji-data-license.txt`, in Acknowledgements); don't use the Unicode name to promote without permission |
| EmbeddingGemma 2 (`google/embeddinggemma-2`), ggml-org Q8_0 GGUF at `bfcd298` | downloaded at runtime to `~/Library/Application Support/codiclens/models`, never bundled | Apache-2.0 ([Google's card](https://huggingface.co/google/embeddinggemma-2): `license: apache-2.0`, linking [ai.google.dev/gemma/docs/gemma_4_license](https://ai.google.dev/gemma/docs/gemma_4_license), the plain Apache-2.0 text; [ggml-org card at the pinned revision](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/blob/bfcd298762cc34d0357ece5ebdd31791a3a374d8/README.md): `license: apache-2.0`) | yes | None on the repo (not redistributed). Credit recommended. Card adds "Deployments must adhere to the Gemma Prohibited Use Policy" (see below) |
| Sparkle 2 (to be added; latest 2.10.1, 2026-10-25) | embedded framework via SwiftPM | MIT (Andy Matuschak and others) plus bsdiff (BSD-2, Colin Percival), sais-lite (MIT, Yuta Mori), ed25519 (zlib, Orson Peters), SUSignatureVerifier (BSD-2, Mark Hamlin) ([LICENSE at 2.10.1](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE)) | yes | Ship Sparkle's whole LICENSE (all sections) in the app; the BSD-2 parts require it "in the documentation and/or other materials provided with the distribution" |
| Swift packages | none today | `project.pbxproj` has no `XCRemoteSwiftPackageReference`; no `Package.resolved` | n/a | Sparkle will be the first; `.gitignore` ignores `Package.resolved`, so un-ignore it for the app to pin versions |
| Apple frameworks and SF Symbols | system, at runtime | Xcode and Apple SDKs Agreement | n/a (not redistributed) | 14 `systemSymbolName:` uses are fine; the agreement bars SF Symbols in app icons, logos or trademark use (section on System-Provided Images). Applies to the site too |
| Fonts, sounds | none bundled | `NSFont(name: "Apple Color Emoji")` is the system font, not shipped; no audio or font files anywhere in history | n/a | none |
| App icon (`codiclens-icon.icon/`, `Assets.xcassets`) | repo | Not stated | needs a decision | Confirm who made it; decide whether it is Apache-2.0 or reserved |
| `.agents/skills/xcode-skills/` | repo | Apple Software (bundled/); upstream wrapper unlicensed | **no** | **Remove from tree and history** |
| `Codiclens.app/` (committed notarized builds) | repo + history | contains llama.cpp without its notice | n/a | Remove (already planned in #2) |

### Inside libllamacpp.a

`Scripts/build-llama.sh` combines `libllama`, `libmtmd`, `libggml*` and `libvendor-hash`. The build's `CMakeCache.txt`
has `GGML_LLAMAFILE=ON`, `MTMD_VIDEO=ON`, `LLAMA_SUBPROCESS=ON`, `GGML_BLAS_VENDOR=Apple`, `GGML_CPU_KLEIDIAI=OFF`.
`tools/mtmd/mtmd-helper.cpp` defines `MINIAUDIO_IMPLEMENTATION` and `STB_IMAGE_IMPLEMENTATION` and includes
`sheredom/subprocess.h`; `nm` on the archive shows `stbi_`, `subprocess_`, `XXH` and sha symbols. So the binary carries:

| Code | License, from the file in `Vendor/llama.cpp` | Notice needed |
|---|---|---|
| ggml + llama.cpp + mtmd | MIT, The ggml authors (`LICENSE`) | yes |
| llamafile `sgemm.cpp` | MIT, Copyright 2024 Mozilla Foundation (file header) | yes |
| YaRN RoPE (`ggml-cpu/ops.cpp`, `ggml-metal/kernels/rope.metal`) | MIT, Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng (comment) | yes (conservatively) |
| BPE tokenizer adapted from ggllm.cpp (`src/llama-vocab.cpp`) | MIT (comment; no holder named) | credit |
| Pillow resampling (`tools/mtmd/mtmd-image.cpp`) | MIT-CMU (comment links Pillow's `Resample.c`) | yes |
| `stb_image.h` | MIT or public domain, your choice (Sean Barrett) | none if public domain is chosen; credit anyway |
| `miniaudio.h` | public domain (Unlicense) or MIT-0 (David Reid) | none |
| `sheredom/subprocess.h` | Unlicense | none |
| xxHash | BSD-2-Clause, Copyright (c) 2012-2021 Yann Collet | **yes, in binary distributions** |
| `rotate-bits.h` | MIT, Copyright (c) 2021 William Casarin | yes |
| sha256 | public domain (Igor Pavlov) | none |
| sha1 | public domain (Steve Reid) | none |
| Apple Accelerate, Metal | system frameworks | none |

`licenses/LICENSE-jsonhpp` (nlohmann/json) and `cpp-httplib` belong to `common`/server targets the script does not
build, so they are not in the app. Every llama.cpp bump should re-run this check (the vendor list moves).

Optional: building with `-DMTMD_VIDEO=OFF -DLLAMA_SUBPROCESS=OFF` drops `subprocess.h` and mtmd's ability to launch an
`ffmpeg` from `PATH`. Codiclens decodes video itself, so nothing should miss it; it is hygiene, not a license need.

## Runtime-downloaded model: who is bound

- **The repo and the app are not.** Apache-2.0's conditions (section 4) attach to redistributing the Work. Codiclens
  ships a URL, a size and a SHA-256 (`codiclens/ModelFiles.swift`), not the weights; Hugging Face, ggml-org and Google
  are the distributors. Apache-2.0 for code is unaffected by what the model's license says.
- **The user** obtains the files from Hugging Face under Apache-2.0 (and Hugging Face's own terms for using its
  service). Apache-2.0 places no use restriction on them.
- **The Gemma Prohibited Use Policy.** Google's card says "Deployments must adhere to the Gemma Prohibited Use Policy",
  but the license it links is the unmodified Apache-2.0 text, which incorporates no policy. The policy page itself says
  "You may not use nor allow others to use Gemma or Model Derivatives to:" and was last modified 2024-02-21, i.e. it was
  written for the old Gemma Terms of Use. Earlier Gemma models (including EmbeddingGemma 1, `google/embeddinggemma-300m`,
  tagged `license:gemma` and gated) were under those Terms, which did bind redistributors and required passing the
  restrictions on. EmbeddingGemma 2 is not gated and is Apache-2.0, so none of that carries over. Local file search is
  nowhere near the policy's list. Recommendation: credit the model, link Google's card, and do not copy the policy into
  NOTICE. If the model is ever swapped back to a Gemma-Terms model, or bundled or mirrored, redo this section: the
  Gemma Terms require passing on their use restrictions and a "Gemma is provided under and subject to the Gemma Terms
  of Use" notice.
- Note for the privacy ticket in #2: the download goes to `huggingface.co` (redirecting to its CDN) at launch while
  search by meaning is on, which is the default. Hugging Face sees the user's IP address and a request for these files.
- The pinned ggml-org revision is no longer the repo's only commit (`main` is now `6ea3e3a`, a README edit); the
  comment in `ModelFiles.swift` saying "The repository's only upload" is stale but the pin still resolves and its
  card still says Apache-2.0.

## Private symbolic hotkey API (ADR 0006)

- **It is gone.** ADR 0006 is `superseded`; `git grep` finds no `CGS*` call, `dlsym` or `dlopen` in `codiclens/`. The
  app uses only `RegisterEventHotKey`. Nothing to assess for the shipping code.
- **Even when it was there, Developer ID distribution was not in breach.** The Apple Developer Program License
  Agreement (page last modified 2026-10-29) applies its Program Requirements, including 3.3.1 A "must not use or call
  any private APIs", to "Any Application that will be submitted to the App Store, Custom App Distribution, or
  TestFlight, or that will be distributed through Ad Hoc distribution". Developer ID / notarized apps (section 5.3) are
  checked for malware and harmful code, not for private API use. The remaining risk of private API outside the App
  Store is technical (a macOS update removes the symbol), not contractual.
- **One thing to reword before the ADR goes public:** it says "Static inspection of the installed Raycast binary shows
  it dynamically imports `CGSIsSymbolicHotKeyEnabled`...". Listing a binary's imported symbols is mild, but publishing
  that we inspected a competitor's binary invites a terms-of-service argument for no gain. Suggest "Raycast offers the
  same toggle" or dropping the sentence (human decision).

## The Codictate name

- Codiclens names Codictate in UI strings, in `AGENTS.md`/`GLOSSARY.md`, links `https://codictate.app`, and runs
  Codictate's command-line client (looked up by bundle id `app.codictate`). That is the same owner's product,
  referred to by name, and the two programs only talk over a command line: no license interaction, no linking.
- Apache-2.0 section 6 already says the license grants no rights to trade names or marks. So a fork can reuse the
  code but not call itself Codiclens or Codictate. Nothing else is required. Recommendation: one short "Trademarks"
  paragraph in the README (not in NOTICE, which should stay attribution only): "Codiclens and Codictate are names of
  their author; the Apache License does not grant permission to use them. Forks must use another name and icon."
  Whether either name is or will be a registered mark is a human decision; the note works either way.
- Third-party names used descriptively (EmbeddingGemma, Gemma, Hugging Face, Unicode, Raycast, Spotlight) are
  nominative use and need nothing beyond the existing Unicode trademark line.

## Fix-ups found along the way

- `codiclens/digup-license.txt` says the adapted files are "SQLite.swift, FileIndexStore.swift, FileIndexRules.swift,
  FileContent.swift, FileContentReader.swift". The first-line credits name DigUp in also `Embedder.swift`,
  `EmbeddingClient.swift`, `EmbeddingService.swift`, `EmbeddingVector.swift`, `ImageSizing.swift`, `MeaningJobs.swift`,
  `MeaningReader.swift`, `MeaningSearch.swift`, `MeaningVectors.swift`, `ModelFiles.swift`,
  `Scripts/build-llama.sh` and the patch. Replace the list with "Parts of Codiclens are adapted from DigUp; each such
  file says so in its first line." so it cannot go stale.
- `ImageSizing.swift` ports Pillow's algorithm (via mtmd) and transformers' Gemma 4 image processor sizing
  (Apache-2.0, a few lines of arithmetic). Add "Pillow (MIT-CMU) via llama.cpp's mtmd" to its first-line credit.
- `INFOPLIST_KEY_NSHumanReadableCopyright` is empty in both configurations; set it to
  "Copyright © 2026 Emil Lykke Grann. Apache License 2.0."
- The bundle id `com.codiclens` suggests a domain (`codiclens.com`) the site does not use (`codiclens.codicstack.com`).
  Not a license matter; changing it after release breaks preferences and Sparkle, so decide before 1.0.
- Every commit is by one author (`Emil Lykke Grann`), so no contributor needs to agree to the license. After going
  public, an inbound=outbound rule (Apache-2.0 section 5 already provides it) is enough; no CLA needed.

## Needs a human decision

1. **Copyright holder**: "Emil Lykke Grann" (as Codictate's NOTICE) or a CodicStack legal entity, if one exists.
2. **App icon**: confirm it is your own work (or that you hold the rights), and choose whether it is Apache-2.0 with
   the code or reserved like the name (if reserved, say so in README and NOTICE, e.g. "The Codiclens name and icon
   are not covered by the Apache License").
3. **History rewrite scope**: add `.agents/`, `.claude/skills/xcode-skills` and `skills-lock.json` to the paths the
   rewrite strips, next to `Codiclens.app/` (#6).
4. **ADR 0006 Raycast sentence**: reword or keep.
5. **Trademark note**: plain README note (recommended) or a fuller TRADEMARKS file; and whether to register.

## Files to add or change

Modelled on Codictate (`LICENSE`, `NOTICE`, `docs/licenses/<component>/` copied into the app).

| File | Content |
|---|---|
| `LICENSE` | Apache-2.0 full text (copy of Codictate's `LICENSE`) |
| `NOTICE` | Draft below |
| `docs/licenses/llama-cpp/LICENSE` | llama.cpp `LICENSE` at the pinned tag |
| `docs/licenses/llama-cpp/THIRD-PARTY.txt` | The notices of the table "Inside libllamacpp.a": llamafile sgemm (Mozilla), YaRN (Quesnelle and Peng), Pillow resampling, xxHash BSD-2 (full text), rotate-bits MIT, ggllm.cpp credit, stb_image / miniaudio / subprocess.h / sha1 / sha256 as public domain |
| `docs/licenses/pillow/LICENSE` | Pillow's MIT-CMU `LICENSE` (for `ImageSizing.swift`) |
| `docs/licenses/sparkle/LICENSE` | Sparkle's `LICENSE` at the pinned tag, all sections (with the Sparkle build ticket) |
| `docs/licenses/digup/LICENSE` | Move of `codiclens/digup-license.txt`, file list replaced by the first-line rule |
| `docs/licenses/embeddinggemma-2/README.txt` | Credit: model id, ggml-org repo and revision, "Apache License 2.0", link to Google's card; says it is downloaded, not bundled |
| `codiclens/emoji-data-license.txt` | Keep as is (generated) |
| `Scripts/build-llama.sh` | Optionally copy `LICENSE` from the checked-out tag into `Vendor/llama/` so a bump cannot leave a stale copy, or check `docs/licenses/llama-cpp/LICENSE` against it |
| `codiclens/SettingsView.swift` | Acknowledgements: add llama.cpp (with THIRD-PARTY), Pillow, Sparkle, EmbeddingGemma 2, and Codiclens's own NOTICE/LICENSE; all from bundled files |
| Xcode project | Bundle `LICENSE`, `NOTICE` and `docs/licenses/**` as resources; set `NSHumanReadableCopyright` |
| `.gitignore` | Stop ignoring `Package.resolved` for the app project once Sparkle is in |
| `README.md` | License section ("Apache 2.0. See LICENSE and NOTICE.") and the trademark paragraph |
| Remove | `.agents/skills/xcode-skills/`, `.claude/skills/xcode-skills`, `skills-lock.json` entry, `Codiclens.app/` (tree and history) |
| Optional | `// SPDX-License-Identifier: Apache-2.0` headers; not required |

## Draft NOTICE

```
Codiclens
Copyright 2026 Emil Lykke Grann

This product includes software developed as part of the Codiclens project:
https://github.com/CodicStack/codiclens

Search by meaning runs on llama.cpp and ggml (release b11567), Copyright (c)
2023-2026 The ggml authors, under the MIT License. It is built from source with
Scripts/llama.cpp-no-logits.patch applied and linked statically. Its license, and
the notices of the third-party code compiled into it (llamafile, xxHash,
rotate-bits, Pillow's resampling and others), are distributed in
licenses/llama-cpp (docs/licenses/llama-cpp in the source distribution).

Parts of the File Index and of search by meaning are adapted from DigUp,
Copyright (c) 2026 Abdur Rahim, under the MIT License; each such file says so in
its first line. Its license is distributed in licenses/digup
(docs/licenses/digup in source).

Image resizing for search by meaning follows Pillow's bicubic resampling, from
the Python Imaging Library, Copyright 1997-2011 by Secret Labs AB, Copyright
1995-2011 by Fredrik Lundh and contributors, and Pillow, Copyright 2010 by
Jeffrey A. Clark and contributors, under the MIT-CMU License. Its license is
distributed in licenses/pillow (docs/licenses/pillow in source).

In-app updates use Sparkle, Copyright (c) 2006-2013 Andy Matuschak and others,
under the MIT License, with parts under BSD, MIT and zlib licenses. Its license
is distributed in licenses/sparkle (docs/licenses/sparkle in source).

The emoji data is generated from Unicode Emoji 17.0 and the Unicode Common Locale
Data Repository (CLDR) 48, Copyright 1991-2025 Unicode, Inc., under the Unicode
License v3. Its notice is distributed in emoji-data-license.txt. Unicode is a
registered trademark of Unicode, Inc. in the U.S. and other countries.

Optional search by meaning downloads EmbeddingGemma 2 by Google DeepMind
(google/embeddinggemma-2), as converted to GGUF by ggml-org
(ggml-org/embeddinggemma-2-GGUF, revision
bfcd298762cc34d0357ece5ebdd31791a3a374d8), from Hugging Face. It is not
included in Codiclens. It is licensed under the Apache License 2.0; see
https://huggingface.co/google/embeddinggemma-2.
```

The Sparkle paragraph goes in with the Sparkle build ticket; the version, tag and CLDR years move with each bump, so
whoever bumps llama.cpp, Sparkle or the emoji data updates NOTICE in the same commit.

## Sources

- llama.cpp `LICENSE` at `b11567`: https://github.com/ggml-org/llama.cpp/blob/b11567/LICENSE (tag resolves to
  `972b5fc`, the pinned commit). Vendor licenses read from `Vendor/llama.cpp/vendor/**` at that commit.
- DigUp `LICENSE`: https://github.com/ARahim3/DigUp/blob/main/LICENSE
- Pillow `LICENSE`: https://github.com/python-pillow/Pillow/blob/main/LICENSE
- Unicode License v3: https://www.unicode.org/license.txt; CLDR: https://github.com/unicode-org/cldr/blob/release-48/LICENSE
- Sparkle `LICENSE` at 2.10.1: https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE
- EmbeddingGemma 2 card: https://huggingface.co/google/embeddinggemma-2 (API: `license:apache-2.0`, `gated: false`)
- ggml-org GGUF card at the pinned revision:
  https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/blob/bfcd298762cc34d0357ece5ebdd31791a3a374d8/README.md
- Gemma 4 license page (Apache-2.0 text): https://ai.google.dev/gemma/docs/gemma_4_license
- Gemma Prohibited Use Policy: https://ai.google.dev/gemma/prohibited_use_policy
- EmbeddingGemma 1 for contrast: https://huggingface.co/google/embeddinggemma-300m (`license:gemma`, gated)
- Apple Developer Program License Agreement, sections 3.3, 3.3.1 A, 5.3, 9.1:
  https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- Xcode and Apple SDKs Agreement (EA1990, in `/Applications/Xcode.app/Contents/Resources/en.lproj/License.rtf`),
  sections 2.7 (no redistribution), 3.2 (pre-release confidentiality), System-Provided Images
- Apache License 2.0, sections 4 and 6: https://www.apache.org/licenses/LICENSE-2.0
