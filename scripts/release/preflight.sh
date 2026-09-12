#!/bin/bash

set -euo pipefail

fail() {
    printf 'release preflight: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: preflight.sh --repo-root PATH --config PATH --metadata-out PATH'
}

repo_root=
config_argument=
metadata_out=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo-root|--config|--metadata-out)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --repo-root) repo_root=$2 ;;
                --config) config_argument=$2 ;;
                --metadata-out) metadata_out=$2 ;;
            esac
            shift 2
            ;;
        *) usage ;;
    esac
done

[ -n "$repo_root" ] && [ -n "$config_argument" ] && [ -n "$metadata_out" ] || usage
[ -d "$repo_root" ] || fail "repository root does not exist: $repo_root"
repo_root=$(cd -- "$repo_root" && pwd -P)

case "$config_argument" in
    /*) fail 'release config must be repository-relative' ;;
esac
config_candidate=$repo_root/$config_argument
[ -f "$config_candidate" ] || fail "release config does not exist: $config_argument"
[ ! -L "$config_candidate" ] || fail 'release config must not be a symbolic link'
config_directory=$(cd -P -- "$(dirname -- "$config_candidate")" && pwd -P) || fail 'could not resolve release config directory'
config_path=$config_directory/$(basename -- "$config_candidate")
case "$config_path" in
    "$repo_root"/*) ;;
    *) fail 'release config must remain within the repository root' ;;
esac

# shellcheck source=/dev/null
source "$config_path"

for required in PRODUCT_NAME PROJECT SCHEME CONFIGURATION BUNDLE_ID TEAM_ID DEPLOYMENT_TARGET SIGNING_IDENTITY_PREFIX NOTARY_PROFILE; do
    [ -n "${!required:-}" ] || fail "release config is missing $required"
done

if [ -n "${VERSION+x}" ] || [ -n "${BUILD+x}" ]; then
    fail 'VERSION and BUILD overrides are not permitted for releases'
fi

[ "$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true)" = main ] || fail 'release branch must be main'
git -C "$repo_root" diff --quiet || fail 'working tree has unstaged changes'
git -C "$repo_root" diff --cached --quiet || fail 'working tree has staged changes'
[ -z "$(git -C "$repo_root" ls-files --others --exclude-standard)" ] || fail 'working tree has untracked files'
source_commit=$(git -C "$repo_root" rev-parse HEAD) || fail 'could not determine committed source revision'
source_index_tree=$(git -C "$repo_root" write-tree) || fail 'could not snapshot staged source tree'

for tool in xcodebuild codesign notarytool stapler hdiutil; do
    xcrun --find "$tool" >/dev/null 2>&1 || fail "required Apple tool is unavailable: $tool"
done

identity_output=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-identity.XXXXXX")
notary_output=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-notary.XXXXXX")
settings_output=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-settings.XXXXXX")
settings_error=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-settings-error.XXXXXX")
metadata_tmp=$(mktemp "${TMPDIR:-/tmp}/linkgate-release-metadata.XXXXXX")
cleanup() {
    rm -f "$identity_output" "$notary_output" "$settings_output" "$settings_error" "$metadata_tmp"
}
trap cleanup EXIT HUP INT TERM

if ! security find-identity -v -p codesigning >"$identity_output" 2>&1; then
    fail 'could not inspect Developer ID signing identities'
fi
signing_identity=$(awk -v prefix="$SIGNING_IDENTITY_PREFIX: " -v team=" ($TEAM_ID)" '
    {
        identity = $0
        sub(/^[^"]*"/, "", identity)
        sub(/"[^"]*$/, "", identity)
        if (index(identity, prefix) == 1 && substr(identity, length(identity) - length(team) + 1) == team) {
            print identity
            exit
        }
    }
' "$identity_output")
if [ -z "$signing_identity" ]; then
    fail "no $SIGNING_IDENTITY_PREFIX signing identity is available for team $TEAM_ID"
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >"$notary_output" 2>&1; then
    fail "notary keychain profile is unusable: $NOTARY_PROFILE"
fi

project_path=$repo_root/$PROJECT
[ -e "$project_path" ] || fail "configured Xcode project does not exist: $PROJECT"
support=$repo_root/scripts/release/ReleaseSupport.swift
[ -f "$support" ] || fail 'release metadata helper is unavailable'

if ! xcodebuild -project "$project_path" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings -json >"$settings_output" 2>"$settings_error"; then
    fail 'could not read committed Xcode build settings'
fi
if ! xcrun swift "$support" metadata --input "$settings_output" --output "$metadata_tmp" >/dev/null 2>&1; then
    fail 'committed Xcode build settings are incomplete or invalid'
fi

metadata_value() {
    plutil -extract "$1" raw -o - "$metadata_tmp" 2>/dev/null
}

[ "$(metadata_value product)" = "$PRODUCT_NAME" ] || fail 'Xcode product metadata does not match release policy'
[ "$(metadata_value bundle_id)" = "$BUNDLE_ID" ] || fail 'Xcode bundle identifier does not match release policy'
[ "$(metadata_value deployment_target)" = "$DEPLOYMENT_TARGET" ] || fail 'Xcode deployment target does not match release policy'

plutil -replace source_commit -string "$source_commit" "$metadata_tmp" >/dev/null 2>&1 || fail 'could not add source commit to release metadata'
plutil -replace source_index_tree -string "$source_index_tree" "$metadata_tmp" >/dev/null 2>&1 || fail 'could not add source index snapshot to release metadata'
plutil -replace signing_identity -string "$signing_identity" "$metadata_tmp" >/dev/null 2>&1 || fail 'could not add selected signing identity to release metadata'
metadata_directory=$(dirname -- "$metadata_out")
[ -d "$metadata_directory" ] || fail "metadata output directory does not exist: $metadata_directory"
mv "$metadata_tmp" "$metadata_out"
