#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
fixtures="$script_dir/fixtures"
preflight="$repo_root/scripts/release/preflight.sh"
validate_app="$repo_root/scripts/release/validate-app.sh"
config="$repo_root/scripts/release/config.sh"
support="$repo_root/scripts/release/ReleaseSupport.swift"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/linkgate-release-preflight-tests.XXXXXX")

cleanup() {
    rm -rf "$tmp"
}

trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_no_file() {
    [ ! -e "$1" ] || fail "did not expect file: $1"
}

assert_contains() {
    local file=$1
    local expected=$2

    grep -F -- "$expected" "$file" >/dev/null || fail "expected $file to contain: $expected"
}

assert_not_contains() {
    local file=$1
    local unexpected=$2

    if grep -F -- "$unexpected" "$file" >/dev/null; then
        fail "did not expect $file to contain: $unexpected"
    fi
}

assert_precedes() {
    local file=$1
    local first=$2
    local second=$3
    local first_line
    local second_line

    first_line=$(grep -n -F -- "$first" "$file" | head -n 1 | cut -d: -f1) || fail "expected $file to contain: $first"
    second_line=$(grep -n -F -- "$second" "$file" | head -n 1 | cut -d: -f1) || fail "expected $file to contain: $second"
    [ "$first_line" -lt "$second_line" ] || fail "expected $first to precede $second in $file"
}

assert_json_value() {
    local file=$1
    local key=$2
    local expected=$3
    local actual

    actual=$(plutil -extract "${key#.}" raw -o - "$file") || fail "could not read $key from $file"
    [ "$actual" = "$expected" ] || fail "expected $key in $file to be $expected, got $actual"
}

assert_fails() {
    local label=$1
    shift
    local stdout="$tmp/$label.stdout"
    local stderr="$tmp/$label.stderr"

    if "$@" >"$stdout" 2>"$stderr"; then
        fail "expected command to fail: $label"
    fi

    [ -s "$stderr" ] || fail "expected actionable stderr from failing command: $label"
}

write_config() {
    local destination=$1

    cat >"$destination" <<'CONFIG'
export PRODUCT_NAME=LinkGate
export PROJECT=LinkGate.xcodeproj
export SCHEME=LinkGate
export CONFIGURATION=Release
export BUNDLE_ID=com.nickghardwick.LinkGate
export TEAM_ID=Z8A8ZWCZ45
export DEPLOYMENT_TARGET=14.0
export SIGNING_IDENTITY_PREFIX='Developer ID Application'
export NOTARY_PROFILE=linkgate-notary
export DMG_VOLUME_NAME=LinkGate
CONFIG
}

write_fake_repository() {
    local destination=$1

    mkdir -p "$destination/LinkGate.xcodeproj" "$destination/scripts/release"
    printf '// controlled project fixture\n' >"$destination/LinkGate.xcodeproj/project.pbxproj"
    cp "$support" "$destination/scripts/release/ReleaseSupport.swift"
    write_config "$destination/config.sh"
    git -C "$destination" init -q -b main
    git -C "$destination" config user.name 'LinkGate Release Test'
    git -C "$destination" config user.email 'release-test@example.invalid'
    git -C "$destination" add .
    git -C "$destination" commit -qm 'fixture baseline'
}

write_stubs() {
    local destination=$1

    mkdir -p "$destination"

    cat >"$destination/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'xcrun %s\n' "$*" >>"$STUB_LOG"

if [ "$1" = "--find" ]; then
    [ "$2" = "${MISSING_TOOL:-}" ] && exit 1
    printf '%s/%s\n' "$STUB_BIN" "$2"
    exit 0
fi

if [ "$1" = "notarytool" ] && [ "$2" = "history" ]; then
    if [ "${NOTARY_USABLE:-1}" != 1 ]; then
        printf 'credential-token-must-not-be-logged: profile unavailable\n' >&2
        exit 1
    fi
    printf 'history: no submissions\n'
    exit 0
fi

if [ "$1" = "stapler" ] && [ "$2" = "validate" ]; then
    [ "${STAPLER_VALIDATE_OK:-1}" = 1 ] || exit 1
    exit 0
fi

exec "$REAL_XCRUN" "$@"
STUB

    cat >"$destination/security" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'security %s\n' "$*" >>"$STUB_LOG"
printf '  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Developer ID Application: %s (%s)"\n' "${SECURITY_IDENTITY_NAME:-Nicholas Hardwick}" "${SECURITY_TEAM_ID:-Z8A8ZWCZ45}"
printf '     1 valid identities found\n'
STUB

    cat >"$destination/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'xcodebuild %s\n' "$*" >>"$STUB_LOG"
case " $* " in
    *' build '*) : >"$BUILD_MARKER" ;;
esac
cat "$BUILD_SETTINGS_JSON"
[ -z "${XCODEBUILD_STDERR_WARNING:-}" ] || printf '%s\n' "$XCODEBUILD_STDERR_WARNING" >&2
STUB

    cat >"$destination/lipo" <<'STUB'
#!/bin/bash
set -euo pipefail

printf '%s\n' "${LIPO_ARCHS:-arm64 x86_64}"
STUB

    cat >"$destination/codesign" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'codesign %s\n' "$*" >>"$STUB_LOG"
if [ "$1" = "--verify" ]; then
    target=${!#}
    if [ -n "${NESTED_CODESIGN_VERIFY_TARGET:-}" ] && [[ "$target" == *"$NESTED_CODESIGN_VERIFY_TARGET" ]]; then
        [ "${NESTED_CODESIGN_VERIFY_OK:-1}" = 1 ] || exit 1
    fi
    [ "${CODESIGN_VERIFY_OK:-1}" = 1 ] || exit 1
    exit 0
fi

if [ "$1" = "--display" ]; then
    target=${!#}
    signing_prefix=${SIGNING_PREFIX:-Developer ID Application}
    signing_name=${SIGNING_NAME:-LinkGate}
    signing_team_id=${SIGNING_TEAM_ID:-Z8A8ZWCZ45}
    hardened_runtime=${HARDENED_RUNTIME:-1}
    secure_timestamp=${SECURE_TIMESTAMP:-1}
    if [ -n "${NESTED_SIGNING_TARGET:-}" ] && [[ "$target" == *"$NESTED_SIGNING_TARGET" ]]; then
        signing_prefix=${NESTED_SIGNING_PREFIX:-$signing_prefix}
        signing_name=${NESTED_SIGNING_NAME:-$signing_name}
        signing_team_id=${NESTED_SIGNING_TEAM_ID:-$signing_team_id}
        hardened_runtime=${NESTED_HARDENED_RUNTIME:-$hardened_runtime}
        secure_timestamp=${NESTED_SECURE_TIMESTAMP:-$secure_timestamp}
    fi
    printf 'Authority=%s: %s (%s)\n' "$signing_prefix" "$signing_name" "$signing_team_id" >&2
    printf 'TeamIdentifier=%s\n' "$signing_team_id" >&2
    [ "$hardened_runtime" = 1 ] && printf 'flags=0x10000(runtime)\n' >&2
    [ "$secure_timestamp" = 1 ] && printf 'Timestamp=2026-09-11 00:00:00 +0000\n' >&2
    exit 0
fi

exit 0
STUB

    cat >"$destination/spctl" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'spctl %s\n' "$*" >>"$STUB_LOG"
[ "${SPCTL_OK:-1}" = 1 ] || exit 1
printf '%s: accepted\n' "${!#}"
STUB

    chmod +x "$destination/xcrun" "$destination/security" "$destination/xcodebuild" "$destination/lipo" "$destination/codesign" "$destination/spctl"
}

run_preflight() {
    local repository=$1
    local metadata_out=$2
    shift 2

    (
        cd "$tmp"
        env \
            PATH="$stub_bin:$PATH" \
            STUB_BIN="$stub_bin" \
            STUB_LOG="$stub_log" \
            BUILD_MARKER="$build_marker" \
            BUILD_SETTINGS_JSON="$build_settings" \
            REAL_XCRUN="$real_xcrun" \
            "$@" \
            bash "$preflight" --repo-root "$repository" --config config.sh --metadata-out "$metadata_out"
    )
}

run_preflight_with_positional_override() {
    local repository=$1
    local metadata_out=$2
    local override=$3

    (
        cd "$tmp"
        env \
            PATH="$stub_bin:$PATH" \
            STUB_BIN="$stub_bin" \
            STUB_LOG="$stub_log" \
            BUILD_MARKER="$build_marker" \
            BUILD_SETTINGS_JSON="$build_settings" \
            REAL_XCRUN="$real_xcrun" \
            bash "$preflight" --repo-root "$repository" --config config.sh --metadata-out "$metadata_out" "$override"
    )
}

run_preflight_with_config() {
    local repository=$1
    local metadata_out=$2
    local config_path=$3
    shift 3

    (
        cd "$tmp"
        env \
            PATH="$stub_bin:$PATH" \
            STUB_BIN="$stub_bin" \
            STUB_LOG="$stub_log" \
            BUILD_MARKER="$build_marker" \
            BUILD_SETTINGS_JSON="$build_settings" \
            REAL_XCRUN="$real_xcrun" \
            "$@" \
            bash "$preflight" --repo-root "$repository" --config "$config_path" --metadata-out "$metadata_out"
    )
}

run_validate_app() {
    local app=$1
    local metadata=$2
    local observed_out=$3
    shift 3

    env \
        PATH="$stub_bin:$PATH" \
        STUB_BIN="$stub_bin" \
        STUB_LOG="$stub_log" \
        "$@" \
        bash "$validate_app" --app "$app" --metadata "$metadata" --observed-out "$observed_out"
}

run_validate_app_require_stapled_ticket() {
    local app=$1
    local metadata=$2
    local observed_out=$3
    shift 3

    env \
        PATH="$stub_bin:$PATH" \
        STUB_BIN="$stub_bin" \
        STUB_LOG="$stub_log" \
        "$@" \
        bash "$validate_app" --app "$app" --metadata "$metadata" --observed-out "$observed_out" --require-stapled-ticket
}

new_preflight_case() {
    local name=$1

    case_root="$tmp/preflight-$name"
    fake_repo="$case_root/repository"
    stub_bin="$case_root/bin"
    stub_log="$case_root/stubs.log"
    build_marker="$case_root/build-ran"
    build_settings="$case_root/build-settings.json"
    metadata_out="$case_root/metadata.json"
    mkdir -p "$case_root"
    cp "$fixtures/show-build-settings-valid.json" "$build_settings"
    write_fake_repository "$fake_repo"
    write_stubs "$stub_bin"
}

assert_config_exports() {
    local output="$tmp/config-values"

    env -i bash -c '
        source "$1"
        printf "%s\\n" "$PRODUCT_NAME|$PROJECT|$SCHEME|$CONFIGURATION|$BUNDLE_ID|$TEAM_ID|$DEPLOYMENT_TARGET|$SIGNING_IDENTITY_PREFIX|$NOTARY_PROFILE|$DMG_VOLUME_NAME"
    ' bash "$config" >"$output"
    [ "$(cat "$output")" = 'LinkGate|LinkGate.xcodeproj|LinkGate|Release|com.nickghardwick.LinkGate|Z8A8ZWCZ45|14.0|Developer ID Application|linkgate-notary|LinkGate' ] || fail 'config exports do not match the frozen release policy'
}

assert_preflight_failure_before_build() {
    local label=$1
    shift

    assert_fails "$label" run_preflight "$fake_repo" "$metadata_out" "$@"
    assert_no_file "$metadata_out"
    assert_no_file "$build_marker"
}

assert_validation_failure() {
    local label=$1
    shift
    local app=$1
    local metadata=$2
    local observed_out=$3
    shift 3

    assert_fails "$label" run_validate_app "$app" "$metadata" "$observed_out" "$@"
    assert_no_file "$observed_out"
}

for required in "$config" "$preflight" "$validate_app" "$support"; do
    assert_file "$required"
done

real_xcrun=$(command -v xcrun) || fail 'xcrun is required to exercise the existing ReleaseSupport.swift fixture helper'
assert_config_exports

new_preflight_case clean-main
run_preflight "$fake_repo" "$metadata_out"
assert_file "$metadata_out"
assert_no_file "$build_marker"
fake_repo_commit=$(git -C "$fake_repo" rev-parse HEAD)
fake_repo_index_tree=$(git -C "$fake_repo" write-tree)
assert_json_value "$metadata_out" '.source_commit' "$fake_repo_commit"
assert_json_value "$metadata_out" '.source_index_tree' "$fake_repo_index_tree"
assert_json_value "$metadata_out" '.product' 'LinkGate'
assert_json_value "$metadata_out" '.marketing_version' '0.1.0'
assert_json_value "$metadata_out" '.build' '1'
assert_json_value "$metadata_out" '.bundle_id' 'com.nickghardwick.LinkGate'
assert_json_value "$metadata_out" '.deployment_target' '14.0'
assert_json_value "$metadata_out" '.signing_identity' 'Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)'
assert_contains "$stub_log" 'xcrun notarytool history --keychain-profile linkgate-notary'
[ "$(grep -c '^xcrun notarytool history ' "$stub_log")" -eq 1 ] || fail 'preflight must probe the notary profile exactly once'

new_preflight_case build-settings-stderr-warning
run_preflight "$fake_repo" "$metadata_out" XCODEBUILD_STDERR_WARNING='xcodebuild: warning: Using the first of multiple matching destinations'
assert_file "$metadata_out"
assert_json_value "$metadata_out" '.product' 'LinkGate'
assert_json_value "$metadata_out" '.marketing_version' '0.1.0'
assert_json_value "$metadata_out" '.build' '1'
assert_json_value "$metadata_out" '.bundle_id' 'com.nickghardwick.LinkGate'
assert_json_value "$metadata_out" '.deployment_target' '14.0'

new_preflight_case dirty-unstaged
printf '// uncommitted change\n' >>"$fake_repo/LinkGate.xcodeproj/project.pbxproj"
assert_preflight_failure_before_build dirty-unstaged

new_preflight_case dirty-staged
printf '// staged change\n' >>"$fake_repo/LinkGate.xcodeproj/project.pbxproj"
git -C "$fake_repo" add LinkGate.xcodeproj/project.pbxproj
assert_preflight_failure_before_build dirty-staged

new_preflight_case dirty-untracked
printf 'untracked\n' >"$fake_repo/untracked-release-input"
assert_preflight_failure_before_build dirty-untracked

new_preflight_case wrong-branch
git -C "$fake_repo" checkout -qb release-candidate
assert_preflight_failure_before_build wrong-branch

new_preflight_case missing-project-metadata
sed '/"MARKETING_VERSION":/d' "$fixtures/show-build-settings-valid.json" >"$build_settings"
assert_preflight_failure_before_build missing-project-metadata

new_preflight_case wrong-project-bundle-id
sed 's/"PRODUCT_BUNDLE_IDENTIFIER": "com.nickghardwick.LinkGate"/"PRODUCT_BUNDLE_IDENTIFIER": "com.example.Other"/' "$fixtures/show-build-settings-valid.json" >"$build_settings"
assert_preflight_failure_before_build wrong-project-bundle-id

new_preflight_case missing-project-bundle-id
sed '/"PRODUCT_BUNDLE_IDENTIFIER":/d' "$fixtures/show-build-settings-valid.json" >"$build_settings"
assert_preflight_failure_before_build missing-project-bundle-id

new_preflight_case wrong-project-deployment-target
sed 's/"MACOSX_DEPLOYMENT_TARGET": "14.0"/"MACOSX_DEPLOYMENT_TARGET": "15.0"/' "$fixtures/show-build-settings-valid.json" >"$build_settings"
assert_preflight_failure_before_build wrong-project-deployment-target

new_preflight_case missing-project-deployment-target
sed '/"MACOSX_DEPLOYMENT_TARGET":/d' "$fixtures/show-build-settings-valid.json" >"$build_settings"
assert_preflight_failure_before_build missing-project-deployment-target

for missing_tool in xcodebuild codesign notarytool stapler hdiutil; do
    new_preflight_case "missing-$missing_tool"
    assert_preflight_failure_before_build "missing-$missing_tool" MISSING_TOOL="$missing_tool"
done

new_preflight_case unusable-notary-profile
assert_preflight_failure_before_build unusable-notary-profile NOTARY_USABLE=0
assert_contains "$tmp/unusable-notary-profile.stderr" 'notary'
if grep -F 'credential-token-must-not-be-logged' "$tmp/unusable-notary-profile.stderr" >/dev/null; then
    fail 'preflight leaked notary command output'
fi

new_preflight_case wrong-signing-team
assert_preflight_failure_before_build wrong-signing-team SECURITY_TEAM_ID=OTHERTEAM123

new_preflight_case version-override
assert_preflight_failure_before_build version-override VERSION=9.9

new_preflight_case build-override
assert_preflight_failure_before_build build-override BUILD=99

new_preflight_case positional-override
assert_fails positional-override run_preflight_with_positional_override "$fake_repo" "$metadata_out" 9.9
assert_no_file "$metadata_out"
assert_no_file "$build_marker"

new_preflight_case outside-config
outside_config="$case_root/outside-config.sh"
outside_config_marker="$case_root/outside-config-ran"
cat >"$outside_config" <<'CONFIG'
: >"$OUTSIDE_CONFIG_MARKER"
export BUNDLE_ID=com.example.Evil
CONFIG
assert_fails outside-config run_preflight_with_config "$fake_repo" "$metadata_out" "$outside_config" OUTSIDE_CONFIG_MARKER="$outside_config_marker"
assert_no_file "$outside_config_marker"
assert_no_file "$metadata_out"
assert_no_file "$build_marker"

new_preflight_case relative-outside-config
outside_config="$case_root/outside-config.sh"
outside_config_marker="$case_root/outside-config-ran"
cat >"$outside_config" <<'CONFIG'
: >"$OUTSIDE_CONFIG_MARKER"
export BUNDLE_ID=com.example.Evil
CONFIG
assert_fails relative-outside-config run_preflight_with_config "$fake_repo" "$metadata_out" ../outside-config.sh OUTSIDE_CONFIG_MARKER="$outside_config_marker"
assert_no_file "$outside_config_marker"
assert_no_file "$metadata_out"
assert_no_file "$build_marker"

new_preflight_case symlink-outside-config
outside_config="$case_root/outside-config.sh"
outside_config_marker="$case_root/outside-config-ran"
cat >"$outside_config" <<'CONFIG'
: >"$OUTSIDE_CONFIG_MARKER"
export BUNDLE_ID=com.example.Evil
CONFIG
ln -s "$outside_config" "$fake_repo/linked-outside-config.sh"
assert_fails symlink-outside-config run_preflight_with_config "$fake_repo" "$metadata_out" linked-outside-config.sh OUTSIDE_CONFIG_MARKER="$outside_config_marker"
assert_no_file "$outside_config_marker"
assert_no_file "$metadata_out"
assert_no_file "$build_marker"

valid_metadata="$tmp/valid-metadata.json"
cat >"$valid_metadata" <<'JSON'
{
  "product": "LinkGate",
  "marketing_version": "0.1.0",
  "build": "1",
  "bundle_id": "com.nickghardwick.LinkGate",
  "architectures": ["arm64", "x86_64"],
  "deployment_target": "14.0",
  "signing_identity": "Developer ID Application: LinkGate (Z8A8ZWCZ45)"
}
JSON

configure_approved_sparkle_info() {
    local plist=$1/Contents/Info.plist

    plutil -insert SUFeedURL -string 'https://nickghardwick.github.io/LinkGate/updates/appcast.xml' "$plist"
    plutil -insert SUPublicEDKey -string 'En8Ohgkw8WSkc/10bYvg692dCDZUeb+w30bCOqR+qkU=' "$plist"
}

install_expected_sparkle_runtime() {
    local bundle=$1
    local framework=$bundle/Contents/Frameworks/Sparkle.framework/Versions/B
    local framework_root=$bundle/Contents/Frameworks/Sparkle.framework
    local framework_info=$framework/Resources/Info.plist
    local code_signature
    local executable

    # These paths are the observed Xcode Release layout for Sparkle 2.9.6.
    for code_signature in \
        Contents/_CodeSignature \
        Contents/Frameworks/Sparkle.framework/Versions/B/_CodeSignature \
        Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/_CodeSignature \
        Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/_CodeSignature \
        Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/_CodeSignature; do
        mkdir -p "$bundle/$code_signature"
    done

    mkdir -p "$(dirname -- "$framework_info")"
    plutil -create xml1 "$framework_info"
    plutil -insert CFBundleShortVersionString -string 2.9.6 "$framework_info"

    for executable in \
        Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle \
        Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
        Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater \
        Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader \
        Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer; do
        mkdir -p "$(dirname -- "$bundle/$executable")"
        : >"$bundle/$executable"
        chmod +x "$bundle/$executable"
    done

    ln -s B "$framework_root/Versions/Current"
    ln -s Versions/Current/Updater.app "$framework_root/Updater.app"
    mkdir -p "$bundle/Contents/Resources"
    : >"$bundle/Contents/PkgInfo"
    : >"$bundle/Contents/Resources/AppIcon.icns"
    : >"$bundle/Contents/Resources/Assets.car"
}

new_app_case() {
    local name=$1

    app_case="$tmp/app-$name"
    app="$app_case/LinkGate.app"
    observed="$app_case/observed.json"
    stub_bin="$app_case/bin"
    stub_log="$app_case/stubs.log"
    mkdir -p "$app_case"
    cp -R "$fixtures/app/LinkGate.app" "$app"
    chmod +x "$app/Contents/MacOS/LinkGate"
    configure_approved_sparkle_info "$app"
    install_expected_sparkle_runtime "$app"
    write_stubs "$stub_bin"
}

replace_plist_value() {
    local plist=$1
    local from=$2
    local to=$3

    sed "s|$from|$to|" "$plist" >"$plist.updated"
    mv "$plist.updated" "$plist"
}

replace_executable_name() {
    local plist=$1
    local executable_name=$2

    plutil -replace CFBundleExecutable -string "$executable_name" "$plist"
}

new_app_case valid
run_validate_app "$app" "$valid_metadata" "$observed"
assert_file "$observed"
assert_json_value "$observed" '.product' 'LinkGate'
assert_json_value "$observed" '.marketing_version' '0.1.0'
assert_json_value "$observed" '.build' '1'
assert_json_value "$observed" '.bundle_id' 'com.nickghardwick.LinkGate'
assert_json_value "$observed" '.deployment_target' '14.0'
assert_json_value "$observed" '.architectures.0' 'arm64'
assert_json_value "$observed" '.architectures.1' 'x86_64'
assert_contains "$stub_log" 'codesign --verify --deep --strict --verbose=2'
assert_contains "$stub_log" 'codesign --display --verbose=4'
assert_not_contains "$stub_log" 'spctl --assess --type execute --verbose=4'
assert_json_value "$observed" '.notarized' 'false'
assert_json_value "$observed" '.stapled' 'false'

new_app_case wrong-sparkle-feed
plutil -replace SUFeedURL -string 'https://example.invalid/updates/appcast.xml' "$app/Contents/Info.plist"
assert_validation_failure wrong-sparkle-feed "$app" "$valid_metadata" "$observed"

new_app_case wrong-sparkle-public-key
plutil -replace SUPublicEDKey -string 'invalid-public-key' "$app/Contents/Info.plist"
assert_validation_failure wrong-sparkle-public-key "$app" "$valid_metadata" "$observed"

new_app_case private-sparkle-key
plutil -insert SUPrivateEDKey -string 'private-test-key-material' "$app/Contents/Info.plist"
assert_validation_failure private-sparkle-key "$app" "$valid_metadata" "$observed"

new_app_case neutral-name-private-material
: >"$app/Contents/Resources/ed25519"
assert_validation_failure neutral-name-private-material "$app" "$valid_metadata" "$observed"

new_app_case unexpected-direct-contents-entry
: >"$app/Contents/neutral"
assert_validation_failure unexpected-direct-contents-entry "$app" "$valid_metadata" "$observed"

new_app_case missing-sparkle-executable
rm "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
assert_validation_failure missing-sparkle-executable "$app" "$valid_metadata" "$observed"

new_app_case wrong-sparkle-runtime-version
plutil -replace CFBundleShortVersionString -string 2.9.5 "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
assert_validation_failure wrong-sparkle-runtime-version "$app" "$valid_metadata" "$observed"

new_app_case unexpected-signed-framework
mkdir -p "$app/Contents/Frameworks/Foreign.framework/Versions/A/_CodeSignature"
assert_validation_failure unexpected-signed-framework "$app" "$valid_metadata" "$observed"

new_app_case unexpected-signed-xpc-service
mkdir -p "$app/Contents/XPCServices/Foreign.xpc/Contents/_CodeSignature"
assert_validation_failure unexpected-signed-xpc-service "$app" "$valid_metadata" "$observed"

new_app_case unexpected-signed-application
mkdir -p "$app/Contents/Frameworks/Foreign.app/Contents/_CodeSignature"
assert_validation_failure unexpected-signed-application "$app" "$valid_metadata" "$observed"

new_app_case unexpected-embedded-library
mkdir -p "$app/Contents/Frameworks"
: >"$app/Contents/Frameworks/Foreign.dylib"
chmod +x "$app/Contents/Frameworks/Foreign.dylib"
assert_validation_failure unexpected-embedded-library "$app" "$valid_metadata" "$observed"

new_app_case pre-notarization-gatekeeper-rejected
run_validate_app "$app" "$valid_metadata" "$observed" SPCTL_OK=0
assert_file "$observed"
assert_not_contains "$stub_log" 'spctl --assess --type execute --verbose=4'

new_app_case stapled
: >"$app/Contents/CodeResources"
run_validate_app_require_stapled_ticket "$app" "$valid_metadata" "$observed"
assert_file "$observed"
assert_contains "$stub_log" 'xcrun stapler validate'
assert_contains "$stub_log" 'spctl --assess --type execute --verbose=4'
assert_precedes "$stub_log" 'xcrun stapler validate' 'spctl --assess --type execute --verbose=4'
assert_json_value "$observed" '.notarized' 'true'
assert_json_value "$observed" '.stapled' 'true'

new_app_case stapled-missing-code-resources
assert_fails stapled-missing-code-resources run_validate_app_require_stapled_ticket "$app" "$valid_metadata" "$observed"
assert_no_file "$observed"

new_app_case stapled-invalid-ticket
: >"$app/Contents/CodeResources"
assert_fails stapled-invalid-ticket run_validate_app_require_stapled_ticket "$app" "$valid_metadata" "$observed" STAPLER_VALIDATE_OK=0
assert_no_file "$observed"
assert_contains "$stub_log" 'xcrun stapler validate'
assert_not_contains "$stub_log" 'spctl --assess --type execute --verbose=4'

new_app_case reversed-architectures
run_validate_app "$app" "$valid_metadata" "$observed" LIPO_ARCHS='x86_64 arm64'
assert_file "$observed"

new_app_case wrong-bundle
replace_plist_value "$app/Contents/Info.plist" 'com.nickghardwick.LinkGate' 'com.example.Other'
assert_validation_failure wrong-bundle "$app" "$valid_metadata" "$observed"
assert_no_file "$observed"

new_app_case wrong-version
replace_plist_value "$app/Contents/Info.plist" '0.1.0' '0.1.1'
assert_validation_failure wrong-version "$app" "$valid_metadata" "$observed"

new_app_case wrong-build
replace_plist_value "$app/Contents/Info.plist" '>1<' '>2<'
assert_validation_failure wrong-build "$app" "$valid_metadata" "$observed"

new_app_case wrong-deployment-target
replace_plist_value "$app/Contents/Info.plist" '14.0' '15.0'
assert_validation_failure wrong-deployment-target "$app" "$valid_metadata" "$observed"

new_app_case missing-executable
rm "$app/Contents/MacOS/LinkGate"
assert_validation_failure missing-executable "$app" "$valid_metadata" "$observed"

new_app_case executable-traversal
replace_executable_name "$app/Contents/Info.plist" '../MacOS/LinkGate'
assert_validation_failure executable-traversal "$app" "$valid_metadata" "$observed"

new_app_case executable-separator
replace_executable_name "$app/Contents/Info.plist" './LinkGate'
assert_validation_failure executable-separator "$app" "$valid_metadata" "$observed"

new_app_case missing-architecture
assert_validation_failure missing-architecture "$app" "$valid_metadata" "$observed" LIPO_ARCHS=arm64

new_app_case signing-identity-mismatch
assert_validation_failure signing-identity-mismatch "$app" "$valid_metadata" "$observed" SIGNING_PREFIX='Apple Development'

new_app_case signing-authority-mismatch
assert_validation_failure signing-authority-mismatch "$app" "$valid_metadata" "$observed" SIGNING_NAME='Other Developer'

new_app_case signing-team-mismatch
assert_validation_failure signing-team-mismatch "$app" "$valid_metadata" "$observed" SIGNING_TEAM_ID=OTHERTEAM123

new_app_case invalid-signature
assert_validation_failure invalid-signature "$app" "$valid_metadata" "$observed" CODESIGN_VERIFY_OK=0

new_app_case missing-hardened-runtime
assert_validation_failure missing-hardened-runtime "$app" "$valid_metadata" "$observed" HARDENED_RUNTIME=0

new_app_case missing-secure-timestamp
assert_validation_failure missing-secure-timestamp "$app" "$valid_metadata" "$observed" SECURE_TIMESTAMP=0

new_app_case nested-sparkle-identity-mismatch
assert_validation_failure nested-sparkle-identity-mismatch "$app" "$valid_metadata" "$observed" NESTED_SIGNING_TARGET=Downloader.xpc NESTED_SIGNING_PREFIX='Apple Development'

new_app_case nested-sparkle-team-mismatch
assert_validation_failure nested-sparkle-team-mismatch "$app" "$valid_metadata" "$observed" NESTED_SIGNING_TARGET=Updater.app NESTED_SIGNING_TEAM_ID=OTHERTEAM123

new_app_case nested-sparkle-framework-identity-mismatch
assert_validation_failure nested-sparkle-framework-identity-mismatch "$app" "$valid_metadata" "$observed" NESTED_SIGNING_TARGET=/Sparkle.framework NESTED_SIGNING_PREFIX='Apple Development'

new_app_case nested-sparkle-missing-hardened-runtime
assert_validation_failure nested-sparkle-missing-hardened-runtime "$app" "$valid_metadata" "$observed" NESTED_SIGNING_TARGET=Autoupdate NESTED_HARDENED_RUNTIME=0

new_app_case nested-sparkle-missing-secure-timestamp
assert_validation_failure nested-sparkle-missing-secure-timestamp "$app" "$valid_metadata" "$observed" NESTED_SIGNING_TARGET=Installer.xpc NESTED_SECURE_TIMESTAMP=0

new_app_case nested-sparkle-invalid-signature
assert_validation_failure nested-sparkle-invalid-signature "$app" "$valid_metadata" "$observed" NESTED_CODESIGN_VERIFY_TARGET=Installer.xpc NESTED_CODESIGN_VERIFY_OK=0

new_app_case gatekeeper-rejection
: >"$app/Contents/CodeResources"
assert_fails gatekeeper-rejection run_validate_app_require_stapled_ticket "$app" "$valid_metadata" "$observed" SPCTL_OK=0
assert_no_file "$observed"
assert_contains "$stub_log" 'xcrun stapler validate'
assert_contains "$stub_log" 'spctl --assess --type execute --verbose=4'

new_app_case quoted-signing-identity
quoted_metadata="$app_case/quoted-metadata.json"
cp "$valid_metadata" "$quoted_metadata"
plutil -replace signing_identity -string 'Developer ID Application: Link"Gate (Z8A8ZWCZ45)' "$quoted_metadata"
run_validate_app "$app" "$quoted_metadata" "$observed" SIGNING_NAME='Link"Gate'
assert_file "$observed"
assert_json_value "$observed" '.signing_identity' 'Developer ID Application: Link"Gate (Z8A8ZWCZ45)'

new_app_case nested-code-signature
mkdir -p "$app/Contents/Resources/_CodeSignature"
assert_validation_failure nested-code-signature "$app" "$valid_metadata" "$observed"

new_app_case debug-artifact
mkdir -p "$app/Contents/Resources/LinkGate.dSYM"
assert_validation_failure debug-artifact "$app" "$valid_metadata" "$observed"

printf 'PASS: deterministic release preflight and app validation tests\n'
