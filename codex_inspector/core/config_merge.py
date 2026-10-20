"""按 Codex 官方文档的优先级还原"当前生效配置"。

优先级(从低到高):
    内置默认值 < 系统级 /etc/codex/config.toml < 全局 ~/.codex/config.toml
    < 项目级 .codex/config.toml(仓库根 -> cwd,越靠近 cwd 越后覆盖,且仅 trusted 项目生效)
    < profile 文件 ~/.codex/<profile>.config.toml < CLI 的 `-c key=value`

合并是"按 key 覆盖",不是整份替换——这里用递归 dict merge 实现,和官方文档描述的行为
(“A project config that sets only model does not discard your user config's sandbox_mode”)
保持一致。
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from .models import ConfigLayer
from .toml_compat import load_toml
from .trust import get_trust_level

SYSTEM_CONFIG_PATH = Path("/etc/codex/config.toml")

# 会被判定为"敏感"、展示时打码的 key 关键词(不区分大小写,子串匹配)
_SECRET_KEY_HINTS = ("key", "token", "secret", "password", "auth", "credential")


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result


def redact_secrets(value: Any, key_hint: str = "") -> Any:
    """递归地把看起来像密钥/token 的字符串值替换成 ***redacted***,方便安全地分享报告。"""
    if isinstance(value, dict):
        # 认证头和环境变量可使用任意名称，不能只靠 key/token 等关键词判断。
        # 隐藏这些容器的值，仍保留字段名称供用户检查配置结构。
        if key_hint.lower() in {"http_headers", "headers", "env"}:
            return {k: redact_secret_container(v) for k, v in value.items()}
        return {k: redact_secrets(v, key_hint=k) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_secrets(v, key_hint=key_hint) for v in value]
    if isinstance(value, str) and any(h in key_hint.lower() for h in _SECRET_KEY_HINTS):
        return "***redacted***"
    return value


def redact_secret_container(value: Any) -> Any:
    """遮蔽任意命名的认证值，递归保留配置结构。"""
    if isinstance(value, dict):
        return {k: redact_secret_container(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_secret_container(v) for v in value]
    if value is not None:
        return "***redacted***"
    return None


def find_git_root(cwd: Path) -> str | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    # GUI 启动环境里的 Git 可能不可用；仅通过本地仓库标记回退，不依赖 shell 配置。
    if not cwd.is_dir():
        return None
    directory = cwd.resolve()
    for candidate in (directory, *directory.parents):
        marker = candidate / ".git"
        if marker.is_dir() and (marker / "HEAD").is_file():
            return str(candidate)
        if marker.is_file():
            try:
                with marker.open(encoding="utf-8") as file:
                    pointer = file.readline(16384).strip()
                if pointer.startswith("gitdir:"):
                    git_dir = Path(pointer.removeprefix("gitdir:").strip())
                    if not git_dir.is_absolute():
                        git_dir = candidate / git_dir
                    if (git_dir / "HEAD").is_file():
                        return str(candidate)
            except (OSError, UnicodeError):
                continue
    return None


def _dirs_from_root_to_cwd(root: Path, cwd: Path) -> list[Path]:
    """返回从 root 到 cwd(含两端)的目录链,root 在前,cwd 在后。"""
    try:
        rel = cwd.relative_to(root)
    except ValueError:
        return [cwd]
    dirs = [root]
    acc = root
    for part in rel.parts:
        acc = acc / part
        dirs.append(acc)
    return dirs


def build_merged_config(
    codex_home: Path,
    cwd: Path,
    profile: str | None,
    cli_overrides: list[tuple[str, Any]],
) -> tuple[dict[str, Any], list[ConfigLayer], str | None, bool, str]:
    """返回 (merged_config, layers_used, project_root, is_git_repo, trust_level)。"""
    layers: list[ConfigLayer] = []
    merged: dict[str, Any] = {}

    # 1. 系统级(macOS 上基本不存在,但还是尝试一下)
    sys_cfg, sys_err = load_toml(SYSTEM_CONFIG_PATH)
    layers.append(
        ConfigLayer(
            kind="system",
            path=str(SYSTEM_CONFIG_PATH),
            exists=SYSTEM_CONFIG_PATH.is_file(),
            applied=bool(sys_cfg),
            parse_error=sys_err,
        )
    )
    merged = deep_merge(merged, sys_cfg)

    # 2. 全局
    global_path = codex_home / "config.toml"
    global_cfg, global_err = load_toml(global_path)
    layers.append(
        ConfigLayer(
            kind="global",
            path=str(global_path),
            exists=global_path.is_file(),
            applied=bool(global_cfg),
            parse_error=global_err,
        )
    )
    merged = deep_merge(merged, global_cfg)

    # 3. 项目层(仅 trusted 项目生效)
    project_root = find_git_root(cwd)
    is_git_repo = project_root is not None
    root_path = Path(project_root) if project_root else cwd
    trust_level = get_trust_level(global_cfg, str(root_path) if is_git_repo else None)

    project_applied = trust_level == "trusted"
    for d in _dirs_from_root_to_cwd(root_path, cwd):
        layer_path = d / ".codex" / "config.toml"
        cfg, err = load_toml(layer_path)
        exists = layer_path.is_file()
        applied = project_applied and bool(cfg)
        layers.append(
            ConfigLayer(
                kind="project",
                path=str(layer_path),
                exists=exists,
                applied=applied,
                skip_reason=None
                if project_applied
                else ("项目未标记为 trusted,该层被跳过" if exists else None),
                parse_error=err,
            )
        )
        if applied:
            merged = deep_merge(merged, cfg)

    # 4. profile 文件
    if profile:
        profile_path = codex_home / f"{profile}.config.toml"
        prof_cfg, prof_err = load_toml(profile_path)
        layers.append(
            ConfigLayer(
                kind="profile",
                path=str(profile_path),
                exists=profile_path.is_file(),
                applied=bool(prof_cfg),
                parse_error=prof_err,
            )
        )
        merged = deep_merge(merged, prof_cfg)

    # 5. CLI -c 覆盖(点号路径,比如 "model" 或 "sandbox_mode")
    if cli_overrides:
        cli_dict: dict[str, Any] = {}
        for dotted_key, value in cli_overrides:
            parts = dotted_key.split(".")
            node = cli_dict
            for p in parts[:-1]:
                node = node.setdefault(p, {})
            node[parts[-1]] = value
        layers.append(ConfigLayer(kind="cli", path=None, exists=True, applied=True))
        merged = deep_merge(merged, cli_dict)

    return (
        merged,
        layers,
        (str(root_path) if is_git_repo else None),
        is_git_repo,
        trust_level,
    )
