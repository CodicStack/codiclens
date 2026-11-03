# Contributing

## Getting started

Fork the repo, make your changes on a branch, and open a pull request. For substantial changes, open an issue first so we can align before you invest time.

After your first merged PR you'll be added to [CONTRIBUTORS.md](CONTRIBUTORS.md).

## Setup

**Requirements:** macOS 26.4 or later on Apple Silicon, Xcode 26.4 or later, and cmake (`brew install cmake`).

```bash
Scripts/build-llama.sh   # once, and again when the script's llama.cpp tag changes
xcodebuild -project codiclens.xcodeproj -scheme codiclens -configuration Debug build
```

Or open `codiclens.xcodeproj` in Xcode and press ⌘R. Debug builds sign to run locally, so you don't need an Apple developer account or any signing setup.

`Scripts/build-llama.sh` fetches llama.cpp at a pinned release, applies a small patch and builds static libraries into `Vendor/llama/`, which is not in git. Without it the build stops at `CLlama/CLlama.h` with "llama.cpp is not built".

## Tests

```bash
xcodebuild test -project codiclens.xcodeproj -scheme codiclens
```

The unit tests run inside the app as test host, which starts nothing: no panel, no shortcuts, no folder crawl, no model download. Search by meaning is tested over fakes, so the default run never needs the model files.

Several suites are opt-in, turned on by a `TEST_RUNNER_CODICLENS_*` variable: the real model download, the real embedding helper, real-model search, the meaning ship gate, timing runs and a real Codictate transcription. [AGENTS.md](AGENTS.md#tests) lists each one and what it needs. Run them without parallel testing, or parallel clones race on the same download folder and the same GPU:

```bash
TEST_RUNNER_CODICLENS_EMBEDDING_INTEGRATION=10 xcodebuild test \
  -project codiclens.xcodeproj -scheme codiclens \
  -parallel-testing-enabled NO \
  -only-testing:codiclensTests/EmbeddingIntegrationTests
```

There is no CI, so please run the unit tests before you open a pull request.

## Architecture and terms

- [AGENTS.md](AGENTS.md) is the architecture reference: build, tests, the rules the code follows, how the components connect, and known issues.
- [GLOSSARY.md](GLOSSARY.md) is the shared vocabulary. Use its words (Subject, Action, Panel, Card...) in code, tests and PRs.
- [docs/adr/](docs/adr/) records the decisions behind the code and why.

## Pull requests

- Describe the user-facing change and how you tested it.
- Update AGENTS.md, GLOSSARY.md or an ADR when behavior, terms or a decision changes.
- Add a line under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) when users will notice the change.
- Don't mix refactors with unrelated fixes.

## License

Codiclens is licensed under the Apache License 2.0. By submitting a contribution, you agree it is licensed under the same Apache License 2.0, as section 5 of the license describes.
