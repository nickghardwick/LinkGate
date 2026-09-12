#!/bin/bash

set -euo pipefail

fail() {
    printf 'DMG validation: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: validate-dmg.sh --dmg PATH --metadata PATH --observed-out PATH [--require-stapled-ticket]'
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

dmg=
metadata=
observed_out=
require_stapled_ticket=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dmg|--metadata|--observed-out)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --dmg) dmg=$2 ;;
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

[ -n "$dmg" ] && [ -n "$metadata" ] && [ -n "$observed_out" ] || usage
[ -f "$dmg" ] || fail "DMG does not exist: $dmg"
[ -f "$metadata" ] || fail "release metadata does not exist: $metadata"
[ -d "$(dirname -- "$observed_out")" ] || fail "observed metadata output directory does not exist: $(dirname -- "$observed_out")"

image_format=$(hdiutil imageinfo -format "$dmg" 2>/dev/null) || fail 'could not inspect DMG format'
[ "$image_format" = UDZO ] || fail 'DMG must be a read-only compressed UDZO image'

mountpoint=$(mktemp -d "${TMPDIR:-/tmp}/linkgate-dmg-mount.XXXXXX")
attached=false

cleanup() {
    local status=${1:-$?}
    local detach_may_be_needed=${2:-false}
    local cleanup_failed=false

    trap - EXIT HUP INT TERM
    set +e
    if [ "$attached" = true ] || [ "$detach_may_be_needed" = true ]; then
        hdiutil detach "$mountpoint" >/dev/null
        if [ "$?" -ne 0 ]; then
            cleanup_failed=true
        fi
    fi
    rm -rf -- "$mountpoint"
    if [ "$?" -ne 0 ]; then
        cleanup_failed=true
    fi
    if [ "$status" -eq 0 ] && [ "$cleanup_failed" = true ]; then
        status=1
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'cleanup 129 true' HUP
trap 'cleanup 130 true' INT
trap 'cleanup 143 true' TERM

if ! hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$dmg" >/dev/null; then
    fail 'could not attach DMG read-only'
fi
attached=true

expected_entries=$(printf '%s\n' Applications LinkGate.app)
actual_entries=$(find "$mountpoint" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
[ "$actual_entries" = "$expected_entries" ] || fail 'DMG must contain exactly LinkGate.app and Applications'

app="$mountpoint/LinkGate.app"
applications="$mountpoint/Applications"
[ ! -L "$app" ] || fail 'DMG LinkGate.app must be a directory inside the mounted image'
[ -d "$app" ] || fail 'DMG LinkGate.app is missing or is not an application bundle'
[ -L "$applications" ] || fail 'DMG Applications entry must be a symbolic link'
[ "$(readlink "$applications")" = /Applications ] || fail 'DMG Applications symbolic link must resolve to /Applications'

validate_app_arguments=(--app "$app" --metadata "$metadata" --observed-out "$observed_out")
if [ "$require_stapled_ticket" = true ]; then
    validate_app_arguments+=(--require-stapled-ticket)
fi
"$script_dir/validate-app.sh" "${validate_app_arguments[@]}"
