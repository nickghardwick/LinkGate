#!/bin/bash

# Check the public release entry points without requiring maintainer notes.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)
makefile="$repo_root/Makefile"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

makefile_has_force_execution_risk() {
    awk '
        function command_has_force_execution_risk(command, prefix) {
            sub(/^[[:space:]]+/, "", command)
            while (length(command) > 0) {
                prefix = substr(command, 1, 1)
                if (prefix == "+") {
                    return 1
                }
                if (prefix != "@" && prefix != "-") {
                    break
                }
                command = substr(command, 2)
            }
            return command ~ /\$\(MAKE\)/
        }

        function continues_on_next_line(line, trailing_backslashes) {
            trailing_backslashes = 0
            while (line ~ /\\$/) {
                trailing_backslashes++
                line = substr(line, 1, length(line) - 1)
            }
            return trailing_backslashes % 2 == 1
        }

        BEGIN { recipe_prefix = "\t" }

        {
            if (recipe_continues) {
                if ($0 ~ /\$\(MAKE\)/) {
                    found = 1
                    exit
                }
                recipe_continues = continues_on_next_line($0)
                next
            }

            if ($0 ~ /^[[:space:]]*\.RECIPEPREFIX[[:space:]]*(:|\?|\+|!)?=/) {
                value = $0
                sub(/^[[:space:]]*\.RECIPEPREFIX[[:space:]]*(:|\?|\+|!)?=[[:space:]]*/, "", value)
                recipe_prefix = value == "" ? "\t" : substr(value, 1, 1)
                next
            }

            if (substr($0, 1, 1) == recipe_prefix) {
                recipe = substr($0, 2)
                if (command_has_force_execution_risk(recipe)) {
                    found = 1
                    exit
                }
                recipe_continues = continues_on_next_line(recipe)
                next
            }

            if ($0 ~ /^[^[:space:]#]/) {
                rule = $0
                colon_index = index(rule, ":")
                if (colon_index == 0) {
                    next
                }
                rule_suffix = substr(rule, colon_index + 1)
                if (rule_suffix ~ /^[[:space:]]*(:|\?|\+|!)?=/ || index(rule_suffix, ";") == 0) {
                    next
                }
                sub(/^[^;]*;/, "", rule_suffix)
                if (command_has_force_execution_risk(rule_suffix)) {
                    found = 1
                    exit
                }
                recipe_continues = continues_on_next_line(rule_suffix)
            }
        }

        END { exit(found ? 0 : 1) }
    ' "$makefile"
}

[ -f "$makefile" ] || fail 'missing Makefile'

awk '
    /^[[:space:]]*\.PHONY[[:space:]]*:/ {
        for (field = 1; field <= NF; field++) {
            if ($field == "release") found = 1
        }
    }
    END { exit(found ? 0 : 1) }
' "$makefile" || fail 'release must be a .PHONY Make target'

if makefile_has_force_execution_risk; then
    fail 'Makefile must not force execution during make -n'
fi

release_recipe=$(cd "$repo_root" && make -n release) || fail 'make -n release failed'
release_recipe=$(printf '%s\n' "$release_recipe" | sed '/^[[:space:]]*$/d')
case "$release_recipe" in
    ./scripts/release/release.sh|scripts/release/release.sh) ;;
    *) fail 'make release must invoke only scripts/release/release.sh' ;;
esac

verify_recipe=$(cd "$repo_root" && make -n verify) || fail 'make -n verify failed'
release_tests_recipe=$(cd "$repo_root" && make -n release-tests) || fail 'make -n release-tests failed'
for release_test in \
    release-support-tests.sh \
    release-preflight-tests.sh \
    release-workflow-tests.sh \
    release-interface-tests.sh; do
    test_command="./scripts/release/tests/$release_test"
    printf '%s\n' "$verify_recipe" | grep -F -- "$test_command" >/dev/null ||
        fail "make verify must invoke $release_test"
    printf '%s\n' "$release_tests_recipe" | grep -F -x -- "$test_command" >/dev/null ||
        fail "make release-tests must invoke $release_test"
done
publish_tests_command='./scripts/release/tests/publish-beta-tests.sh'
printf '%s\n' "$verify_recipe" | grep -F -- "$publish_tests_command" >/dev/null ||
    fail 'make verify must invoke the offline publication foundation tests'
printf '%s\n' "$release_tests_recipe" | grep -F -x -- "$publish_tests_command" >/dev/null ||
    fail 'make release-tests must invoke the offline publication foundation tests'
publish_tests_recipe=$(cd "$repo_root" && make -n publish-beta-tests) || fail 'make -n publish-beta-tests failed'
[ "$(printf '%s\n' "$publish_tests_recipe" | sed '/^[[:space:]]*$/d')" = "$publish_tests_command" ] ||
    fail 'make publish-beta-tests must invoke only the offline publication foundation tests'
publish_check_command='./scripts/release/publish-beta-check.sh'
publish_check_recipe=$(cd "$repo_root" && make -n publish-beta-check) || fail 'make -n publish-beta-check failed'
[ "$(printf '%s\n' "$publish_check_recipe" | sed '/^[[:space:]]*$/d')" = "$publish_check_command" ] ||
    fail 'make publish-beta-check must invoke only the read-only preflight wrapper'
publish_command='./scripts/release/publish-beta.sh'
publish_recipe=$(cd "$repo_root" && make -n publish-beta) || fail 'make -n publish-beta failed'
[ "$(printf '%s\n' "$publish_recipe" | sed '/^[[:space:]]*$/d')" = "$publish_command" ] ||
    fail 'make publish-beta must invoke only the public orchestration wrapper'
if printf '%s\n' "$verify_recipe" "$release_tests_recipe" "$publish_tests_recipe" | grep -F -- "$publish_command" >/dev/null; then
    fail 'offline verification targets must not invoke live publication'
fi
if grep -E -- '(^|[;&|[:space:]])(git[[:space:]]+push|git[[:space:]]+tag[[:space:]]+(-a|-s|-m)|gh[[:space:]]+release[[:space:]]+(create|upload|delete))([[:space:]]|$)' \
    "$repo_root/scripts/release/publish-beta-check.sh" "$repo_root/scripts/release/publish_beta/preflight.py" >/dev/null; then
    fail 'publish-beta-check must not contain publication mutation commands'
fi
if grep -E -- 'gh[[:space:]]+release[[:space:]]+publish|generate_appcast|sign_update|gh-pages|git[[:space:]]+push[[:space:]]+(-f|--force|--all|--tags|--mirror)' \
    "$repo_root/scripts/release/publish_beta/mutation.py" >/dev/null; then
    fail 'draft mutation core must not publish, sign, update Pages, or force-push'
fi
if grep -E -- 'git[[:space:]]+push|gh[[:space:]]+release|gh-pages.*push' \
    "$repo_root/scripts/release/publish_beta/pages.py" "$repo_root/scripts/release/publish_beta/staging.py" >/dev/null; then
    fail 'Step 7E Pages staging must not push or mutate GitHub Releases'
fi
if printf '%s\n' "$verify_recipe" | grep -F -- './scripts/release/release.sh' >/dev/null; then
    fail 'make verify must not perform a release'
fi

(cd "$repo_root" && git check-ignore -q --no-index -- dist/LinkGate-test.dmg) ||
    fail 'dist/ output must be ignored'

# Publication is a separate, explicit action; the release command must not do it.
if grep -E -- '(^|[;&|[:space:]])(git[[:space:]]+(tag|push)|gh[[:space:]]+release)([[:space:]]|$)' \
    "$repo_root/scripts/release/release.sh" >/dev/null; then
    fail 'release.sh must not tag, push, or publish a GitHub release'
fi

printf 'PASS: deterministic release public-interface tests\n'
