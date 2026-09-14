#!/bin/bash

# Deterministic publication-tool provisioning tests. These use a temporary
# repository and a mocked download command; no Sparkle archive is fetched.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)
setup_script="$repo_root/scripts/release/setup-publish-env.sh"
activation_script="$repo_root/scripts/release/activate-publish-env.sh"
config="$repo_root/scripts/release/publish-config.json"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/linkgate-publish-env-tests.XXXXXX")
system_path=$PATH
real_tar=$(command -v tar)

cleanup() {
    rm -rf "$tmp"
}

trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local actual=$1
    local expected=$2
    local context=$3

    [ "$actual" = "$expected" ] || fail "$context (expected $expected, got $actual)"
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_executable() {
    [ -x "$1" ] || fail "expected executable: $1"
}

assert_fails() {
    local label=$1
    shift

    if "$@" >"$tmp/$label.stdout" 2>"$tmp/$label.stderr"; then
        fail "expected command to fail: $label"
    fi

    [ -s "$tmp/$label.stderr" ] || fail "expected actionable stderr from failing command: $label"
}

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

config_value() {
    plutil -extract "$1" raw -o - "$2"
}

assert_canonical_distribution() {
    assert_equal "$(config_value sparkle.version "$config")" '2.9.6' 'expected pinned Sparkle version'
    assert_equal "$(config_value sparkle.distribution.archive_name "$config")" 'Sparkle-2.9.6.tar.xz' 'expected pinned archive name'
    assert_equal "$(config_value sparkle.distribution.archive_url "$config")" 'https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz' 'expected pinned archive URL'
    assert_equal "$(config_value sparkle.distribution.archive_sha256 "$config")" '52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192' 'expected pinned archive checksum'
    assert_equal "$(config_value sparkle.distribution.sign_update_path "$config")" 'bin/sign_update' 'expected pinned sign_update path'
    assert_equal "$(config_value sparkle.distribution.sign_update_sha256 "$config")" 'bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad' 'expected pinned sign_update checksum'
}

write_stub_tools() {
    local destination=$1

    mkdir -p "$destination"

    cat >"$destination/python3" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'python3 %s\n' "$*" >>"$FIXTURE_PYTHON_LOG"
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
    venv=${3:?missing venv destination}
    mkdir -p "$venv/bin"
    cat >"$venv/bin/python" <<'PYTHON'
#!/bin/bash
set -euo pipefail
printf 'venv-python %s\n' "$*" >>"$FIXTURE_PYTHON_LOG"
exit 0
PYTHON
    chmod +x "$venv/bin/python"
    exit 0
fi

printf 'unexpected python3 invocation\n' >&2
exit 1
STUB

    cat >"$destination/curl" <<'STUB'
#!/bin/bash
set -euo pipefail

output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            output=${2:?missing download destination}
            shift 2
            ;;
        http://*|https://*)
            url=$1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

[ -n "$output" ] || { printf 'download did not provide an output path\n' >&2; exit 1; }
[ -n "$url" ] || { printf 'download did not provide an HTTPS URL\n' >&2; exit 1; }
printf '%s\n' "$url" >>"$FIXTURE_CURL_LOG"
cp "$FIXTURE_DOWNLOAD_ARCHIVE" "$output"
STUB

    cat >"$destination/tar" <<'STUB'
#!/bin/bash
set -euo pipefail

printf 'tar %s\n' "$*" >>"$FIXTURE_TAR_LOG"
if [ "${FIXTURE_TAR_MUST_NOT_RUN:-0}" = 1 ]; then
    printf 'tar must not run before archive checksum verification\n' >&2
    exit 1
fi
exec "$FIXTURE_REAL_TAR" "$@"
STUB

    chmod +x "$destination/python3" "$destination/curl" "$destination/tar"
}

make_archive() {
    local archive=$1
    local include_tool=$2
    local payload="$tmp/payload-$(basename "$archive")"

    mkdir -p "$payload/Sparkle-2.9.6/bin"
    if [ "$include_tool" = true ]; then
        cat >"$payload/Sparkle-2.9.6/bin/sign_update" <<'TOOL'
#!/bin/sh
printf 'fixture sign_update\n'
TOOL
        chmod +x "$payload/Sparkle-2.9.6/bin/sign_update"
    fi
    tar -cJf "$archive" -C "$payload" Sparkle-2.9.6
}

new_fixture_repository() {
    local name=$1
    local archive=$2
    local expected_archive_sha=$3
    local expected_tool_sha=$4
    local destination="$tmp/$name/repo"

    mkdir -p "$destination/scripts/release"
    cp "$setup_script" "$destination/scripts/release/setup-publish-env.sh"
    # The activation script is intentionally an explicit supported companion
    # to setup, rather than an undocumented PATH mutation.
    cp "$activation_script" "$destination/scripts/release/activate-publish-env.sh"
    cp "$config" "$destination/scripts/release/publish-config.json"
    : >"$destination/requirements-publish.txt"
    plutil -replace sparkle.distribution.archive_url -string "https://fixtures.invalid/$name/Sparkle-2.9.6.tar.xz" "$destination/scripts/release/publish-config.json"
    plutil -replace sparkle.distribution.archive_sha256 -string "$expected_archive_sha" "$destination/scripts/release/publish-config.json"
    plutil -replace sparkle.distribution.sign_update_sha256 -string "$expected_tool_sha" "$destination/scripts/release/publish-config.json"
    (cd "$destination" && pwd -P)
}

run_setup() {
    local fixture_root=$1
    local archive=$2
    shift 2

    env \
        PATH="$tmp/stubs:$system_path" \
        FIXTURE_DOWNLOAD_ARCHIVE="$archive" \
        FIXTURE_CURL_LOG="$tmp/curl.log" \
        FIXTURE_TAR_LOG="$tmp/tar.log" \
        FIXTURE_PYTHON_LOG="$tmp/python.log" \
        FIXTURE_REAL_TAR="$real_tar" \
        "$@" \
        bash "$fixture_root/scripts/release/setup-publish-env.sh"
}

assert_canonical_distribution
assert_file "$setup_script"
assert_file "$activation_script"

write_stub_tools "$tmp/stubs"

valid_archive="$tmp/Sparkle-2.9.6-valid.tar.xz"
make_archive "$valid_archive" true
valid_tool="$tmp/valid-tool"
tar -xJOf "$valid_archive" Sparkle-2.9.6/bin/sign_update >"$valid_tool"
valid_archive_sha=$(sha256 "$valid_archive")
valid_tool_sha=$(sha256 "$valid_tool")

fixture_root=$(new_fixture_repository success "$valid_archive" "$valid_archive_sha" "$valid_tool_sha")
run_setup "$fixture_root" "$valid_archive"
tool_root="$fixture_root/.venv/publish-tools/sparkle-2.9.6"
tool="$tool_root/bin/sign_update"
assert_executable "$tool"
assert_equal "$(sha256 "$tool")" "$valid_tool_sha" 'expected installed sign_update checksum'
assert_equal "$(cat "$tmp/curl.log")" 'https://fixtures.invalid/success/Sparkle-2.9.6.tar.xz' 'expected download URL from fixture publication configuration'
grep -F -- "venv-python -m pip install --requirement $fixture_root/requirements-publish.txt" "$tmp/python.log" >/dev/null ||
    fail 'expected existing Python publication environment setup to remain functional'

activation_output=$(env PATH="$tmp/arbitrary-bin:$system_path" bash -c '. "$1"; printf "sparkle=%s\\npath=%s\\nsign_update=%s\\npython=%s\\n" "$LINKGATE_SPARKLE_DIR" "$PATH" "$(command -v sign_update)" "$(command -v python)"' _ "$fixture_root/scripts/release/activate-publish-env.sh")
assert_equal "$(printf '%s\n' "$activation_output" | sed -n 's/^sparkle=//p')" "$tool_root" 'expected activation to export approved Sparkle directory'
assert_equal "$(printf '%s\n' "$activation_output" | sed -n 's/^sign_update=//p')" "$tool" 'expected activation to resolve sign_update from approved Sparkle directory'
assert_equal "$(printf '%s\n' "$activation_output" | sed -n 's/^python=//p')" "$fixture_root/.venv/publish/bin/python" 'expected activation to resolve Python from publication environment'
case "$(printf '%s\n' "$activation_output" | sed -n 's/^path=//p')" in
    "$tool_root/bin:$fixture_root/.venv/publish/bin:"*) ;;
    *) fail 'expected activation to prepend Sparkle then publication Python bins to PATH' ;;
esac

zsh_activation_output=$(env PATH="$tmp/arbitrary-bin:$system_path" zsh -fc '. "$1"; printf "sparkle=%s\\npath=%s\\nsign_update=%s\\npython=%s\\n" "$LINKGATE_SPARKLE_DIR" "$PATH" "$(command -v sign_update)" "$(command -v python)"' zsh "$fixture_root/scripts/release/activate-publish-env.sh")
assert_equal "$(printf '%s\n' "$zsh_activation_output" | sed -n 's/^sparkle=//p')" "$tool_root" 'expected zsh activation to export approved Sparkle directory'
assert_equal "$(printf '%s\n' "$zsh_activation_output" | sed -n 's/^sign_update=//p')" "$tool" 'expected zsh activation to resolve sign_update from approved Sparkle directory'
assert_equal "$(printf '%s\n' "$zsh_activation_output" | sed -n 's/^python=//p')" "$fixture_root/.venv/publish/bin/python" 'expected zsh activation to resolve Python from publication environment'
case "$(printf '%s\n' "$zsh_activation_output" | sed -n 's/^path=//p')" in
    "$tool_root/bin:$fixture_root/.venv/publish/bin:"*) ;;
    *) fail 'expected zsh activation to prepend Sparkle then publication Python bins to PATH' ;;
esac

tampered_tool="$tool"
printf 'tampered fixture sign_update\n' >"$tampered_tool"
assert_fails activation-rejects-tampered-tool env PATH="$system_path" bash -c '. "$1"' _ "$fixture_root/scripts/release/activate-publish-env.sh"

mismatched_archive="$tmp/Sparkle-2.9.6-mismatched.tar.xz"
printf 'not the configured archive\n' >"$mismatched_archive"
archive_mismatch_root=$(new_fixture_repository archive-mismatch "$mismatched_archive" "$valid_archive_sha" "$valid_tool_sha")
: >"$tmp/tar.log"
assert_fails archive-checksum-mismatch run_setup "$archive_mismatch_root" "$mismatched_archive" FIXTURE_TAR_MUST_NOT_RUN=1
[ ! -s "$tmp/tar.log" ] || fail 'archive extraction ran before archive checksum verification'

missing_tool_archive="$tmp/Sparkle-2.9.6-missing-tool.tar.xz"
make_archive "$missing_tool_archive" false
missing_tool_root=$(new_fixture_repository missing-tool "$missing_tool_archive" "$(sha256 "$missing_tool_archive")" "$valid_tool_sha")
assert_fails missing-sign-update run_setup "$missing_tool_root" "$missing_tool_archive"

wrong_tool_root=$(new_fixture_repository tool-checksum-mismatch "$valid_archive" "$valid_archive_sha" "$(printf '%064d' 0)")
assert_fails sign-update-checksum-mismatch run_setup "$wrong_tool_root" "$valid_archive"

printf 'PASS: deterministic Sparkle publication environment provisioning tests\n'
