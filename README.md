# codex-inspector

[![CI](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/ci.yml)
[![Release](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml/badge.svg)](https://github.com/Jaschenn/codex-inspector/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个只读的诊断工具:找出当前机器上所有正在运行的 `codex` 进程,并为每一个进程还原出它
**实际生效**的配置——包括合并后的 `config.toml`、AGENTS.md 指令链、当前可见的 Skills(含
被禁用的)、以及 MCP 服务器列表。

设计上把「核心探测/合并逻辑」和「展示层」分开(见 `codex_inspector/core/` 与
`codex_inspector/cli.py`),核心逻辑只产出一份 JSON 可序列化的 snapshot,不依赖任何终端
库。这样以后你想做 macOS App,只需要另写一个 UI 层调用 `core.build_report()`,不用重写
探测逻辑。

## 安装

```bash
cd codex-inspector
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

需要 Python 3.11+(用到内置 `tomllib`)。`rich` 是可选依赖,没装的话会自动降级成纯文本输出。

## 用法

```bash
# 一次性快照,打印所有正在运行的 codex 进程 + 生效配置
python3 -m codex_inspector

# 常驻监控 + 键盘交互(默认每 2 秒拉取一次新数据),真正的终端里运行
python3 -m codex_inspector --watch

# 自定义数据刷新间隔(按键响应不受这个影响,一直是实时的)
python3 -m codex_inspector --watch --interval 5

# 只看某一个 pid
python3 -m codex_inspector --pid 12345

# 输出原始 JSON,方便接到别的工具 / 未来的 App 里
python3 -m codex_inspector --json
```

### `--watch` 模式下的键盘操作

一次只聚焦显示一个进程,内容按「概览 / 配置层 / AGENTS.md / Skills / MCP / 警告」分成
带编号的区块,每个区块前面有一条分隔线标出 `[编号] 标题`,底部有一条导航条高亮当前滚动到
了哪个区块。有多个 codex 进程时,顶部还会出现进程标签栏,当前聚焦的用高亮底色标出。

| 按键 | 作用 |
|---|---|
| `↑` / `k` | 向上滚动 |
| `↓` / `j` | 向下滚动 |
| `1`-`6` | 直接跳到对应编号的区块(概览/配置层/AGENTS.md/Skills/MCP/警告) |
| `←` / `h` / `p` | 切换到上一个进程 |
| `→` / `l` / `n` | 切换到下一个进程 |
| `g` | 跳到顶部 |
| `G` | 跳到底部 |
| `r` | 立即强制刷新(不等 `--interval`) |
| `q` / `Ctrl+C` | 退出 |

布局上做了几个方便阅读的处理:
- 家目录路径会显示成 `~/...` 而不是完整绝对路径,省掉一大截视觉噪音
- 配置层、Skill 用颜色区分状态(绿色=生效/启用,暗灰=存在但被跳过,红色=禁用或解析出错)
- 概览区块用左右两栏布局,右边是「配置层生效 X/Y、Skills 启用 X/Y、MCP 个数」这类一眼扫到的计数

数据刷新(重新跑一遍探测)按 `--interval` 定时进行,但按键响应是每 50ms 轮询一次,滚动/切换/跳转都是即时的,不会卡在下一次数据刷新上。

如果 stdout 被重定向到文件、或者终端不支持 `termios`(比如某些 Windows 环境),会自动退化成没有交互的定时清屏刷新模式。

## 它是怎么拿到信息的(以及已知的局限)

| 信息 | 拿法 | 局限 |
|---|---|---|
| 有哪些 codex 进程在跑 | `ps -axo pid=,etime=,command=` 过滤出可执行文件名为 `codex` 的行 | 如果你把 codex 包了一层壳脚本改了名字,识别不到;可以在 `core/process_scan.py` 里加白名单 |
| 进程的 cwd | macOS 下用 `lsof -a -p <pid> -d cwd -Fn` | 需要 `lsof` 有权限读该进程,通常同用户下没问题;沙箱/权限受限的进程可能拿不到 |
| 进程的环境变量(主要为了拿 `CODEX_HOME`) | 优先 `psutil`,失败则退回 `ps eww -p <pid>` 解析行尾的 `KEY=VALUE` | macOS 的强化运行时(hardened runtime)有时会拒绝读取其他进程的完整环境,即使是同一用户;拿不到时会标记为「未知」而不是瞎猜 |
| CLI 覆盖(`-c key=value`、`--profile`、`--cd`) | 直接从 `ps` 拿到的完整命令行里 shlex 解析 | 如果命令行被截断(极长参数在某些系统上会被截断显示),解析可能不全 |
| 项目是否 trusted | 读全局 `~/.codex/config.toml` 里的 `[projects."<abs-path>"]` → `trust_level` | 官方目前把这块存在全局 config 里(见 openai/codex#15433 的讨论,未来可能拆分出去);工具按当前已知格式解析,如果 OpenAI 改了存储位置需要更新这一小块 |
| 生效配置合并 | 按官方文档优先级手工实现 TOML 深度 merge:CLI `-c` > profile 文件 > 项目 `.codex/config.toml`(仓库根到 cwd,越近越后覆盖,仅 trusted 项目)> 全局 `~/.codex/config.toml` > 内置默认值 | 系统级 `/etc/codex/config.toml` 在 macOS 上极少见,工具会尝试读取但通常不存在;`requirements.toml` 强制约束未处理 |
| Skills | 从 cwd 向上扫到 git 仓库根,每层找 `.agents/skills/` 和 `.codex/skills/`,加上全局 `~/.codex/skills/`;再套用合并配置里 `[[skills.config]]` 的 enable/disable 覆盖 | 不会向下扫描子目录(和官方行为一致);同名 skill 不合并,按你之前问过的规则原样列出 |
| MCP 服务器 | 从合并后配置的 `[mcp_servers.*]` 读取,附带 `enabled_tools` / `disabled_tools` / `default_tools_approval_mode` | 不会主动连接 MCP 服务器验证是否真的能连上,只反映配置层面「应该启用什么」 |
| AGENTS.md 指令链 | 全局 `~/.codex/AGENTS.override.md`(或 `AGENTS.md`)+ 项目根到 cwd 逐层的 `AGENTS.override.md`/`AGENTS.md` | 自定义 `project_doc_fallback_filenames` 暂未支持,先按默认文件名扫描 |

## macOS 菜单栏 App

`codex_inspector/core/report.py` 里的 `build_report()` 返回一份可以直接 `json.dumps`
的 dict,[`macapp/`](macapp) 是基于这份核心逻辑写的 SwiftUI 菜单栏 App:顶部菜单栏图标
实时显示当前正在跑的 codex 进程数,点开能看每个进程的概览/配置层/AGENTS.md/Skills/MCP/
警告——原理是每隔几秒在后台跑一次 `python3 -m codex_inspector --json` 并解析结果,没有
重新实现探测逻辑。详见 [macapp/README.md](macapp/README.md)。

打包好的 `.app`(自包含,免装 Python)可以在 [Releases](../../releases) 页面直接下载,
也可以本地跑 `macapp/build_app.sh` 自己打包。
