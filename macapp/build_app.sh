#!/bin/bash
# 把 SwiftUI 菜单栏源码 + codex_inspector Python 核心 打包成一个自包含、可双击运行的
# CodexInspector.app,不依赖用户机器上装没装 Python / psutil。
#
# 用法:
#   ./build_app.sh
#
# 可选环境变量:
#   CODEX_INSPECTOR_PYTHON_RUNTIME  指向一份 python-build-standalone 风格的、
#                                   可重定位的 CPython 3.13 安装目录(即 bin/python3.13
#                                   通过 @executable_path 相对路径找库,不依赖固定绝对路径)。
#                                   不指定的话,自动用 `uv` 定位/安装一份(本机和 CI 都适用)。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
APP_NAME="CodexInspector"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
VENV_SITE_PACKAGES="$PROJECT_ROOT/.venv/lib/python3.13/site-packages"

if [ -z "${CODEX_INSPECTOR_PYTHON_RUNTIME:-}" ] && command -v uv >/dev/null 2>&1; then
  echo "==> 0/6 未指定 CODEX_INSPECTOR_PYTHON_RUNTIME,用 uv 定位/安装可重定位的 CPython 3.13"
  uv python install 3.13 >/dev/null 2>&1 || true
  UV_PY_BIN="$(uv python find 3.13 2>/dev/null || true)"
  if [ -n "$UV_PY_BIN" ]; then
    UV_PY_BIN="$(realpath "$UV_PY_BIN")"
    CODEX_INSPECTOR_PYTHON_RUNTIME="$(cd "$(dirname "$UV_PY_BIN")/.." && pwd)"
  fi
fi
PYTHON_RUNTIME_SRC="${CODEX_INSPECTOR_PYTHON_RUNTIME:-$HOME/.local/share/uv/python/cpython-3.13.5-macos-aarch64-none}"

echo "==> 1/6 编译 Swift 可执行文件 (release)"
# 优先用 Command Line Tools 自带的 swift 工具链构建,不依赖系统级 `xcode-select` 指向哪里
# (完整 Xcode.app 首次使用需要 `sudo xcodebuild -license` 同意许可协议,这里绕开它)。
if [ -x /Library/Developer/CommandLineTools/usr/bin/swift ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --package-path "$ROOT_DIR"

echo "==> 2/6 组装 .app bundle 骨架"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> 3/6 拷贝独立 Python 运行时 (可重定位,约 50MB): $PYTHON_RUNTIME_SRC"
if [ ! -d "$PYTHON_RUNTIME_SRC" ]; then
  echo "错误: 找不到 Python 运行时目录: $PYTHON_RUNTIME_SRC"
  echo "请通过 CODEX_INSPECTOR_PYTHON_RUNTIME 指定一份 python-build-standalone 安装目录"
  exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Resources/python"
cp -R "$PYTHON_RUNTIME_SRC"/. "$APP_BUNDLE/Contents/Resources/python/"

echo "==> 4/6 安装 Python 依赖 (psutil / rich)"
mkdir -p "$APP_BUNDLE/Contents/Resources/pylib"
if [ -d "$VENV_SITE_PACKAGES" ]; then
  echo "    复用现有 .venv 的依赖 (免联网,ABI 已确认匹配)"
  cp -R "$VENV_SITE_PACKAGES"/. "$APP_BUNDLE/Contents/Resources/pylib/"
else
  echo "    .venv 不存在,通过 pip 联网安装"
  "$APP_BUNDLE/Contents/Resources/python/bin/python3.13" -m pip install --quiet psutil rich \
    --target "$APP_BUNDLE/Contents/Resources/pylib"
fi

echo "==> 5/6 拷贝 codex_inspector 核心逻辑源码"
rm -rf "$APP_BUNDLE/Contents/Resources/pylib/codex_inspector"
cp -R "$PROJECT_ROOT/codex_inspector" "$APP_BUNDLE/Contents/Resources/pylib/"
find "$APP_BUNDLE/Contents/Resources/pylib" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

echo "==> 6/6 给 App 内所有二进制签名"
# 只有最外层可执行文件会被 swift build 的链接器顺手打上 ad-hoc 签名,内嵌的整份 Python
# 运行时(几十个 .dylib/.so/可执行文件)完全没有签名。这份 App 一旦经过"从网上下载"
# (被打上 com.apple.quarantine 标记)会触发比本地直接运行严格得多的完整性校验,
# 校验会发现"外层签名说 Resources 应该有完整性封印,但实际没有"——直接被判定为
# "已损坏,应该移到废纸篓",而不是常见的"未验证开发者"提示。
# 解法是自底向上把每一个二进制都签一遍,最后再签一次整个 .app 封印 Resources。
# 没有付费 Apple Developer 证书时用 ad-hoc("-"),能解决"已损坏"这个硬性错误;
# 但 Gatekeeper 仍会提示"未验证开发者"(所有非 Apple 分发的 App 都这样,除非做
# 付费开发者账号 + notarization),用户右键"打开"确认一次即可,这是正常现象。
SIGN_IDENTITY="${CODEX_INSPECTOR_SIGN_IDENTITY:--}"
while IFS= read -r -d '' f; do
  file "$f" | grep -q "Mach-O" && codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$f" 2>&1 | grep -v "^$f: replacing existing signature" || true
done < <(find "$APP_BUNDLE" -type f \( -perm -u+x -o -name "*.dylib" -o -name "*.so" \) -print0)
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_BUNDLE"

echo "    校验签名..."
codesign --verify --deep --strict "$APP_BUNDLE"

echo ""
echo "完成: $APP_BUNDLE"
echo "双击运行,或: open '$APP_BUNDLE'"
echo "首次运行如被 Gatekeeper 拦截(提示"未验证开发者"),右键点击 App -> 打开 即可。"
