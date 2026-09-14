#!/bin/bash

set -euo pipefail

fail() {
    printf 'application validation: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: validate-app.sh --app PATH --metadata PATH --observed-out PATH [--require-stapled-ticket]'
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=config.sh
source "$script_dir/config.sh"

app=
metadata=
observed_out=
require_stapled_ticket=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app|--metadata|--observed-out)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --app) app=$2 ;;
                --metadata) metadata=$2 ;;
                --observed-out) observed_out=$2 ;;
            esac
            shift 2
            ;;
        --require-stapled-ticket)
            require_stapled_ticket=true
            shift
            ;;
        *) usage ;;
    esac
done

[ -n "$app" ] && [ -n "$metadata" ] && [ -n "$observed_out" ] || usage
[ -d "$app" ] || fail "application bundle does not exist: $app"
[ -f "$metadata" ] || fail "release metadata does not exist: $metadata"

plist=$app/Contents/Info.plist
[ -f "$plist" ] || fail 'application Info.plist is missing'

plist_value() {
    plutil -extract "$1" raw -o - "$plist" 2>/dev/null || fail "application Info.plist is missing $1"
}
metadata_value() {
    plutil -extract "$1" raw -o - "$metadata" 2>/dev/null || fail "release metadata is missing $1"
}

product=$(plist_value CFBundleName)
bundle_id=$(plist_value CFBundleIdentifier)
marketing_version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
deployment_target=$(plist_value LSMinimumSystemVersion)
executable_name=$(plist_value CFBundleExecutable)
case "$executable_name" in
    ''|.|..|*/*|*\\*) fail 'application executable name must be a single safe path component' ;;
esac
executable=$app/Contents/MacOS/$executable_name
sparkle_feed_url='https://nickghardwick.github.io/LinkGate/updates/appcast.xml'
sparkle_public_ed_key='En8Ohgkw8WSkc/10bYvg692dCDZUeb+w30bCOqR+qkU='
sparkle_framework=$app/Contents/Frameworks/Sparkle.framework
sparkle_runtime=$sparkle_framework/Versions/B
sparkle_info_plist=$sparkle_runtime/Resources/Info.plist

[ "$product" = "$PRODUCT_NAME" ] || fail 'application product does not match release policy'
[ "$bundle_id" = "$BUNDLE_ID" ] || fail 'application bundle identifier does not match release policy'
[ "$marketing_version" = "$(metadata_value marketing_version)" ] || fail 'application marketing version does not match metadata'
[ "$build" = "$(metadata_value build)" ] || fail 'application build does not match metadata'
[ "$bundle_id" = "$(metadata_value bundle_id)" ] || fail 'application bundle identifier does not match metadata'
[ "$deployment_target" = "$DEPLOYMENT_TARGET" ] || fail 'application deployment target does not match release policy'
[ "$deployment_target" = "$(metadata_value deployment_target)" ] || fail 'application deployment target does not match metadata'
[ -f "$executable" ] && [ -x "$executable" ] || fail 'application executable is missing or not executable'
[ "$(plist_value SUFeedURL)" = "$sparkle_feed_url" ] || fail 'application Sparkle feed URL does not match release policy'
[ "$(plist_value SUPublicEDKey)" = "$sparkle_public_ed_key" ] || fail 'application Sparkle public Ed25519 key does not match release policy'

for private_key_configuration in SUPrivateEDKey SUPrivateEDKeyFile SUPrivateDSAKeyFile; do
    if plutil -extract "$private_key_configuration" raw -o - "$plist" >/dev/null 2>&1; then
        fail 'application Info.plist contains private Sparkle key configuration'
    fi
done
if find "$app/Contents" -iname '*private*key*' -print -quit | grep -q .; then
    fail 'application bundle contains private key material filename'
fi

expected_contents_entries=$(cat <<'PATHS'
Contents/Frameworks
Contents/Info.plist
Contents/MacOS
Contents/PkgInfo
Contents/Resources
Contents/_CodeSignature
PATHS
)
actual_contents_entries=$(find "$app/Contents" -mindepth 1 -maxdepth 1 -print | sed "s|^$app/||" | LC_ALL=C sort)
[ "$actual_contents_entries" = "$expected_contents_entries" ] || fail 'application Contents entries do not match release policy'
[ -d "$app/Contents/Frameworks" ] || fail 'application Frameworks directory is missing'
[ -f "$app/Contents/Info.plist" ] || fail 'application Info.plist is missing'
[ -d "$app/Contents/MacOS" ] || fail 'application MacOS directory is missing'
[ -f "$app/Contents/PkgInfo" ] || fail 'application PkgInfo is missing'
[ -d "$app/Contents/Resources" ] || fail 'application Resources directory is missing'

expected_resource_entries=$(cat <<'PATHS'
Contents/Resources/AppIcon.icns
Contents/Resources/Assets.car
PATHS
)
actual_resource_entries=$(find "$app/Contents/Resources" -mindepth 1 -maxdepth 1 -print | sed "s|^$app/||" | LC_ALL=C sort)
[ "$actual_resource_entries" = "$expected_resource_entries" ] || fail 'application Resources entries do not match release policy'
for resource in "$app/Contents/Resources/AppIcon.icns" "$app/Contents/Resources/Assets.car"; do
    [ -f "$resource" ] || fail 'application resource is missing or is not a regular file'
done

expected_code_signatures=$(cat <<'PATHS'
Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/_CodeSignature
Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/_CodeSignature
Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/_CodeSignature
Contents/Frameworks/Sparkle.framework/Versions/B/_CodeSignature
Contents/_CodeSignature
PATHS
)
actual_code_signatures=$(find "$app" -type d -name _CodeSignature -print | sed "s|^$app/||" | LC_ALL=C sort)
[ "$actual_code_signatures" = "$expected_code_signatures" ] || fail 'application code signature directories do not match the approved Sparkle runtime'

[ -d "$sparkle_framework" ] || fail 'application is missing the Sparkle framework'
[ -f "$sparkle_info_plist" ] || fail 'Sparkle framework Info.plist is missing'
sparkle_version=$(plutil -extract CFBundleShortVersionString raw -o - "$sparkle_info_plist" 2>/dev/null) || fail 'Sparkle framework version is missing'
[ "$sparkle_version" = '2.9.6' ] || fail 'Sparkle framework version does not match release policy'

expected_embedded_code=$(cat <<'PATHS'
Contents/Frameworks/Sparkle.framework
Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
PATHS
)
actual_embedded_code=$(find "$app/Contents" \( \( -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) \) -o -name '*.dylib' \) -print | sed "s|^$app/||" | LC_ALL=C sort)
[ "$actual_embedded_code" = "$expected_embedded_code" ] || fail 'application contains unexpected embedded code'

framework_entries=$(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print | sed "s|^$app/||" | LC_ALL=C sort)
[ "$framework_entries" = 'Contents/Frameworks/Sparkle.framework' ] || fail 'application frameworks do not match the approved Sparkle runtime'

for sparkle_executable in \
    "$sparkle_runtime/Sparkle" \
    "$sparkle_runtime/Autoupdate" \
    "$sparkle_runtime/Updater.app/Contents/MacOS/Updater" \
    "$sparkle_runtime/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$sparkle_runtime/XPCServices/Installer.xpc/Contents/MacOS/Installer"; do
    [ -f "$sparkle_executable" ] && [ -x "$sparkle_executable" ] || fail 'Sparkle runtime executable is missing or not executable'
done

expected_executables=$(cat <<PATHS
Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle
Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater
Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader
Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer
Contents/MacOS/$executable_name
PATHS
)
actual_executables=$(find "$app/Contents" -type f -perm -111 -print | sed "s|^$app/||" | LC_ALL=C sort)
[ "$actual_executables" = "$expected_executables" ] || fail 'application contains unexpected executable code'

if find "$app" \( -name '*.dSYM' -o -name '*.debug.dylib' \) -print | grep -q .; then
    fail 'application contains debug artifacts'
fi

architectures=$(lipo -archs "$executable" 2>/dev/null) || fail 'could not inspect application architectures'
read -r -a architecture_list <<<"$architectures"
[ "${#architecture_list[@]}" -eq 2 ] || fail 'application must contain exactly arm64 and x86_64 architectures'
has_arm64=false
has_x86_64=false
for architecture in "${architecture_list[@]}"; do
    case "$architecture" in
        arm64) has_arm64=true ;;
        x86_64) has_x86_64=true ;;
        *) fail 'application must contain exactly arm64 and x86_64 architectures' ;;
    esac
done
[ "$has_arm64" = true ] && [ "$has_x86_64" = true ] || fail 'application must contain arm64 and x86_64 architectures'

signature_output=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-signature.XXXXXX")
observed_placeholder=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-observed.XXXXXX")
observed_plist=$observed_placeholder.plist
observed_tmp=$observed_placeholder.json
cleanup() {
    rm -f "$signature_output" "$observed_placeholder" "$observed_plist" "$observed_tmp"
}
trap cleanup EXIT HUP INT TERM

assert_production_signature() {
    local signed_object=$1
    local description=$2
    local expected_identity

    codesign --verify --strict --verbose=2 "$signed_object" >/dev/null 2>&1 || fail "$description code signature verification failed"
    codesign --display --verbose=4 "$signed_object" >"$signature_output" 2>&1 || fail "could not inspect $description code signature"
    expected_identity=$(metadata_value signing_identity)
    grep -F "Authority=$expected_identity" "$signature_output" >/dev/null || fail "$description is not signed with the configured Developer ID identity"
    grep -F "TeamIdentifier=$TEAM_ID" "$signature_output" >/dev/null || fail "$description signing team does not match release policy"
    grep -F 'flags=0x10000(runtime)' "$signature_output" >/dev/null || fail "$description is missing the hardened runtime"
    grep -F 'Timestamp=' "$signature_output" >/dev/null || fail "$description is missing a secure timestamp"
}

for sparkle_signed_object in \
    "$sparkle_runtime/XPCServices/Installer.xpc" \
    "$sparkle_runtime/XPCServices/Downloader.xpc" \
    "$sparkle_runtime/Autoupdate" \
    "$sparkle_runtime/Updater.app" \
    "$sparkle_framework"; do
    assert_production_signature "$sparkle_signed_object" 'Sparkle runtime object'
done

codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || fail 'application code signature verification failed'
assert_production_signature "$app" 'application'
if [ "$require_stapled_ticket" = true ]; then
    xcrun stapler validate "$app" >/dev/null 2>&1 || fail 'application does not have a valid stapled notarization ticket'
    spctl --assess --type execute --verbose=4 "$app" >/dev/null 2>&1 || fail 'Gatekeeper rejected the application'
fi

signing_identity=$(sed -n "s/^Authority=\\(${SIGNING_IDENTITY_PREFIX}:.*\\)$/\\1/p" "$signature_output" | head -n 1)
[ -n "$signing_identity" ] || fail 'could not read the Developer ID signing identity'
[ "$signing_identity" = "$(metadata_value signing_identity)" ] || fail 'application signing identity does not match release metadata'
observed_directory=$(dirname -- "$observed_out")
[ -d "$observed_directory" ] || fail "observed metadata output directory does not exist: $observed_directory"
plutil -create xml1 "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert product -string "$product" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert marketing_version -string "$marketing_version" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert build -string "$build" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert bundle_id -string "$bundle_id" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert architectures -json '["arm64", "x86_64"]' "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert deployment_target -string "$deployment_target" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert signing_identity -string "$signing_identity" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert notarized -bool "$require_stapled_ticket" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -insert stapled -bool "$require_stapled_ticket" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -convert json -o "$observed_tmp" "$observed_plist" >/dev/null 2>&1 || fail 'could not create observed application metadata'
plutil -extract product raw -o - "$observed_tmp" >/dev/null 2>&1 || fail 'could not create observed application metadata'
mv "$observed_tmp" "$observed_out"
