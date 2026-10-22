# 内存归因审计（2026-10-21）

本次仅做诊断与源码对照，没有改动应用源码、功能、列表或 UI 框架，也没有重启或更改原应用设置。只新增这份报告和汇总 JSON。仓库已有未提交修改保留原样。

## 测量对象与口径

- Apple M4，macOS 27.0.1；Inspector 0.3.0 UI PID 82566、Rust PID 82567。
- CC Switch 4.0.9，主进程 PID 1870。对照源码为 farion1231/cc-switch 的 v4.0.9 标签，解析到提交 8845b1ef799aa8810b864b122de6af5f4629de10；未验证安装二进制与该源码的逐字节对应关系。
- 使用系统 heap、leaks、vmmap、footprint、lsappinfo。heap/leaks 采用 --noContent，没有输出聊天文本、配置值或对象字符串内容。
- MB = 1,000,000 字节。vmmap/leaks 的 K/M 按二进制单位显示，本文对其近似换算。
- 原“约 41 MB”来自较早的 vmmap 已分配块统计。20:34:01 的可复核内存图快照实际有 38,436,478 字节、257,622 个堆块。它不是 physical footprint，也不是全部业务数据。
- 现场日志和应用状态持续变化；20:42:44 的 vmmap 显示已分配块约 49.2 MB，碎片约 25.9 MB、约 34.5 万块。两次采样不是固定场景 A/B，也不足以证明泄漏或增长原因。

## 当前堆块归因

用 heap --addresses=all 导出每个堆块的地址、大小和类型，再与同一 memgraph 的 leaks --referenceTree 逐地址、逐大小匹配。匹配 38,416,606 字节，未匹配 19,872 字节，恰好对应 leaks 报告的 XPC 引用循环。

以下分类互斥，总和为同一快照的堆块总量。分类依据对象类型和主要所有权路径，属于工程归因，不是历史创建栈；有共享引用时，主要所有者的选择会改变归属。不可将“属于某分支”理解为“全部可释放”。

| 归属 | 字节 | MB |
| --- | ---: | ---: |
| 矢量图标、SVG 和路径分支 | 8,064,192 | 8.06 |
| AttributeGraph 分支 | 5,335,006 | 5.34 |
| 其他 UI 分支 | 4,807,248 | 4.81 |
| Objective-C 运行时分支 | 4,058,480 | 4.06 |
| Swift 类型元数据 | 3,882,880 | 3.88 |
| 字体、文字与语言系统分支 | 3,074,128 | 3.07 |
| 其他图形分支 | 1,676,480 | 1.68 |
| 其他 CoreUI 分支 | 986,384 | 0.99 |
| 语法规则缓存分支 | 347,696 | 0.35 |
| 其他 Swift 运行时分支 | 268,752 | 0.27 |
| 报告及引擎对象分支 | 218,976 | 0.22 |
| 其他所有权分支 | 5,696,384 | 5.70 |
| 未匹配的 XPC 循环 | 19,872 | 0.02 |
| 合计 | 38,436,478 | 38.44 |

独立的类型统计也确认：
- CoreSVG 对象及其可识别字段共 3.82 MB；CGPath 及其可识别字段共 3.34 MB。
- Swift Metadata 3.88 MB；Objective-C method-cache buckets 单项 2.49 MB。
- 全部 Foundation/CoreFoundation 类型分组约 6.01 MB，包含系统内部对象，不能全部当作 JSON 报告。
- 采用 --guessNonObjects 的类型汇总仍有 8.15 MB 没有类型名。所有权分析能给出多数块的引用来源，但无法补回创建调用栈。未启用该猜测时，原始 non-object 类为 14.21 MB，二者口径不同，不能混用。

## 已确认的引用路径

1. 当前报告：
   ReportFetcher -> _report.storage.publisher.subject -> PublishedSubject -> currentValue._variant -> DictionaryStorage。
   主要所有权树中 ReportFetcher 分支约 199 KiB，报告分支约 197 KiB。这不能计算所有共享引用的完整传递大小，但明显不支持“当前完整报告占了几十 MB”的判断。

2. 矢量图标：
   主线程持有的 NSMutableDictionary storage -> _CUIThemeVectorGlyphRendition -> SVGDocument -> SVGRootNode -> SVGShapeNode -> SVGAttributeMap / SVGPath / CGPath。
   该主所有权分支约 4.40 MiB（约 4.61 MB）。代码确实使用 Image(systemName:) 和 Label(systemImage:)，但尚未通过创建栈或固定操作差分确认哪个图标、样式或状态触发了这些缓存，也没有证明它们是泄漏。

3. SwiftUI 图：
   AttributeGraph Owned 分支约 4.27 MiB（约 4.48 MB），包含 ResolvedTextFilter、PropertyList.Tracker 和属性存储。完整堆块归类还包括其他 AttributeGraph 根，因此表中为 5.34 MB。

4. 全局图片缓存：
   CoreUI sharedCache.sharedCache -> NSCache -> _CSIRenditionBlockData -> VM: CoreUI Image Data。
   该分支约 5.05 MiB（约 5.30 MB），包含堆外 VM。不能再加到上面的堆块表中，或与 footprint 中同类条目重复相加。

5. 两个较大的无类型块：
   163,840 字节块由 objc::AssociationsManager::_mapStorage 引用；
   147,456 字节块由 Swift Conformances 引用。
   它们是运行时存储证据，不是聊天数据证据。

6. leaks 报告：
   414 个块共 19,872 字节，属于 NSXPCConnection 相关引用循环。本快照没有检测到能解释几十 MB 占用的大泄漏；这不排除仍可达但不再需要的缓存、其他状态中的泄漏或增长。

## CC Switch 的完整进程集合

lsappinfo 将 CC Switch 登记为 coalition 1301，包含 1870、1882、1885、1892、47243。它们的 PPID 是 launchd，因此仅按父进程查找会漏掉 WebKit XPC 服务。

同一次 footprint 扫描：

| 进程 | PID | MB |
| --- | ---: | ---: |
| CC Switch 主进程 | 1870 | 57.85 |
| WebKit WebContent | 1885 | 292.05 |
| WebKit GPU | 1882 | 24.74 |
| WebKit Networking | 1892 | 7.80 |
| SafariPlatformSupport Helper | 47243 | 17.38 |
| 前四项 footprint 之和 | | 382.44 |
| 含登记的 Helper 之和 | | 399.82 |
| Inspector UI | 82566 | 94.78 |
| Inspector Rust | 82567 | 7.67 |
| Inspector 两项之和 | | 102.45 |

进程 footprint 相加是产品进程集合的近似比较，共享页可能重复计入；不是严格去重的系统物理内存。现场窗口状态、运行历史和工作量不同，不是产品性能排名。关键事实是：CC Switch 主进程约 50 MB 不代表带主窗口的产品整体约 50 MB。

## CC Switch v4.0.9 源码对照

- [Tauri 配置](https://github.com/farion1231/cc-switch/blob/v4.0.9/src-tauri/tauri.conf.json)：采用 WebView 前端。进程拆分与上面的现场证据一致。
- [轻量模式](https://github.com/farion1231/cc-switch/blob/v4.0.9/src-tauri/src/lightweight.rs)：enter_lightweight_mode 调用 window.destroy()；退出时用 WebviewWindowBuilder 重建。源码证实低资源模式会销毁主窗口。未切换用户的 CC Switch 模式，也未测量轻量模式节省多少；这个模式不满足主窗口保持打开的目标。
- [查询配置](https://github.com/farion1231/cc-switch/blob/v4.0.9/src/lib/query/queries.ts)：按 providers/settings/usage 等领域查询；providers 的 gcTime 为 Infinity。它并非所有缓存都积极释放。
- [用量查询](https://github.com/farion1231/cc-switch/blob/v4.0.9/src/lib/query/usage.ts)：请求日志分页默认 20 项、详情按 ID 请求；部分统计默认每 30 秒刷新且后台停止刷新。具体查询存在例外，不能概括成全部暂停。
- [窗口活动](https://github.com/farion1231/cc-switch/blob/v4.0.9/src/lib/windowActivity.ts)：焦点变化会启停状态心跳。它管理的是状态指示，不是销毁 WebView 或全面释放内存。

## 结论与下一步验证

已有证据支持优先调查图标/图形缓存、AttributeGraph 对象生命周期和分配器碎片，不支持先删功能、简化列表、换 UI 框架，也不支持先把业务 JSON 当作几十 MB 的主因。

若继续诊断，使用相同 Release 二进制的独立诊断副本，从启动时开启 Allocations/MallocStackLogging，依次记录冷启动、同页静置、重复切换页面、展开同样内容及关闭后回落：
- 对比每阶段新增并仍存活的类型、分配栈和持有路径。
- 图标保持相同外观与功能，先检查相同输入是否反复产生 rendition/cache 项。
- 分开测业务数据增长、UI 图增长与碎片变化。
- 启用诊断栈日志会增加内存，诊断副本只用于归因，不用其 footprint 作为产品目标成绩。

当前没有启动诊断副本。原进程从启动时未启用 MallocStackLogging，无法从现有快照还原所有历史创建栈。20 MB 是否可达、哪个改动可节省多少，仍须受控实验验证。

## 原始证据与校验

临时目录：/tmp/codex-inspector-memory-audit.7Kv0hP

- inspector.memgraph（--noContent）
- inspector-graph-heap.txt / inspector-all-addresses.txt
- inspector-reference-addresses.txt / reportfetcher-reference-tree.txt / reportfetcher-layout.txt
- inspector-leak-analysis.txt / trace-large-163840.txt / trace-large-147456.txt
- inspector-vmmap-final.txt
- ccswitch-coalition.txt / all-process-footprints.txt
- whole-heap-ownership-summary.json
- cc-source/（仅保存公开源码快照，不运行）

UI SHA-256：277e98a3665ded0364443f2c0c168bb7db923ad58663398e24159fd1d89d47c7
Rust SHA-256：01eb883d42564c87c3b8b4eb7100f3518d26b35851c287026d5cabff293ea5a5

只读诊断，无应用代码变更，因此未重复运行应用单元测试。汇总已检查：分类字节之和加未匹配字节等于快照堆块总量。

