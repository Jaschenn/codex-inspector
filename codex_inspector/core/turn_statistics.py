"""从日志提取本轮用量与可观测时间线，不推测模型内部的思考时间。"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
from typing import Any

TOKEN_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)
ITEM_CATEGORIES = {
    "reasoning": "reasoning",
    "agentmessage": "output",
    "commandexecution": "command",
    "mcptoolcall": "tool",
    "dynamictoolcall": "tool",
    "filechange": "tool",
}


def timestamp_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return round(parsed.timestamp() * 1000)
    except ValueError:
        return None


def normalized_usage(value: object) -> dict[str, int] | None:
    if not isinstance(value, dict):
        return None
    result = {
        field: value[field]
        for field in TOKEN_FIELDS
        if isinstance(value.get(field), int)
        and not isinstance(value[field], bool)
        and value[field] >= 0
    }
    return result or None


def new_metrics(baseline: dict[str, int] | None) -> dict[str, Any]:
    return {
        "baseline": baseline,
        "reported_usage": None,
        "response_usage": {},
        "legacy_usage": None,
        "legacy_reset": False,
        "intervals": {},
        "pending_calls": {},
        "pending_items": {},
        "reported_duration_ms": None,
        "first_token_ms": None,
        "last_event_ms": None,
    }


def _integer(value: object) -> int | None:
    return (
        value
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0
        else None
    )


def _span(
    metrics: dict[str, Any],
    key: str,
    category: str,
    start: int | None,
    end: int | None,
    label: str,
) -> None:
    if start is not None and end is not None and end > start:
        metrics["intervals"][key] = {
            "category": category,
            "start_ms": start,
            "end_ms": end,
            "label": label,
        }


def consume_statistics(state: dict[str, Any], row: dict[str, Any]) -> None:
    payload = row.get("payload", {})
    if not isinstance(payload, dict):
        return
    metadata = payload.get("internal_chat_message_metadata_passthrough") or {}
    if not isinstance(metadata, dict):
        metadata = {}
    thread_id = payload.get("thread_id")
    own_id = state["metadata"].get("id")
    if thread_id and own_id and thread_id != own_id:
        return
    turn_id = (
        payload.get("turn_id") or metadata.get("turn_id") or state["current_turn_id"]
    )
    turn = next((item for item in state["turns"] if item["id"] == turn_id), None)
    call_id = payload.get("call_id")
    kind = payload.get("type")
    if kind in {"function_call_output", "custom_tool_call_output"} and call_id:
        # 返回可能晚于下一轮开始，必须按 call_id 找回原轮次。
        turn = next(
            (
                item
                for item in state["turns"]
                if call_id in item["metrics"]["pending_calls"]
            ),
            turn,
        )
    event_time = timestamp_ms(row.get("timestamp"))
    if row.get("type") == "token_usage_record":
        total = normalized_usage(payload.get("thread_token_usage"))
        if turn is None:
            if total is not None:
                state["last_thread_usage"] = total
            return
        metrics = turn["metrics"]
        response_id = payload.get("response_id")
        if response_id and response_id in metrics["response_usage"]:
            return  # 重放/重复事件不能倒退或重复累计用量。
        if total is not None:
            state["last_thread_usage"] = total
        usage = normalized_usage(payload.get("usage"))
        if response_id:
            metrics["response_usage"][str(response_id)] = usage or {}
        reported = normalized_usage(payload.get("turn_token_usage"))
        if reported is not None:
            metrics["reported_usage"] = reported
    legacy_regressed = False
    if row.get("type") == "event_msg" and kind == "token_count":
        info = payload.get("info") or {}
        total = (
            normalized_usage(info.get("total_token_usage"))
            if isinstance(info, dict)
            else None
        )
        if total is not None:
            previous = state["last_thread_usage"]
            legacy_regressed = previous is not None and any(
                count < previous[field]
                for field, count in total.items()
                if field in previous
            )
            state["last_thread_usage"] = total
    if turn is None:
        return
    metrics = turn["metrics"]
    if event_time is not None:
        metrics["last_event_ms"] = max(
            event_time, metrics["last_event_ms"] or event_time
        )
    if row.get("type") == "event_msg" and kind == "token_count":
        info = payload.get("info") or {}
        total = (
            normalized_usage(info.get("total_token_usage"))
            if isinstance(info, dict)
            else None
        )
        if total is not None:
            state["last_thread_usage"] = total
            baseline = metrics["baseline"]
            if baseline is not None:
                delta = {
                    field: count - baseline[field]
                    for field, count in total.items()
                    if field in baseline
                }
                if legacy_regressed or any(count < 0 for count in delta.values()):
                    metrics["legacy_reset"] = True
                    metrics["legacy_usage"] = None
                elif not metrics["legacy_reset"]:
                    metrics["legacy_usage"] = delta or None
    if row.get("type") == "event_msg" and kind in {
        "task_complete",
        "turn_complete",
        "turn_completed",
        "turn_aborted",
        "task_aborted",
    }:
        metrics["reported_duration_ms"] = _integer(payload.get("duration_ms"))
        metrics["first_token_ms"] = _integer(payload.get("time_to_first_token_ms"))
    if row.get("type") == "response_item":
        if (
            kind in {"function_call", "custom_tool_call", "local_shell_call"}
            and call_id
            and event_time is not None
        ):
            metrics["pending_calls"][str(call_id)] = {
                "start_ms": event_time,
                "label": str(payload.get("name") or "工具调用"),
            }
        elif kind in {"function_call_output", "custom_tool_call_output"} and call_id:
            pending = metrics["pending_calls"].pop(str(call_id), None)
            if pending:
                _span(
                    metrics,
                    "call:" + str(call_id),
                    "tool_wrapper",
                    pending["start_ms"],
                    event_time,
                    pending["label"],
                )
    if row.get("type") == "event_msg" and kind in {"item_started", "item_completed"}:
        item = payload.get("item") or {}
        if not isinstance(item, dict):
            return
        item_kind = str(item.get("type", "")).replace("_", "").lower()
        category = ITEM_CATEGORIES.get(item_kind)
        item_id = str(item.get("id") or "")
        if not category or not item_id:
            return
        start = _integer(payload.get("started_at_ms"))
        if kind == "item_started":
            metrics["pending_items"][item_id] = (
                start if start is not None else event_time
            )
        else:
            start = (
                start
                if start is not None
                else metrics["pending_items"].pop(item_id, None)
            )
            end = _integer(payload.get("completed_at_ms"))
            if end is None:
                end = event_time
            _span(metrics, "item:" + item_id, category, start, end, item_kind)
    legacy_categories = {"exec_command_begin": "command", "mcp_tool_call_begin": "tool"}
    if row.get("type") == "event_msg" and kind in legacy_categories and call_id:
        metrics["pending_items"]["legacy:" + str(call_id)] = {
            "start_ms": _integer(payload.get("started_at_ms")) or event_time,
            "category": legacy_categories[kind],
        }
    if (
        row.get("type") == "event_msg"
        and kind in {"exec_command_end", "mcp_tool_call_end"}
        and call_id
    ):
        pending = metrics["pending_items"].pop("legacy:" + str(call_id), None)
        if isinstance(pending, dict):
            _span(
                metrics,
                "legacy:" + str(call_id),
                pending["category"],
                pending["start_ms"],
                event_time,
                str(kind),
            )


def usage_summary(metrics: dict[str, Any]) -> dict[str, Any]:
    usage = metrics["reported_usage"]
    source = "turn_record"
    if usage is None:
        responses = list(metrics["response_usage"].values())
        if responses and all("total_tokens" in item for item in responses):
            usage = {
                field: sum(item[field] for item in responses)
                for field in TOKEN_FIELDS
                if all(field in item for item in responses)
            }
            source = "response_records"
        elif metrics["legacy_usage"] is not None:
            usage = metrics["legacy_usage"]
            source = "thread_delta"
        else:
            source = "unavailable"
    return {
        "usage": usage,
        "source": source,
        "response_count": len(metrics["response_usage"]),
        "counter_reset": metrics["legacy_reset"] and usage is None,
    }


def timeline_summary(turn: dict[str, Any]) -> dict[str, Any]:
    metrics = turn["metrics"]
    start = timestamp_ms(turn.get("started_at"))
    end = timestamp_ms(turn.get("completed_at"))
    reported = metrics["reported_duration_ms"]
    source = "boundaries" if end is not None else "partial"
    if end is not None and reported is not None:
        start = end - reported
        source = "reported"
    if start is None:
        return {
            "source": "unavailable",
            "span_duration_ms": 0,
            "segments": [],
            "category_totals": [],
        }
    if end is None:
        end = metrics["last_event_ms"] or start
    duration = max(0, end - start)
    events: dict[int, list[tuple[int, str, int]]] = defaultdict(list)
    intervals = list(metrics["intervals"].values())
    first_token = metrics["first_token_ms"]
    if first_token is not None and first_token > 0:
        intervals.append(
            {
                "category": "first_token_wait",
                "start_ms": start,
                "end_ms": min(end, start + first_token),
            }
        )
    for ordinal, interval in enumerate(intervals):
        left = max(0, interval["start_ms"] - start)
        right = min(duration, interval["end_ms"] - start)
        if right <= left:
            continue
        category = interval["category"]
        events[left].append((ordinal, category, 1))
        events[right].append((ordinal, category, -1))
    active: dict[int, str] = {}
    segments: list[dict[str, Any]] = []
    position = 0
    for boundary in sorted(set(events) | {0, duration}):
        if boundary > position:
            categories = set(active.values())
            # 包装调用覆盖内部运行，不与其重复计时；独立的原生工具仍可与命令重叠。
            if "tool_wrapper" in categories:
                categories.remove("tool_wrapper")
                if not categories.intersection({"command", "tool"}):
                    categories.add("tool")
            if len(categories) > 1:
                categories.discard("first_token_wait")
            category = (
                "overlap" if len(categories) > 1 else next(iter(categories), "unknown")
            )
            components = sorted(categories)
            if (
                segments
                and segments[-1]["category"] == category
                and segments[-1]["components"] == components
            ):
                segments[-1]["end_ms"] = boundary
                segments[-1]["duration_ms"] += boundary - position
            else:
                segments.append(
                    {
                        "start_ms": position,
                        "end_ms": boundary,
                        "duration_ms": boundary - position,
                        "category": category,
                        "components": components,
                    }
                )
        for ordinal, category, direction in events.get(boundary, []):
            if direction == 1:
                active[ordinal] = category
            else:
                active.pop(ordinal, None)
        position = boundary
    totals: dict[str, int] = defaultdict(int)
    for segment in segments:
        totals[segment["category"]] += segment["duration_ms"]
    return {
        "source": source,
        "span_duration_ms": duration,
        "total_duration_ms": duration if turn.get("completed_at") else None,
        "first_token_ms": first_token,
        "segments": segments,
        "category_totals": [
            {"category": category, "duration_ms": value}
            for category, value in sorted(
                totals.items(), key=lambda item: item[1], reverse=True
            )
        ],
        "pending_tool_count": len(metrics["pending_calls"]),
    }


def statistics_for_turn(turn: dict[str, Any]) -> dict[str, Any]:
    return {"tokens": usage_summary(turn["metrics"]), "timing": timeline_summary(turn)}
