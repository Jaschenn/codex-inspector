"""所有跨模块共享的数据结构。全部是可以直接 json.dumps 的普通 dataclass。"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any


@dataclass
class RawProcess:
    pid: int
    user: str
    etime: str          # 运行时长,ps 的 etime 字段,如 "01:23:45"
    cmdline: str         # 完整命令行(尽力而为,可能被系统截断)


@dataclass
class CliOverrides:
    profile: str | None = None
    cd: str | None = None            # --cd/-C 指定的工作目录
    config_path: str | None = None   # --config 指定的额外配置文件
    codex_home: str | None = None    # 通过 -c codex_home=... 之类方式显式指定(少见)
    c_overrides: list[tuple[str, Any]] = field(default_factory=list)  # (-c key=value) 列表


@dataclass
class ConfigLayer:
    """参与 merge 的每一层配置,方便用户看清"到底是哪个文件在起作用"。"""
    kind: str            # "system" | "global" | "project" | "profile" | "cli"
    path: str | None     # 对应文件路径,cli 覆盖没有文件所以是 None
    exists: bool
    applied: bool        # 是否真的被加载参与了 merge(比如 untrusted 项目层会是 False)
    skip_reason: str | None = None
    parse_error: str | None = None


@dataclass
class AgentsDoc:
    path: str
    exists: bool
    scope: str            # "global" | "project"


@dataclass
class SkillEntry:
    name: str | None
    description: str | None
    path: str
    scope: str             # "cwd" | "project-root-or-between" | "global" | "system"
    enabled: bool
    disabled_reason: str | None = None
    parse_error: str | None = None


@dataclass
class McpServerEntry:
    name: str
    raw: dict[str, Any]


@dataclass
class ProcessReport:
    pid: int
    user: str
    etime: str
    cmdline: str
    cwd: str | None
    cwd_error: str | None
    env_status: str            # "ok" | "partial" | "unavailable"
    codex_home: str
    cli_overrides: CliOverrides
    project_root: str | None
    is_git_repo: bool
    trust_level: str            # "trusted" | "untrusted" | "unknown"
    config_layers: list[ConfigLayer]
    merged_config: dict[str, Any]
    agents_chain: list[AgentsDoc]
    skills: list[SkillEntry]
    mcp_servers: list[McpServerEntry]
    warnings: list[str]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
