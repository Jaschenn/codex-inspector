# CodexInspector.app (菜单栏版)

用 SwiftUI `MenuBarExtra` 写的原生菜单栏 App,顶部菜单栏图标实时显示当前机器上正在运行的
`codex` 进程数,点击展开可以看每个进程的 cwd / trust / 配置层 / AGENTS.md / Skills / MCP /
警告——内容和 `python3 -m codex_inspector` 命令行版完全一致,因为它就是每隔 3 秒在后台跑一次
`python3 -m codex_inspector --json`,解析 JSON 渲染出来的,没有重新实现探测逻辑。

## 目录结构

- `Package.swift` / `Sources/CodexInspector/` — SwiftUI 源码
- `Info.plist` — App 的 bundle 描述(`LSUIElement=true`,不占 Dock)
- `build_app.sh` — 一键打包脚本,产出 `dist/CodexInspector.app`

## 打包

```bash
cd macapp
./build_app.sh
```

打包脚本会做三件事:
1. `swift build -c release` 编译菜单栏 UI
2. 拷贝一份独立、可重定位的 Python 3.13 运行时(默认用本机 uv 装的那份,约 50MB)进
   `Contents/Resources/python/`
3. 拷贝 `../.venv` 里已经装好的 `psutil`/`rich` 和 `../codex_inspector` 源码进
   `Contents/Resources/pylib/`

打完包的 `.app` 是自包含的,不依赖用户机器上是否装了 Python——但因为直接拷贝了当前架构
(arm64)编译好的 Python 运行时和 C 扩展,只能在同架构的 Mac 上用。换架构/换机器分发,需要
用 `CODEX_INSPECTOR_PYTHON_RUNTIME` 指定一份对应架构的 python-build-standalone 运行时,
脚本会在没有可复用 `.venv` 时自动 `pip install psutil rich` 兜底。

## 运行

```bash
open dist/CodexInspector.app
```

或者直接在 Finder 里双击。首次运行大概率会被 Gatekeeper 拦一下(提示"无法验证开发者",
因为没有做 Apple 开发者签名),右键点击 App -> 打开,确认一次就行,以后正常双击即可。

**如果菜单栏没看到图标**:这是本机新装的、未签名的菜单栏 App,macOS 有时会把它归到
"隐藏"分组里。打开 系统设置 -> 控制中心 -> 菜单栏(拉到最下面找 "CodexInspector" 或类似
条目),把它设成"始终显示"。

## 已知限制

- 和 CLI 版一样,靠轮询发现新进程(默认 3 秒一次),不是真正的系统级进程事件订阅。
- 没有做 Apple 开发者签名/公证,只能在本机或信任来源的情况下运行。
- 目前把 `merged_config`(合并后的完整配置)原样拿到了,但菜单栏 UI 没有单独展示这一大坨
  JSON(CLI 版本也没有单独展示,只用它算了"配置层生效数"这类统计);如果你需要在 App 里
  看完整合并配置,在 `DetailView.swift` 里加一个区块,把 `proc["merged_config"]` pretty-print
  出来即可。
