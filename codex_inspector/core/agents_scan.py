"""还原 AGENTS.md 的加载链:全局一份 + 项目根到 cwd 逐层一份。

注意:社区里有反馈说 AGENTS.md / rules 在某些版本里似乎不完全受 project trust 门禁
(参见 openai/codex#10389 里提到的 "I believe I observed .codex/rules were being used
still"),行为在不同版本间可能有出入。这里选择"不管 trust 状态,只要文件存在就列出",
更保守也更透明——把"文件是否存在"和"是否真的会被读取"分开呈现,而不是替用户下结论。
"""
from __future__ import annotations

from pathlib import Path

from .models import AgentsDoc


def _first_existing(dir_path: Path) -> AgentsDoc | None:
    for fname in ("AGENTS.override.md", "AGENTS.md"):
        p = dir_path / fname
        if p.is_file():
            return AgentsDoc(path=str(p), exists=True, scope="")
    return None


def scan_agents_chain(codex_home: Path, cwd: Path, project_root: str | None) -> list[AgentsDoc]:
    chain: list[AgentsDoc] = []

    global_doc = _first_existing(codex_home)
    if global_doc:
        global_doc.scope = "global"
        chain.append(global_doc)

    root_path = Path(project_root) if project_root else cwd
    dirs: list[Path] = [root_path]
    if project_root:
        cur = cwd
        target = root_path.resolve()
        collected = []
        while cur.resolve() != target:
            collected.append(cur)
            if cur.parent == cur:
                break
            cur = cur.parent
        dirs = [root_path] + list(reversed(collected))
    else:
        dirs = [cwd]

    for d in dirs:
        doc = _first_existing(d)
        if doc:
            doc.scope = "project"
            chain.append(doc)

    return chain
