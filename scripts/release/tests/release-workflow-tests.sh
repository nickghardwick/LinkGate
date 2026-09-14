#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)
fixtures="$script_dir/fixtures"
source_release="$repo_root/scripts/release/release.sh"
source_release_support="$repo_root/scripts/release/ReleaseSupport.swift"
source_validate_dmg="$repo_root/scripts/release/validate-dmg.sh"
source_config="$repo_root/scripts/release/config.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/linkgate-release-workflow-tests.XXXXXX")

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

assert_empty_file() {
    [ -f "$1" ] || fail "expected file: $1"
    [ ! -s "$1" ] || fail "expected empty file: $1"
}

assert_empty_directory() {
    local directory=$1

    [ -d "$directory" ] || fail "expected directory: $directory"
    [ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "expected empty directory: $directory"
}

assert_fails() {
    local label=$1
    shift
    local stdout="$tmp/$label.stdout"
    local stderr="$tmp/$label.stderr"

    if "$@" >"$stdout" 2>"$stderr"; then
        fail "expected command to fail: $label"
    fi
}

assert_fails_with_status() {
    local label=$1
    local expected_status=$2
    shift 2
    local actual_status

    if "$@" >"$tmp/$label.stdout" 2>"$tmp/$label.stderr"; then
        fail "expected command to fail: $label"
    else
        actual_status=$?
    fi

    [ "$actual_status" -eq "$expected_status" ] || fail "expected $label to exit $expected_status, got $actual_status"
}

assert_stage_sequence() {
    local log=$1
    shift
    local previous=0
    local stage line

    for stage in "$@"; do
        line=$(grep -n -m 1 -x -- "$stage" "$log" | cut -d: -f1 || true)
        [ -n "$line" ] || fail "missing release stage: $stage"
        [ "$line" -gt "$previous" ] || fail "release stage was out of order: $stage"
        previous=$line
    done
}

assert_no_stage() {
    local log=$1
    local stage=$2

    ! grep -F -x -- "$stage" "$log" >/dev/null || fail "did not expect release stage: $stage"
}

assert_directory_entries() {
    local directory=$1
    shift
    local expected actual

    expected=$(printf '%s\n' "$@" | sort)
    actual=$({
        while IFS= read -r -d '' entry; do
            name=$(basename "$entry")
            if [ -L "$entry" ]; then
                printf 'symlink:%s\n' "$name"
            elif [ -d "$entry" ]; then
                printf 'directory:%s\n' "$name"
            elif [ -f "$entry" ]; then
                printf 'file:%s\n' "$name"
            else
                printf 'other:%s\n' "$name"
            fi
        done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
    } | sort)
    [ "$actual" = "$expected" ] || fail "unexpected final release outputs in $directory: $actual"
}

assert_no_release_staging() {
    local parent=$1

    [ -z "$(find "$parent" -mindepth 1 -maxdepth 1 -name '.linkgate-release-final.*' -print -quit)" ] || fail "expected no partial sibling release staging directory in $parent"
}

assert_log_contains() {
    local log=$1
    local expected=$2

    grep -F -x -- "$expected" "$log" >/dev/null || fail "expected log entry: $expected"
}

sparkle_signing_line() {
    local target=$1

    awk -v target="$target" '
        substr($0, length($0) - length(target) + 1) == target {
            print NR
            exit
        }
    ' "$codesign_commands_log"
}

assert_sparkle_signing_invocation() {
    local target=$1
    local expected_preserved_metadata=${2:-false}
    local invocation

    invocation=$(awk -v target="$target" '
        substr($0, length($0) - length(target) + 1) == target {
            print
            exit
        }
    ' "$codesign_commands_log")
    [ -n "$invocation" ] || fail "expected a codesign invocation for $target"
    for required_flag in \
        '--force' \
        '--options runtime' \
        '--timestamp' \
        '--sign Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)'; do
        case "$invocation" in
            *"$required_flag"*) ;;
            *) fail "expected $required_flag for $target: $invocation" ;;
        esac
    done
    case "$invocation" in
        *'--deep'*) fail "Sparkle runtime signing must not use --deep: $invocation" ;;
    esac
    if [ "$expected_preserved_metadata" = true ]; then
        case "$invocation" in
            *'--preserve-metadata=entitlements'*) ;;
            *) fail "expected Downloader entitlement preservation: $invocation" ;;
        esac
    else
        case "$invocation" in
            *'--preserve-metadata=entitlements'*) fail "unexpected entitlement preservation on $target: $invocation" ;;
        esac
    fi
}

assert_sparkle_signing_sequence() {
    local previous=0
    local target
    local line

    for target in "$@"; do
        line=$(sparkle_signing_line "$target")
        [ -n "$line" ] || fail "expected a codesign invocation for $target"
        [ "$line" -gt "$previous" ] || fail "expected Sparkle runtime signing to be inside-out at $target"
        previous=$line
    done
}

write_dmg_validation_stubs() {
    local bin=$1
    local app_fixture=$2

    mkdir -p "$bin"

    cat >"$bin/hdiutil" <<'STUB'
#!/bin/bash
set -euo pipefail

command=$1
shift

case "$command" in
    imageinfo)
        [ "${1:-}" = -format ] || exit 64
        printf 'imageinfo\n' >>"$STAGE_LOG"
        printf '%s\n' "${DMG_IMAGE_FORMAT:-UDZO}"
        ;;
    attach)
        mountpoint=
        readonly=false
        nobrowse=false
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -readonly)
                    readonly=true
                    shift
                    ;;
                -nobrowse)
                    nobrowse=true
                    shift
                    ;;
                -mountpoint)
                    mountpoint=$2
                    shift 2
                    ;;
                *) shift ;;
            esac
        done
        [ -n "$mountpoint" ] || exit 64
        [ "$readonly" = true ] || exit 67
        [ "$nobrowse" = true ] || exit 68
        [ -n "${DMG_LAYOUT_FILE:-}" ] || exit 69
        printf 'attach\n' >>"$STAGE_LOG"
        [ "${HDIUTIL_ATTACH_FAIL:-0}" = 1 ] && exit 65
        printf '%s\n' "$mountpoint" >"$MOUNTPOINT_LOG"
        mkdir -p "$mountpoint"
        while IFS= read -r entry || [ -n "$entry" ]; do
            case "$entry" in
                LinkGate.app)
                    cp -R "$APP_FIXTURE" "$mountpoint/LinkGate.app"
                    ;;
                'LinkGate.app -> '* )
                    ln -s "${entry#LinkGate.app -> }" "$mountpoint/LinkGate.app"
                    ;;
                'Applications -> '*)
                    ln -s "${entry#Applications -> }" "$mountpoint/Applications"
                    ;;
                '')
                    ;;
                *)
                    : >"$mountpoint/$entry"
                    ;;
            esac
        done <"$DMG_LAYOUT_FILE"
        if [ "${HDIUTIL_ATTACH_SIGNAL_TERM:-0}" = 1 ]; then
            kill -TERM "$PPID"
        fi
        printf '%s\n' '/dev/disk99'
        ;;
    detach)
        printf 'detach\n' >>"$STAGE_LOG"
        exit "${HDIUTIL_DETACH_STATUS:-0}"
        ;;
    *) exit 64 ;;
esac
STUB

    cat >"$bin/readlink" <<'STUB'
#!/bin/bash
exec "${REAL_READLINK}" "$@"
STUB

    cat >"$bin/rm" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'rm\n' >>"$STAGE_LOG"
"$REAL_RM" "$@"
exit "${RM_STATUS:-0}"
STUB

    chmod +x "$bin/hdiutil" "$bin/readlink" "$bin/rm"
}

write_validate_app_stub() {
    local destination=$1

    cat >"$destination" <<'STUB'
#!/bin/bash
set -euo pipefail

app=
metadata=
observed_out=
require_stapled_ticket=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            app=$2
            shift 2
            ;;
        --metadata)
            metadata=$2
            shift 2
            ;;
        --observed-out)
            observed_out=$2
            shift 2
            ;;
        --require-stapled-ticket)
            require_stapled_ticket=true
            shift
            ;;
        *) shift ;;
    esac
done

[ -d "$app" ] || exit 66
[ -f "$metadata" ] || exit 67
[ -n "$observed_out" ] || exit 68
printf '%s|%s\n' "$app" "$metadata" >>"$VALIDATE_APP_LOG"
if [ "${VALIDATE_APP_SIGNAL_TERM:-0}" = 1 ]; then
    kill -TERM "$PPID"
fi
if [ "$require_stapled_ticket" = true ]; then
    xcrun stapler validate "$app"
fi
printf '%s\n' '{"validated":true}' >"$observed_out"
STUB
    chmod +x "$destination"
}

new_dmg_case() {
    local name=$1

    case_root="$tmp/dmg-$name"
    fixture_repo="$case_root/repository"
    stub_bin="$case_root/bin"
    stage_log="$case_root/stages.log"
    validate_app_log="$case_root/validate-app.log"
    metadata="$case_root/metadata.json"
    observed_out="$case_root/observed.json"
    dmg="$case_root/LinkGate-0.1.0.dmg"
    mountpoint_log="$case_root/mountpoint.log"

    mkdir -p "$fixture_repo/scripts/release" "$case_root"
    cp "$source_validate_dmg" "$fixture_repo/scripts/release/validate-dmg.sh"
    write_validate_app_stub "$fixture_repo/scripts/release/validate-app.sh"
    write_dmg_validation_stubs "$stub_bin" "$repo_root/scripts/release/tests/fixtures/app/LinkGate.app"
    chmod +x "$fixture_repo/scripts/release/validate-dmg.sh"
    printf '%s\n' '{}' >"$metadata"
    : >"$dmg"
    : >"$stage_log"
    : >"$validate_app_log"
}

run_validate_dmg() {
    env \
        PATH="$stub_bin:$PATH" \
        STAGE_LOG="$stage_log" \
        VALIDATE_APP_LOG="$validate_app_log" \
        MOUNTPOINT_LOG="$mountpoint_log" \
        APP_FIXTURE="$repo_root/scripts/release/tests/fixtures/app/LinkGate.app" \
        REAL_READLINK="$(command -v readlink)" \
        REAL_RM="$(command -v rm)" \
        "$@" \
        bash "$fixture_repo/scripts/release/validate-dmg.sh" --dmg "$dmg" --metadata "$metadata" --observed-out "$observed_out"
}

write_invalid_symlink_layout() {
    local output=$1

    sed 's#Applications -> /Applications#Applications -> /NotApplications#' "$fixtures/dmg-layout-valid.txt" >"$output"
}

write_invalid_app_symlink_layout() {
    local output=$1

    printf '%s\n' 'LinkGate.app -> /Applications/LinkGate.app' 'Applications -> /Applications' >"$output"
}

write_release_stubs() {
    local bin=$1
    local release_dir=$2

    mkdir -p "$bin"

    cat >"$release_dir/preflight.sh" <<'STUB'
#!/bin/bash
set -euo pipefail

metadata_out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --metadata-out)
            metadata_out=$2
            shift 2
            ;;
        *) shift ;;
    esac
done

printf 'preflight\n' >>"$STAGE_LOG"
[ "${FAIL_STAGE:-}" != preflight ] || exit 70
[ -z "${VERSION+x}" ] && [ -z "${BUILD+x}" ] || exit 71
[ -n "$metadata_out" ] || exit 64
printf '%s\n' "$metadata_out" >"$METADATA_LOG"
printf '%s\n' '{"product":"LinkGate","marketing_version":"0.1.0","build":"1","bundle_id":"com.nickghardwick.LinkGate","architectures":["arm64","x86_64"],"deployment_target":"14.0","signing_identity":"Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)","source_commit":"0123456789abcdef0123456789abcdef01234567","source_index_tree":"0123456789abcdef0123456789abcdef01234567"}' >"$metadata_out"
STUB

    cat >"$release_dir/validate-app.sh" <<'STUB'
#!/bin/bash
set -euo pipefail

app=
metadata=
observed_out=
require_stapled_ticket=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            app=$2
            shift 2
            ;;
        --metadata)
            metadata=$2
            shift 2
            ;;
        --observed-out)
            observed_out=$2
            shift 2
            ;;
        --require-stapled-ticket)
            require_stapled_ticket=true
            shift
            ;;
        *) shift ;;
    esac
done

[ -d "$app" ] || exit 66
[ -f "$metadata" ] || exit 67
[ -n "$observed_out" ] || exit 68
validation_count=$(wc -l <"$VALIDATE_APP_LOG" | tr -d ' ')
case "$validation_count" in
    0) stage=validate-built ;;
    1) stage=validate-stapled ;;
    *) exit 69 ;;
esac
printf '%s|%s|%s\n' "$app" "$metadata" "$require_stapled_ticket" >>"$VALIDATE_APP_LOG"
if [ "$require_stapled_ticket" = true ]; then
    xcrun stapler validate "$app"
    observed_security=',"notarized":true,"stapled":true'
else
    observed_security=',"notarized":false,"stapled":false'
fi
printf '%s\n' "$stage" >>"$STAGE_LOG"
[ "${FAIL_STAGE:-}" != "$stage" ] || exit 70
printf '%s\n' "{\"product\":\"LinkGate\",\"marketing_version\":\"0.1.0\",\"build\":\"1\",\"bundle_id\":\"com.nickghardwick.LinkGate\",\"architectures\":[\"arm64\",\"x86_64\"],\"deployment_target\":\"14.0\",\"signing_identity\":\"Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)\"$observed_security}" >"$observed_out"
STUB

    cat >"$release_dir/validate-dmg.sh" <<'STUB'
#!/bin/bash
set -euo pipefail

dmg=
metadata=
observed_out=
require_stapled_ticket=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dmg)
            dmg=$2
            shift 2
            ;;
        --metadata)
            metadata=$2
            shift 2
            ;;
        --observed-out)
            observed_out=$2
            shift 2
            ;;
        --require-stapled-ticket)
            require_stapled_ticket=true
            shift
            ;;
        *) shift ;;
    esac
done

printf 'validate\n' >>"$STAGE_LOG"
[ "${FAIL_STAGE:-}" != validate ] || exit 72
[ -f "$dmg" ] || exit 73
[ -f "$metadata" ] || exit 74
[ -n "$observed_out" ] || exit 64
printf '%s|%s|%s|%s\n' "$dmg" "$metadata" "$observed_out" "$require_stapled_ticket" >>"$VALIDATE_DMG_LOG"
if [[ "$dmg" == "$RELEASE_FINAL".*/* ]] && [ "${FINAL_DMG_OBSERVED_MISMATCH:-0}" = 1 ]; then
    printf '%s\n' '{"mismatch":true}' >"$observed_out"
elif [ "$require_stapled_ticket" = true ]; then
    printf '%s\n' '{"product":"LinkGate","marketing_version":"0.1.0","build":"1","bundle_id":"com.nickghardwick.LinkGate","architectures":["arm64","x86_64"],"deployment_target":"14.0","signing_identity":"Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)","notarized":true,"stapled":true}' >"$observed_out"
else
    printf '%s\n' '{"product":"LinkGate","marketing_version":"0.1.0","build":"1","bundle_id":"com.nickghardwick.LinkGate","architectures":["arm64","x86_64"],"deployment_target":"14.0","signing_identity":"Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)","notarized":false,"stapled":false}' >"$observed_out"
fi
STUB

    cat >"$bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$@" >>"$XCODEBUILD_ARGS_LOG"

if [ "${1:-}" = -version ]; then
    printf 'Xcode 26.6\nBuild version TEST\n'
    exit 0
fi

printf 'build\n' >>"$STAGE_LOG"
: >"$BUILD_MARKER"
[ "${FAIL_STAGE:-}" != build ] || exit 73
derived_data=
project=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -project)
            project=$2
            shift 2
            ;;
        -derivedDataPath)
            derived_data=$2
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "$derived_data" ] || exit 64
[ -n "$project" ] || exit 65
grep -F -x -- snapshot-source "$project/project.pbxproj" >/dev/null || exit 66
app="$derived_data/Build/Products/Release/LinkGate.app"
mkdir -p "$app/Contents/MacOS"
: >"$app/Contents/MacOS/LinkGate"
chmod +x "$app/Contents/MacOS/LinkGate"
sparkle_runtime="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p "$sparkle_runtime/XPCServices/Installer.xpc" \
    "$sparkle_runtime/XPCServices/Downloader.xpc" \
    "$sparkle_runtime/Updater.app"
: >"$sparkle_runtime/Autoupdate"
chmod +x "$sparkle_runtime/Autoupdate"
printf '%s\n' "$app" >"$BUILT_APP_LOG"
STUB

    cat >"$bin/codesign" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'sign\n' >>"$STAGE_LOG"
[ "${FAIL_STAGE:-}" != sign ] || exit 74
invocation="$*"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --sign ]; then
        printf '%s\n' "$invocation" >>"$CODESIGN_COMMAND_LOG"
        printf '%s\n' "$2" >"$CODESIGN_IDENTITY_LOG"
        break
    fi
    shift
done
STUB

    cat >"$bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >>"$XCRUN_LOG"

if [ "${1:-}" = --find ]; then
    printf '%s/%s\n' "$STUB_BIN" "$2"
    exit 0
fi

case "${1:-}" in
    notarytool)
        [ "${2:-}" = submit ] || exit 64
        [ "${4:-}" = --keychain-profile ] || exit 64
        [ "${5:-}" = linkgate-notary ] || exit 64
        [ "${6:-}" = --wait ] || exit 64
        printf 'notarize\n' >>"$STAGE_LOG"
        [ "${FAIL_STAGE:-}" != notarize ] || exit 75
        printf 'status: Accepted\n'
        ;;
    stapler)
        case "${2:-}" in
            staple)
                printf 'staple\n' >>"$STAGE_LOG"
                [ "${FAIL_STAGE:-}" != staple ] || exit 76
                ;;
            validate)
                printf 'stapler-validate\n' >>"$STAGE_LOG"
                [ "${FAIL_STAGE:-}" != stapler-validate ] || exit 85
                ;;
            *) exit 64 ;;
        esac
        ;;
    swift)
        if [ "${2:-}" = -e ]; then
            printf 'atomic-publish\n' >>"$STAGE_LOG"
            [ "${FAIL_STAGE:-}" != final-rename ] || exit 83
            if [ "${FAIL_STAGE:-}" = signal-term ]; then
                kill -TERM "$PPID"
                exit 0
            fi
            exec "$REAL_XCRUN" "$@"
        fi
        if [ "${2:-}" = "$RELEASE_SUPPORT" ]; then
            case "${3:-}" in
                manifest-write)
                    printf 'manifest\n' >>"$STAGE_LOG"
                    [ "${FAIL_STAGE:-}" != manifest ] || exit 77
                    ;;
                manifest-validate)
                    printf 'cross-check\n' >>"$STAGE_LOG"
                    [ "${FAIL_STAGE:-}" != cross-check ] || exit 78
                    ;;
                *) exit 64 ;;
            esac
            exec "$REAL_XCRUN" "$@"
        fi
        exit 64
        ;;
    *) exit 64 ;;
esac
STUB

    cat >"$bin/hdiutil" <<'STUB'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = create ] || exit 64
format=
output=${!#}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -format)
            format=$2
            shift 2
            ;;
        *) shift ;;
    esac
done
[ "$format" = UDZO ] || exit 81
printf 'package\n' >>"$STAGE_LOG"
[ "${FAIL_STAGE:-}" != package ] || exit 79
printf '%s\n' "$output" >"$PACKAGED_DMG_LOG"
: >"$output"
STUB

    cat >"$bin/cp" <<'STUB'
#!/bin/bash
set -euo pipefail
destination=${!#}
if [ "${FAIL_STAGE:-}" = final-copy ] && [[ "$destination" == "$RELEASE_FINAL".*/* ]]; then
    exit 82
fi
exec "$REAL_CP" "$@"
STUB

    cat >"$bin/mv" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'mv %s\n' "$*" >>"$PUBLICATION_COMMAND_LOG"
destination=${!#}
if [ "${FAIL_STAGE:-}" = signal-term ] && [ "$destination" = "$RELEASE_DIST" ]; then
    kill -TERM "$PPID"
    exit 0
fi
if [ "$destination" = "$RELEASE_DIST" ]; then
    printf 'publish\n' >>"$STAGE_LOG"
fi
if [ "${FAIL_STAGE:-}" = final-rename ] && { [ "$destination" = "$RELEASE_DIST" ] || [[ "$destination" == "$RELEASE_DIST"/* ]]; }; then
    exit 83
fi
exec "$REAL_MV" "$@"
STUB

    cat >"$bin/rmdir" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'rmdir %s\n' "$*" >>"$PUBLICATION_COMMAND_LOG"
printf 'rmdir\n' >>"$STAGE_LOG"
exec "$REAL_RMDIR" "$@"
STUB

    cat >"$bin/shasum" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'checksum\n' >>"$STAGE_LOG"
[ "${FAIL_STAGE:-}" != checksum ] || exit 80
exec "$REAL_SHASUM" "$@"
STUB

    cat >"$bin/sw_vers" <<'STUB'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = -productVersion ] || exit 64
printf '26.5\n'
STUB

    cat >"$bin/git" <<'STUB'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    archive)
        [ "${2:-}" = --format=tar ] || exit 64
        [ "${3:-}" = 0123456789abcdef0123456789abcdef01234567 ] || exit 65
        tar -cf - -C "$GIT_ARCHIVE_SOURCE" .
        ;;
    rev-parse)
        rev_parse_count=0
        if [ -n "${GIT_REV_PARSE_LOG:-}" ] && [ -f "$GIT_REV_PARSE_LOG" ]; then
            rev_parse_count=$(wc -l <"$GIT_REV_PARSE_LOG" | tr -d ' ')
        fi
        rev_parse_count=$((rev_parse_count + 1))
        [ -z "${GIT_REV_PARSE_LOG:-}" ] || printf '%s\n' "$rev_parse_count" >>"$GIT_REV_PARSE_LOG"
        if [ -n "${GIT_HEAD_CHANGE_AFTER:-}" ] && [ "$rev_parse_count" -gt "$GIT_HEAD_CHANGE_AFTER" ]; then
            printf '%s\n' "${GIT_HEAD_AFTER_CHANGE:-ffffffffffffffffffffffffffffffffffffffff}"
        else
            printf '%s\n' "${GIT_HEAD:-0123456789abcdef0123456789abcdef01234567}"
        fi
        ;;
    write-tree)
        index_tree_count=0
        if [ -n "${GIT_INDEX_TREE_LOG:-}" ] && [ -f "$GIT_INDEX_TREE_LOG" ]; then
            index_tree_count=$(wc -l <"$GIT_INDEX_TREE_LOG" | tr -d ' ')
        fi
        index_tree_count=$((index_tree_count + 1))
        [ -z "${GIT_INDEX_TREE_LOG:-}" ] || printf '%s\n' "$index_tree_count" >>"$GIT_INDEX_TREE_LOG"
        if [ -n "${GIT_INDEX_CHANGE_AFTER:-}" ] && [ "$index_tree_count" -gt "$GIT_INDEX_CHANGE_AFTER" ]; then
            printf '%s\n' ffffffffffffffffffffffffffffffffffffffff
        else
            printf '%s\n' 0123456789abcdef0123456789abcdef01234567
        fi
        ;;
    diff)
        worktree_diff_count=0
        if [ -n "${GIT_WORKTREE_DIFF_LOG:-}" ] && [ -f "$GIT_WORKTREE_DIFF_LOG" ]; then
            worktree_diff_count=$(wc -l <"$GIT_WORKTREE_DIFF_LOG" | tr -d ' ')
        fi
        worktree_diff_count=$((worktree_diff_count + 1))
        [ -z "${GIT_WORKTREE_DIFF_LOG:-}" ] || printf '%s\n' "$worktree_diff_count" >>"$GIT_WORKTREE_DIFF_LOG"
        if [ -n "${GIT_WORKTREE_DRIFT_AFTER:-}" ] && [ "$worktree_diff_count" -gt "$GIT_WORKTREE_DRIFT_AFTER" ]; then
            exit 1
        fi
        ;;
    ls-files)
        [ "${2:-}" = --others ] && [ "${3:-}" = --exclude-standard ] || exit 64
        untracked_count=0
        if [ -n "${GIT_UNTRACKED_LOG:-}" ] && [ -f "$GIT_UNTRACKED_LOG" ]; then
            untracked_count=$(wc -l <"$GIT_UNTRACKED_LOG" | tr -d ' ')
        fi
        untracked_count=$((untracked_count + 1))
        [ -z "${GIT_UNTRACKED_LOG:-}" ] || printf '%s\n' "$untracked_count" >>"$GIT_UNTRACKED_LOG"
        if [ -n "${GIT_UNTRACKED_AFTER:-}" ] && [ "$untracked_count" -gt "$GIT_UNTRACKED_AFTER" ]; then
            printf '%s\n' release-source.txt
        fi
        ;;
    *) exit 64 ;;
esac
STUB

    chmod +x "$release_dir/preflight.sh" "$release_dir/validate-app.sh" "$release_dir/validate-dmg.sh" "$bin/xcodebuild" "$bin/codesign" "$bin/xcrun" "$bin/hdiutil" "$bin/cp" "$bin/mv" "$bin/rmdir" "$bin/shasum" "$bin/sw_vers" "$bin/git"
}

new_release_case() {
    local name=$1

    case_root="$tmp/release-$name"
    fixture_repo="$case_root/repository"
    release_dir="$fixture_repo/scripts/release"
    stub_bin="$case_root/bin"
    stage_log="$case_root/stages.log"
    build_marker="$case_root/build-started"
    config_sourced_marker="$case_root/config-sourced"
    validate_app_log="$case_root/validate-app.log"
    built_app_log="$case_root/built-app.log"
    validate_dmg_log="$case_root/validate-dmg.log"
    packaged_dmg_log="$case_root/packaged-dmg.log"
    metadata_log="$case_root/metadata.log"
    xcodebuild_args_log="$case_root/xcodebuild-args.log"
    xcrun_log="$case_root/xcrun.log"
    publication_command_log="$case_root/publication-commands.log"
    git_rev_parse_log="$case_root/git-rev-parse.log"
    git_index_tree_log="$case_root/git-index-tree.log"
    git_worktree_diff_log="$case_root/git-worktree-diff.log"
    git_untracked_log="$case_root/git-untracked.log"
    codesign_identity_log="$case_root/codesign-identity.log"
    codesign_commands_log="$case_root/codesign-commands.log"
    archive_source="$case_root/archive-source"

    mkdir -p "$release_dir" "$fixture_repo/LinkGate.xcodeproj" "$fixture_repo/dist" "$archive_source/LinkGate.xcodeproj"
    fixture_repo=$(cd -- "$fixture_repo" && pwd -P)
    release_dir="$fixture_repo/scripts/release"
    cp "$source_release" "$release_dir/release.sh"
    cp "$source_release_support" "$release_dir/ReleaseSupport.swift"
    cp "$source_config" "$release_dir/config.sh"
    printf '\n: > "$CONFIG_SOURCED_MARKER"\n' >>"$release_dir/config.sh"
    printf '%s\n' live-checkout >"$fixture_repo/LinkGate.xcodeproj/project.pbxproj"
    printf '%s\n' snapshot-source >"$archive_source/LinkGate.xcodeproj/project.pbxproj"
    : >"$fixture_repo/dist/stale-output"
    : >"$fixture_repo/dist/partial-output"
    mkdir "$fixture_repo/dist/.tmp"
    ln -s /tmp "$fixture_repo/dist/stale-link"
    : >"$stage_log"
    : >"$validate_app_log"
    : >"$validate_dmg_log"
    : >"$xcodebuild_args_log"
    : >"$xcrun_log"
    : >"$publication_command_log"
    : >"$git_rev_parse_log"
    : >"$git_index_tree_log"
    : >"$git_worktree_diff_log"
    : >"$git_untracked_log"
    : >"$codesign_commands_log"
    chmod +x "$release_dir/release.sh"
    write_release_stubs "$stub_bin" "$release_dir"
}

run_release() {
    local failure_stage=$1
    shift
    local -a environment
    local -a release_arguments
    environment=()
    release_arguments=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --)
                shift
                release_arguments=("$@")
                break
                ;;
            *=*)
                environment+=("$1")
                shift
                ;;
            *)
                fail "test harness expected an environment assignment or -- before release arguments: $1"
                ;;
        esac
    done

    (
        cd "$fixture_repo"
        env \
            PATH="$stub_bin:$PATH" \
            STUB_BIN="$stub_bin" \
            STAGE_LOG="$stage_log" \
            BUILD_MARKER="$build_marker" \
            BUILT_APP_LOG="$built_app_log" \
            VALIDATE_APP_LOG="$validate_app_log" \
            VALIDATE_DMG_LOG="$validate_dmg_log" \
            PACKAGED_DMG_LOG="$packaged_dmg_log" \
            METADATA_LOG="$metadata_log" \
            XCODEBUILD_ARGS_LOG="$xcodebuild_args_log" \
            XCRUN_LOG="$xcrun_log" \
            PUBLICATION_COMMAND_LOG="$publication_command_log" \
            GIT_REV_PARSE_LOG="$git_rev_parse_log" \
            GIT_INDEX_TREE_LOG="$git_index_tree_log" \
            GIT_WORKTREE_DIFF_LOG="$git_worktree_diff_log" \
            GIT_UNTRACKED_LOG="$git_untracked_log" \
            GIT_UNTRACKED_AFTER="${GIT_UNTRACKED_AFTER:-}" \
            GIT_ARCHIVE_SOURCE="$archive_source" \
            CODESIGN_IDENTITY_LOG="$codesign_identity_log" \
            CODESIGN_COMMAND_LOG="$codesign_commands_log" \
            CONFIG_SOURCED_MARKER="$config_sourced_marker" \
            RELEASE_DIST="$fixture_repo/dist" \
            RELEASE_FINAL="$(dirname "$fixture_repo/dist")/.linkgate-release-final" \
            REAL_CP="$(command -v cp)" \
            REAL_MV="$(command -v mv)" \
            REAL_RMDIR="$(command -v rmdir)" \
            REAL_SHASUM="$(command -v shasum)" \
            REAL_XCRUN="$real_xcrun" \
            RELEASE_SUPPORT="$release_dir/ReleaseSupport.swift" \
            FAIL_STAGE="$failure_stage" \
            ${environment[@]+"${environment[@]}"} \
            bash "$release_dir/release.sh" ${release_arguments[@]+"${release_arguments[@]}"}
    )
}

assert_file "$source_config"
assert_file "$source_validate_dmg"
assert_file "$source_release"
assert_file "$source_release_support"
assert_file "$fixtures/dmg-layout-valid.txt"
assert_file "$fixtures/dmg-layout-invalid.txt"
real_xcrun=$(command -v xcrun) || fail 'xcrun is required to exercise release publication through the local Swift toolchain'
[ -x "$real_xcrun" ] || fail "expected an executable xcrun path: $real_xcrun"

new_dmg_case valid
run_validate_dmg DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt"
assert_file "$observed_out"
assert_stage_sequence "$stage_log" imageinfo attach detach
[ "$(wc -l <"$validate_app_log" | tr -d ' ')" = 1 ] || fail 'expected mounted app validation exactly once'
mounted_app="$(cat "$mountpoint_log")/LinkGate.app"
grep -F -x -- "$mounted_app|$metadata" "$validate_app_log" >/dev/null || fail 'expected validator to receive the mounted LinkGate.app and metadata'

new_dmg_case writable-image
assert_fails writable-image run_validate_dmg DMG_IMAGE_FORMAT=UDRW DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt"
assert_log_contains "$stage_log" imageinfo
assert_no_stage "$stage_log" attach
assert_no_stage "$stage_log" detach
[ ! -s "$validate_app_log" ] || fail 'validator ran for a writable image that could attach read-only'

new_dmg_case uncompressed-read-only-image
assert_fails uncompressed-read-only-image run_validate_dmg DMG_IMAGE_FORMAT=UDRO DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt"
assert_log_contains "$stage_log" imageinfo
assert_no_stage "$stage_log" attach
assert_no_stage "$stage_log" detach
[ ! -s "$validate_app_log" ] || fail 'validator ran for a non-UDZO image that could attach read-only'

new_dmg_case invalid-format
assert_fails invalid-format run_validate_dmg HDIUTIL_ATTACH_FAIL=1 DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt"
assert_stage_sequence "$stage_log" imageinfo attach
assert_no_stage "$stage_log" detach
[ ! -s "$validate_app_log" ] || fail 'validator ran for an unmounted invalid image'

new_dmg_case invalid-layout
assert_fails invalid-layout run_validate_dmg DMG_LAYOUT_FILE="$fixtures/dmg-layout-invalid.txt"
assert_stage_sequence "$stage_log" attach detach
[ ! -s "$validate_app_log" ] || fail 'validator ran before rejecting an invalid DMG layout'

new_dmg_case invalid-applications-symlink
invalid_symlink_layout="$case_root/invalid-symlink-layout.txt"
write_invalid_symlink_layout "$invalid_symlink_layout"
assert_fails invalid-applications-symlink run_validate_dmg DMG_LAYOUT_FILE="$invalid_symlink_layout"
assert_stage_sequence "$stage_log" attach detach
[ ! -s "$validate_app_log" ] || fail 'validator ran before rejecting the Applications symlink target'

new_dmg_case invalid-app-symlink
invalid_app_symlink_layout="$case_root/invalid-app-symlink-layout.txt"
write_invalid_app_symlink_layout "$invalid_app_symlink_layout"
assert_fails invalid-app-symlink run_validate_dmg DMG_LAYOUT_FILE="$invalid_app_symlink_layout"
assert_stage_sequence "$stage_log" attach detach
[ ! -s "$validate_app_log" ] || fail 'validator ran before rejecting a symlinked LinkGate.app'

new_dmg_case detach-failure
assert_fails detach-failure run_validate_dmg DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt" HDIUTIL_DETACH_STATUS=1
assert_stage_sequence "$stage_log" attach detach
[ -s "$validate_app_log" ] || fail 'expected mounted app validation before detach failure'

new_dmg_case signal-term
assert_fails_with_status signal-term 143 run_validate_dmg DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt" VALIDATE_APP_SIGNAL_TERM=1
assert_stage_sequence "$stage_log" attach detach

new_dmg_case signal-term-during-attach
assert_fails_with_status signal-term-during-attach 143 run_validate_dmg DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt" HDIUTIL_ATTACH_SIGNAL_TERM=1
assert_stage_sequence "$stage_log" attach detach

new_dmg_case signal-term-cleanup-failures
assert_fails_with_status signal-term-cleanup-failures 143 run_validate_dmg DMG_LAYOUT_FILE="$fixtures/dmg-layout-valid.txt" VALIDATE_APP_SIGNAL_TERM=1 HDIUTIL_DETACH_STATUS=1 RM_STATUS=1
assert_stage_sequence "$stage_log" attach detach rm
assert_no_file "$(cat "$mountpoint_log")"

new_release_case success
run_release ''
assert_file "$config_sourced_marker"
assert_stage_sequence "$stage_log" preflight build sign validate-built notarize staple stapler-validate validate-stapled package validate checksum manifest cross-check atomic-publish
# The PATH-stubbed xcrun delegates the original `swift -e` source and paths to
# the local Xcode toolchain, exercising the production Darwin rename(2) call.
assert_no_stage "$stage_log" publish
assert_no_stage "$stage_log" rmdir
assert_empty_file "$publication_command_log"
[ "$(cat "$codesign_identity_log")" = 'Developer ID Application: Nicholas Hardwick (Z8A8ZWCZ45)' ] || fail 'expected codesign to receive the Keychain-selected Developer ID authority'
[ "$(wc -l <"$codesign_commands_log" | tr -d ' ')" = 6 ] || fail 'expected exactly the approved Sparkle runtime and outer app signing invocations'
[ "$(wc -l <"$validate_app_log" | tr -d ' ')" = 2 ] || fail 'expected built and stapled app validation exactly once each'
built_app="$(cat "$built_app_log")"
sparkle_runtime="$built_app/Contents/Frameworks/Sparkle.framework/Versions/B"
sparkle_framework="$built_app/Contents/Frameworks/Sparkle.framework"
assert_sparkle_signing_invocation "$sparkle_runtime/XPCServices/Installer.xpc"
assert_sparkle_signing_invocation "$sparkle_runtime/XPCServices/Downloader.xpc" true
assert_sparkle_signing_invocation "$sparkle_runtime/Autoupdate"
assert_sparkle_signing_invocation "$sparkle_runtime/Updater.app"
assert_sparkle_signing_invocation "$sparkle_framework"
assert_sparkle_signing_invocation "$built_app"
assert_sparkle_signing_sequence \
    "$sparkle_runtime/XPCServices/Installer.xpc" \
    "$sparkle_runtime/XPCServices/Downloader.xpc" \
    "$sparkle_runtime/Autoupdate" \
    "$sparkle_runtime/Updater.app" \
    "$sparkle_framework" \
    "$built_app"
first_validated_app=$(sed -n '1s/|.*//p' "$validate_app_log")
second_validated_app=$(sed -n '2s/|.*//p' "$validate_app_log")
[ "$first_validated_app" = "$built_app" ] || fail 'expected built app validation to target the release build product'
[ "$second_validated_app" = "$built_app" ] || fail 'expected stapled app validation to target the release build product'
first_validation_metadata=$(sed -n '1s/^[^|]*|//' "$validate_app_log")
second_validation_metadata=$(sed -n '2s/^[^|]*|//' "$validate_app_log")
first_validation_metadata=${first_validation_metadata%%|*}
second_validation_metadata=${second_validation_metadata%%|*}
[ "$first_validation_metadata" = "$second_validation_metadata" ] || fail 'expected built and stapled app validation to use the same release metadata'
[ "$(sed -n '1s/.*|//p' "$validate_app_log")" = false ] || fail 'expected built app validation to report no stapled ticket'
[ "$(sed -n '2s/.*|//p' "$validate_app_log")" = true ] || fail 'expected stapled app validation to require a validated stapled ticket'
expected_dmg="$(cat "$packaged_dmg_log")"
expected_metadata="$(cat "$metadata_log")"
expected_validate_dmg_prefix="$expected_dmg|$expected_metadata|"
[ "$(wc -l <"$validate_dmg_log" | tr -d ' ')" = 2 ] || fail 'expected packaged and final-staging DMG validation exactly once each'
case "$(sed -n '1p' "$validate_dmg_log")" in
    "$expected_validate_dmg_prefix"*) ;;
    *) fail 'expected final DMG validation to receive the packaged DMG and release metadata' ;;
esac
[ "$(sed -n '1s/.*|//p' "$validate_dmg_log")" = true ] || fail 'expected packaged DMG validation to require a validated stapled ticket'
final_validated_dmg=$(sed -n '2s/|.*//p' "$validate_dmg_log")
case "$final_validated_dmg" in
    "$fixture_repo"/.linkgate-release-final.*/LinkGate-0.1.0.dmg) ;;
    *) fail 'expected final DMG validation to inspect the copied sibling-staging DMG' ;;
esac
[ "$(sed -n '2s/.*|//p' "$validate_dmg_log")" = true ] || fail 'expected final DMG validation to require a validated stapled ticket'
assert_directory_entries "$fixture_repo/dist" file:LinkGate-0.1.0.dmg file:LinkGate-0.1.0.dmg.sha256 file:LinkGate-0.1.0.release.json
checksum_line=$(cat "$fixture_repo/dist/LinkGate-0.1.0.dmg.sha256")
[ "$checksum_line" = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  LinkGate-0.1.0.dmg' ] || fail 'expected the published checksum to name only the final DMG basename'
assert_no_release_staging "$fixture_repo"
assert_log_contains "$xcodebuild_args_log" '-project'
snapshot_project=$(sed -n '/^-project$/ { n; p; }' "$xcodebuild_args_log")
case "$snapshot_project" in
    "${TMPDIR:-/tmp}"/linkgate-release.*/source/LinkGate.xcodeproj) ;;
    *) fail "expected xcodebuild to receive a project path from the source snapshot, got: $snapshot_project" ;;
esac
[ "$snapshot_project" != "$fixture_repo/LinkGate.xcodeproj" ] || fail 'xcodebuild used the live checkout project instead of the source snapshot'
assert_log_contains "$xcodebuild_args_log" '-scheme'
assert_log_contains "$xcodebuild_args_log" 'LinkGate'
assert_log_contains "$xcodebuild_args_log" '-configuration'
assert_log_contains "$xcodebuild_args_log" 'Release'
assert_log_contains "$xcodebuild_args_log" '-destination'
assert_log_contains "$xcodebuild_args_log" 'platform=macOS,arch=arm64'
assert_log_contains "$xcodebuild_args_log" '-derivedDataPath'
assert_log_contains "$xcodebuild_args_log" 'ARCHS=arm64 x86_64'
assert_log_contains "$xcodebuild_args_log" 'ONLY_ACTIVE_ARCH=NO'
grep -E -x -- 'notarytool submit .*/LinkGate\.zip --keychain-profile linkgate-notary --wait' "$xcrun_log" >/dev/null || fail 'expected notary submission with the configured profile and --wait'
assert_log_contains "$xcrun_log" "stapler validate $built_app"
manifest_path=$(sed -n 's/^.* manifest-write .* --output //p' "$xcrun_log")
[ -n "$manifest_path" ] || fail 'expected manifest-write output path'
assert_log_contains "$xcrun_log" "swift $release_dir/ReleaseSupport.swift manifest-write --metadata $expected_metadata --source-commit 0123456789abcdef0123456789abcdef01234567 --xcode-version Xcode 26.6 Build version TEST --macos-version 26.5 --artifact LinkGate-0.1.0.dmg --sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --output $manifest_path"
expected_dmg_observed=$(cut -d '|' -f 3 < <(sed -n '2p' "$validate_dmg_log"))
assert_log_contains "$xcrun_log" "swift $release_dir/ReleaseSupport.swift manifest-validate --manifest $manifest_path --checksum ${manifest_path%.release.json}.dmg.sha256 --observed $expected_dmg_observed --dmg ${manifest_path%.release.json}.dmg"

new_release_case final-dmg-observed-mismatch
assert_fails final-dmg-observed-mismatch run_release '' FINAL_DMG_OBSERVED_MISMATCH=1
[ "$(wc -l <"$validate_dmg_log" | tr -d ' ')" = 2 ] || fail 'expected final staging DMG validation before rejecting observed metadata mismatch'
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case preflight-failure
assert_fails preflight-failure run_release preflight
assert_no_file "$build_marker"
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case source-commit-changed
assert_fails source-commit-changed run_release '' GIT_HEAD=ffffffffffffffffffffffffffffffffffffffff
assert_no_file "$build_marker"
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case tracked-worktree-drift-before-build
assert_fails tracked-worktree-drift-before-build run_release '' GIT_WORKTREE_DRIFT_AFTER=0
assert_no_file "$build_marker"
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case tracked-worktree-drift-after-build
assert_fails tracked-worktree-drift-after-build run_release '' GIT_WORKTREE_DRIFT_AFTER=1
assert_stage_sequence "$stage_log" preflight build
assert_no_stage "$stage_log" sign
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case tracked-index-drift-after-build
assert_fails tracked-index-drift-after-build run_release '' GIT_INDEX_CHANGE_AFTER=1
assert_stage_sequence "$stage_log" preflight build
assert_no_stage "$stage_log" sign
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case untracked-file-drift-after-build
assert_fails untracked-file-drift-after-build run_release '' GIT_UNTRACKED_AFTER=1
assert_stage_sequence "$stage_log" preflight build
assert_no_stage "$stage_log" sign
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case source-commit-changed-before-publication
assert_fails source-commit-changed-before-publication run_release '' GIT_HEAD_CHANGE_AFTER=3
assert_stage_sequence "$stage_log" preflight build sign validate-built notarize staple stapler-validate validate-stapled package validate checksum manifest cross-check
[ "$(wc -l <"$git_rev_parse_log" | tr -d ' ')" = 4 ] || fail 'expected a source revision check immediately before publication'
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case source-commit-changed-after-publication
assert_fails source-commit-changed-after-publication run_release '' GIT_HEAD_CHANGE_AFTER=4
assert_stage_sequence "$stage_log" preflight build sign validate-built notarize staple stapler-validate validate-stapled package validate checksum manifest cross-check atomic-publish
[ "$(wc -l <"$git_rev_parse_log" | tr -d ' ')" = 5 ] || fail 'expected a source revision check immediately after publication'
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case version-override
assert_fails version-override run_release '' VERSION=9.9
assert_no_file "$build_marker"
assert_empty_directory "$fixture_repo/dist"

new_release_case build-override
assert_fails build-override run_release '' BUILD=99
assert_no_file "$build_marker"
assert_empty_directory "$fixture_repo/dist"

new_release_case positional-release-override
assert_fails positional-release-override run_release '' -- 9.9 99
assert_no_file "$build_marker"
assert_empty_directory "$fixture_repo/dist"

for failing_stage in build sign validate-built notarize staple stapler-validate validate-stapled package validate checksum manifest cross-check final-copy final-rename; do
    new_release_case "failure-$failing_stage"
    assert_fails "failure-$failing_stage" run_release "$failing_stage"
    assert_empty_directory "$fixture_repo/dist"
    assert_no_release_staging "$fixture_repo"
done

new_release_case preserve-build-failure-status
assert_fails_with_status preserve-build-failure-status 73 run_release build
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

new_release_case signal-term-before-publication
assert_fails_with_status signal-term-before-publication 143 run_release signal-term
assert_empty_directory "$fixture_repo/dist"
assert_no_release_staging "$fixture_repo"

printf 'PASS: deterministic release DMG validation and workflow tests\n'
