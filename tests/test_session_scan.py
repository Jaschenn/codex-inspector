from __future__ import annotations

import json
import sqlite3
import subprocess
from pathlib import Path
from typing import Any, NoReturn

import pytest
from codex_inspector.core.config_merge import find_git_root

from codex_inspector.core.session_scan import (
    index_rollout,
    inspect_session,
    list_sessions,
)


def event(kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {"type": kind, "timestamp": "2026-10-20T12:00:00Z", "payload": payload}


def write_events(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def test_turn_directory_drives_project_agent_scan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("CODEX_INSPECTOR_CACHE_DIR", str(tmp_path / "cache"))
    home, repo = tmp_path / "home", tmp_path / "repo"
    home.mkdir()
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (home / "AGENTS.md").write_text("Global rules", encoding="utf-8")
    (repo / "AGENTS.md").write_text("Project rules", encoding="utf-8")
    first, second = repo / "first", repo / "second"
    first.mkdir()
    second.mkdir()
    (first / "AGENTS.override.md").write_text("First rules", encoding="utf-8")
    (second / "AGENTS.md").write_text("Second rules", encoding="utf-8")
    log = home / "sessions/2026/10/20/rollout-test.jsonl"
    rows = [
        event("session_meta", {"id": "chat", "cwd": str(repo)}),
        event("event_msg", {"type": "task_started", "turn_id": "one"}),
        event("turn_context", {"turn_id": "one", "cwd": str(first)}),
        event(
            "response_item",
            {
                "type": "message",
                "role": "user",
                "content": [{"text": "# AGENTS.md instructions\nRecorded text"}],
            },
        ),
        event("event_msg", {"type": "user_message", "message": "First question"}),
        event("response_item", {"type": "function_call", "name": "read"}),
        event(
            "event_msg",
            {
                "type": "task_complete",
                "turn_id": "one",
                "last_agent_message": "First answer",
            },
        ),
        event("event_msg", {"type": "task_started", "turn_id": "two"}),
        event("turn_context", {"turn_id": "two", "cwd": str(second)}),
    ]
    write_events(log, rows)
    summary = {
        "id": "selection",
        "codex_home": str(home),
        "rollout_path": str(log),
        "cwd": str(repo),
    }
    older, latest = inspect_session(summary, "one"), inspect_session(summary)
    assert older["cwd"] == str(first)
    assert latest["cwd"] == str(second)
    assert older["directory_source"] == "turn_context"
    assert older["selected_turn"]["tool_count"] == 1
    assert older["selected_turn"]["user_preview"] == "First question"
    assert older["selected_turn"]["assistant_preview"] == "First answer"
    assert {doc["path"] for doc in older["inspection"]["agents_chain"]} == {
        str(home / "AGENTS.md"),
        str(repo / "AGENTS.md"),
        str(first / "AGENTS.override.md"),
    }
    assert str(first / "AGENTS.override.md") not in {
        doc["path"] for doc in latest["inspection"]["agents_chain"]
    }
    assert older["recorded_instructions"][0]["text"].endswith("Recorded text")


def test_partial_append_is_retried_without_duplicate_turns(tmp_path: Path) -> None:
    log, cache = tmp_path / "rollout.jsonl", tmp_path / "cache"
    write_events(log, [event("event_msg", {"type": "task_started", "turn_id": "one"})])
    assert len(index_rollout(log, cache)["turns"]) == 1
    line = json.dumps(event("event_msg", {"type": "task_started", "turn_id": "two"}))
    with log.open("a") as file:
        file.write(line[:25])
    assert len(index_rollout(log, cache)["turns"]) == 1
    with log.open("a") as file:
        file.write(line[25:] + "\n")
    assert [turn["id"] for turn in index_rollout(log, cache)["turns"]] == ["one", "two"]
    assert len(index_rollout(log, cache)["turns"]) == 2


def test_log_rewrite_invalidates_cached_turns(tmp_path: Path) -> None:
    log, cache = tmp_path / "rollout.jsonl", tmp_path / "cache"
    write_events(log, [event("event_msg", {"type": "task_started", "turn_id": "old"})])
    index_rollout(log, cache)
    write_events(
        log, [event("event_msg", {"type": "task_started", "turn_id": "new-and-longer"})]
    )
    assert [turn["id"] for turn in index_rollout(log, cache)["turns"]] == [
        "new-and-longer"
    ]


def test_database_catalog_filters_children_and_archives(tmp_path: Path) -> None:
    with sqlite3.connect(tmp_path / "state_5.sqlite") as connection:
        connection.execute(
            "CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, rollout_path TEXT, updated_at INTEGER, archived INTEGER, source TEXT, agent_path TEXT)"
        )
        connection.executemany(
            "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
            [
                ("main", "Main chat", "/repo", "log", 3, 0, "vscode", "/root"),
                ("child", "Child", "/repo", "log", 4, 0, "subagent", "/root/child"),
                ("archived", "Archived", "/repo", "log", 2, 1, "cli", None),
            ],
        )
    assert [session["thread_id"] for session in list_sessions([tmp_path])] == ["main"]
    assert [session["thread_id"] for session in list_sessions([tmp_path], True)] == [
        "main",
        "archived",
    ]


def test_missing_directory_does_not_fall_back_to_inspector_cwd(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("CODEX_INSPECTOR_CACHE_DIR", str(tmp_path / "cache"))
    log, missing = tmp_path / "rollout.jsonl", tmp_path / "deleted-project"
    write_events(
        log,
        [
            event("session_meta", {"id": "chat", "cwd": str(missing)}),
            event("event_msg", {"type": "task_started", "turn_id": "one"}),
        ],
    )
    result = inspect_session(
        {"id": "chat", "codex_home": str(tmp_path), "rollout_path": str(log)}
    )
    assert result["cwd"] == str(missing)
    assert result["directory_source"] == "session_metadata"
    assert result["inspection"] is None
    assert result["error"]


def test_file_catalog_fallback_reads_chat_title(tmp_path: Path) -> None:
    log = tmp_path / "sessions/2026/10/20/rollout-test.jsonl"
    write_events(
        log, [event("session_meta", {"id": "chat", "cwd": "/repo", "source": "cli"})]
    )
    (tmp_path / "session_index.jsonl").write_text(
        json.dumps({"id": "chat", "thread_name": "My chat"}) + "\n", encoding="utf-8"
    )
    assert list_sessions([tmp_path])[0]["title"] == "My chat"


def test_legacy_user_messages_define_turns_without_explicit_boundaries(
    tmp_path: Path,
) -> None:
    log = tmp_path / "rollout.jsonl"
    write_events(
        log,
        [
            event("event_msg", {"type": "user_message", "message": "first"}),
            event(
                "response_item",
                {"type": "message", "role": "user", "content": [{"text": "first"}]},
            ),
            event("event_msg", {"type": "user_message", "message": "second"}),
        ],
    )
    turns = index_rollout(log, tmp_path / "cache")["turns"]
    assert len(turns) == 2
    assert [turn["user_preview"] for turn in turns] == ["first", "second"]


def test_startup_developer_messages_do_not_create_fake_turns(tmp_path: Path) -> None:
    log = tmp_path / "rollout.jsonl"
    write_events(
        log,
        [
            event(
                "response_item",
                {
                    "type": "message",
                    "role": "developer",
                    "content": [{"text": "Host instructions"}],
                },
            ),
            event("event_msg", {"type": "task_started", "turn_id": "real"}),
        ],
    )
    assert [turn["id"] for turn in index_rollout(log, tmp_path / "cache")["turns"]] == [
        "real"
    ]


def test_late_completion_does_not_rewind_current_turn(tmp_path: Path) -> None:
    log = tmp_path / "rollout.jsonl"
    write_events(
        log,
        [
            event("event_msg", {"type": "task_started", "turn_id": "old"}),
            event("event_msg", {"type": "task_started", "turn_id": "new"}),
            event("event_msg", {"type": "task_complete", "turn_id": "old"}),
            event("event_msg", {"type": "user_message", "message": "new question"}),
        ],
    )
    turns = index_rollout(log, tmp_path / "cache")["turns"]
    assert len(turns) == 2
    assert turns[-1]["id"] == "new"
    assert turns[-1]["user_preview"] == "new question"


def test_other_client_records_are_opt_in(tmp_path: Path) -> None:
    with sqlite3.connect(tmp_path / "state_5.sqlite") as connection:
        connection.execute(
            "CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, rollout_path TEXT, updated_at INTEGER, archived INTEGER, source TEXT, originator TEXT)"
        )
        connection.executemany(
            "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
            [
                (
                    "desktop",
                    "Desktop chat",
                    "/repo",
                    "log",
                    1,
                    0,
                    "vscode",
                    "Codex Desktop",
                ),
                ("terminal", "CLI chat", "/repo", "log", 2, 0, "cli", None),
                (
                    "other",
                    "Other client",
                    "/repo",
                    "log",
                    3,
                    0,
                    "vscode",
                    "OtherClient",
                ),
                (
                    "background",
                    "Background task",
                    "/repo",
                    "log",
                    4,
                    0,
                    "exec",
                    "codex_exec",
                ),
            ],
        )
    assert [session["thread_id"] for session in list_sessions([tmp_path])] == [
        "terminal",
        "desktop",
    ]
    assert len(list_sessions([tmp_path], include_other_sources=True)) == 4


def test_git_root_fallback_finds_parent_repository(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    nested = tmp_path / "nested"
    nested.mkdir()

    def unavailable_git(*arguments: object, **keywords: object) -> NoReturn:
        raise FileNotFoundError("git unavailable")

    monkeypatch.setattr(subprocess, "run", unavailable_git)
    assert find_git_root(nested) == str(tmp_path.resolve())


def test_git_root_fallback_supports_worktree_markers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    checkout, metadata = tmp_path / "checkout", tmp_path / "metadata"
    checkout.mkdir()
    metadata.mkdir()
    (metadata / "HEAD").write_text("ref: refs/heads/example\n", encoding="utf-8")
    (checkout / ".git").write_text("gitdir: ../metadata\n", encoding="utf-8")

    def unavailable_git(*arguments: object, **keywords: object) -> NoReturn:
        raise FileNotFoundError("git unavailable")

    monkeypatch.setattr(subprocess, "run", unavailable_git)
    assert find_git_root(checkout) == str(checkout.resolve())
