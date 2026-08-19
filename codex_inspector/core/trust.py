"""判断某个项目路径在 Codex 眼里是 trusted / untrusted / unknown。

Trust 状态目前(2026-08)存储在全局 ~/.codex/config.toml 的
    [projects."/abs/path/to/repo"]
    trust_level = "trusted" | "untrusted"
这一段里。官方内部有讨论未来可能把这部分拆到单独文件(openai/codex#15433),如果 Codex
之后改了存储位置,只需要更新这一个模块。
"""
from __future__ import annotations

from typing import Any


def get_trust_level(global_config: dict[str, Any], project_root: str | None) -> str:
    if not project_root:
        return "unknown"
    projects = global_config.get("projects")
    if not isinstance(projects, dict):
        return "unknown"
    entry = projects.get(project_root)
    if not isinstance(entry, dict):
        return "unknown"
    level = entry.get("trust_level")
    if level in ("trusted", "untrusted"):
        return level
    return "unknown"
