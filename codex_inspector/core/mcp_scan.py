"""从合并后的配置里取出 MCP 服务器定义。

这里只反映"配置层面声明了什么",不会真的去连接每个 MCP 服务器验证它是否可用——
连接验证请用 `codex mcp list`,两者信息互补:这个工具告诉你"配置为什么会长这样"
(来自哪一层、有没有被 enabled_tools/disabled_tools 收窄),`codex mcp list` 告诉你
"现在是否真的连上了"。
"""
from __future__ import annotations

from typing import Any

from .models import McpServerEntry


def scan_mcp_servers(merged_config: dict[str, Any]) -> list[McpServerEntry]:
    servers = merged_config.get("mcp_servers", {})
    if not isinstance(servers, dict):
        return []
    result = []
    for name, raw in servers.items():
        if isinstance(raw, dict):
            result.append(McpServerEntry(name=name, raw=raw))
    return result
