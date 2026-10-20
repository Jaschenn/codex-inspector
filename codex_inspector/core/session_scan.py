"""只读发现 Codex 聊天，增量索引轮次；缓存写在 Inspector 自己的目录。"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .agents_scan import scan_agents_chain
from .config_merge import build_merged_config, redact_secrets
from .mcp_scan import scan_mcp_servers
from .models import CliOverrides
from .skills_scan import scan_skills
from .turn_statistics import (
    TOKEN_FIELDS,
    consume_statistics,
    new_metrics,
    statistics_for_turn,
)

CATALOG_LIMIT = 300
CACHE_VERSION = 4
PREVIEW_LIMIT = 1800
INTERACTIVE_ORIGINATORS = {
    "Codex Desktop",
    "codex-tui",
    "codex-vscode",
    "codex_vscode",
    "Codex VS Code",
}


def _database(home: Path) -> Path | None:
    candidates = list(home.glob("state_*.sqlite")) + list(
        (home / "sqlite").glob("state_*.sqlite")
    )
    override = os.environ.get("CODEX_SQLITE_HOME")
    if override:
        candidates += list(Path(override).expanduser().glob("state_*.sqlite"))
    valid = [path for path in candidates if path.stem.removeprefix("state_").isdigit()]
    return max(
        valid, key=lambda path: int(path.stem.removeprefix("state_")), default=None
    )


def _is_child(row: dict[str, Any]) -> bool:
    return "subagent" in str(row.get("source", "")).lower() or row.get(
        "agent_path"
    ) not in (None, "", "/root")


def _summary(row: dict[str, Any], home: Path) -> dict[str, Any]:
    thread_id = str(row["id"])
    title = (
        row.get("name") or row.get("title") or row.get("thread_name") or "未命名聊天"
    )
    return {
        "id": f"{home}::{thread_id}",
        "thread_id": thread_id,
        "title": str(title)[:500],
        "cwd": row.get("cwd"),
        "codex_home": str(home),
        "rollout_path": row.get("rollout_path"),
        "updated_at": row.get("updated_at", 0),
        "archived": bool(row.get("archived", False)),
        "source": row.get("source", "unknown"),
        "model": row.get("model"),
        "primary_source": row.get("source") == "cli"
        or (
            row.get("source") == "vscode"
            and (
                "originator" not in row
                or row.get("originator") in INTERACTIVE_ORIGINATORS
            )
        ),
    }


def _catalog_from_database(
    home: Path, include_archived: bool
) -> list[dict[str, Any]] | None:
    path = _database(home)
    if path is None:
        return None
    try:
        with sqlite3.connect(
            path.as_uri() + "?mode=ro", uri=True, timeout=0.5
        ) as connection:
            connection.row_factory = sqlite3.Row
            available = {
                row[1] for row in connection.execute("PRAGMA table_info(threads)")
            }
            columns = [
                name
                for name in (
                    "id",
                    "name",
                    "title",
                    "cwd",
                    "source",
                    "model",
                    "rollout_path",
                    "updated_at",
                    "archived",
                    "agent_path",
                    "originator",
                )
                if name in available
            ]
            rows = connection.execute(
                "SELECT " + ",".join(columns) + " FROM threads ORDER BY updated_at DESC"
            ).fetchall()
        return [
            _summary(dict(row), home)
            for row in rows
            if not _is_child(dict(row)) and (include_archived or not row["archived"])
        ]
    except (sqlite3.Error, OSError, KeyError):
        return None


def _catalog_from_files(
    home: Path, include_archived: bool, include_other_sources: bool = False
) -> list[dict[str, Any]]:
    names: dict[str, str] = {}
    index = home / "session_index.jsonl"
    try:
        for line in index.read_text(encoding="utf-8").splitlines():
            try:
                item = json.loads(line)
                if isinstance(item, dict) and item.get("id"):
                    names[str(item["id"])] = str(
                        item.get("thread_name") or "未命名聊天"
                    )
            except json.JSONDecodeError:
                continue
    except OSError:
        pass
    paths = list((home / "sessions").rglob("rollout-*.jsonl"))
    if include_archived:
        paths += list((home / "archived_sessions").rglob("rollout-*.jsonl"))
    result = []
    for path in sorted(
        paths,
        key=lambda file: file.stat().st_mtime if file.exists() else 0,
        reverse=True,
    ):
        try:
            with path.open("rb") as file:
                first = json.loads(file.readline(1024 * 1024))
            if first.get("type") != "session_meta":
                continue
            metadata = first.get("payload", {})
            if (
                not isinstance(metadata, dict)
                or not metadata.get("id")
                or _is_child(metadata)
            ):
                continue
            metadata = dict(metadata)
            metadata.update(
                rollout_path=str(path),
                title=names.get(str(metadata["id"])),
                updated_at=path.stat().st_mtime,
                archived="archived_sessions" in path.parts,
            )
            summary = _summary(metadata, home)
            if not include_other_sources and not summary["primary_source"]:
                continue
            result.append(summary)
            if len(result) >= CATALOG_LIMIT:
                break
        except (OSError, ValueError, AttributeError):
            continue
    return result


def list_sessions(
    homes: list[Path],
    include_archived: bool = False,
    include_other_sources: bool = False,
) -> list[dict[str, Any]]:
    result = []
    for home in dict.fromkeys(path.expanduser().resolve() for path in homes):
        items = _catalog_from_database(home, include_archived)
        result.extend(
            items
            if items is not None
            else _catalog_from_files(home, include_archived, include_other_sources)
        )
    if not include_other_sources:
        result = [session for session in result if session["primary_source"]]
    return sorted(result, key=lambda row: row["updated_at"] or 0, reverse=True)[
        :CATALOG_LIMIT
    ]


def _empty_index() -> dict[str, Any]:
    return {
        "version": CACHE_VERSION,
        "offset": 0,
        "inode": None,
        "metadata": {},
        "turns": [],
        "instructions": {},
        "active_instructions": [],
        "current_turn_id": None,
        "explicit_boundaries": False,
        "last_thread_usage": None,
    }


def _new_turn(
    state: dict[str, Any], turn_id: str, timestamp: str | None
) -> dict[str, Any]:
    existing = next((turn for turn in state["turns"] if turn["id"] == turn_id), None)
    if existing is not None:
        # 旧轮次的异步结束事件不能把后续无 turn_id 的记录重新归到旧轮次。
        if existing is state["turns"][-1]:
            state["current_turn_id"] = turn_id
        return existing
    baseline = state["last_thread_usage"]
    if (
        baseline is None
        and not state["turns"]
        and state["metadata"].get("id")
        and not state["metadata"].get("forked_from_id")
    ):
        baseline = {field: 0 for field in TOKEN_FIELDS}
    turn = {
        "id": turn_id,
        "number": len(state["turns"]) + 1,
        "started_at": timestamp,
        "completed_at": None,
        "status": "in_progress",
        "cwd": None,
        "model": None,
        "user_preview": "",
        "assistant_preview": "",
        "tool_count": 0,
        "instruction_ids": list(state["active_instructions"]),
        "instruction_sources": [],
        "metrics": new_metrics(dict(baseline) if baseline is not None else None),
    }
    state["turns"].append(turn)
    state["current_turn_id"] = turn_id
    return turn


def _turn(
    state: dict[str, Any], payload: dict[str, Any], timestamp: str | None
) -> dict[str, Any]:
    turn_id = (
        payload.get("turn_id")
        or state["current_turn_id"]
        or f"legacy-turn-{len(state['turns']) + 1}"
    )
    return _new_turn(state, str(turn_id), timestamp)


def _record_instruction(state: dict[str, Any], turn: dict[str, Any], text: str) -> None:
    key = hashlib.sha256(text.encode()).hexdigest()
    if key not in state["instructions"]:
        state["instructions"][key] = {
            "id": key,
            "title": text.splitlines()[0][:200] if text else "指令文本",
            "text": text[:128000],
            "truncated": len(text) > 128000,
            "first_turn_number": turn["number"],
        }
    if key not in state["active_instructions"]:
        state["active_instructions"].append(key)
    if key not in turn["instruction_ids"]:
        turn["instruction_ids"].append(key)


def _append_preview(turn: dict[str, Any], text: str) -> None:
    if text and text[:PREVIEW_LIMIT] not in turn["user_preview"]:
        turn["user_preview"] = (
            turn["user_preview"] + ("\n\n" if turn["user_preview"] else "") + text
        )[:PREVIEW_LIMIT]


def _consume(state: dict[str, Any], row: dict[str, Any]) -> None:
    payload = row.get("payload", {})
    if not isinstance(payload, dict):
        return
    timestamp = row.get("timestamp")
    kind = payload.get("type")
    if row.get("type") == "session_meta":
        state["metadata"] = {
            key: payload.get(key)
            for key in ("id", "cwd", "model", "source", "originator", "forked_from_id")
        }
        return
    if row.get("type") == "event_msg" and kind in {"task_started", "turn_started"}:
        state["explicit_boundaries"] = True
        _turn(state, payload, timestamp)
        return
    if row.get("type") == "turn_context":
        turn = _turn(state, payload, timestamp)
        turn["cwd"] = payload.get("cwd") or turn["cwd"]
        turn["model"] = payload.get("model") or turn["model"]
        sources = payload.get(
            "instruction_sources", payload.get("instructionSources", [])
        )
        if isinstance(sources, list):
            turn["instruction_sources"] = [
                path for path in sources if isinstance(path, str)
            ]
        return
    if row.get("type") == "compacted":
        # 压缩后不能假设旧指令原文仍在上下文中；保留历史记录，停止自动沿用。
        state["active_instructions"] = []
        return
    if row.get("type") == "event_msg" and kind in {
        "task_complete",
        "turn_complete",
        "turn_completed",
        "turn_aborted",
        "task_aborted",
    }:
        turn = _turn(state, payload, timestamp)
        turn["completed_at"] = timestamp
        turn["status"] = "interrupted" if "aborted" in str(kind) else "completed"
        if payload.get("last_agent_message"):
            turn["assistant_preview"] = str(payload["last_agent_message"])[
                :PREVIEW_LIMIT
            ]
        return
    if row.get("type") == "event_msg" and kind == "user_message":
        # 老版本没有 task_started：每条用户消息可以作为一轮的起点。
        current = next(
            (turn for turn in state["turns"] if turn["id"] == state["current_turn_id"]),
            None,
        )
        message = str(payload.get("message", ""))
        if current and (
            current["status"] != "in_progress"
            or (
                not state["explicit_boundaries"]
                and current["user_preview"]
                and message[:PREVIEW_LIMIT] not in current["user_preview"]
            )
        ):
            state["current_turn_id"] = None
        turn = _turn(state, payload, timestamp)
        _append_preview(turn, message)
        return
    if row.get("type") != "response_item":
        return
    if kind not in {"message", "function_call", "custom_tool_call", "local_shell_call"}:
        return
    metadata = payload.get("internal_chat_message_metadata_passthrough") or {}
    if not isinstance(metadata, dict):
        metadata = {}
    if (
        state["current_turn_id"] is None
        and not metadata.get("turn_id")
        and payload.get("role") == "developer"
    ):
        return
    turn = _turn(state, metadata, timestamp)
    if kind in {"function_call", "custom_tool_call", "local_shell_call"}:
        turn["tool_count"] += 1
    if kind != "message":
        return
    content = payload.get("content", [])
    if not isinstance(content, list):
        return
    kinds = metadata.get("content_item_kinds") or []
    for index, item in enumerate(content):
        if not isinstance(item, dict) or not isinstance(item.get("text"), str):
            continue
        text = item["text"]
        item_kind = kinds[index] if index < len(kinds) else ""
        if "agents_md" in str(item_kind) or text.startswith("# AGENTS.md instructions"):
            _record_instruction(state, turn, text)
        elif (
            payload.get("role") == "user"
            and not str(item_kind).startswith("environments.")
            and not text.startswith("<environment_context>")
        ):
            _append_preview(turn, text)
        elif payload.get("role") == "assistant" and payload.get("phase") in {
            "final_answer",
            "final",
            None,
        }:
            turn["assistant_preview"] = text[:PREVIEW_LIMIT]


def index_rollout(path: Path, cache_root: Path | None = None) -> dict[str, Any]:
    root = cache_root or Path(
        os.environ.get(
            "CODEX_INSPECTOR_CACHE_DIR",
            str(Path.home() / "Library/Caches/CodexInspector"),
        )
    )
    cache = root / (hashlib.sha256(str(path).encode()).hexdigest() + ".json")
    state = _empty_index()
    stat = path.stat()
    try:
        cached = json.loads(cache.read_text(encoding="utf-8"))
        if (
            cached.get("version") == CACHE_VERSION
            and cached.get("inode") == stat.st_ino
            and cached.get("offset", 0) <= stat.st_size
            and cached.get("mtime_ns", 0) <= stat.st_mtime_ns
        ):
            # 同尺寸但内容重写时重新索引，避免保留被回退的轮次。
            if (
                cached["offset"] != stat.st_size
                or cached.get("mtime_ns") == stat.st_mtime_ns
            ):
                with path.open("rb") as current_file:
                    current_file.seek(max(0, cached["offset"] - 128))
                    boundary = current_file.read(min(128, cached["offset"]))
                if cached.get("boundary_hash") == hashlib.sha256(boundary).hexdigest():
                    state = cached
    except (OSError, ValueError, AttributeError, KeyError):
        pass
    initial_offset = state["offset"]
    with path.open("rb") as file:
        file.seek(initial_offset)
        while True:
            position = file.tell()
            line = file.readline()
            if not line:
                break
            if not line.endswith(b"\n"):
                # 正在追加的最后一行不能当成坏日志跳过；下次从这里继续读。
                state["offset"] = position
                break
            try:
                row = json.loads(line)
                if isinstance(row, dict):
                    _consume(state, row)
                    consume_statistics(state, row)
            except (ValueError, TypeError, KeyError):
                state["malformed_lines"] = state.get("malformed_lines", 0) + 1
            state["offset"] = file.tell()
    state["inode"] = stat.st_ino
    state["mtime_ns"] = stat.st_mtime_ns
    with path.open("rb") as current_file:
        current_file.seek(max(0, state["offset"] - 128))
        boundary = current_file.read(min(128, state["offset"]))
        state["boundary_hash"] = hashlib.sha256(boundary).hexdigest()
    if state["offset"] != initial_offset or not cache.exists():
        try:
            root.mkdir(parents=True, exist_ok=True)
            temporary = cache.with_suffix(f".{os.getpid()}.tmp")
            temporary.write_text(
                json.dumps(state, ensure_ascii=False), encoding="utf-8"
            )
            temporary.chmod(0o600)
            temporary.replace(cache)
        except OSError:
            pass  # 缓存失败不影响只读检查。
    return state


def inspect_session(
    summary: dict[str, Any], turn_id: str | None = None
) -> dict[str, Any]:
    result = dict(summary)
    result["requested_turn_id"] = turn_id
    result["turns"] = []
    result["selected_turn"] = None
    result["inspection"] = None
    home = Path(summary["codex_home"])
    raw_path = summary.get("rollout_path")
    if not raw_path:
        result["error"] = "这条聊天记录没有可读取的本地日志路径。"
        return result
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        path = home / path
    try:
        state = index_rollout(path)
    except (OSError, ValueError):
        result["error"] = "聊天日志无法读取；文件可能已移动、删除或位于其他环境。"
        return result
    turns = state["turns"]
    result["turns"] = [
        {
            key: turn[key]
            for key in (
                "id",
                "number",
                "started_at",
                "completed_at",
                "status",
                "cwd",
                "model",
                "user_preview",
                "tool_count",
            )
        }
        for turn in turns
    ]
    selected = (
        next((turn for turn in turns if turn["id"] == turn_id), None)
        if turn_id
        else (turns[-1] if turns else None)
    )
    if selected is None:
        result["error"] = (
            "该轮次已不在日志中，请切换到最新轮次。"
            if turn_id
            else "聊天尚未记录可检查的轮次。"
        )
        return result
    result["selected_turn"] = dict(selected)
    result["selected_turn"].pop("metrics", None)
    result["selected_turn"]["statistics"] = statistics_for_turn(selected)
    result["recorded_instructions"] = [
        state["instructions"][key]
        for key in selected["instruction_ids"]
        if key in state["instructions"]
    ]
    cwd = selected.get("cwd") or state["metadata"].get("cwd") or summary.get("cwd")
    result["directory_source"] = (
        "turn_context" if selected.get("cwd") else "session_metadata"
    )
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        result["error"] = "记录中没有可用于本机检查的绝对工作目录。"
        return result
    directory = Path(cwd)
    result["cwd"] = cwd
    if not directory.is_dir():
        result["error"] = "该轮次的工作目录在本机不存在，仍可查看轮次与指令记录。"
        return result
    merged, layers, root, is_git, trust = build_merged_config(home, directory, None, [])
    result["inspection"] = {
        "cwd": cwd,
        "cwd_error": None,
        "codex_home": str(home),
        "project_root": root,
        "is_git_repo": is_git,
        "trust_level": trust,
        "config_layers": [asdict(layer) for layer in layers],
        "agents_chain": [
            asdict(doc) for doc in scan_agents_chain(home, directory, root)
        ],
        "skills": [
            asdict(skill) for skill in scan_skills(home, directory, root, merged)
        ],
        "mcp_servers": [
            asdict(server) for server in scan_mcp_servers(redact_secrets(merged))
        ],
        "merged_config": redact_secrets(merged),
        "cli_overrides": asdict(CliOverrides()),
        "warnings": [],
    }
    if result["directory_source"] == "session_metadata":
        result["inspection"]["warnings"].append(
            "本轮未记录 cwd；当前使用会话元数据中的目录。"
        )
    if state.get("malformed_lines"):
        result["inspection"]["warnings"].append(
            f"日志中有 {state['malformed_lines']} 条无法解析的完整记录，结果可能不完整。"
        )
    return result
