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
  echo "==> 0/5 未指定 CODEX_INSPECTOR_PYTHON_RUNTIME,用 uv 定位/安装可重定位的 CPython 3.13"
  uv python install 3.13 >/dev/null 2>&1 || true
  UV_PY_BIN="$(uv python find 3.13 2>/dev/null || true)"
  if [ -n "$UV_PY_BIN" ]; then
    UV_PY_BIN="$(realpath "$UV_PY_BIN")"
    CODEX_INSPECTOR_PYTHON_RUNTIME="$(cd "$(dirname "$UV_PY_BIN")/.." && pwd)"
  fi
fi
PYTHON_RUNTIME_SRC="${CODEX_INSPECTOR_PYTHON_RUNTIME:-$HOME/.local/share/uv/python/cpython-3.13.5-macos-aarch64-none}"

echo "==> 1/5 编译 Swift 可执行文件 (release)"
# 优先用 Command Line Tools 自带的 swift 工具链构建,不依赖系统级 `xcode-select` 指向哪里
# (完整 Xcode.app 首次使用需要 `sudo xcodebuild -license` 同意许可协议,这里绕开它)。
if [ -x /Library/Developer/CommandLineTools/usr/bin/swift ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --package-path "$ROOT_DIR"

echo "==> 2/5 组装 .app bundle 骨架"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> 3/5 拷贝独立 Python 运行时 (可重定位,约 50MB): $PYTHON_RUNTIME_SRC"
if [ ! -d "$PYTHON_RUNTIME_SRC" ]; then
  echo "错误: 找不到 Python 运行时目录: $PYTHON_RUNTIME_SRC"
  echo "请通过 CODEX_INSPECTOR_PYTHON_RUNTIME 指定一份 python-build-standalone 安装目录"
  exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Resources/python"
cp -R "$PYTHON_RUNTIME_SRC"/. "$APP_BUNDLE/Contents/Resources/python/"

echo "==> 4/5 安装 Python 依赖 (psutil / rich)"
mkdir -p "$APP_BUNDLE/Contents/Resources/pylib"
if [ -d "$VENV_SITE_PACKAGES" ]; then
  echo "    复用现有 .venv 的依赖 (免联网,ABI 已确认匹配)"
  cp -R "$VENV_SITE_PACKAGES"/. "$APP_BUNDLE/Contents/Resources/pylib/"
else
  echo "    .venv 不存在,通过 pip 联网安装"
  "$APP_BUNDLE/Contents/Resources/python/bin/python3.13" -m pip install --quiet psutil rich \
    --target "$APP_BUNDLE/Contents/Resources/pylib"
fi

echo "==> 5/5 拷贝 codex_inspector 核心逻辑源码"
rm -rf "$APP_BUNDLE/Contents/Resources/pylib/codex_inspector"
cp -R "$PROJECT_ROOT/codex_inspector" "$APP_BUNDLE/Contents/Resources/pylib/"
find "$APP_BUNDLE/Contents/Resources/pylib" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

echo ""
echo "完成: $APP_BUNDLE"
echo "双击运行,或: open '$APP_BUNDLE'"
echo "首次运行如被 Gatekeeper 拦截(提示"无法验证开发者"),右键点击 App -> 打开 即可。"
