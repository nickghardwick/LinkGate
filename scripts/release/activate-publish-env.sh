#!/bin/sh

# Source this script from a shell after setup-publish-env.sh. It verifies the
# repository-local Sparkle tool before exposing it to publication commands.

if [ -n "${BASH_SOURCE:-}" ]; then
    activation_script=${BASH_SOURCE}
elif [ -n "${ZSH_VERSION:-}" ]; then
    activation_script=${(%):-%N}
else
    printf 'activate-publish-env: source this script from bash or zsh\n' >&2
    return 2 2>/dev/null || exit 2
fi

linkgate_activate_publish_env() {
    script_dir=$(CDPATH= cd -- "$(dirname -- "$activation_script")" && pwd -P) || return 2
    repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P) || return 2
    config="$script_dir/publish-config.json"
    venv="$repo_root/.venv/publish"
    python="$venv/bin/python"

    if [ ! -x "$python" ]; then
        printf 'activate-publish-env: missing %s; run ./scripts/release/setup-publish-env.sh first\n' "$python" >&2
        return 2
    fi

    config_value() {
        plutil -extract "$1" raw -o - "$config" 2>/dev/null || {
            printf 'activate-publish-env: could not read %s from %s\n' "$1" "$config" >&2
            return 1
        }
    }

    sparkle_version=$(config_value sparkle.version) || return 2
    sign_update_path=$(config_value sparkle.distribution.sign_update_path) || return 2
    expected_sha256=$(config_value sparkle.distribution.sign_update_sha256) || return 2
    sparkle_dir="$repo_root/.venv/publish-tools/sparkle-$sparkle_version"
    sign_update="$sparkle_dir/$sign_update_path"

    if [ ! -f "$sign_update" ] || [ ! -x "$sign_update" ]; then
        printf 'activate-publish-env: missing executable %s; run ./scripts/release/setup-publish-env.sh first\n' "$sign_update" >&2
        return 2
    fi
    actual_sha256=$(shasum -a 256 "$sign_update" | awk 'NR == 1 { print $1 }') || return 2
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'activate-publish-env: Sparkle sign_update does not match pinned SHA-256\n' >&2
        return 2
    fi

    export LINKGATE_SPARKLE_DIR="$sparkle_dir"
    export PATH="$sparkle_dir/bin:$venv/bin:$PATH"
}

linkgate_activate_publish_env
linkgate_activate_status=$?
unset -f linkgate_activate_publish_env 2>/dev/null || true
return "$linkgate_activate_status" 2>/dev/null || exit "$linkgate_activate_status"
