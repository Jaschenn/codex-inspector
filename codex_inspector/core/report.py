"""顶层入口:把各个子模块的结果拼成一份完整、可直接 json.dumps 的报告。"""
from __future__ import annotations

import datetime as _dt
from pathlib import Path
from typing import Any

from .models import ProcessReport
from .process_scan import find_codex_processes, get_cwd, get_env, parse_cli_overrides
from .config_merge import build_merged_config, redact_secrets
from .skills_scan import scan_skills
from .mcp_scan import scan_mcp_servers
from .agents_scan import scan_agents_chain

DEFAULT_CODEX_HOME = Path.home() / ".codex"


def build_process_report(pid: int, user: str, etime: str, cmdline: str) -> ProcessReport:
    warnings: list[str] = []

    cwd_str, cwd_err = get_cwd(pid)
    if cwd_err:
        warnings.append(f"cwd: {cwd_err}")
    cwd = Path(cwd_str) if cwd_str else Path.cwd()

    env, env_status = get_env(pid)
    if env_status != "ok":
        warnings.append(
            "环境变量读取" + ("不完整(值含空格的变量可能被截断)" if env_status == "partial" else "失败,可能受系统权限限制")
        )

    cli_overrides = parse_cli_overrides(cmdline)

    codex_home = Path(cli_overrides.codex_home or env.get("CODEX_HOME") or str(DEFAULT_CODEX_HOME)).expanduser()

    effective_cwd = Path(cli_overrides.cd).expanduser() if cli_overrides.cd else cwd

    merged_config, layers, project_root, is_git_repo, trust_level = build_merged_config(
        codex_home=codex_home,
        cwd=effective_cwd,
        profile=cli_overrides.profile,
        cli_overrides=cli_overrides.c_overrides,
    )

    skills = scan_skills(codex_home, effective_cwd, project_root, merged_config)
    mcp_servers = scan_mcp_servers(merged_config)
    agents_chain = scan_agents_chain(codex_home, effective_cwd, project_root)

    if is_git_repo and trust_level == "unknown":
        warnings.append("该项目是 git 仓库,但在全局 config.toml 里找不到 trust 记录——项目层配置大概率不会生效")

    return ProcessReport(
        pid=pid,
        user=user,
        etime=etime,
        cmdline=cmdline,
        cwd=cwd_str,
        cwd_error=cwd_err,
        env_status=env_status,
        codex_home=str(codex_home),
        cli_overrides=cli_overrides,
        project_root=project_root,
        is_git_repo=is_git_repo,
        trust_level=trust_level,
        config_layers=layers,
        merged_config=redact_secrets(merged_config),
        agents_chain=agents_chain,
        skills=skills,
        mcp_servers=mcp_servers,
        warnings=warnings,
    )


def build_report() -> dict[str, Any]:
    processes = find_codex_processes()
    reports = []
    errors = []
    for p in processes:
        try:
            reports.append(build_process_report(p.pid, p.user, p.etime, p.cmdline).to_dict())
        except Exception as exc:  # 单个进程分析失败不该拖垮整体报告
            errors.append({"pid": p.pid, "error": str(exc)})

    return {
        "generated_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "process_count": len(reports),
        "processes": reports,
        "process_errors": errors,
    }
