"""扫描当前生效的 Skills(不含 Codex 内置的系统 Skill,那部分是编译进二进制的,读不到)。

规则(来自官方文档 + 社区实测,已在对话里跟用户核对过):
    - 从 cwd 向上扫到 git 仓库根,每一层目录都检查 .agents/skills/ 和 .codex/skills/
      (两者等价),但不会向下扫描子目录。
    - 加上全局 ~/.codex/skills/(即 $CODEX_HOME/skills)。
    - 同名 skill 不会被合并去重,两个都会出现——这里如实列出,不擅自去重。
    - ~/.codex/config.toml 里的 [[skills.config]] 可以按路径禁用某个 skill,即使文件还在。
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .models import SkillEntry

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def _parse_frontmatter(text: str) -> tuple[str | None, str | None, str | None]:
    """极简 frontmatter 解析,只取 name / description 两个字段。

    不是完整的 YAML parser——只处理最常见的 `key: value` 单行写法。复杂的多行值
    (用 | 或 > 折叠的)不保证解析正确,这种情况下 description 会显示为 None 并附带提示。
    """
    m = _FRONTMATTER_RE.match(text)
    if not m:
        return None, None, "未找到 --- frontmatter 区块"
    name = None
    desc = None
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith("name:"):
            name = line.split(":", 1)[1].strip().strip('"').strip("'")
        elif line.startswith("description:"):
            desc = line.split(":", 1)[1].strip().strip('"').strip("'")
    return name, desc, None


def _collect_skill_files(skills_dir: Path) -> list[Path]:
    if not skills_dir.is_dir():
        return []
    found = []
    for child in sorted(skills_dir.iterdir()):
        if child.is_dir():
            skill_md = child / "SKILL.md"
            if skill_md.is_file():
                found.append(skill_md)
        elif child.is_symlink():
            # 官方文档提到会跟随符号链接目标
            resolved = child.resolve()
            if resolved.is_dir():
                skill_md = resolved / "SKILL.md"
                if skill_md.is_file():
                    found.append(skill_md)
    return found


def _dirs_cwd_up_to_root(cwd: Path, root: Path | None) -> list[Path]:
    dirs = [cwd]
    if root is None:
        return dirs
    cur = cwd
    root = root.resolve()
    while cur.resolve() != root and root in cur.resolve().parents:
        cur = cur.parent
        dirs.append(cur)
    return dirs


def build_skills_overrides(merged_config: dict[str, Any]) -> dict[str, bool]:
    """从合并配置里取出 [[skills.config]] 的 path -> enabled 映射。"""
    overrides: dict[str, bool] = {}
    skills_cfg = merged_config.get("skills", {})
    entries = skills_cfg.get("config", []) if isinstance(skills_cfg, dict) else []
    if isinstance(entries, list):
        for entry in entries:
            if isinstance(entry, dict) and "path" in entry and "enabled" in entry:
                overrides[str(Path(entry["path"]).expanduser())] = bool(entry["enabled"])
    return overrides


def scan_skills(
    codex_home: Path,
    cwd: Path,
    project_root: str | None,
    merged_config: dict[str, Any],
) -> list[SkillEntry]:
    overrides = build_skills_overrides(merged_config)
    result: list[SkillEntry] = []

    root_path = Path(project_root) if project_root else None
    project_dirs = _dirs_cwd_up_to_root(cwd, root_path)

    def add_entries(base_dirs: list[Path], scope: str, subdir_names: tuple[str, ...]) -> None:
        for d in base_dirs:
            for subdir_name in subdir_names:
                target_dir = d / subdir_name
                skill_files = _collect_skill_files(target_dir)
                for skill_md in skill_files:
                    text = ""
                    parse_error = None
                    try:
                        text = skill_md.read_text(encoding="utf-8")
                    except OSError as exc:
                        parse_error = f"读取失败: {exc}"
                    name = desc = None
                    if text:
                        name, desc, fm_err = _parse_frontmatter(text)
                        parse_error = parse_error or fm_err
                    key = str(skill_md.expanduser())
                    enabled = overrides.get(key, True)
                    disabled_reason = "被 ~/.codex/config.toml 的 skills.config 显式禁用" if not enabled else None
                    result.append(SkillEntry(
                        name=name, description=desc, path=key, scope=scope,
                        enabled=enabled, disabled_reason=disabled_reason,
                        parse_error=parse_error,
                    ))

    # 越靠近 cwd 优先级越高,所以放在列表前面
    add_entries(project_dirs, scope="project", subdir_names=(".agents/skills", ".codex/skills"))
    # 全局 skill 目录是 $CODEX_HOME/skills 本身,不是 $CODEX_HOME/.codex/skills
    add_entries([codex_home], scope="global", subdir_names=("skills",))

    return result
