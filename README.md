# Codex Inspector

[![CI](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml)
[![Release](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml)

macOS 原生检查工具：按进程、聊天和轮次查看 Codex 的配置、AGENTS.md、Skills、MCP、Token 用量与耗时分布。
左侧选择聊天或进程，右侧顶部切换检查类型；菜单栏展示当前对话的累计 Token、缓存命中率和本轮耗时摘要；支持语法高亮文件编辑和 Markdown 消息预览。
当前 arm64 应用约 4.8 MiB，ZIP 约 2.6 MiB，保留完全离线的 Skill 分词估算。

应用由 **SwiftUI 界面 + Rust 检查引擎**组成，分发包不包含 Python、虚拟环境或浏览器运行时。
原 Python 实现暂留在仓库作为迁移参考，不参与应用构建，也不再生成 Python release 包。

## 本次性能测量

2026-10-21 在 Apple M4（10 核、16 GiB 内存，macOS 27.0.1）测量。
基线为 `85a7cff` 的原生版本，候选为本次交付的签名应用；证据文件保存两端 UI / Rust 二进制的 SHA-256。
这是一台机器的一次受控检查测量和两段内存采样，不代表所有电脑的性能。
输入来自本机私有日志，原文不随证据提交；其他机器可以按同一方法复测自己的工作负载。

| 指标 | 优化前 | 本次版本 | 口径 |
| --- | ---: | ---: | --- |
| 缓存预热后单次检查，中位数 | 140.26 ms | 6.74 ms | 各 50 次；新引擎首次请求不计入此行 |
| 缓存预热后单次检查，P95 | 144.05 ms | 7.37 ms | 原始逐次样本计算，nearest-rank P95 |
| 每次检查平均子进程 CPU 时间 | 91.83 ms | 6.81 ms | 用户态 + 内核态；新版包含首次启动，按 51 次摊销 |
| 新进程首次完整快照，中位数 | 141.57 ms | 17.05 ms | 各启动 10 个新进程，磁盘/系统文件缓存已预热 |
| 主窗口 UI 进程 RSS，中位数 | 145.71 MiB | 181.36 MiB | 启动后等待 20 秒，再采样 40 次；间隔设置 0.25 秒 |
| 主窗口 UI 进程 RSS，采样范围 | 145.61–147.03 MiB | 161.17–187.36 MiB | 本次采样窗口的最小/最大值，非峰值 |
| 常驻 Rust 引擎 RSS，中位数 | 临时进程，无同口径稳态值 | 12.59 MiB | 新版 40 次均观测到引擎；范围 12.33–12.61 MiB |
| 应用文件总字节 | 4,763,255（4.54 MiB） | 5,045,362（4.81 MiB） | 递归相加文件逻辑字节，包含签名/图标/许可证 |
| ZIP 文件字节 | 2,540,489（2.42 MiB） | 2,757,124（2.63 MiB） | 同样使用 `ditto -c -k --sequesterRsrc --keepParent` |
| 自动检查策略（代码设置） | 每 3 秒全量调用 CLI | 文件事件触发 + 每秒兜底 | 这是配置，不是实测的日志写入到绘制延迟 |

本次固定快照的检查中位数下降约 **95.2%**，每次检查的子进程 CPU 时间下降约 **92.6%**。
前期小样本的“约 9 ms / 100–130 ms”是即时观察，上表采用保存了逐次样本的正式测量。
优化前每次启动并退出 CLI；新版复用引擎，并额外生成菜单统计。
两端均检查 2 个进程、57 条聊天目录和同一聊天的 28 个轮次；所有计时请求的选中聊天详情 SHA-256 一致，
脚本遇到聊天在测量期间变化会报错。引擎计时包含启动/管道传输，排除 Python JSON 解析、SwiftUI 更新与绘制。
CPU 指标不包含 UI 进程，不能直接当作整个应用或整台机器的 CPU 占用率。

内存与包体积没有下降。常驻引擎用缓存换取更快的检查，图标及新功能也增加了约 0.27 MiB 应用文件。
内存采样时两端都只打开同一聊天的主窗口概览，未打开编辑器或统计窗口；聊天日志在两段采样之间持续增长，
因此这两段 RSS 是实际场景记录，不是固定日志内容的内存 A/B，也不能用来证明某项改动导致了特定增幅。
RSS 包含驻留共享页，不等于堆大小或物理占用，两个进程的 RSS 不应相加当作独占物理内存。
读取更多大日志、打开更多页面或初始化未缓存 Skill 的分词器，均可能改变内存占用。
上述启动指标仅是引擎到第一份 JSON 快照；应用首帧启动、全空缓存启动、峰值物理内存和事件端到端延迟尚未测量。

原始证据与方法：

- [引擎耗时、CPU、逐次样本与二进制指纹](docs/performance/2026-10-21-arm64-engine.json)
- [优化前内存采样](docs/performance/2026-10-21-arm64-memory-baseline.json) / [本次版本内存采样](docs/performance/2026-10-21-arm64-memory-candidate.json)
- [ZIP 字节与 SHA-256](docs/performance/2026-10-21-arm64-package.json)
- [测量脚本](scripts/benchmark.py)；[刷新策略](macapp/Sources/CodexInspector/ReportFetcher.swift) / [文件事件监听](macapp/Sources/CodexInspector/InspectionMonitor.swift)

复测时先从基线提交构建并保留旧 `.app`，然后构建候选版本。选择一条日志暂时不再变化的本地聊天；
不指定 `--session-id` 时使用最新聊天。以下脚本仅用于开发测量，不随应用分发，没有第三方 Python 依赖：

```bash
macapp/build_app.sh
uv run python scripts/benchmark.py \
  --baseline-app /path/to/baseline/CodexInspector.app \
  --baseline-revision 85a7cffb393384f52ad14d8368eb4e3417c88873 \
  --candidate-app macapp/dist/CodexInspector.app \
  --iterations 50 --startup-samples 10 --output /tmp/inspector-engine.json

# 分别启动两端应用，每次只保留一个 Inspector 进程、同一主窗口概览；采样期间不操作界面。
uv run python scripts/benchmark.py --live-memory \
  --candidate-app /path/to/running/CodexInspector.app \
  --memory-state 'Fresh launch; only main overview; no editor/statistics window' \
  --settle-seconds 20 --memory-samples 40 --interval 0.25 \
  --output /tmp/inspector-memory.json

# ZIP 使用相同打包参数；文件大小看逻辑字节，不使用 du 的分配块大小。
ditto -c -k --sequesterRsrc --keepParent /path/to/baseline/CodexInspector.app /tmp/baseline.zip
stat -f '%z' /tmp/baseline.zip macapp/dist/CodexInspector-macos-arm64.zip
shasum -a 256 /tmp/baseline.zip macapp/dist/CodexInspector-macos-arm64.zip
```

## 安装与构建

在 [Releases](https://github.com/Jaschenn/codex-inspector/releases) 下载对应架构的 ZIP：
Apple Silicon 使用 `arm64`，Intel 使用 `x86_64`。需要 macOS 13 或更高版本。

本地构建需要 Xcode 或兼容的 Command Line Tools、Rust stable 与 Cargo：

```bash
# 一键构建、签名并压缩原生应用，无需 uv/Python/pnpm
macapp/build_app.sh
open macapp/dist/CodexInspector.app

# 独立命令行引擎
cargo build --release --locked --manifest-path rust-core/Cargo.toml
rust-core/target/release/codex-inspector-core --json --sessions
rust-core/target/release/codex-inspector-core --json --pid 12345
# 使用列表中 id 字段选择聊天；不指定 turn-id 时检查最新轮次
rust-core/target/release/codex-inspector-core --json --sessions \
  --session-id '/Users/example/.codex::THREAD_UUID' --turn-id TURN_UUID
# TOML 编辑校验：读取标准输入，语法错误输出到 stderr 并返回非零退出码
rust-core/target/release/codex-inspector-core --validate-toml < config.toml
```

详细界面与统计说明见 [macapp/README.md](macapp/README.md)。

## 结构

- `rust-core/src/process.rs`：进程发现、cwd、原生 sysctl 环境变量探测及 CLI 覆盖。
- `rust-core/src/config.rs`：TOML 递归合并、信任状态、AGENTS/Skills/MCP 扫描和敏感信息遮蔽。
- `rust-core/src/sessions.rs`：只读 SQLite 聊天目录与增量 JSONL 轮次索引。
- `rust-core/src/statistics.rs`：响应去重、Token 累计差值与互斥耗时区间。
- `rust-core/src/tokens.rs`：无损压缩内嵌 `o200k_base` 分词表，完全离线的 Skill Token 估算。
- `macapp/`：原生 SwiftUI 窗口、编辑器、Markdown 和打包脚本。

Rust 引擎通过应用私有管道常驻，复用配置与增量日志索引。日志/SQLite WAL 变更触发刷新，连续写入合并到最多约每 300 毫秒一次；每秒兜底检查进程和文件状态。macOS 原生接口读取进程列表、参数和工作目录，权限受限时回退 `ps` / `lsof`。多个目录存在状态数据库时，按数据库内最新聊天更新时间选择（包含 WAL 中的更新），避免同版本的旧数据库覆盖当前记录。日志索引缓存保存到 `~/Library/Caches/CodexInspector/rust-*.json`，
Skill 分词缓存仅保存文本 SHA-256 和数量，命中时无需重新初始化分词器。缓存文件以 0600 权限创建。
Rust 缓存与旧 Python 缓存使用不同文件名，首次打开聊天会重建索引。
支持 `.jsonl` 和 `.jsonl.zst`；数据库仍指向旧 `.jsonl` 路径时自动查找同名压缩文件。压缩日志流式解压读取，未变化时复用索引；不写回或解压到 Codex 目录。
不修改 Codex 数据库、日志或配置；文件编辑仅在明确保存后写入。

## CI 与发布

- 推送 `main`、打开 PR 或手动运行 CI：检查 Rust 格式与 Clippy，构建两个架构的应用并上传 artifacts。
- 推送 `v*.*.*` 标签：分别打包 Apple Silicon/Intel ZIP、Rust CLI 和 SHA-256 文件，成功后创建 GitHub Release。
- 手动运行 Release：仅生成 artifacts，不创建正式 Release。
- Cargo.lock 和 Package.resolved 锁定依赖；CI 生成并随包附带 Rust 与 Swift 依赖许可证。

```bash
cargo fmt --manifest-path rust-core/Cargo.toml --check
cargo clippy --manifest-path rust-core/Cargo.toml --locked -- -D warnings
```

按本次要求，迁移交付不运行测试套件；工作流目前执行静态检查、编译与打包，未添加自动测试步骤。
使用 ad-hoc 签名，尚未配置 Developer ID 或 Apple 公证。首次打开可能需要在系统设置的隐私与安全性中允许打开。

## 数据含义与限制

配置结果是根据当前磁盘文件和日志工作目录重建的推断，无法覆盖 Codex 内置默认值、
`requirements.toml` 的所有约束或历史配置快照。项目配置仅在全局记录为 trusted 时合并。
默认 AGENTS 文件名优先 `AGENTS.override.md`，其次 `AGENTS.md`，暂不处理自定义 fallback 文件名。
Skills 扫描当前目录到 Git 根的 `.agents/skills`、`.codex/skills` 和 `$CODEX_HOME/skills`；
同名条目保留，不向下扫描项目。MCP 列表反映配置声明，探测器不主动连接服务器。

Skill Token 使用固定 `o200k_base` 编码，统计 **SKILL.md 全文（含 frontmatter）**，
不包含引用资源、消息包装或工具定义，也不证明该 Skill 已进入模型请求。
分词器初始化失败时明确标为字符粗估，文件读取失败则为不可用。

每轮 Token 优先使用日志 turn 统计，其次响应统计或可靠基线的旧累计差值。
缺少字段不当作零，独立子线程用量不归入父轮次。耗时重叠区间只计一次；
未分类时间可能包含模型内部思考、网络延迟、服务器排队、调度等待和日志缺口，不能精确拆分。
普通 JSONL 的消息/指令记录不等于每次 LLM 请求的完整 payload。

进程发现使用 macOS libproc/sysctl 和系统权限，受限时回退 `ps`/`lsof`；无法读取时明确提示。
`ps` 的命令行引号/截断可能影响 CLI 覆盖解析，环境变量读取失败会退回标注为不完整的 `ps eww`。
历史轮次目录用于检查当前文件，不还原旧版本。敏感字段、任意命名的 HTTP header 与 env 值均会遮蔽。
