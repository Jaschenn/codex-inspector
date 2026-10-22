# Codex Inspector

[![CI](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml)
[![Release](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml)

macOS 原生 Codex 检查工具，采用 SwiftUI + Rust，无 Python 或浏览器运行时。

0.3.0 增加本轮文件与工具活动明细，减少概览刷新及路径列表重复计算，并修复时间线状态与异常耗时边界。[性能与验证结果](docs/performance/2026-10-21-stability/RESULTS.md)。

## 功能

- 按进程、聊天和轮次查看配置、AGENTS.md、Skills 与 MCP。
- 菜单栏展示当前对话累计 Token、缓存命中率及最新轮次耗时分布。
- 配置与指令文件支持语法高亮、行号、查找替换及编辑保存。
- Markdown 消息预览、合并配置高亮、Skill 全文 Token 估算。
- 文件变更触发更新，每秒兜底检查；支持普通与 Zstandard 压缩日志。
- 独立的活动统计窗口。

## 安装

使用 Homebrew（个人 tap）：

```bash
brew tap Jaschenn/tap
brew trust Jaschenn/tap
brew install --cask codex-inspector
```

Homebrew 7 及以上要求先 `brew trust` 第三方 tap；旧版本可省略该命令。
升级使用 `brew upgrade --cask codex-inspector`。tap 的创建与发布维护见
[Homebrew 配置](docs/HOMEBREW.md)。

也可以手动下载安装：

在 [Releases](https://github.com/Jaschenn/codex-inspector/releases/latest) 下载 ZIP，解压后将 `CodexInspector.app` 放入应用程序目录。

- Apple Silicon：`arm64`；Intel：`x86_64`。
- 系统要求：macOS 13 或更高版本。
- 当前为 ad-hoc 签名，未进行 Apple 公证；首次打开如被阻止，可在系统设置 → 隐私与安全性中允许。

## 本地构建

需要 Xcode、Rust stable 与 Cargo。

```bash
macapp/build_app.sh
open macapp/dist/CodexInspector.app
```

独立 Rust CLI：

```bash
cargo build --release --locked --manifest-path rust-core/Cargo.toml
rust-core/target/release/codex-inspector-core --json --sessions
```

[界面与使用说明](macapp/README.md)

## 开发验证

应用与 CLI 使用 SwiftUI + Rust，开发验证直接使用原生工具链：

```bash
cargo fmt --manifest-path rust-core/Cargo.toml --check
cargo clippy --manifest-path rust-core/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust-core/Cargo.toml --locked
swift test --package-path macapp --only-use-versions-from-resolved-file
```

性能基准通过 Swift 测试显式运行，见[编辑器](docs/performance/2026-10-21-editor/RESULTS.md)与[刷新](docs/performance/2026-10-21-config-refresh/RESULTS.md)测量说明。
进程内存使用 `xcrun swift scripts/measure_native_memory.swift OUTPUT.json UI_PID CORE_PID [SAMPLES]` 测量。

旧 Python CLI 已停止维护。运行 `bash scripts/remove_legacy_python.sh` 可移除旧引擎、测试、依赖文件、迁移期基准脚本，以及本仓库内的虚拟环境与测试缓存。
历史性能报告保留当时的工具和验证记录。

## 统计含义

配置按当前磁盘内容重建，历史轮次不还原文件旧版本。Skill Token 仅估算 `SKILL.md` 全文。
Token 与耗时来自已写入的本地日志；缺失数据保持未知，未分类时间不能直接视为思考。
普通 JSONL 不等于每次 LLM 请求的完整内容。文件编辑仅在明确保存后写入。
