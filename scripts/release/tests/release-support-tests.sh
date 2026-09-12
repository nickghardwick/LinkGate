#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
fixtures="$script_dir/fixtures"
support="$repo_root/scripts/release/ReleaseSupport.swift"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/linkgate-release-support-tests.XXXXXX")

cleanup() {
    rm -rf "$tmp"
}

trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_support() {
    xcrun swift "$support" "$@"
}

assert_json_value() {
    local file=$1
    local key=$2
    local expected=$3
    local actual
    local plist_key=${key#.}

    actual=$(plutil -extract "$plist_key" raw -o - "$file") || fail "could not read $key from $file"
    [ "$actual" = "$expected" ] || fail "expected $key in $file to be $expected, got $actual"
}

assert_json_equal() {
    local actual=$1
    local expected=$2

    xcrun swift - "$actual" "$expected" <<'SWIFT' || fail "JSON differs: $actual != $expected"
import Foundation

func readJSONObject(at path: String) throws -> Any {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONSerialization.jsonObject(with: data)
}

let paths = Array(CommandLine.arguments.dropFirst())
guard paths.count == 2 else { exit(2) }
let actual = try readJSONObject(at: paths[0])
let expected = try readJSONObject(at: paths[1])
guard JSONSerialization.isValidJSONObject(actual), JSONSerialization.isValidJSONObject(expected) else {
    exit(2)
}
let actualData = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
exit(actualData == expectedData ? 0 : 1)
SWIFT
}

assert_fails() {
    local stderr_file="$tmp/failed-command.stderr"

    if "$@" >"$tmp/failed-command.stdout" 2>"$stderr_file"; then
        fail "expected command to fail: $*"
    fi

    [ -s "$stderr_file" ] || fail "expected actionable stderr from failing command: $*"
}

copy_manifest_with_replacement() {
    local output=$1
    local from=$2
    local to=$3

    sed "s/$from/$to/" "$fixtures/manifest-valid.json" >"$output"
}

if [ ! -f "$support" ]; then
    fail "missing ReleaseSupport.swift; implement the metadata, manifest-write, and manifest-validate commands"
fi

dmg="$tmp/LinkGate-0.1.0.dmg"
checksum="$tmp/LinkGate-0.1.0.dmg.sha256"
metadata="$tmp/metadata.json"
manifest="$tmp/manifest.json"
observed="$tmp/observed.json"
source_commit=0123456789abcdef0123456789abcdef01234567
sha256=190c6196218b88c15d65ff286963b5829cad57bf25c8ae8ec0b46e3d15cd80ed
uppercase_sha256=190C6196218B88C15D65FF286963B5829CAD57BF25C8AE8EC0B46E3D15CD80ED

printf 'LinkGate release fixture DMG\n' >"$dmg"
printf '%s  %s\n' "$sha256" "$(basename "$dmg")" >"$checksum"

cat >"$observed" <<'JSON'
{
  "product": "LinkGate",
  "marketing_version": "0.1.0",
  "build": "1",
  "bundle_id": "com.nickghardwick.LinkGate",
  "architectures": ["arm64", "x86_64"],
  "deployment_target": "14.0",
  "signing_identity": "Developer ID Application: LinkGate (Z8A8ZWCZ45)",
  "notarized": true,
  "stapled": true
}
JSON

run_support metadata --input "$fixtures/show-build-settings-valid.json" --output "$metadata"
assert_json_value "$metadata" '.product' 'LinkGate'
assert_json_value "$metadata" '.marketing_version' '0.1.0'
assert_json_value "$metadata" '.build' '1'
assert_json_value "$metadata" '.bundle_id' 'com.nickghardwick.LinkGate'
assert_json_value "$metadata" '.architectures.0' 'arm64'
assert_json_value "$metadata" '.architectures.1' 'x86_64'
assert_json_value "$metadata" '.deployment_target' '14.0'
assert_json_value "$metadata" '.signing_identity' 'Developer ID Application'
# Preflight replaces Xcode's generic selector with the Keychain authority
# before this narrow metadata/manifest helper receives release metadata.
plutil -replace signing_identity -string 'Developer ID Application: LinkGate (Z8A8ZWCZ45)' "$metadata"
sed 's/"PRODUCT_NAME": "LinkGate"/"PRODUCT_NAME": "LinkGateFixtureProduct"/' "$fixtures/show-build-settings-valid.json" >"$tmp/show-build-settings-product-mutated.json"
run_support metadata --input "$tmp/show-build-settings-product-mutated.json" --output "$tmp/product-mutated-metadata.json"
assert_json_value "$tmp/product-mutated-metadata.json" '.product' 'LinkGateFixtureProduct'
assert_fails run_support metadata --input "$fixtures/show-build-settings-invalid.json" --output "$metadata"
printf '{"buildSettings":' >"$tmp/show-build-settings-malformed.json"
assert_fails run_support metadata --input "$tmp/show-build-settings-malformed.json" --output "$metadata"
sed '/"PRODUCT_BUNDLE_IDENTIFIER":/d' "$fixtures/show-build-settings-valid.json" >"$tmp/show-build-settings-missing-bundle-id.json"
assert_fails run_support metadata --input "$tmp/show-build-settings-missing-bundle-id.json" --output "$metadata"
sed 's/"CURRENT_PROJECT_VERSION": "1"/"CURRENT_PROJECT_VERSION": "not-a-build"/' "$fixtures/show-build-settings-valid.json" >"$tmp/show-build-settings-invalid-build.json"
assert_fails run_support metadata --input "$tmp/show-build-settings-invalid-build.json" --output "$metadata"

assert_fails run_support manifest-validate --manifest "$fixtures/manifest-malformed.json" --checksum "$tmp/missing.sha256" --observed "$tmp/missing-observed.json" --dmg "$dmg"

run_support manifest-write \
    --metadata "$metadata" \
    --source-commit "$source_commit" \
    --xcode-version 'Xcode 26.6' \
    --macos-version '26.5' \
    --artifact "$(basename "$dmg")" \
    --sha256 "$sha256" \
    --output "$manifest"
assert_json_equal "$manifest" "$fixtures/manifest-valid.json"
run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$observed" --dmg "$dmg"
run_support manifest-validate --manifest "$fixtures/manifest-valid.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"
assert_fails run_support manifest-validate --manifest "$fixtures/manifest-malformed.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"

assert_fails run_support manifest-write \
    --metadata "$metadata" \
    --source-commit not-a-commit \
    --xcode-version 'Xcode 26.6' \
    --macos-version '26.5' \
    --artifact "$(basename "$dmg")" \
    --sha256 "$sha256" \
    --output "$tmp/invalid-source.json"
assert_fails run_support manifest-write \
    --metadata "$metadata" \
    --source-commit "$source_commit" \
    --xcode-version 'Xcode 26.6' \
    --macos-version '26.5' \
    --artifact "$(basename "$dmg")" \
    --sha256 ABCD \
    --output "$tmp/invalid-sha.json"
assert_fails run_support manifest-write \
    --metadata "$metadata" \
    --source-commit "$source_commit" \
    --xcode-version 'Xcode 26.6' \
    --macos-version '26.5' \
    --artifact "$(basename "$dmg")" \
    --sha256 "$uppercase_sha256" \
    --output "$tmp/uppercase-sha.json"

printf 'tampered DMG bytes\n' >"$dmg"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$observed" --dmg "$dmg"
printf 'LinkGate release fixture DMG\n' >"$dmg"

printf '%064d  %s\n' 0 "$(basename "$dmg")" >"$tmp/wrong-checksum.sha256"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$tmp/wrong-checksum.sha256" --observed "$observed" --dmg "$dmg"

copy_manifest_with_replacement "$tmp/wrong-version.json" '"marketing_version": "0.1.0"' '"marketing_version": "0.1.1"'
assert_fails run_support manifest-validate --manifest "$tmp/wrong-version.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"

copy_manifest_with_replacement "$tmp/wrong-artifact.json" '"artifact_name": "LinkGate-0.1.0.dmg"' '"artifact_name": "LinkGate-0.1.1.dmg"'
assert_fails run_support manifest-validate --manifest "$tmp/wrong-artifact.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"

copy_manifest_with_replacement "$tmp/wrong-sha.json" "$sha256" '0000000000000000000000000000000000000000000000000000000000000000'
assert_fails run_support manifest-validate --manifest "$tmp/wrong-sha.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"

sed 's/"build": "1"/"build": "2"/' "$observed" >"$tmp/wrong-observed.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed.json" --dmg "$dmg"

sed 's/"marketing_version": "0.1.0"/"marketing_version": "0.1.1"/' "$observed" >"$tmp/wrong-observed-marketing-version.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed-marketing-version.json" --dmg "$dmg"

sed 's/"product": "LinkGate"/"product": "OtherProduct"/' "$observed" >"$tmp/wrong-observed-product.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed-product.json" --dmg "$dmg"

sed 's/"bundle_id": "com.nickghardwick.LinkGate"/"bundle_id": "com.example.Other"/' "$observed" >"$tmp/wrong-observed-bundle-id.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed-bundle-id.json" --dmg "$dmg"

sed 's/"architectures": \["arm64", "x86_64"\]/"architectures": ["arm64"]/' "$observed" >"$tmp/wrong-observed-architectures.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed-architectures.json" --dmg "$dmg"

sed 's/"deployment_target": "14.0"/"deployment_target": "15.0"/' "$observed" >"$tmp/wrong-observed-deployment-target.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed-deployment-target.json" --dmg "$dmg"

sed 's/"signing_identity": "Developer ID Application: LinkGate (Z8A8ZWCZ45)"/"signing_identity": "Developer ID Application: Other (Z8A8ZWCZ45)"/' "$observed" >"$tmp/wrong-observed-signing-identity.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/wrong-observed-signing-identity.json" --dmg "$dmg"

copy_manifest_with_replacement "$tmp/not-notarized.json" '"notarized": true' '"notarized": false'
assert_fails run_support manifest-validate --manifest "$tmp/not-notarized.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"

copy_manifest_with_replacement "$tmp/not-stapled.json" '"stapled": true' '"stapled": false'
assert_fails run_support manifest-validate --manifest "$tmp/not-stapled.json" --checksum "$checksum" --observed "$observed" --dmg "$dmg"

sed 's/"notarized": true/"notarized": false/' "$observed" >"$tmp/observed-not-notarized.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/observed-not-notarized.json" --dmg "$dmg"

sed 's/"stapled": true/"stapled": false/' "$observed" >"$tmp/observed-not-stapled.json"
assert_fails run_support manifest-validate --manifest "$manifest" --checksum "$checksum" --observed "$tmp/observed-not-stapled.json" --dmg "$dmg"

printf 'PASS: deterministic release support tests\n'
