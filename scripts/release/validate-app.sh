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

[ "$product" = "$PRODUCT_NAME" ] || fail 'application product does not match release policy'
[ "$bundle_id" = "$BUNDLE_ID" ] || fail 'application bundle identifier does not match release policy'
[ "$marketing_version" = "$(metadata_value marketing_version)" ] || fail 'application marketing version does not match metadata'
[ "$build" = "$(metadata_value build)" ] || fail 'application build does not match metadata'
[ "$bundle_id" = "$(metadata_value bundle_id)" ] || fail 'application bundle identifier does not match metadata'
[ "$deployment_target" = "$DEPLOYMENT_TARGET" ] || fail 'application deployment target does not match release policy'
[ "$deployment_target" = "$(metadata_value deployment_target)" ] || fail 'application deployment target does not match metadata'
[ -f "$executable" ] && [ -x "$executable" ] || fail 'application executable is missing or not executable'

if find "$app/Contents" -path "$app/Contents/_CodeSignature" -prune -o -name _CodeSignature -print | grep -q .; then
    fail 'application contains a nested _CodeSignature directory'
fi
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

codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || fail 'application code signature verification failed'
codesign --display --verbose=4 "$app" >"$signature_output" 2>&1 || fail 'could not inspect application code signature'
grep -F "Authority=$SIGNING_IDENTITY_PREFIX:" "$signature_output" | grep -F "($TEAM_ID)" >/dev/null || fail 'application is not signed with the configured Developer ID identity'
grep -F "TeamIdentifier=$TEAM_ID" "$signature_output" >/dev/null || fail 'application signing team does not match release policy'
grep -F 'flags=0x10000(runtime)' "$signature_output" >/dev/null || fail 'application is missing the hardened runtime'
grep -F 'Timestamp=' "$signature_output" >/dev/null || fail 'application is missing a secure timestamp'
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
