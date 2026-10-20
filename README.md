# Codex Inspector

[![CI](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml)
[![Release](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml)

macOS 原生 Codex 检查工具，采用 SwiftUI + Rust，无 Python 或浏览器运行时。Apple Silicon 应用约 **4.8 MiB**，ZIP 约 **2.6 MiB**。

## 功能

- 按进程、聊天和轮次查看配置、AGENTS.md、Skills 与 MCP。
- 菜单栏展示当前对话累计 Token、缓存命中率及最新轮次耗时分布。
- 配置与指令文件支持语法高亮、行号、查找替换及编辑保存。
- Markdown 消息预览、合并配置高亮、Skill 全文 Token 估算。
- 文件变更触发更新，每秒兜底检查；支持普通与 Zstandard 压缩日志。
- 石墨灰应用图标，独立的活动统计窗口。

## 性能结果

Apple M4 / 16 GiB / macOS 27.0.1，2026-10-21 测量；对比 `85a7cff` 与 `6406f3f`，检查样本各 50 次。

| 指标 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 暖缓存检查中位数 | 140.26 ms | **6.74 ms（−95.2%）** |
| 暖缓存检查 P95 | 144.05 ms | **7.37 ms** |
| 每次检查平均引擎及子进程 CPU 时间 | 91.83 ms | **6.81 ms（−92.6%）** |
| 暖缓存引擎首次快照中位数 | 141.57 ms | **17.05 ms** |
| 主窗口 UI RSS 中位数 | 145.71 MiB | 181.36 MiB |
| 常驻引擎 RSS 中位数 | 临时进程 | 12.59 MiB |
| 应用体积 | 4.54 MiB | 4.81 MiB |
| ZIP 体积 | 2.42 MiB | 2.63 MiB |

RSS 为实际窗口采样，非固定日志的内存 A/B；首次快照不代表 App 首帧时间。CPU 不含 UI，新版包含首次启动摊销。内存与包体积未下降。

证据：[耗时与 CPU](docs/performance/2026-10-21-arm64-engine.json) · [旧版内存](docs/performance/2026-10-21-arm64-memory-baseline.json) · [新版内存](docs/performance/2026-10-21-arm64-memory-candidate.json) · [体积](docs/performance/2026-10-21-arm64-package.json) · [测量脚本](scripts/benchmark.py)

## 安装

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

## 统计含义

配置按当前磁盘内容重建，历史轮次不还原文件旧版本。Skill Token 仅估算 `SKILL.md` 全文。
Token 与耗时来自已写入的本地日志；缺失数据保持未知，未分类时间不能直接视为思考。
普通 JSONL 不等于每次 LLM 请求的完整内容。文件编辑仅在明确保存后写入。
