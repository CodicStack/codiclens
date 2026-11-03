# Repo audit before going public

Ticket: CodicStack/codiclens#6. Audited 2026-11-02 at `main` = `bf4a1fa`, all local and
remote branches (110 commits). Read-only: every history operation ran on a scratch
`git clone --no-local` with its remote removed. Nothing was pushed from it. No secret
values appear in this file.

## Verdict

No secrets anywhere in history. The only thing that must go before flipping to public
is the committed `Codiclens.app` bundle (14 commits), which is 93% of the pack and carries
223 absolute build paths under `/Users/emillykkegrann/Documents/Projects/codictate-project/…`
per binary. Strip it, untrack it, and decide the two optional items below (author email,
vendored Apple skills).

## Secrets

| Check | Result |
|---|---|
| `gitleaks git --log-opts=--all` (8.30.1, default rules) | 0 findings, before and after the rewrite |
| `trufflehog git file://…` (3.99.7, all detectors) | 0 findings |
| Manual grep over every blob ever committed (929 blobs, binaries included): PEM blocks, `PRIVATE KEY`, `ghp_`/`github_pat_`/`sk-`/`sk-ant-`/`AKIA`/`xox?-`/`AIza`, `password`/`secret`/`api_key`/`bearer`, notarytool/altool/keychain-profile/app-specific | no real credential |
| Paths ever committed matching `.p12 .cer .pem .key .mobileprovision .provisionprofile .env` | none |

What the grep did hit, all benign:

- `README.md` (in history since its first commit, still in HEAD): a `notarytool
  store-credentials` example. All three values (`--apple-id`, `--team-id`, `--password`)
  are `YOUR…` placeholders. Profile name `codiclens-profile` only. Fine.
- `codiclensTests/FileIndexRulesTests.swift`: a fixture file `private.key` whose content is
  only the `-----BEGIN PRIVATE KEY-----` header text, no key material. Fine.
- Source and tests mention `password`/`secret`/`PRIVATE KEY` as words (secret-file rules,
  clipboard concealed-type handling). Fine.
- `codiclens-icon.icon/Assets/Codiclens.png` (and its copies in `Assets.xcassets`): an
  embedded C2PA content-credentials manifest from Trufo's signing CA, with a public
  `@trufo.ai` contact address. Not personal. Optional: strip the metadata from the PNG if
  you'd rather not ship image-generator provenance.
- Apple Team IDs `L256GR2793` and `HHNPP7C8GB` in `project.pbxproj` and `AGENTS.md`. Team
  IDs are public (they are in every signed binary's signature). Fine to publish. The
  mismatch itself is already a Known issue in `AGENTS.md`.

## Personal data

- **Absolute home paths**: only inside `Codiclens.app/Contents/MacOS/codiclens` (all 14
  versions; Swift `#file`/debug paths). No text file in any commit holds
  `/Users/emillykkegrann`. Tests use `/Users/someone` and `/Users/x`. Gone with the strip.
- **Author identity**: all 110 commits are authored and committed as a personal Gmail
  address. Decide whether that is fine in public. If not, add `--mailmap` to the rewrite
  (see below) mapping it to the GitHub noreply address. Commit trailers are only
  `Co-Authored-By: Claude … <noreply@anthropic.com>`.
- **Repodo**: `codiclensTests/Embedding{Client,Integration,Vector}Tests.swift` use the query
  "kontrakt med Repodo" and a fixture "Ansættelseskontrakt mellem Repodo ApS og
  medarbejderen". `AGENTS.md:933` says "on this Mac `repodo-project` held eighteen of
  [the worktrees]". Harmless, but it names your company and a private project. Optional:
  swap for a made-up company name.
- `AGENTS.md:939-940` mentions other local projects' folders (`data/…/raw/` 841 MB,
  `.moon/cache`, `supabase/.temp`) as measurement anecdotes. No names, harmless.
- Commit messages: read all 2,006 lines; nothing private.

## Large blobs and what to strip

Before: 110 commits, 929 blobs, pack 20.67 MiB after `git gc --aggressive` (GitHub reports
20,298 KB). The local `.git` is 54 MB only because its 1,483 objects are all loose; a
`git gc` alone would bring it to ~21 MB.

| Path (all versions) | Blobs | Raw size | Packed |
|---|---|---|---|
| `Codiclens.app/` | 42 | 117.6 MB | 19.1 MB |
| `codiclens/` | 472 | 7.4 MB | 1.2 MB |
| `codiclens-icon.icon/` | 2 | 0.45 MB | 0.43 MB |
| `.agents/` (vendored xcode-skills) | 89 | 0.92 MB | 0.31 MB |
| `codiclensTests/` | 188 | 2.7 MB | 0.28 MB |
| `AGENTS.md` | 42 | 2.8 MB | 0.09 MB |
| everything else | | | < 0.1 MB |

The 7 largest blobs are all `Codiclens.app/Contents/MacOS/codiclens` (15 MB each, the
llama.cpp-linked builds since 2026-10-13). The largest non-bundle blob is the 445 KB icon PNG.

**Never committed** (checked every path in history): `default.profraw`, `build/`,
`Vendor/` (llama.cpp), `DerivedData/`, `xcuserdata/`, `.DS_Store`, `.xcarchive`, `.dmg`,
`.zip`, `.gguf`, `.dylib`/`.a`. They are in the working tree only and are already ignored.
They are in the strip command anyway so it stays safe to re-run.

History-only files (deleted in HEAD, survive in history): `HANDOFF.md`, `CONTEXT.md`,
`docs/DESIGN-HANDOFF.md`, `docs/handoff-border-beam.md`. Session handoff notes about the
design work, nothing private. Fine to leave in.

### The rewrite that worked (scratch clone, git-filter-repo a40bce548d2c via Homebrew)

```sh
git clone --no-local <repo> audit-clone && cd audit-clone
git remote remove origin
git filter-repo --force --invert-paths \
  --path Codiclens.app/ --path default.profraw --path build/ --path Vendor/ \
  --path DerivedData/ --path-glob '*.DS_Store' --path-glob '*/xcuserdata/*'
git reflog expire --expire=now --all && git gc --aggressive --prune=now
```

`--force` was needed because the clone had been touched (fetches, gc) before the run.

| | Commits | Pack |
|---|---|---|
| Before | 110 | 20.67 MiB |
| After strip (above) | 100 | **2.47 MiB** |
| After strip + `--path .agents/skills/ --path .claude/skills/` | 100 | 2.17 MiB |

The 10 dropped commits are the bundle-only "chore: rebuild Codiclens.app bundle" commits,
which become empty. Every commit sha changes, so all branches, open PRs and worktrees
(`research/*`, `feat/*`, `card-glass`, `border-beam-and-loading-ring`) need re-cloning or
rebasing onto the rewritten history. Push the rewrite with `--force --all` from a fresh
clone of the result, and delete stale remote branches first.

To also replace the author email, add `--mailmap my.mailmap` with one line
`Emil Lykke Grann <ID+EmilLykke@users.noreply.github.com> <personal address>`.

Where the app goes instead: the notarized bundle should become a GitHub Release asset (or the
Sparkle feed, see the Sparkle research), not a tracked file.

## Agent and docs files

| File | Publish? | Why |
|---|---|---|
| `AGENTS.md` (117 KB, 1,590 lines) | **Yes** | Technical: build, tests, rules, architecture, known issues. No secrets, no absolute paths. Optional: drop the `repodo-project` aside (line 933). |
| `CLAUDE.md` | **Yes** | One line, `@AGENTS.md`. |
| `GLOSSARY.md` | **Yes** | Domain language only. |
| `docs/adr/0001-0014` | **Yes** | Decisions and reasoning. 0006 and 0011 openly discuss private CoreGraphics API use; that is a design fact, not a secret. |
| `README.md` | **Yes**, after a touch-up | Placeholders only. It reads as private build notes; write a public README when flipping (separate concern). |
| `skills-lock.json` | **Yes** | Points at public `mikker/xcode-apple-skills` plus a hash. |
| `.agents/skills/xcode-skills/` | **No, recommended** | Vendored copy of a third-party skill with no LICENSE file in the copy, whose `bundled/` folder is Apple-authored guidance exported from the Xcode 27 beta. Redistributing that publicly is a licensing question you don't need. Untrack it, gitignore it, reinstall from `skills-lock.json` (`npx skills add mikker/xcode-apple-skills`). Its nested `.github/workflows/bootstrap.yml` never ran here (not at repo root). |
| `.claude/skills/xcode-skills` | **No** (goes with the above) | A symlink into `.agents/`; dangles once `.agents/skills/` is untracked. |

No file references a private repo by URL. The `CodicStack/` org name never appears in the
tree. Codictate is referenced as a public product (`codictate.app`, bundle id
`app.codictate`, its CLI contract), which is fine.

## .gitignore going forward

Already covered: `build/`, `DerivedData/`, `xcuserdata/`, `.DS_Store`, `default.profraw`,
`Vendor/` (so `Vendor/llama` too), `*.mobileprovision`, `*.provisionprofile`, `*.dSYM`.

Missing:

- **`Codiclens.app/`**: tracked in HEAD today, so the rewrite (or `git rm -r --cached
  Codiclens.app`) plus an ignore line is needed, or the next rebuild re-adds it. A
  root-anchored `/*.app/` covers renames.
- Notarization and export output: `*.xcarchive`, `*.zip`, `*.dmg`.
- Signing material, defensive: `*.p12`, `*.cer`, `*.p8`, `*.pem`, `*.key`, `.env*`.
- Agent local state: `.claude/settings.local.json`, and `.agents/skills/` +
  `.claude/skills/` if the vendored skill is dropped.

Suggested block:

```gitignore
# Built app and release artefacts
/*.app/
*.xcarchive
*.zip
*.dmg

# Signing material
*.p12
*.p8
*.cer
*.pem
*.key
.env*

# Agent local state and installed skills
.claude/settings.local.json
.agents/skills/
.claude/skills/
```

`*.key` would match a `.key` test fixture if one were ever written to disk under the
repo. Today's fixture is created in a temp folder at test time, so it is safe.
