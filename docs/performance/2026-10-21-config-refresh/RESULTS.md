# 配置修复与刷新开销验证（2026-10-21）

本轮修复配置优先级、CLI 覆盖和 AGENTS 指令文件发现，同时减少刷新临时对象的生命周期和重复文件监控准备。没有添加轮次对比、诊断导出或跨会话用量汇总，没有删减功能、简化列表或替换 SwiftUI。

## 配置与发现修复

- 可读取的配置层顺序：系统 < 用户 < profile < 受信任项目（根目录到 cwd）< CLI。保留低优先级层中没有被覆盖的字段。
- 项目中的供应商、认证重定向、通知及遥测等受限字段不再参与覆盖，并在诊断中提示。
- 非 Git 项目的显式信任记录也能应用。目录链规范化，避免 /tmp 与 /private/tmp、符号链接路径不一致时漏掉上层配置。
- -c 与 --config 都解析为可重复的 TOML 键值覆盖，不再将 --config 误解成配置文件路径。
- 支持等号形式、常见短参数连写、含空格值和 TOML 引号键。CLI 覆盖按顺序应用，标量与表互相替换不再崩溃；常用专用参数优先于通用覆盖，-- 后的内容不再当作选项解析。
- 原生扫描已有的参数转义保持不变，增加回归测试。Python CLI 优先读取操作系统 argv，读不到时提示显示文本解析的边界限制。
- AGENTS 每目录选择首个非空文件：AGENTS.override.md、AGENTS.md；项目目录再检查配置中的备用文件名。全局目录不使用项目备用名。
- 应用 project_doc_max_bytes 和 UTF-8 边界；在页面与诊断中提示截断。长空白前缀不会错误地让高优先级文件落到备用文件。
- 文件发现用流式扫描和有界样本，仅在报告保留路径、范围和纳入字节数。文件编辑仍可读取完整原文。
- 备用指令文件的内容更新会使配置缓存失效；进程和历史轮次检查保留发现过程产生的诊断。

这些是当前磁盘重建修复，不声称恢复了历史文件或某次完整模型请求。未读取的云端默认值和组织强制策略仍不能由该结果证明。

依据：[配置优先级](https://learn.chatgpt.com/docs/config-file/config-basic)、[CLI 覆盖与项目限制](https://learn.chatgpt.com/docs/config-file/config-advanced)、[AGENTS 发现规则](https://learn.chatgpt.com/docs/agent-configuration/agents-md)。本机 CLI 为 0.163.0。

## 刷新实现改动

- 后台队列按 work item 回收 autorelease 临时对象。
- autoreleasepool 由仅包围 JSON 请求/解码，扩大到比较和界面版本准备。
- 主线程只接收需要发布的快照；内容没有变化时不继续持有解码报告，也不重复准备文件监控。
- 文件监控候选根未变且当前根仍存在时，复用已有监控。新建目录可继续由上层根监控，根消失时重新准备。
- 保留实时更新频率、全部展示内容、编辑状态和历史数据。没有为了读数而关闭窗口、强制系统压缩或丢弃功能。

## 合成刷新基准

Release XCTest，固定 314,025 字节 JSON，5000 条记录，连续比较 40 次。基线仅在解码时使用 pool；候选每次刷新也回收比较中的临时对象。每种策略使用三个独立测试进程，交替次序，避免同一进程的分配器水位偏置。

| 测量 | 基线 | 候选 |
| --- | ---: | ---: |
| 测试进程峰值 footprint 中位数 | 85.36 MB | 10.18 MB |
| 40 次比较总耗时中位数 | 233.80 ms | 227.72 ms |

峰值降低约 88%。这是后台准备阶段的合成负载，包含测试进程基础占用；不是产品整体内存，也不能直接外推到一秒一次的实际 UI 刷新。基准每次校验两种策略仍判断同一快照相同。

原始汇总：[cold-refresh-summary.json](cold-refresh-summary.json)。

复现单个独立进程：

```sh
CODEX_INSPECTOR_REFRESH_STRATEGY=legacy \
CODEX_INSPECTOR_REFRESH_BENCHMARK=/tmp/legacy-refresh.json \
swift test -c release --package-path macapp --filter OverviewPerformanceTests.testRefreshTemporaryAllocationBenchmark

CODEX_INSPECTOR_REFRESH_STRATEGY=pooled \
CODEX_INSPECTOR_REFRESH_BENCHMARK=/tmp/pooled-refresh.json \
swift test --skip-build -c release --package-path macapp --filter OverviewPerformanceTests.testRefreshTemporaryAllocationBenchmark
```

## 主窗口实测

Apple M4、macOS 27.0.1。两份独立 Release 应用副本，分别使用不同 bundle ID，打开同一聊天的已完成第 5 轮，概览从顶部开始；核对 Token、耗时与活动内容一致。两者都曾打开最新轮次。每秒同时测量两份 UI 与各自 Rust 引擎，共 15 个样本。

| 场景 | 中位数 | 最大值 |
| --- | ---: | ---: |
| 基线 UI | 88.02 MB | 88.77 MB |
| 候选 UI | 91.70 MB | 91.90 MB |
| 基线 UI + Rust | 95.08 MB | 95.64 MB |
| 候选 UI + Rust | 97.96 MB | 98.63 MB |

**本轮没有证明常驻内存下降，也未达到 20 MB。** 不把合成基准的峰值改善宣传成 App 内存从 85 MB 降到 10 MB。

窗口焦点、启动次序、之前的加载历史不同；物理窗口尺寸没有独立测量，仅使用相同默认设置，侧栏 AX 宽度为 280。现场日志和菜单摘要持续变化，原应用也保持运行。因此这个约 3 MB 的差异不能单独证明收益或回归。后续应在固定输入、相同前台顺序和相同操作序列下重复测量。

原始样本与限制：[paired-window-memory.json](paired-window-memory.json)。

测试副本与其引擎已退出，原用户应用未被终止或替换到 /Applications。

## 验证与交付

- 33 项 Rust 测试通过，包括配置、CLI、指令预算、备用文件缓存、活动和统计回归。
- 47 项 Swift Release 测试通过，无跳过；显式启用了编辑器、概览与刷新基准。
- 42 项 Python 测试通过；Ruff lint/format、mypy 通过。
- Rust fmt/Clippy（-D warnings）、Swift 格式检查、git diff --check 通过。
- arm64 Release 包构建、ad-hoc 签名验证和 ZIP SHA-256 校验通过。
- 真实界面验证历史轮次切换、统计/活动展示及 AGENTS 页面。项目文件缺失时仍提供创建入口，日志指令与当前磁盘文件保持区分。
- 本轮没有 Node/React 项目变更，pnpm lint/format/test 不适用于该 Swift/Rust/Python 仓库。
- 没有在 Intel 或 macOS 13 实机运行，不外推该机型与系统的性能。

本地包：macapp/dist/CodexInspector.app 和 macapp/dist/CodexInspector-macos-arm64.zip。原来运行中的实例仍是旧进程，退出后重新打开才能使用新版本。

临时基准、构建和测试日志保留在 /tmp/codex-inspector-low-overhead.seSp8Z；没有把聊天内容或原始配置写入基准产物。

