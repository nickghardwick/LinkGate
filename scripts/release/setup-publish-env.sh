#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
venv="$repo_root/.venv/publish"
config="$script_dir/publish-config.json"
tools_root="$repo_root/.venv/publish-tools"

fail() {
    printf 'setup-publish-env: %s\n' "$*" >&2
    exit 1
}

config_value() {
    plutil -extract "$1" raw -o - "$config" 2>/dev/null ||
        fail "could not read $1 from $config"
}

sha256() {
    shasum -a 256 "$1" | awk 'NR == 1 { print $1 }'
}

sparkle_version=$(config_value sparkle.version)
archive_name=$(config_value sparkle.distribution.archive_name)
archive_url=$(config_value sparkle.distribution.archive_url)
archive_sha256=$(config_value sparkle.distribution.archive_sha256)
sign_update_path=$(config_value sparkle.distribution.sign_update_path)
sign_update_sha256=$(config_value sparkle.distribution.sign_update_sha256)
sparkle_dir="$tools_root/sparkle-$sparkle_version"
sign_update="$sparkle_dir/$sign_update_path"

python3 -m venv "$venv"
"$venv/bin/python" -m pip install --requirement "$repo_root/requirements-publish.txt"
"$venv/bin/python" -c 'import importlib.metadata; print("publish environment ready: markdown-it-py " + importlib.metadata.version("markdown-it-py"))'

if [ -e "$sign_update" ]; then
    [ -x "$sign_update" ] || fail "existing Sparkle tool is not executable: $sign_update"
    [ "$(sha256 "$sign_update")" = "$sign_update_sha256" ] ||
        fail "existing Sparkle tool does not match pinned SHA-256: $sign_update"
    printf 'verified Sparkle %s publication tool: %s\n' "$sparkle_version" "$sign_update"
    exit 0
fi

mkdir -p -- "$tools_root"
stage=$(mktemp -d "$tools_root/.sparkle-$sparkle_version.XXXXXX") ||
    fail 'could not create local Sparkle tooling staging directory'
cleanup() {
    rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

archive="$stage/$archive_name"
extract_root="$stage/extracted"
curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$archive_url" ||
    fail "could not download pinned Sparkle archive: $archive_url"
[ "$(sha256 "$archive")" = "$archive_sha256" ] ||
    fail "Sparkle archive does not match pinned SHA-256: $archive_name"

mkdir -p -- "$extract_root"
tar -xJf "$archive" --strip-components=1 -C "$extract_root" ||
    fail "could not extract pinned Sparkle archive: $archive_name"
extracted_sign_update="$extract_root/$sign_update_path"
[ -f "$extracted_sign_update" ] && [ -x "$extracted_sign_update" ] ||
    fail "Sparkle archive is missing executable $sign_update_path"
[ "$(sha256 "$extracted_sign_update")" = "$sign_update_sha256" ] ||
    fail "Sparkle sign_update does not match pinned SHA-256"

[ ! -e "$sparkle_dir" ] || fail "local Sparkle tooling directory already exists: $sparkle_dir"
mv "$extract_root" "$sparkle_dir"
printf 'installed verified Sparkle %s publication tool: %s\n' "$sparkle_version" "$sign_update"
