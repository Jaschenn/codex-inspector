"""codex-inspector 的命令行入口。

展示层和核心逻辑(core.build_report)彻底分开:这个文件只管"怎么把 dict 打印得好看",
不包含任何探测/合并逻辑。以后做 macOS App 时,直接复用 core,换掉这一个文件即可。
"""

from __future__ import annotations

import argparse
import io
import json
import os
import shutil
import time
from pathlib import Path

from .core import build_report
from .interactive import RawKeyboard

try:
    from rich.console import Console, Group
    from rich.table import Table
    from rich.panel import Panel
    from rich.live import Live
    from rich.columns import Columns
    from rich.text import Text

    HAS_RICH = True
except ModuleNotFoundError:
    HAS_RICH = False


def _fmt_bool(b: bool) -> str:
    return "✅" if b else "❌"


def _shorten_path(path: str | None) -> str:
    """把家目录前缀换成 ~,长路径在小屏幕上能少占一大截。"""
    if not path:
        return "-"
    home = str(Path.home())
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~" + path[len(home) :]
    return path


TRUST_STYLE = {"trusted": "bold green", "untrusted": "bold red", "unknown": "yellow"}
TRUST_LABEL = {
    "trusted": "✅ trusted",
    "untrusted": "⛔ untrusted",
    "unknown": "❔ unknown",
}


# ---------------------------------------------------------------------------
# 纯文本渲染(没装 rich 时的兜底)
# ---------------------------------------------------------------------------


def render_plain(report: dict) -> str:
    lines = [
        f"生成时间: {report['generated_at']}  |  发现 {report['process_count']} 个 codex 进程"
    ]
    for e in report["process_errors"]:
        lines.append(f"  ⚠ pid={e['pid']} 分析失败: {e['error']}")

    for proc in report["processes"]:
        lines.append("")
        lines.append("=" * 78)
        lines.append(
            f"PID {proc['pid']}  user={proc['user']}  运行时长={proc['etime']}"
        )
        lines.append(f"命令行: {proc['cmdline']}")
        lines.append(f"cwd: {proc['cwd'] or '(未知: ' + str(proc['cwd_error']) + ')'}")
        lines.append(
            f"CODEX_HOME: {_shorten_path(proc['codex_home'])}  |  env 读取状态: {proc['env_status']}"
        )
        co = proc["cli_overrides"]
        if co["profile"] or co["cd"] or co["config_path"] or co["c_overrides"]:
            lines.append(
                f"CLI 覆盖: profile={co['profile']} cd={co['cd']} "
                f"config={co['config_path']} -c={co['c_overrides']}"
            )
        lines.append(
            f"项目根: {proc['project_root'] or '(不在 git 仓库内)'}  |  trust: {proc['trust_level']}"
        )
        lines.append("配置层(kind / 是否存在 / 是否生效):")
        for layer in proc["config_layers"]:
            reason = f"  [{layer['skip_reason']}]" if layer.get("skip_reason") else ""
            err = f"  ⚠ {layer['parse_error']}" if layer.get("parse_error") else ""
            lines.append(
                f"  - {layer['kind']:8s} exists={_fmt_bool(layer['exists'])} "
                f"applied={_fmt_bool(layer['applied'])}  {_shorten_path(layer['path'])}"
                f"{reason}{err}"
            )
        lines.append(f"AGENTS.md 链({len(proc['agents_chain'])} 个):")
        for doc in proc["agents_chain"]:
            lines.append(f"  - [{doc['scope']}] {_shorten_path(doc['path'])}")
        lines.append(f"Skills({len(proc['skills'])} 个):")
        for s in proc["skills"]:
            flag = "启用" if s["enabled"] else f"禁用({s['disabled_reason']})"
            name = s["name"] or "(未命名/解析失败)"
            lines.append(
                f"  - [{s['scope']}] {name}: {flag}  <- {_shorten_path(s['path'])}"
            )
            if s.get("description"):
                lines.append(f"      {s['description']}")
        lines.append(f"MCP 服务器({len(proc['mcp_servers'])} 个):")
        for m in proc["mcp_servers"]:
            raw = m["raw"]
            desc_bits = []
            if "command" in raw:
                desc_bits.append(f"command={raw['command']}")
            if "url" in raw:
                desc_bits.append(f"url={raw['url']}")
            if raw.get("enabled_tools"):
                desc_bits.append(f"enabled_tools={raw['enabled_tools']}")
            if raw.get("disabled_tools"):
                desc_bits.append(f"disabled_tools={raw['disabled_tools']}")
            lines.append(f"  - {m['name']}: {', '.join(desc_bits)}")
        if proc["warnings"]:
            lines.append("警告:")
            for w in proc["warnings"]:
                lines.append(f"  ⚠ {w}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# rich 渲染
# ---------------------------------------------------------------------------


def _build_overview(proc: dict):
    """左右两栏的「一眼看清」概览卡片:左边是身份信息,右边是各项计数。"""
    left = Table(show_header=False, box=None, padding=(0, 1))
    left.add_column(style="dim", no_wrap=True)
    left.add_column(overflow="fold")
    left.add_row("命令行", proc["cmdline"])
    left.add_row("用户 / 运行时长", f"{proc['user']} / {proc['etime']}")
    left.add_row(
        "cwd",
        _shorten_path(proc["cwd"])
        if proc["cwd"]
        else f"[red]未知: {proc['cwd_error']}[/red]",
    )
    left.add_row("CODEX_HOME", _shorten_path(proc["codex_home"]))
    left.add_row(
        "项目根",
        _shorten_path(proc["project_root"])
        if proc["project_root"]
        else "(不在 git 仓库内)",
    )
    trust = proc["trust_level"]
    trust_style = TRUST_STYLE.get(trust, "")
    left.add_row(
        "Trust", f"[{trust_style}]{TRUST_LABEL.get(trust, trust)}[/{trust_style}]"
    )

    co = proc["cli_overrides"]
    if co["profile"] or co["cd"] or co["config_path"] or co["c_overrides"]:
        override_bits = []
        if co["profile"]:
            override_bits.append(f"profile={co['profile']}")
        if co["cd"]:
            override_bits.append(f"cd={_shorten_path(co['cd'])}")
        if co["config_path"]:
            override_bits.append(f"config={_shorten_path(co['config_path'])}")
        for k, v in co["c_overrides"]:
            override_bits.append(f"-c {k}={v}")
        left.add_row("CLI 覆盖", "  ".join(override_bits))

    layers_applied = sum(1 for l in proc["config_layers"] if l["applied"])
    skills_enabled = sum(1 for s in proc["skills"] if s["enabled"])

    right = Table(show_header=False, box=None, padding=(0, 1))
    right.add_column(style="dim", no_wrap=True)
    right.add_column()
    right.add_row("配置层生效", f"{layers_applied} / {len(proc['config_layers'])}")
    right.add_row("AGENTS.md", f"{len(proc['agents_chain'])} 份")
    right.add_row("Skills", f"{skills_enabled} 启用 / {len(proc['skills'])} 总数")
    right.add_row("MCP servers", f"{len(proc['mcp_servers'])} 个")
    if proc["warnings"]:
        right.add_row(
            "[yellow]警告[/yellow]", f"[yellow]{len(proc['warnings'])} 条[/yellow]"
        )
    else:
        right.add_row("警告", "无")

    return Columns([left, right], equal=False, expand=True)


def _build_config_layers_table(proc: dict):
    t = Table(title="配置层  (低 → 高优先级)", expand=True)
    t.add_column("层级", no_wrap=True)
    t.add_column("存在", justify="center", no_wrap=True)
    t.add_column("生效", justify="center", no_wrap=True)
    t.add_column("路径", overflow="fold")
    t.add_column("备注", style="yellow")
    for layer in proc["config_layers"]:
        note = layer.get("skip_reason") or layer.get("parse_error") or ""
        if layer.get("parse_error"):
            row_style = "bold red"
        elif not layer["applied"] and layer["exists"]:
            row_style = "dim"
        elif layer["applied"]:
            row_style = "green"
        else:
            row_style = None
        t.add_row(
            layer["kind"],
            _fmt_bool(layer["exists"]),
            _fmt_bool(layer["applied"]),
            _shorten_path(layer["path"]) if layer["path"] else "(CLI 覆盖)",
            note,
            style=row_style,
        )
    return t


def _build_agents_panel(proc: dict):
    if not proc["agents_chain"]:
        text = "[dim](没有找到 AGENTS.md,当前进程没有额外的项目指令)[/dim]"
    else:
        text = "\n".join(
            f"[cyan]\\[{d['scope']}][/cyan] {_shorten_path(d['path'])}"
            for d in proc["agents_chain"]
        )
    return Panel(
        text, title=f"AGENTS.md 链 ({len(proc['agents_chain'])})", border_style="blue"
    )


def _build_skills_table(proc: dict):
    t = Table(title=f"Skills ({len(proc['skills'])})", expand=True)
    t.add_column("scope", no_wrap=True)
    t.add_column("name", no_wrap=True)
    t.add_column("状态", justify="center", no_wrap=True)
    t.add_column("path", overflow="fold")
    for s in proc["skills"]:
        if s["enabled"]:
            status = "[green]启用[/green]"
            row_style = None
        else:
            status = "[red]禁用[/red]"
            row_style = "dim"
        name = s["name"] or "[yellow](未命名/解析失败)[/yellow]"
        t.add_row(s["scope"], name, status, _shorten_path(s["path"]), style=row_style)
    return t


def _build_mcp_table(proc: dict):
    t = Table(title=f"MCP servers ({len(proc['mcp_servers'])})", expand=True)
    t.add_column("name", no_wrap=True, style="bold")
    t.add_column("入口", overflow="fold")
    t.add_column("工具范围")
    for m in proc["mcp_servers"]:
        raw = m["raw"]
        detail = raw.get("command") or raw.get("url") or ""
        if raw.get("args"):
            detail += " " + " ".join(str(a) for a in raw["args"])
        scope_bits = []
        if raw.get("enabled_tools"):
            scope_bits.append(f"[green]仅启用: {raw['enabled_tools']}[/green]")
        if raw.get("disabled_tools"):
            scope_bits.append(f"[red]禁用: {raw['disabled_tools']}[/red]")
        if raw.get("default_tools_approval_mode"):
            scope_bits.append(f"approval={raw['default_tools_approval_mode']}")
        t.add_row(
            m["name"],
            detail,
            "\n".join(scope_bits) or "[dim](全部工具, 默认审批)[/dim]",
        )
    return t


def _build_warnings_panel(proc: dict):
    text = "\n".join(f"⚠ {w}" for w in proc["warnings"])
    return Panel(text, title="警告", border_style="yellow")


def build_process_sections(proc: dict) -> list[tuple[str, str, object]]:
    """把一个进程拆成带编号的分区,(编号键, 简短标签, renderable)。

    编号用于 --watch 模式里按数字键直接跳转,标签用于底部的分区导航条。
    """
    sections: list[tuple[str, str, object]] = [
        ("1", "概览", _build_overview(proc)),
        ("2", "配置层", _build_config_layers_table(proc)),
        ("3", "AGENTS.md", _build_agents_panel(proc)),
        ("4", "Skills", _build_skills_table(proc)),
        ("5", "MCP", _build_mcp_table(proc)),
    ]
    if proc["warnings"]:
        sections.append(("6", "警告", _build_warnings_panel(proc)))
    return sections


def build_process_panel(proc: dict):
    """一次性渲染进程的全部分区(不分页),给一次性输出(非 --watch)用。"""
    header = (
        f"PID {proc['pid']}  ·  {_shorten_path(proc['cwd'])}  ·  "
        f"{TRUST_LABEL.get(proc['trust_level'], proc['trust_level'])}"
    )
    renderables = [r for _, _, r in build_process_sections(proc)]
    return Panel(Group(*renderables), title=header, border_style="cyan")


def build_rich_group(report: dict):
    renderables = [
        f"[bold]codex-inspector[/bold]  {report['generated_at']}  ·  "
        f"发现 [bold]{report['process_count']}[/bold] 个正在运行的 codex 进程"
    ]

    for e in report["process_errors"]:
        renderables.append(f"[red]⚠ pid={e['pid']} 分析失败: {e['error']}[/red]")

    for proc in report["processes"]:
        renderables.append(build_process_panel(proc))

    return Group(*renderables)


# ---------------------------------------------------------------------------
# 运行模式
# ---------------------------------------------------------------------------


def _filter_pid(report: dict, pid: int | None) -> dict:
    if pid is None:
        return report
    report = dict(report)
    report["processes"] = [p for p in report["processes"] if p["pid"] == pid]
    report["process_count"] = len(report["processes"])
    return report


def run_once(args: argparse.Namespace) -> None:
    report = _filter_pid(
        build_report(
            include_sessions=args.sessions,
            session_id=args.session_id,
            turn_id=args.turn_id,
            include_archived=args.include_archived,
            include_other_sources=args.include_other_sources,
        ),
        args.pid,
    )

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    if HAS_RICH:
        Console().print(build_rich_group(report))
    else:
        print(render_plain(report))
        print("\n(提示: `pip install rich` 可以获得更好看的表格式输出)")


def _build_process_tabs(procs: list[dict], focus_index: int) -> str:
    """顶部的进程标签栏,当前聚焦的那个高亮,其余的做成暗色小标签。"""
    if len(procs) <= 1:
        return ""
    bits = []
    for i, p in enumerate(procs):
        cwd_name = Path(p["cwd"]).name if p["cwd"] else "?"
        label = f" {i + 1}:{p['pid']} {cwd_name} "
        if i == focus_index:
            bits.append(f"[black on cyan]{label}[/black on cyan]")
        else:
            trust = p["trust_level"]
            dim_style = (
                "dim"
                if trust == "trusted"
                else ("red" if trust == "untrusted" else "yellow")
            )
            bits.append(f"[{dim_style}]{label}[/{dim_style}]")
    return " ".join(bits)


def _render_focused_view(
    report: dict, focus_index: int, scroll: int, term_width: int, term_height: int
):
    """把「聚焦单个进程 + 滚动」渲染成一份定长的文本,方便塞进 Live。

    返回 (renderable, clamped_scroll, max_scroll, focus_index, jump_targets)。
    jump_targets 是 {"1": 起始行号, ...},供数字键跳转到对应分区使用。
    """
    procs = report["processes"]
    n = len(procs)
    focus_index = max(0, min(focus_index, n - 1)) if n else 0

    tabs = _build_process_tabs(procs, focus_index)
    header = (
        f"[bold]codex-inspector[/bold]  {report['generated_at']}  ·  共 {n} 个进程"
        + (f"  ·  当前第 {focus_index + 1}/{n} 个" if n else "")
    )

    jump_targets: dict[str, int] = {}
    section_legend = ""

    if n == 0:
        body_lines = ["", "[yellow](当前没有检测到正在运行的 codex 进程)[/yellow]"]
        max_scroll = 0
        scroll = 0
    else:
        proc = procs[focus_index]
        sections = build_process_sections(proc)

        body_lines: list[str] = []
        for key, label, renderable in sections:
            jump_targets[key] = len(body_lines)
            buf = io.StringIO()
            offscreen = Console(
                file=buf,
                width=term_width,
                force_terminal=True,
                color_system="truecolor",
                legacy_windows=False,
            )
            offscreen.rule(f"[bold]\\[{key}] {label}[/bold]", style="grey50")
            offscreen.print(renderable)
            body_lines.extend(buf.getvalue().splitlines())
            body_lines.append("")

        # 底部分区导航条:高亮当前滚动位置所在的分区
        current_key = "1"
        for key, start in jump_targets.items():
            if scroll >= start:
                current_key = key
        legend_bits = []
        for key, label, _ in sections:
            if key == current_key:
                legend_bits.append(f"[reverse] {key}:{label} [/reverse]")
            else:
                legend_bits.append(f"[dim] {key}:{label} [/dim]")
        section_legend = " ".join(legend_bits)

    footer = (
        "[dim]↑/↓ j/k 滚动 · ←/→ h/l p/n 切换进程 · 数字键跳转分区 · g/G 顶部/底部 · "
        "r 刷新 · q 退出[/dim]"
    )

    visible_height = max(3, term_height - (6 if n > 1 else 5))
    max_scroll = max(0, len(body_lines) - visible_height)
    scroll = max(0, min(scroll, max_scroll))
    window = body_lines[scroll : scroll + visible_height]
    content = Text.from_ansi("\n".join(window))

    scroll_hint = f"  ·  已滚动 {scroll}/{max_scroll} 行" if max_scroll > 0 else ""

    parts = [header + scroll_hint]
    if tabs:
        parts.append(tabs)
    parts.append("")
    parts.append(content)
    if n:
        parts.append("")
        parts.append(section_legend)
    parts.append(footer)

    return Group(*parts), scroll, max_scroll, focus_index, jump_targets


def run_watch(args: argparse.Namespace) -> None:
    if not HAS_RICH:
        _run_watch_plain(args)
        return

    keyboard = RawKeyboard()
    if not keyboard.available:
        # 不是交互式终端(比如输出被重定向到文件),退化成纯定时刷新,不支持按键
        _run_watch_plain(args)
        return

    console = Console()
    focus_index = 0
    scroll = 0
    last_fetch = 0.0
    report = {
        "generated_at": "",
        "process_count": 0,
        "processes": [],
        "process_errors": [],
    }

    try:
        with (
            keyboard,
            Live(console=console, refresh_per_second=20, screen=True) as live,
        ):
            while True:
                now = time.monotonic()
                if now - last_fetch >= args.interval:
                    report = _filter_pid(build_report(), args.pid)
                    last_fetch = now

                term_size = shutil.get_terminal_size()
                view, scroll, max_scroll, focus_index, jump_targets = (
                    _render_focused_view(
                        report,
                        focus_index,
                        scroll,
                        term_size.columns,
                        term_size.lines,
                    )
                )
                live.update(view)

                key = keyboard.read_key(timeout=0.05)
                if key in ("q", "Q", "\x03"):  # \x03 = Ctrl+C
                    break
                elif key in ("up", "k"):
                    scroll = max(0, scroll - 1)
                elif key in ("down", "j"):
                    scroll = min(max_scroll, scroll + 1)
                elif key == "g":
                    scroll = 0
                elif key == "G":
                    scroll = max_scroll
                elif key in ("left", "h", "p"):
                    if report["processes"]:
                        focus_index = (focus_index - 1) % len(report["processes"])
                        scroll = 0
                elif key in ("right", "l", "n"):
                    if report["processes"]:
                        focus_index = (focus_index + 1) % len(report["processes"])
                        scroll = 0
                elif key in jump_targets:
                    scroll = jump_targets[key]
                elif key == "r":
                    last_fetch = 0.0  # 强制下一轮立即重新拉取
    except KeyboardInterrupt:
        pass


def _run_watch_plain(args: argparse.Namespace) -> None:
    """没有 rich 或者不是交互式终端时的兜底:定时清屏重绘,不支持按键,滚动交给终端自己的翻页。"""
    try:
        while True:
            report = _filter_pid(build_report(), args.pid)
            print("\033c", end="")  # 清屏(ANSI)
            print(render_plain(report))
            print(
                f"\n(每 {args.interval} 秒刷新一次,Ctrl+C 退出;当前模式不支持按键滚动/切换进程,"
                f"如需要请安装 rich 并在真正的终端里运行: pip install rich)"
            )
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="codex-inspector",
        description="查看当前机器上正在运行的 codex 进程及其生效配置",
    )
    parser.add_argument("--watch", action="store_true", help="常驻监控,定时刷新")
    parser.add_argument(
        "--interval", type=float, default=2.0, help="刷新间隔秒数(配合 --watch)"
    )
    parser.add_argument(
        "--json", action="store_true", help="输出原始 JSON,方便接入其他工具/未来的 App"
    )
    parser.add_argument("--pid", type=int, default=None, help="只看指定 pid")
    parser.add_argument(
        "--detail", action="store_true", help="(保留参数,当前默认已展开全部细节)"
    )
    parser.add_argument(
        "--sessions", action="store_true", help="包含本地聊天列表（只读）"
    )
    parser.add_argument(
        "--session-id", help="检查指定聊天的选择 ID（与 --sessions 一起使用）"
    )
    parser.add_argument("--turn-id", help="检查指定轮次，省略时使用最新轮次")
    parser.add_argument(
        "--include-archived", action="store_true", help="聊天列表包含归档记录"
    )
    parser.add_argument(
        "--include-other-sources",
        action="store_true",
        help="聊天列表包含其他客户端和非交互任务来源",
    )
    args = parser.parse_args(argv)

    if args.watch:
        run_watch(args)
    else:
        run_once(args)


if __name__ == "__main__":
    main()
