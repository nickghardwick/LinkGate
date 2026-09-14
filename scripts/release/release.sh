#!/bin/bash

set -euo pipefail

fail() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
dist="$repo_root/dist"

# shellcheck source=config.sh
source "$script_dir/config.sh"

clear_dist() {
    [ -d "$dist" ] || return 0
    find "$dist" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

atomic_replace_dist() {
    local source=$1
    local destination=$2

    # macOS rename(2) atomically replaces the already-empty dist directory
    # because final_release is created as its sibling on the same filesystem.
    xcrun swift -e '
import Darwin

let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
if rename(arguments[1], arguments[2]) != 0 {
    perror("atomic directory publication")
    exit(1)
}
' "$source" "$destination"
}

workspace=
final_release=
cleanup() {
    local status=${1:-$?}

    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$workspace" ] && [ -d "$workspace" ]; then
        rm -rf -- "$workspace"
    fi
    if [ -n "$final_release" ] && [ -d "$final_release" ]; then
        rm -rf -- "$final_release"
    fi
    if [ "$status" -ne 0 ]; then
        mkdir -p -- "$dist"
        clear_dist
    fi
    exit "$status"
}

mkdir -p -- "$dist"
clear_dist
trap cleanup EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

[ "$#" -eq 0 ] || fail 'release.sh does not accept release version or build arguments'
if [ -n "${VERSION+x}" ] || [ -n "${BUILD+x}" ]; then
    fail 'VERSION and BUILD overrides are not permitted for releases'
fi

workspace=$(mktemp -d "${TMPDIR:-/tmp}/linkgate-release.XXXXXX")
metadata="$workspace/release-metadata.json"
derived_data="$workspace/DerivedData"
app="$derived_data/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"
notary_zip="$workspace/$PRODUCT_NAME.zip"
staging="$workspace/dmg-staging"

"$script_dir/preflight.sh" \
    --repo-root "$repo_root" \
    --config scripts/release/config.sh \
    --metadata-out "$metadata"

marketing_version=$(plutil -extract marketing_version raw -o - "$metadata" 2>/dev/null) || fail 'could not read marketing version from release metadata'
source_commit=$(plutil -extract source_commit raw -o - "$metadata" 2>/dev/null) || fail 'could not read source commit from release metadata'
source_index_tree=$(plutil -extract source_index_tree raw -o - "$metadata" 2>/dev/null) || fail 'could not read source index snapshot from release metadata'
signing_identity=$(plutil -extract signing_identity raw -o - "$metadata" 2>/dev/null) || fail 'could not read signing identity from release metadata'
[ -n "$source_commit" ] || fail 'release metadata did not contain a source commit'
[ -n "$source_index_tree" ] || fail 'release metadata did not contain a source index snapshot'
[ -n "$signing_identity" ] || fail 'release metadata did not contain a signing identity'
assert_source_snapshot() {
    local current_source_commit
    local current_source_index_tree

    current_source_commit=$(cd -- "$repo_root" && git rev-parse HEAD) || fail 'could not determine current source revision'
    [ "$current_source_commit" = "$source_commit" ] || fail 'source revision changed after preflight'
    current_source_index_tree=$(cd -- "$repo_root" && git write-tree) || fail 'could not snapshot current staged source tree'
    [ "$current_source_index_tree" = "$source_index_tree" ] || fail 'staged source tree changed after preflight'
    (cd -- "$repo_root" && git diff --quiet) || fail 'tracked working tree changed after preflight'
    local untracked_files

    untracked_files=$(cd -- "$repo_root" && git ls-files --others --exclude-standard)
    [ -z "$untracked_files" ] || fail "working tree gained untracked files after preflight: $untracked_files"
}

assert_source_snapshot
source_snapshot="$workspace/source"
mkdir -p -- "$source_snapshot"
(cd -- "$repo_root" && git archive --format=tar "$source_commit") | tar -x -C "$source_snapshot" || fail 'could not create source snapshot from the preflight commit'
artifact="$PRODUCT_NAME-$marketing_version.dmg"
dmg="$workspace/$artifact"
final_release=$(mktemp -d "$(dirname -- "$dist")/.linkgate-release-final.XXXXXX")
checksum="$final_release/$artifact.sha256"
manifest="$final_release/$PRODUCT_NAME-$marketing_version.release.json"
built_observed="$workspace/built-observed.json"
stapled_observed="$workspace/stapled-observed.json"
dmg_observed="$workspace/dmg-observed.json"
final_dmg_observed="$workspace/final-dmg-observed.json"

xcodebuild \
    -project "$source_snapshot/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    build

assert_source_snapshot

[ -d "$app" ] || fail "release build did not produce $PRODUCT_NAME.app"
sign_sparkle_runtime() {
    local sparkle_framework=$app/Contents/Frameworks/Sparkle.framework
    local sparkle_runtime=$sparkle_framework/Versions/B
    local installer=$sparkle_runtime/XPCServices/Installer.xpc
    local downloader=$sparkle_runtime/XPCServices/Downloader.xpc
    local autoupdate=$sparkle_runtime/Autoupdate
    local updater=$sparkle_runtime/Updater.app

    [ -d "$sparkle_framework" ] || fail 'release build is missing Sparkle.framework'
    [ -d "$installer" ] || fail 'release build is missing the Sparkle Installer XPC service'
    [ -d "$downloader" ] || fail 'release build is missing the Sparkle Downloader XPC service'
    [ -f "$autoupdate" ] && [ -x "$autoupdate" ] || fail 'release build is missing the Sparkle Autoupdate helper'
    [ -d "$updater" ] || fail 'release build is missing the Sparkle Updater application'

    # Sparkle 2.9.6 requires explicitly signing its approved runtime
    # inside-out for non-Archive distribution workflows. Do not use --deep:
    # Downloader may carry service-specific entitlements.
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$installer"
    codesign --verify --strict --verbose=2 "$installer"

    codesign --force --sign "$signing_identity" --options runtime --timestamp --preserve-metadata=entitlements "$downloader"
    codesign --verify --strict --verbose=2 "$downloader"

    codesign --force --sign "$signing_identity" --options runtime --timestamp "$autoupdate"
    codesign --verify --strict --verbose=2 "$autoupdate"

    codesign --force --sign "$signing_identity" --options runtime --timestamp "$updater"
    codesign --verify --strict --verbose=2 "$updater"

    codesign --force --sign "$signing_identity" --options runtime --timestamp "$sparkle_framework"
    codesign --verify --strict --verbose=2 "$sparkle_framework"
}

sign_sparkle_runtime
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app"
"$script_dir/validate-app.sh" --app "$app" --metadata "$metadata" --observed-out "$built_observed"

ditto -c -k --keepParent "$app" "$notary_zip"
xcrun notarytool submit "$notary_zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
"$script_dir/validate-app.sh" --app "$app" --metadata "$metadata" --observed-out "$stapled_observed" --require-stapled-ticket

mkdir -p -- "$staging"
cp -R "$app" "$staging/$PRODUCT_NAME.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$staging" -ov -format UDZO "$dmg"
TMPDIR="$workspace" "$script_dir/validate-dmg.sh" --dmg "$dmg" --metadata "$metadata" --observed-out "$dmg_observed" --require-stapled-ticket

cp "$dmg" "$final_release/$artifact"
final_dmg="$final_release/$artifact"
TMPDIR="$workspace" "$script_dir/validate-dmg.sh" --dmg "$final_dmg" --metadata "$metadata" --observed-out "$final_dmg_observed" --require-stapled-ticket
cmp -s "$dmg_observed" "$final_dmg_observed" || fail 'final staged DMG metadata did not match the packaged DMG'
(cd -- "$final_release" && shasum -a 256 "$artifact") >"$checksum"
sha256=$(awk 'NR == 1 { print $1 }' "$checksum")
[ -n "$sha256" ] || fail 'could not read DMG SHA-256 digest'
assert_source_snapshot
xcode_version=$(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')
macos_version=$(sw_vers -productVersion)

xcrun swift "$script_dir/ReleaseSupport.swift" manifest-write \
    --metadata "$metadata" \
    --source-commit "$source_commit" \
    --xcode-version "$xcode_version" \
    --macos-version "$macos_version" \
    --artifact "$artifact" \
    --sha256 "$sha256" \
    --output "$manifest"
xcrun swift "$script_dir/ReleaseSupport.swift" manifest-validate \
    --manifest "$manifest" \
    --checksum "$checksum" \
    --observed "$final_dmg_observed" \
    --dmg "$final_dmg"

expected_final_entries=$(printf '%s\n' "$artifact" "$artifact.sha256" "${PRODUCT_NAME}-${marketing_version}.release.json" | LC_ALL=C sort)
actual_final_entries=$(find "$final_release" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
[ "$actual_final_entries" = "$expected_final_entries" ] || fail 'final release staging directory has unexpected contents'

assert_source_snapshot
atomic_replace_dist "$final_release" "$dist" || fail 'could not publish complete release directory'
assert_source_snapshot
final_release=
