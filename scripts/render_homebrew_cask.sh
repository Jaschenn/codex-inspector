#!/bin/bash
# Render the tap cask for one release. Kept separate from the network-facing
# update script so CI can use the checksums produced by the release build.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 VERSION ARM_SHA INTEL_SHA OUTPUT_PATH" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CASK="$ROOT_DIR/Casks/codex-inspector.rb"
VERSION="${1#v}"
ARM_SHA="$2"
INTEL_SHA="$3"
OUTPUT_PATH="$4"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid version: $VERSION" >&2
  exit 1
fi

for checksum in "$ARM_SHA" "$INTEL_SHA"; do
  if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "invalid checksum: $checksum" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
TMP_PATH="$(mktemp "${TMPDIR:-/tmp}/codex-inspector-cask.XXXXXX")"
trap 'rm -f "$TMP_PATH"' EXIT

sed -E \
  -e "s/version \"[0-9.]+\"/version \"${VERSION}\"/" \
  -e "s/(sha256 arm: +)\"[0-9a-f]{64}\"/\\1\"${ARM_SHA}\"/" \
  -e "s/(intel: +)\"[0-9a-f]{64}\"/\\1\"${INTEL_SHA}\"/" \
  "$SOURCE_CASK" > "$TMP_PATH"

# Fail loudly if the cask layout changes and a substitution stops matching.
grep -q "version \"${VERSION}\"" "$TMP_PATH"
grep -q "$ARM_SHA" "$TMP_PATH"
grep -q "$INTEL_SHA" "$TMP_PATH"

mv "$TMP_PATH" "$OUTPUT_PATH"
trap - EXIT
