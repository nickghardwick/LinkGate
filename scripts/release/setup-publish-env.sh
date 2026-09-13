#!/bin/bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
venv="$repo_root/.venv/publish"

python3 -m venv "$venv"
"$venv/bin/python" -m pip install --requirement "$repo_root/requirements-publish.txt"
"$venv/bin/python" -c 'import importlib.metadata; print("publish environment ready: markdown-it-py " + importlib.metadata.version("markdown-it-py"))'
