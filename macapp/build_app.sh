#!/bin/bash
# Build the native SwiftUI app and Rust engine. No Python, virtualenv or runtime downloads.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
APP_NAME=CodexInspector
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
STAGING="$ROOT_DIR/dist/.${APP_NAME}-staging-$$.app"
ARCH="${CODEX_INSPECTOR_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64) RUST_TARGET=aarch64-apple-darwin ;;
  x86_64) RUST_TARGET=x86_64-apple-darwin ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
trap 'rm -rf "$STAGING"' EXIT

if ! xcrun --find swift >/dev/null 2>&1 && [ -x /Library/Developer/CommandLineTools/usr/bin/swift ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
export MACOSX_DEPLOYMENT_TARGET=13.0
# Force system SQLite; never accidentally ship a dependency on a local Homebrew dylib.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
export SQLITE3_LIB_DIR="$SDK_PATH/usr/lib"
export SQLITE3_INCLUDE_DIR="$SDK_PATH/usr/include"
export SQLITE3_STATIC=0
export SQLITE3_NO_PKG_CONFIG=1
export LIBSQLITE3_SYS_USE_PKG_CONFIG=0

echo "==> Build Rust engine ($ARCH)"
cargo build --release --locked --manifest-path "$PROJECT_ROOT/rust-core/Cargo.toml" --target "$RUST_TARGET"
CARGO_OUTPUT="${CARGO_TARGET_DIR:-$PROJECT_ROOT/rust-core/target}"
if [[ "$CARGO_OUTPUT" != /* ]]; then CARGO_OUTPUT="$PROJECT_ROOT/$CARGO_OUTPUT"; fi
RUST_BINARY="$CARGO_OUTPUT/$RUST_TARGET/release/codex-inspector-core"

echo "==> Build native SwiftUI interface ($ARCH)"
swift build -c release --arch "$ARCH" --package-path "$ROOT_DIR" --only-use-versions-from-resolved-file \
  -Xswiftc -Osize -Xlinker -dead_strip
SWIFT_OUTPUT="$(swift build -c release --arch "$ARCH" --package-path "$ROOT_DIR" --show-bin-path)"

echo "==> Assemble app"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources/licenses"
cp "$SWIFT_OUTPUT/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "$RUST_BINARY" "$STAGING/Contents/MacOS/codex-inspector-core"
# SwiftPM retains a large local symbol table even in release mode. Strip only staged
# executables before signing; keep development outputs and their diagnostics intact.
xcrun strip -S -x "$STAGING/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$STAGING/Contents/Info.plist"
echo "==> Render application icon"
ICONSET="$STAGING/Contents/Resources/AppIcon.iconset"
xcrun swift "$ROOT_DIR/tools/GenerateIcon.swift" "$ICONSET"
xcrun iconutil -c icns "$ICONSET" -o "$STAGING/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
if [ -n "${CODEX_INSPECTOR_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CODEX_INSPECTOR_VERSION" "$STAGING/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CODEX_INSPECTOR_VERSION" "$STAGING/Contents/Info.plist"
fi
cp "$PROJECT_ROOT/LICENSE" "$STAGING/Contents/Resources/licenses/CodexInspector-LICENSE"
cp "$PROJECT_ROOT/rust-core/THIRD_PARTY_NOTICES.md" "$STAGING/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
# Generate complete notices from the exact locked dependencies using cargo-about (build-time only).
# Local builds may use the checked-in notices; release CI requires the full generated license document.
if command -v cargo-about >/dev/null 2>&1; then
  cargo about generate --manifest-path "$PROJECT_ROOT/rust-core/Cargo.toml" \
    --locked --target "$RUST_TARGET" \
    "$PROJECT_ROOT/rust-core/about.hbs" --output-file "$STAGING/Contents/Resources/licenses/Rust-dependencies.html"
elif [ "${CI:-}" = true ]; then
  echo "CI requires cargo-about to generate dependency licenses" >&2; exit 1
fi
for dependency in "$ROOT_DIR"/.build/checkouts/*; do
  [ -d "$dependency" ] || continue
  for license_file in LICENSE LICENSE.txt COPYING; do
    if [ -f "$dependency/$license_file" ]; then
      cp "$dependency/$license_file" "$STAGING/Contents/Resources/licenses/$(basename "$dependency")-$license_file"
    fi
  done
done

# The only non-system executables are our two binaries. Signing errors must fail packaging.
SIGN_IDENTITY="${CODEX_INSPECTOR_SIGN_IDENTITY:--}"
for binary in "$STAGING/Contents/MacOS"/*; do
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$binary"
done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGING"
codesign --verify --deep --strict "$STAGING"
# Only replace the prior deliverable after the new bundle is complete.
rm -rf "$APP_BUNDLE"
mv "$STAGING" "$APP_BUNDLE"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-macos-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
CLI_ARCHIVE="$ROOT_DIR/dist/codex-inspector-core-macos-$ARCH.tar.gz"
tar -czf "$CLI_ARCHIVE" -C "$APP_BUNDLE/Contents/MacOS" codex-inspector-core \
  -C "$APP_BUNDLE/Contents/Resources" licenses
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$CLI_ARCHIVE")" > "$(basename "$CLI_ARCHIVE").sha256")
echo "App: $APP_BUNDLE"
echo "ZIP: $ZIP_PATH"
du -sh "$APP_BUNDLE" "$ZIP_PATH"
