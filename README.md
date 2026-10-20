# Codex Inspector

[![CI](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml)
[![Release](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml)

macOS 原生检查工具：按进程、聊天和轮次查看 Codex 的配置、AGENTS.md、Skills、MCP、Token 用量与耗时分布。
支持左右布局的窗口、菜单栏快捷入口、语法高亮文件编辑和 Markdown 消息预览。

应用由 **SwiftUI 界面 + Rust 检查引擎**组成，分发包不包含 Python、虚拟环境或浏览器运行时。
原 Python 实现暂留在仓库作为迁移参考，不参与应用构建，也不再生成 Python release 包。

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
- `rust-core/src/tokens.rs`：内嵌 `o200k_base` 分词表，完全离线的 Skill Token 估算。
- `macapp/`：原生 SwiftUI 窗口、编辑器、Markdown 和打包脚本。

默认每 3 秒生成 JSON 快照。多个目录存在状态数据库时，按数据库内最新聊天更新时间选择（包含 WAL 中的更新），避免同版本的旧数据库覆盖当前记录。日志索引缓存保存到 `~/Library/Caches/CodexInspector/rust-*.json`，
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

进程发现依赖 macOS `ps`/`lsof` 和权限；无法读取时明确提示。
`ps` 的命令行引号/截断可能影响 CLI 覆盖解析，环境变量读取失败会退回标注为不完整的 `ps eww`。
历史轮次目录用于检查当前文件，不还原旧版本。敏感字段、任意命名的 HTTP header 与 env 值均会遮蔽。
