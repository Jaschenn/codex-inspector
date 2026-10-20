from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from codex_inspector.core.session_scan import index_rollout
from codex_inspector.core.turn_statistics import statistics_for_turn

BASE = 1792497960000


def event(offset: int, kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "timestamp": datetime.fromtimestamp(
            (BASE + offset) / 1000, timezone.utc
        ).isoformat(),
        "type": kind,
        "payload": payload,
    }


def index_events(tmp_path: Path, rows: list[dict[str, Any]]) -> dict[str, Any]:
    path = tmp_path / "rollout.jsonl"
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    return index_rollout(path, tmp_path / "cache")


def start_events() -> list[dict[str, Any]]:
    return [
        event(0, "session_meta", {"id": "chat"}),
        event(0, "event_msg", {"type": "task_started", "turn_id": "t"}),
    ]


def usage_record(
    offset: int, response: str, amount: int, cumulative: int
) -> dict[str, Any]:
    return event(
        offset,
        "token_usage_record",
        {
            "thread_id": "chat",
            "turn_id": "t",
            "response_id": response,
            "usage": {
                "input_tokens": amount,
                "output_tokens": 10,
                "total_tokens": amount + 10,
            },
            "turn_token_usage": {
                "input_tokens": cumulative,
                "cached_input_tokens": 20,
                "output_tokens": 20,
                "reasoning_output_tokens": 5,
                "total_tokens": cumulative + 20,
            },
            "thread_token_usage": {
                "input_tokens": cumulative,
                "output_tokens": 20,
                "total_tokens": cumulative + 20,
            },
        },
    )


def item(kind: str, identifier: str, left: int, right: int) -> dict[str, Any]:
    return event(
        right,
        "event_msg",
        {
            "type": "item_completed",
            "turn_id": "t",
            "item": {"type": kind, "id": identifier},
            "started_at_ms": BASE + left,
            "completed_at_ms": BASE + right,
        },
    )


def finish(offset: int) -> dict[str, Any]:
    return event(
        offset,
        "event_msg",
        {"type": "task_complete", "turn_id": "t", "duration_ms": offset},
    )


def test_turn_snapshot_wins_and_replayed_response_is_not_counted_twice(
    tmp_path: Path,
) -> None:
    state = index_events(
        tmp_path,
        start_events()
        + [
            usage_record(100, "one", 100, 100),
            usage_record(200, "two", 200, 300),
            usage_record(300, "one", 100, 100),
            finish(500),
        ],
    )
    tokens = statistics_for_turn(state["turns"][0])["tokens"]
    assert tokens["source"] == "turn_record"
    assert tokens["response_count"] == 2
    assert tokens["usage"]["total_tokens"] == 320
    assert tokens["usage"]["input_tokens"] == 300
    assert tokens["usage"]["cached_input_tokens"] == 20
    assert tokens["usage"]["reasoning_output_tokens"] == 5


def test_legacy_cumulative_values_are_differenced_per_turn(tmp_path: Path) -> None:
    rows = start_events() + [
        event(
            100,
            "event_msg",
            {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 100,
                        "output_tokens": 10,
                        "total_tokens": 110,
                    }
                },
            },
        ),
        finish(200),
        event(300, "event_msg", {"type": "task_started", "turn_id": "second"}),
        event(
            400,
            "event_msg",
            {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 150,
                        "output_tokens": 20,
                        "total_tokens": 170,
                    }
                },
            },
        ),
    ]
    state = index_events(tmp_path, rows)
    assert (
        statistics_for_turn(state["turns"][0])["tokens"]["usage"]["total_tokens"] == 110
    )
    second = statistics_for_turn(state["turns"][1])["tokens"]
    assert second["source"] == "thread_delta"
    assert second["usage"]["total_tokens"] == 60


def test_legacy_counter_reset_is_reported_as_unavailable(tmp_path: Path) -> None:
    rows = start_events() + [
        event(
            100,
            "event_msg",
            {
                "type": "token_count",
                "info": {"total_token_usage": {"total_tokens": 100}},
            },
        ),
        event(
            200,
            "event_msg",
            {
                "type": "token_count",
                "info": {"total_token_usage": {"total_tokens": 50}},
            },
        ),
    ]
    tokens = statistics_for_turn(index_events(tmp_path, rows)["turns"][0])["tokens"]
    assert tokens["usage"] is None
    assert tokens["counter_reset"] is True


def test_timeline_preserves_unknown_time_and_removes_nested_tool_double_counting(
    tmp_path: Path,
) -> None:
    rows = start_events() + [
        item("Reasoning", "reason", 1000, 1500),
        event(
            2000,
            "response_item",
            {"type": "custom_tool_call", "call_id": "call", "name": "exec"},
        ),
        item("CommandExecution", "command", 2200, 3000),
        event(
            3100,
            "response_item",
            {"type": "custom_tool_call_output", "call_id": "call"},
        ),
        item("AgentMessage", "reply", 4000, 4900),
        event(
            5000,
            "event_msg",
            {
                "type": "task_complete",
                "turn_id": "t",
                "duration_ms": 5000,
                "time_to_first_token_ms": 1000,
            },
        ),
    ]
    timing = statistics_for_turn(index_events(tmp_path, rows)["turns"][0])["timing"]
    totals = {row["category"]: row["duration_ms"] for row in timing["category_totals"]}
    assert timing["total_duration_ms"] == 5000
    assert sum(totals.values()) == 5000
    assert totals == {
        "first_token_wait": 1000,
        "reasoning": 500,
        "command": 800,
        "tool": 300,
        "output": 900,
        "unknown": 1500,
    }
    assert timing["segments"][0]["start_ms"] == 0
    assert timing["segments"][-1]["end_ms"] == 5000


def test_independent_overlap_is_a_single_wall_clock_segment(tmp_path: Path) -> None:
    rows = start_events() + [
        item("CommandExecution", "command", 1000, 4000),
        item("McpToolCall", "mcp", 2000, 3000),
        item("AgentMessage", "reply", 2500, 3500),
        finish(5000),
    ]
    timing = statistics_for_turn(index_events(tmp_path, rows)["turns"][0])["timing"]
    totals = {row["category"]: row["duration_ms"] for row in timing["category_totals"]}
    assert totals == {"command": 1500, "overlap": 1500, "unknown": 2000}
    assert sum(segment["duration_ms"] for segment in timing["segments"]) == 5000


def test_absent_usage_is_not_shown_as_zero_and_open_turn_is_partial(
    tmp_path: Path,
) -> None:
    rows = start_events() + [item("CommandExecution", "command", 100, 900)]
    result = statistics_for_turn(index_events(tmp_path, rows)["turns"][0])
    assert result["tokens"]["usage"] is None
    assert result["timing"]["source"] == "partial"
    assert result["timing"]["total_duration_ms"] is None
    assert result["timing"]["span_duration_ms"] == 900


def test_child_thread_usage_is_not_attributed_to_parent(tmp_path: Path) -> None:
    record = usage_record(100, "child", 100, 100)
    record["payload"]["thread_id"] = "child-thread"
    result = statistics_for_turn(
        index_events(tmp_path, start_events() + [record])["turns"][0]
    )
    assert result["tokens"]["usage"] is None


def test_response_records_are_deduplicated_without_turn_snapshot(
    tmp_path: Path,
) -> None:
    first, second = (
        usage_record(100, "one", 100, 100),
        usage_record(200, "two", 200, 300),
    )
    del first["payload"]["turn_token_usage"]
    del second["payload"]["turn_token_usage"]
    tokens = statistics_for_turn(
        index_events(tmp_path, start_events() + [first, second, first, finish(500)])[
            "turns"
        ][0]
    )["tokens"]
    assert tokens["source"] == "response_records"
    assert tokens["usage"]["total_tokens"] == 320


def test_legacy_checkpoint_before_turn_is_used_as_baseline(tmp_path: Path) -> None:
    checkpoint = event(
        0,
        "event_msg",
        {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 500}}},
    )
    later = event(
        100,
        "event_msg",
        {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 610}}},
    )
    tokens = statistics_for_turn(
        index_events(
            tmp_path, [start_events()[0], checkpoint, start_events()[1], later]
        )["turns"][0]
    )["tokens"]
    assert tokens["usage"]["total_tokens"] == 110


def test_unfinished_tool_call_does_not_invent_return_time(tmp_path: Path) -> None:
    rows = start_events() + [
        event(
            100,
            "response_item",
            {"type": "custom_tool_call", "call_id": "pending", "name": "exec"},
        ),
        finish(5000),
    ]
    timing = statistics_for_turn(index_events(tmp_path, rows)["turns"][0])["timing"]
    assert timing["pending_tool_count"] == 1
    assert timing["category_totals"] == [{"category": "unknown", "duration_ms": 5000}]


def test_activity_intervals_are_clipped_to_turn_boundaries(tmp_path: Path) -> None:
    rows = start_events() + [
        item("CommandExecution", "long-command", -500, 6000),
        finish(5000),
    ]
    timing = statistics_for_turn(index_events(tmp_path, rows)["turns"][0])["timing"]
    assert timing["category_totals"] == [{"category": "command", "duration_ms": 5000}]
