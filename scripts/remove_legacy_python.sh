#!/bin/bash
# One-time retirement of the old Python implementation and local environment.
# Run manually from any directory: bash scripts/remove_legacy_python.sh
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$REPOSITORY_ROOT/rust-core/Cargo.toml" || ! -f "$REPOSITORY_ROOT/macapp/Package.swift" ]]; then
  echo "Expected the Codex Inspector repository; refusing cleanup." >&2
  exit 1
fi

# Explicit paths prevent removing another project's environment or source tree.
rm -rf -- \
  "$REPOSITORY_ROOT/codex_inspector" \
  "$REPOSITORY_ROOT/tests" \
  "$REPOSITORY_ROOT/.venv" \
  "$REPOSITORY_ROOT/.mypy_cache" \
  "$REPOSITORY_ROOT/.pytest_cache" \
  "$REPOSITORY_ROOT/.ruff_cache"
rm -f -- \
  "$REPOSITORY_ROOT/pyproject.toml" \
  "$REPOSITORY_ROOT/requirements.txt" \
  "$REPOSITORY_ROOT/uv.lock" \
  "$REPOSITORY_ROOT/scripts/benchmark.py"

# Remove the retired section only after its formerly ignored files are gone.
# BSD sed is available on the macOS hosts supported by this repository.
sed -i '' '/^# Python$/,/^# Swift \/ SwiftPM$/{
  /^# Swift \/ SwiftPM$/!d
}' "$REPOSITORY_ROOT/.gitignore"

echo "Removed the legacy Python implementation, dependencies and local caches."
