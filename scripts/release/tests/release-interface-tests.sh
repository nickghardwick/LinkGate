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
