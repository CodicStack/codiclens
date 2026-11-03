#!/bin/bash
# Fixture test of the changelog-to-notes step of Scripts/release.sh (Scripts/release-notes.swift).
# Run from anywhere: Scripts/tests/release-notes.sh. Exits non-zero on the first difference.
set -euo pipefail
cd "$(dirname "$0")/../.."
FIXTURE=Scripts/tests/release-notes
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
NOTES=(swift Scripts/release-notes.swift)

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Unreleased becomes 1.4.0 dated 2026-12-07 under a fresh Unreleased; the release body is the section's markdown;
#    the appcast notes hold the newest 5 versions, each tagged with its version and headed "X.Y.Z · D Mon YYYY".
"${NOTES[@]}" --changelog "$FIXTURE/CHANGELOG.md" --version 1.4.0 --date 2026-12-07 --out "$OUT/notes" \
  --renderer "$FIXTURE/fake-render.sh" > /dev/null
for f in CHANGELOG.md release-notes.md Codiclens-1.4.0.html; do
  diff -u "$FIXTURE/expected/$f" "$OUT/notes/$f" || fail "$f differs from $FIXTURE/expected/$f"
done

# 2. --check passes on the fixture and refuses an empty Unreleased, a version already in the changelog, and notes
#    that break the style rules, each with a message naming the problem.
"${NOTES[@]}" --check --changelog "$FIXTURE/CHANGELOG.md" --version 1.4.0 > /dev/null || fail "--check refused the fixture"
refuses() {  # refuses <expected message fragment> <changelog text> [version]
  printf '%s' "$2" > "$OUT/CHANGELOG.md"
  if "${NOTES[@]}" --check --changelog "$OUT/CHANGELOG.md" --version "${3:-1.4.0}" 2> "$OUT/err"; then
    fail "--check accepted a changelog that should be refused ($1)"
  fi
  grep -qF "$1" "$OUT/err" || fail "expected '$1' in: $(cat "$OUT/err")"
}
refuses "nothing under ## Unreleased" $'# Changelog\n\n## Unreleased\n\n## 1.0.0 (2026-11-02)\n\nFirst.\n'
refuses "no ## Unreleased heading" $'# Changelog\n\n## 1.0.0 (2026-11-02)\n\nFirst.\n'
refuses "already has a 1.0.0 section" $'# Changelog\n\n## Unreleased\n\nMore.\n\n## 1.0.0 (2026-11-02)\n\nFirst.\n' 1.0.0
refuses "em dash" $'# Changelog\n\n## Unreleased\n\nFaster \xe2\x80\x94 much faster.\n'
refuses "subheading" $'# Changelog\n\n## Unreleased\n\n### Fixes\n\nFaster.\n'
refuses "ticket number" $'# Changelog\n\n## Unreleased\n\nFaster search (#41).\n'

echo "release notes fixture test passed"
