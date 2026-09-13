#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)
python="$repo_root/.venv/publish/bin/python"

if [ ! -x "$python" ]; then
    printf 'publish-beta-tests: missing %s; run ./scripts/release/setup-publish-env.sh first\n' "$python" >&2
    exit 1
fi

exec "$python" -m unittest discover \
    -s "$repo_root/scripts/release/tests" \
    -p 'test_*.py' \
    -v
