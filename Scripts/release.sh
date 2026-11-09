#!/bin/bash
# Cuts a Codiclens release on the maintainer's Mac (ADR 0015). The guide is docs/RELEASING.md.
#
#   Scripts/release.sh                 the next patch version (1.0.0 -> 1.0.1); v1.0.0 when there is no tag yet
#   Scripts/release.sh 1.1.0           an explicit version, for a minor or major bump
#   Scripts/release.sh --dry-run       build, notarize, make the DMG and the appcast; no commit, tag or publish
#   Scripts/release.sh --skip-tests    skip the unit-test guard
#
# Guards run before anything builds: on main, clean tree, in sync with origin, version above the last tag, tag free,
# something under "## Unreleased" in CHANGELOG.md, the Developer ID identity, the notarytool profile, the Sparkle key
# (and the project's SPARKLE_PUBLIC_ED_KEY matching it), and the unit tests.
#
# Everything is made under build/release/vX.Y.Z/. Each step leaves a marker in .done/ and a rerun skips the steps that
# finished, so a failed notarization costs one resubmission, not a rebuild. The version goes into the project (and the
# changelog's Unreleased section becomes the release) only in the release commit, made after the DMG and the appcast
# exist; a dry run leaves git untouched. The script never touches /Applications or the site.
set -euo pipefail

REPO=CodicStack/codiclens
TEAM=L256GR2793
NOTARY_PROFILE=codiclens
SPARKLE_ACCOUNT=codiclens
SITE=https://codiclens.codicstack.com

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT=codiclens.xcodeproj
RELEASES=$ROOT/build/release
DERIVED=$RELEASES/DerivedData
PACKAGES=$RELEASES/SourcePackages
SPARKLE_BIN=$PACKAGES/artifacts/sparkle/Sparkle/bin

DRY_RUN=0
SKIP_TESTS=0
VERSION=
REQUESTED=
RESUMING=0
STARTED=0
IDENTITY=
IDENTITY_NAME=
SPARKLE_KEY=

# MARK: - Output

bold=$'\033[1m' red=$'\033[1;31m' green=$'\033[32m' plain=$'\033[0m'
[[ -t 1 ]] || { bold= red= green= plain=; }
say() { printf '%s\n' "${bold}$*${plain}"; }
ok() { printf '  %s\n' "${green}✓${plain} $*"; }
die() {
  printf '%s\n' "${red}error:${plain} $1" >&2
  shift
  local argument line
  for argument in "$@"; do
    while IFS= read -r line; do printf '       %s\n' "$line" >&2; done <<< "$argument"
  done
  exit 1
}

# Runs a command with its output in the step's log; on failure shows the log's tail and stops.
logged() {
  local log=$DIR/logs/$1.log
  shift
  mkdir -p "$DIR/logs"
  if ! "$@" > "$log" 2>&1; then
    tail -n 25 "$log" >&2
    die "$(basename "$1") failed. Full log: $log"
  fi
}

rerun_command() {
  local command="Scripts/release.sh $VERSION"
  ((DRY_RUN)) && command+=" --dry-run"
  ((SKIP_TESTS)) && command+=" --skip-tests"
  printf '%s' "$command"
}

on_exit() {
  local status=$?
  if ((status != 0 && STARTED)); then
    printf '\n%s\n' "Nothing was published. Fix the problem and rerun: $(rerun_command)" >&2
    printf '%s\n' "Finished steps are skipped (markers in ${DIR#"$ROOT/"}/.done)." >&2
  fi
}

# MARK: - Versions

is_version() { [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# version_above A B: A > B, both X.Y.Z.
version_above() {
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    ((a[i] > b[i])) && return 0
    ((a[i] < b[i])) && return 1
  done
  return 1
}

# The highest vX.Y.Z tag here or on origin, without the v; empty when there is none.
last_tag() {
  local tag best=
  for tag in $( (git tag --list 'v*'; git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||') | sort -u); do
    tag=${tag#v}
    is_version "$tag" || continue
    if [[ -z $best ]] || version_above "$tag" "$best"; then best=$tag; fi
  done
  printf '%s' "$best"
}

next_patch() {
  local IFS=.
  local -a parts=($1)
  printf '%s' "${parts[0]}.${parts[1]}.$((parts[2] + 1))"
}

pick_version() {
  local last
  last=$(last_tag)
  if [[ -n $REQUESTED ]]; then
    is_version "$REQUESTED" || die "\"$REQUESTED\" is not a version. Use X.Y.Z, for example 1.1.0."
    VERSION=$REQUESTED
  else
    # A release that was committed but not yet published picks up where it stopped.
    local subject
    subject=$(git log -1 --format=%s)
    if [[ $subject =~ ^Release\ v([0-9.]+)$ && -f $RELEASES/v${BASH_REMATCH[1]}/.done/commit ]]; then
      VERSION=${BASH_REMATCH[1]}
    elif [[ -z $last ]]; then
      VERSION=1.0.0
    else
      VERSION=$(next_patch "$last")
    fi
  fi
  DIR=$RELEASES/v$VERSION
  DONE=$DIR/.done
  if [[ -f $DONE/commit ]]; then
    RESUMING=1
  elif [[ -n $last ]] && ! version_above "$VERSION" "$last"; then
    die "$VERSION is not above the last tag, v$last." \
      "Pick a higher version, or run without one for v$(next_patch "$last")."
  fi
}

# MARK: - Guards

guard_tools() {
  local tool
  for tool in git gh xcodebuild xcrun hdiutil codesign ditto swift security spctl; do
    command -v "$tool" > /dev/null || die "$tool is not on PATH."
  done
  gh auth status --hostname github.com > /dev/null 2>&1 || die "gh is not signed in to GitHub. Run: gh auth login"
  ok "Tools found, gh signed in"
}

guard_main() {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD || echo "a detached HEAD")
  [[ $branch == main ]] || die "On $branch, not main. Releases are cut from main: git switch main"
  ok "On main"
}

guard_clean() {
  local changes
  changes=$(git status --porcelain)
  [[ -z $changes ]] || die "The working tree has changes. Commit or stash them first:" "$changes"
  ok "Working tree clean"
}

guard_in_sync() {
  git fetch --quiet origin main || die "Couldn't fetch origin."
  local here there
  here=$(git rev-parse HEAD)
  there=$(git rev-parse origin/main)
  if [[ $here != "$there" ]]; then
    local ahead behind
    ahead=$(git rev-list --count origin/main..HEAD)
    behind=$(git rev-list --count HEAD..origin/main)
    die "main is not in sync with origin/main ($ahead ahead, $behind behind). Push or pull first."
  fi
  ok "In sync with origin/main"
}

guard_tag_free() {
  if git rev-parse --quiet --verify "refs/tags/v$VERSION" > /dev/null; then
    die "Tag v$VERSION already exists here."
  fi
  if [[ -n $(git ls-remote --tags --refs origin "refs/tags/v$VERSION") ]]; then
    die "Tag v$VERSION already exists on origin."
  fi
  ok "Tag v$VERSION is free"
}

guard_changelog() {
  local message
  if ! message=$(swift Scripts/release-notes.swift --check --changelog CHANGELOG.md --version "$VERSION" 2>&1); then
    die "${message#error: }" "See docs/RELEASING.md, \"The changelog\"."
  fi
  ok "CHANGELOG.md has notes under ## Unreleased"
}

guard_identity() {
  # The certificate's SHA-1, so an expired twin with the same name can't make codesign's choice ambiguous.
  local line
  line=$(security find-identity -v -p codesigning | grep -E "\"Developer ID Application: .*\($TEAM\)\"$" | head -n 1)
  IDENTITY=$(awk '{print $2}' <<< "$line")
  IDENTITY_NAME=$(sed -E 's/^[^"]*"(.*)"$/\1/' <<< "$line")
  [[ -n $line ]] ||
    die "No \"Developer ID Application\" identity for team $TEAM in the keychain." \
      "Install the certificate (Xcode > Settings > Accounts > Manage Certificates), see docs/RELEASING.md."
  ok "$IDENTITY_NAME"
}

guard_notary_profile() {
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null 2>&1; then
    die "The notarytool keychain profile \"$NOTARY_PROFILE\" was not found or doesn't work." \
      "Store it once with notarytool store-credentials, see docs/RELEASING.md, \"One-time setup\"." \
      "Check it with: xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
  fi
  ok "notarytool profile \"$NOTARY_PROFILE\""
}

# The SPARKLE_PUBLIC_ED_KEY build setting, the same in every configuration that sets it.
project_sparkle_key() {
  grep -E '^[[:space:]]*SPARKLE_PUBLIC_ED_KEY = ' "$PROJECT/project.pbxproj" |
    sed -E 's/.*= "?([^";]*)"?;.*/\1/' | sort -u
}

guard_sparkle_key() {
  local keys
  keys=$(project_sparkle_key)
  [[ -n $keys ]] || die "SPARKLE_PUBLIC_ED_KEY is not set in $PROJECT."
  [[ $(wc -l <<< "$keys") -eq 1 ]] || die "SPARKLE_PUBLIC_ED_KEY differs between configurations in $PROJECT:" "$keys"
  SPARKLE_KEY=$keys
  local bytes
  bytes=$(printf '%s' "$SPARKLE_KEY" | base64 -D 2> /dev/null | od -An -v -tx1 | tr -d ' \n')
  [[ ${#bytes} -eq 64 ]] || die "SPARKLE_PUBLIC_ED_KEY in $PROJECT is not a 32-byte base64 key: $SPARKLE_KEY"
  if [[ -z ${bytes//0/} ]]; then
    die "SPARKLE_PUBLIC_ED_KEY in $PROJECT is still the all-zero placeholder." \
      "Generate the Sparkle key and put its public key there, see docs/RELEASING.md, \"One-time setup\"."
  fi
  logged resolve-packages xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme codiclens \
    -clonedSourcePackagesDirPath "$PACKAGES"
  [[ -x $SPARKLE_BIN/generate_keys ]] || die "Sparkle's tools are missing from $SPARKLE_BIN after resolving packages."
  local keychain_key
  # -p only looks the key up; it never generates one.
  if ! keychain_key=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2> /dev/null); then
    die "No Sparkle signing key for account \"$SPARKLE_ACCOUNT\" in the login keychain." \
      "Generate it once (or import the backup), see docs/RELEASING.md, \"One-time setup\"."
  fi
  [[ $keychain_key == "$SPARKLE_KEY" ]] ||
    die "The Sparkle key in the keychain (account \"$SPARKLE_ACCOUNT\") doesn't match SPARKLE_PUBLIC_ED_KEY." \
      "Keychain: $keychain_key" "Project:  $SPARKLE_KEY"
  ok "Sparkle key \"$SPARKLE_ACCOUNT\" matches SPARKLE_PUBLIC_ED_KEY"
}

guard_tests() {
  if ((SKIP_TESTS)); then
    ok "Unit tests skipped (--skip-tests)"
    return
  fi
  say "  Running the unit tests (Debug)…"
  mkdir -p "$RELEASES/logs"
  if ! xcodebuild test -project "$PROJECT" -scheme codiclens -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$PACKAGES" > "$RELEASES/logs/tests.log" 2>&1; then
    grep -E "failed on '|✘|: error:" "$RELEASES/logs/tests.log" | tail -n 25 >&2 || true
    die "The unit tests failed. Full log: $RELEASES/logs/tests.log"
  fi
  ok "Unit tests pass"
}

# A rerun reuses build/release/vX.Y.Z only when it was made from this commit.
guard_same_source() {
  local expected=$1 recorded
  [[ -f $DIR/source-commit ]] || return 0
  recorded=$(cat "$DIR/source-commit")
  [[ $recorded == "$expected" ]] ||
    die "${DIR#"$ROOT/"} was built from ${recorded:0:12}, not ${expected:0:12}." \
      "Start that version over with: rm -rf ${DIR#"$ROOT/"}"
}

guards() {
  say "Checking before building v$VERSION"
  guard_tools
  guard_main
  guard_clean
  guard_in_sync
  guard_tag_free
  guard_changelog
  guard_identity
  guard_notary_profile
  guard_sparkle_key
  guard_tests
  guard_same_source "$(git rev-parse HEAD)"
}

# After the release commit only tagging, pushing and publishing remain.
guards_resuming() {
  say "Resuming v$VERSION after its release commit"
  guard_tools
  guard_main
  guard_clean
  [[ $(git log -1 --format=%s) == "Release v$VERSION" ]] ||
    die "HEAD is not the \"Release v$VERSION\" commit this script made. Check git log before rerunning."
  guard_same_source "$(git rev-parse HEAD^)"
  if git rev-parse --quiet --verify "refs/tags/v$VERSION" > /dev/null; then
    [[ $(git rev-parse "v$VERSION^{commit}") == $(git rev-parse HEAD) ]] ||
      die "Tag v$VERSION exists but doesn't point at the release commit."
  fi
  ok "HEAD is the release commit"
}

# MARK: - Steps

step() {
  local name=$1 title=$2
  shift 2
  if [[ -f $DONE/$name ]]; then
    ok "$title (done earlier)"
    return
  fi
  say "→ $title"
  "$@"
  mkdir -p "$DONE"
  date '+%Y-%m-%dT%H:%M:%S' > "$DONE/$name"
  ok "$title"
}

APP_NAME=Codiclens.app
archive_path() { printf '%s' "$DIR/Codiclens.xcarchive"; }
app_path() { printf '%s' "$DIR/export/$APP_NAME"; }
dmg_path() { printf '%s' "$DIR/Codiclens-$VERSION.dmg"; }
appcast_path() { printf '%s' "$DIR/updates/appcast.xml"; }

do_notes() {
  rm -rf "$DIR/notes"
  logged notes swift Scripts/release-notes.swift --changelog CHANGELOG.md --version "$VERSION" --date "$TODAY" \
    --out "$DIR/notes"
  printf '%s\n' "$TODAY" > "$DIR/notes/DATE"
}

do_llama() {
  logged llama Scripts/build-llama.sh
}

do_archive() {
  rm -rf "$(archive_path)"
  logged archive xcodebuild archive -project "$PROJECT" -scheme codiclens -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$(archive_path)" \
    -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$PACKAGES" \
    ARCHS=arm64 MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION"
}

do_export() {
  rm -rf "$DIR/export"
  mkdir -p "$DIR/export"
  cat > "$DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF
  logged export xcodebuild -exportArchive -archivePath "$(archive_path)" -exportPath "$DIR/export" \
    -exportOptionsPlist "$DIR/ExportOptions.plist"
  # The product is codiclens.app; it ships as Codiclens.app, the name installs already have and Sparkle replaces.
  # Renaming the bundle folder leaves its signature intact.
  local exported=("$DIR/export/"*.app)
  [[ ${#exported[@]} -eq 1 && -d ${exported[0]} ]] || die "The export doesn't hold exactly one app: ${exported[*]}"
  mv "${exported[0]}" "$DIR/export/renaming.app"
  mv "$DIR/export/renaming.app" "$(app_path)"
  verify_app
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2> /dev/null || true; }

# The exported app is what it should be: this version, arm64 only, our Sparkle key, Developer ID signed with the
# hardened runtime and a timestamp, Sparkle's helpers included.
verify_app() {
  local app
  app=$(app_path)
  ls "$DIR/export" | grep -qx "$APP_NAME" || die "The export has no $APP_NAME."
  [[ $(plist_value "$app" CFBundleShortVersionString) == "$VERSION" && $(plist_value "$app" CFBundleVersion) == "$VERSION" ]] ||
    die "$APP_NAME is version $(plist_value "$app" CFBundleShortVersionString) ($(plist_value "$app" CFBundleVersion)), not $VERSION ($VERSION)."
  local archs
  archs=$(lipo -archs "$app/Contents/MacOS/$(plist_value "$app" CFBundleExecutable)")
  [[ $archs == arm64 ]] || die "$APP_NAME is built for \"$archs\", not arm64 only."
  [[ $(plist_value "$app" SUPublicEDKey) == "$(project_sparkle_key)" ]] ||
    die "$APP_NAME's SUPublicEDKey isn't the project's SPARKLE_PUBLIC_ED_KEY."
  logged verify-app codesign --verify --deep --strict --verbose=2 "$app"
  local helper details
  local sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
  for helper in "$app" "$sparkle/Autoupdate" "$sparkle/Updater.app" "$sparkle/XPCServices/Installer.xpc" \
    "$sparkle/XPCServices/Downloader.xpc"; do
    [[ -e $helper ]] || die "Missing from the export: ${helper#"$app/"}"
    details=$(codesign -dvv "$helper" 2>&1)
    grep -q "^Authority=Developer ID Application: .*($TEAM)$" <<< "$details" &&
      grep -q "^Timestamp=" <<< "$details" && grep -Eq "flags=.*runtime" <<< "$details" ||
      die "${helper#"$DIR/"} is not Developer ID signed with the hardened runtime and a timestamp." \
        "$(grep -E '^(Authority|Timestamp|CodeDirectory)' <<< "$details" | tr '\n' ' ')"
  done
}

# notarize FILE NAME: submits FILE with the notarytool profile and waits for Apple's answer.
notarize() {
  local file=$1 name=$2
  local result=$DIR/logs/notarize-$name.json
  mkdir -p "$DIR/logs"
  say "  Waiting for Apple to notarize the $name (usually a few minutes)…"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 1h --output-format json \
    > "$result" 2> "$DIR/logs/notarize-$name.err" || true
  local status id
  status=$(plutil -extract status raw -o - "$result" 2> /dev/null || true)
  id=$(plutil -extract id raw -o - "$result" 2> /dev/null || true)
  if [[ $status != Accepted ]]; then
    local log=
    if [[ -n $id ]]; then
      log=$DIR/logs/notarize-$name-apple.json
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$log" > /dev/null 2>&1 || log=
    fi
    die "Notarizing the $name failed (status: ${status:-no answer})." \
      "notarytool said: $(tr '\n' ' ' < "$DIR/logs/notarize-$name.err")" \
      ${log:+"Apple's log: $log"}
  fi
  ok "Notarized the $name ($id)"
}

# assess TYPE PATH: Gatekeeper accepts PATH as notarized Developer ID.
assess() {
  local verdict
  if [[ $1 == open ]]; then
    verdict=$(spctl --assess --type open --context context:primary-signature -vv "$2" 2>&1 || true)
  else
    verdict=$(spctl --assess --type exec -vv "$2" 2>&1 || true)
  fi
  grep -q ": accepted" <<< "$verdict" && grep -q "source=Notarized Developer ID" <<< "$verdict" ||
    die "Gatekeeper doesn't accept $(basename "$2") as notarized:" "$verdict"
}

do_notarize_app() {
  local app zip
  app=$(app_path)
  zip=$DIR/notarize/Codiclens.zip
  rm -rf "$DIR/notarize"
  mkdir -p "$DIR/notarize"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" app
  logged staple-app xcrun stapler staple "$app"
  logged validate-app xcrun stapler validate "$app"
  assess exec "$app"
  rm -rf "$DIR/notarize"
}

do_dmg() {
  local dmg stage
  dmg=$(dmg_path)
  stage=$DIR/dmg
  rm -rf "$stage" "$dmg"
  mkdir -p "$stage"
  ditto "$(app_path)" "$stage/$APP_NAME"
  ln -s /Applications "$stage/Applications"
  logged dmg hdiutil create -volname Codiclens -srcfolder "$stage" -fs APFS -format ULFO "$dmg"
  rm -rf "$stage"
  logged sign-dmg codesign --sign "$IDENTITY" --timestamp "$dmg"
  logged verify-dmg codesign --verify --verbose=2 "$dmg"
}

do_notarize_dmg() {
  notarize "$(dmg_path)" "disk image"
  logged staple-dmg xcrun stapler staple "$(dmg_path)"
  logged validate-dmg xcrun stapler validate "$(dmg_path)"
  assess open "$(dmg_path)"
}

do_appcast() {
  local updates=$DIR/updates
  rm -rf "$updates"
  mkdir -p "$updates"
  # The feed keeps the previous items, so it starts from the one the latest release carries.
  local published
  published=$(gh release list --repo "$REPO" --exclude-drafts --limit 1 --json tagName --jq length) ||
    die "Couldn't list the releases of $REPO."
  if ((published > 0)); then
    gh release download --repo "$REPO" --pattern appcast.xml --dir "$updates" ||
      die "Couldn't download appcast.xml from the latest release of $REPO."
  fi
  cp "$(dmg_path)" "$DIR/notes/Codiclens-$VERSION.html" "$updates/"
  logged appcast "$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --full-release-notes-url "$SITE/releases#v$VERSION" --link "$SITE" \
    --maximum-deltas 0 --embed-release-notes "$updates"
  verify_appcast
}

verify_appcast() {
  local appcast
  appcast=$(appcast_path)
  [[ -f $appcast ]] || die "generate_appcast wrote no appcast.xml."
  grep -q "<sparkle:version>$VERSION</sparkle:version>" "$appcast" || die "appcast.xml has no item for $VERSION."
  grep -q "data-sparkle-version=\"$VERSION\"" "$appcast" || die "appcast.xml's $VERSION item doesn't embed the notes."
  grep -q "releases/download/v$VERSION/Codiclens-$VERSION.dmg" "$appcast" ||
    die "appcast.xml doesn't point the $VERSION item at its DMG on the release."
  grep -q "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>" "$appcast" ||
    die "appcast.xml doesn't mark $VERSION as arm64 only."
  logged verify-appcast "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$appcast"
}

do_commit() {
  cp "$DIR/notes/CHANGELOG.md" CHANGELOG.md
  sed -i '' -E "s/(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [^;]+;/\1 = $VERSION;/" "$PROJECT/project.pbxproj"
  git add CHANGELOG.md "$PROJECT/project.pbxproj"
  if ! git commit --quiet -m "Release v$VERSION"; then
    git reset --quiet HEAD -- CHANGELOG.md "$PROJECT/project.pbxproj"
    git checkout -- CHANGELOG.md "$PROJECT/project.pbxproj"
    die "Committing \"Release v$VERSION\" failed; CHANGELOG.md and the project are back as they were."
  fi
}

do_tag() {
  if git rev-parse --quiet --verify "refs/tags/v$VERSION" > /dev/null; then return; fi
  git tag -a "v$VERSION" -m "Codiclens $VERSION"
}

do_push() {
  git push --quiet --atomic origin main "refs/tags/v$VERSION"
}

do_release_draft() {
  if gh release view "v$VERSION" --repo "$REPO" > /dev/null 2>&1; then return; fi
  gh release create "v$VERSION" --repo "$REPO" --draft --verify-tag --title "Codiclens $VERSION" \
    --notes-file "$DIR/notes/release-notes.md" > /dev/null
}

do_release_upload() {
  gh release upload "v$VERSION" --repo "$REPO" --clobber "$(dmg_path)" "$(appcast_path)"
}

do_release_publish() {
  gh release edit "v$VERSION" --repo "$REPO" --draft=false --latest > /dev/null
}

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Once published, the DMG is the release's copy of the app. The archive's app, the export and the build product each
# stay registered with Launch Services, so every release left three more Codiclens in Spotlight and Open With. They go,
# unregistered first; the dSYMs, the DMG, the appcast, the notes and the logs stay.
do_tidy() {
  local app
  for app in "$(archive_path)/Products/Applications/"*.app "$DIR/export/"*.app \
    "$DERIVED/Build/Intermediates.noindex/ArchiveIntermediates/codiclens/BuildProductsPath/Release/codiclens.app"; do
    [[ -d $app ]] || continue
    "$LSREGISTER" -u "$app" 2> /dev/null || true
    rm -rf "$app"
  done
}

# MARK: - Main

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

parse_args() {
  local argument
  for argument in "$@"; do
    case $argument in
      --dry-run) DRY_RUN=1 ;;
      --skip-tests) SKIP_TESTS=1 ;;
      -h | --help) usage; exit 0 ;;
      -*) die "Unknown option $argument." "$(usage)" ;;
      *) [[ -z $REQUESTED ]] || die "Give at most one version."; REQUESTED=$argument ;;
    esac
  done
}

main() {
  parse_args "$@"
  cd "$ROOT"
  TODAY=$(date '+%Y-%m-%d')
  pick_version
  if ((RESUMING)); then guards_resuming; else guards; fi

  mkdir -p "$DONE"
  STARTED=1
  trap on_exit EXIT
  if ((!RESUMING)); then
    git rev-parse HEAD > "$DIR/source-commit"
    # The notes and the appcast carry the release date: made on another day, they're made again.
    if [[ -f $DONE/notes && $(cat "$DIR/notes/DATE" 2> /dev/null) != "$TODAY" ]]; then
      rm -f "$DONE/notes" "$DONE/appcast"
    fi
  fi

  say "Releasing v$VERSION in ${DIR#"$ROOT/"}$( ((DRY_RUN)) && echo " (dry run)")"
  step notes "Release notes" do_notes
  step llama "llama.cpp" do_llama
  step archive "Archive (Release, arm64)" do_archive
  step export "Export with Developer ID" do_export
  step notarize-app "Notarize and staple the app" do_notarize_app
  step dmg "DMG (APFS, lzfse), signed" do_dmg
  step notarize-dmg "Notarize and staple the DMG" do_notarize_dmg
  step appcast "Appcast (signed, notes embedded, no deltas)" do_appcast

  if ((DRY_RUN)); then
    STARTED=0
    say "Dry run done. Nothing was committed, tagged or published."
    printf '  %s\n' "DMG:     $(dmg_path)" "Appcast: $(appcast_path)" "Notes:   $DIR/notes/release-notes.md"
    printf '  %s\n' "Run Scripts/release.sh $VERSION to publish it; the finished steps are reused."
    return
  fi

  step commit "Commit \"Release v$VERSION\"" do_commit
  step tag "Tag v$VERSION" do_tag
  step push "Push main and v$VERSION" do_push
  step release-draft "Draft the GitHub release" do_release_draft
  step release-upload "Upload the DMG and appcast.xml" do_release_upload
  step release-publish "Publish the release" do_release_publish
  step tidy "Remove the build's app copies (the DMG stays)" do_tidy
  STARTED=0
  say "Released v$VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
}

# Sourcing the script defines its functions without running it.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
