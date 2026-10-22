#!/bin/bash
# Bump the checked-in cask to a published GitHub release and refresh both
# architecture checksums from the release's .sha256 assets.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 VERSION   (for example: $0 0.3.0)" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_PATH="$ROOT_DIR/Casks/codex-inspector.rb"
VERSION="${1#v}"
BASE_URL="https://github.com/Jaschenn/codex-inspector/releases/download/v${VERSION}"

if [[ ! -f "$CASK_PATH" ]]; then
  echo "cask not found: $CASK_PATH" >&2
  exit 1
fi

fetch_sha() {
  local asset="$1"
  local checksum
  checksum="$(curl -fsSL --retry 3 "$BASE_URL/${asset}.sha256" | awk 'NR == 1 { print $1 }')"
  if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "invalid checksum for $asset: $checksum" >&2
    exit 1
  fi
  printf '%s' "$checksum"
}

ARM_SHA="$(fetch_sha CodexInspector-macos-arm64.zip)"
INTEL_SHA="$(fetch_sha CodexInspector-macos-x86_64.zip)"

bash "$ROOT_DIR/scripts/render_homebrew_cask.sh" \
  "$VERSION" "$ARM_SHA" "$INTEL_SHA" "$CASK_PATH"

echo "Updated $CASK_PATH to ${VERSION}"
echo "Next: copy it to homebrew-tap/Casks/ and push that repository."
