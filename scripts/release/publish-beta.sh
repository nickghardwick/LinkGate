#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
python="$repo_root/.venv/publish/bin/python"

if [ ! -x "$python" ]; then
    printf 'publish-beta: missing %s; run ./scripts/release/setup-publish-env.sh first\n' "$python" >&2
    exit 2
fi

exec "$python" -c 'from scripts.release.publish_beta.orchestrator import main; raise SystemExit(main())' \
    --repo-root "$repo_root" \
    --config scripts/release/publish-config.json
