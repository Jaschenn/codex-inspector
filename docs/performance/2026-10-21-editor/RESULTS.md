# 编辑器与内存优化验证（2026-10-21）

**50 MB 目标未达到。** 按活动监视器的 physical footprint 统计界面与 Rust 引擎之和，主窗口中位数为 65.0 MB，大文件编辑场景为 125.8 MB。MB 按 1,000,000 字节计算，不使用 RSS 或压缩后的数字替代该目标。

| 场景 | 样本数 | 合计中位数 | 合计最大值 |
| --- | ---: | ---: | ---: |
| 主窗口 / 最新轮次概览 | 15 | 65.03 MB | 71.27 MB |
| 1,064,000 字节 TOML / 浏览与连续滚动 | 15 | 125.77 MB | 138.51 MB |

机器为 Apple M4、16 GiB、macOS 27.0.1。使用 release 打包程序的独立副本，界面可见，每秒采样一次；副本仅修改应用名称、bundle ID 和签名以避免与用户试用窗口混淆。测量时日志仍有新记录，因此这些数据是现场场景测量，不是固定日志的严格内存 A/B。原始数据保留每个进程的 footprint 与 resident size。

## 滚动热点

相同 1,204,000 字节、28,001 行样本，100 个相同 UTF-16 滚动偏移，Release 测试结果：

- 原来的行号路径：扫描当前位置之前的文本，再扫描全文统计最后一行；中位数 **68.645 ms**。
- 新的行号路径：文本变化时建立行起点索引，滚动时二分查询；中位数 **0.001073 ms**。

这仅衡量行号计算，不是完整 UI 帧率或端到端滚动延迟。已在应用中验证大文件连续滚动、可见区高亮、编辑及保存。测试文件是临时合成样本，没有改动用户配置文件。

## 保留的优化

- 行号索引与可见行绘制，避免逐帧扫描全文。
- 正则表达式复用；后台可取消的语法解析；仅为可见区设置 TextKit 临时颜色属性，不触发全文重新排版。
- 文本宽度、字体和换行参数未变化时不重复设置；Markdown 和代码预览内容相同时复用视图。
- 聊天列表复用原生可见行；长菜单按需创建；折叠指令不提前创建编辑器；Skills/MCP 列表延迟创建。
- 时间线改用 Core Graphics 原生绘制，避免 Canvas 图形缓存及每个片段独立视图。
- Rust 增量索引转移所有权，避免每次刷新深拷贝历史；减少驻留索引数量；完成 Token 计算后释放词表；定期回收已释放的分配器页面。

保留原有主界面和编辑功能。没有稳定收益的主界面重写未纳入最终交付。尚不能保证长日志、多个窗口、冷 Token 词表加载或大文件的内存低于 50 MB。

## 复现

```sh
CODEX_INSPECTOR_EDITOR_BENCHMARK=/tmp/editor-benchmark.json \
  swift test -c release --package-path macapp --only-use-versions-from-resolved-file

xcrun swift scripts/measure_native_memory.swift /tmp/memory.json UI_PID CORE_PID 15
macapp/build_app.sh
```

相关原始文件：`line-index-benchmark.json`、`overview-memory.json`、`editor-memory.json`。所有 32 项 Swift Release 测试及 5 项 Rust 测试通过，Clippy、Rust 格式检查和差异检查通过；应用重新打包并验证 ad-hoc 签名。
