#!/bin/bash

# Offline checks for the LinkGate-owned Sparkle integration contract. This test deliberately reads
# only committed build inputs; it must never contact the appcast, GitHub Releases, or a package
# registry.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)
info_plist="$repo_root/LinkGate/Info.plist"
project="$repo_root/LinkGate.xcodeproj/project.pbxproj"
resolution="$repo_root/LinkGate.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ -f "$info_plist" ] || fail 'missing application Info.plist'
[ -f "$project" ] || fail 'missing Xcode project'
[ -f "$resolution" ] || fail 'missing committed Swift package resolution'

feed_url=$(plutil -extract SUFeedURL raw -o - "$info_plist" 2>/dev/null) ||
    fail 'missing Info.plist key: SUFeedURL'
public_key=$(plutil -extract SUPublicEDKey raw -o - "$info_plist" 2>/dev/null) ||
    fail 'missing Info.plist key: SUPublicEDKey'

[ "$feed_url" = 'https://nickghardwick.github.io/LinkGate/updates/appcast.xml' ] ||
    fail 'SUFeedURL must be the approved production appcast'
[ "$public_key" = 'En8Ohgkw8WSkc/10bYvg692dCDZUeb+w30bCOqR+qkU=' ] ||
    fail 'SUPublicEDKey must be the approved production Ed25519 public key'

for forbidden_key in \
    SUEnableAutomaticChecks \
    SUAutomaticallyUpdate \
    SUEnableSystemProfiling \
    SUSendProfileInfo \
    SUPrivateEDKey; do
    if plutil -extract "$forbidden_key" raw -o - "$info_plist" >/dev/null 2>&1; then
        fail "$forbidden_key must be unset in application Info.plist"
    fi
done

if grep -E -i '<key>[^<]*private[^<]*key[^<]*</key>' "$info_plist" >/dev/null; then
    fail 'application Info.plist must not contain private-key configuration'
fi

grep -F 'https://github.com/sparkle-project/Sparkle' "$project" >/dev/null ||
    fail 'Xcode project must declare the official Sparkle package'
grep -E 'kind = exactVersion;[[:space:]]*version = 2\.9\.6;' "$project" >/dev/null ||
    fail 'Xcode project must pin Sparkle to exactly 2.9.6'
grep -F 'productName = Sparkle;' "$project" >/dev/null ||
    fail 'LinkGate target must link the Sparkle package product'

xcrun swift - "$resolution" <<'SWIFT' || fail 'Package.resolved must resolve only the official Sparkle 2.9.6 package pin'
import Foundation

let resolutionPath = CommandLine.arguments[1]
let data = try Data(contentsOf: URL(fileURLWithPath: resolutionPath))
let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
let pins = (root?["pins"] as? [[String: Any]])
    ?? ((root?["object"] as? [String: Any])?["pins"] as? [[String: Any]])
let sparklePins = pins?.filter { ($0["identity"] as? String)?.lowercased() == "sparkle" } ?? []

guard sparklePins.count == 1,
      let sparkle = sparklePins.first,
      sparkle["kind"] as? String == "remoteSourceControl",
      sparkle["location"] as? String == "https://github.com/sparkle-project/Sparkle",
      let state = sparkle["state"] as? [String: Any],
      state["version"] as? String == "2.9.6" else {
    exit(1)
}
SWIFT

printf 'PASS: offline Sparkle integration configuration tests\n'
