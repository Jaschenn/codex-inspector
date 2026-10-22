use crate::{
    sessions::{State, Turn},
    util,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub const TOKEN_FIELDS: [&str; 6] = [
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
];
type Usage = BTreeMap<String, u64>;
fn usage(value: &Value) -> Option<Usage> {
    let result: Usage = TOKEN_FIELDS
        .iter()
        .filter_map(|key| value[*key].as_u64().map(|v| ((*key).into(), v)))
        .collect();
    if result.is_empty() {
        None
    } else {
        Some(result)
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Metrics {
    pub baseline: Option<Usage>,
    reported_usage: Option<Usage>,
    response_usage: BTreeMap<String, Usage>,
    legacy_usage: Option<Usage>,
    legacy_reset: bool,
    intervals: BTreeMap<String, Interval>,
    pending_calls: BTreeMap<String, PendingCall>,
    pending_items: BTreeMap<String, Option<i64>>,
    pending_legacy: BTreeMap<String, (Option<i64>, String)>,
    // Endpoint gaps locate a phase, not its cause. Keep them separate from
    // measured execution/streaming spans so they can never mask direct evidence.
    model_windows: BTreeMap<String, (i64, i64)>,
    ready_points: BTreeMap<String, i64>,
    zero_duration_items: BTreeSet<String>,
    unsupported_items: BTreeMap<String, String>,
    reported_duration_ms: Option<i64>,
    first_token_ms: Option<i64>,
    last_event_ms: Option<i64>,
}
impl Metrics {
    pub fn new(baseline: Option<Usage>) -> Self {
        Self {
            baseline,
            ..Self::default()
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
struct Interval {
    category: String,
    start_ms: i64,
    end_ms: i64,
}
#[derive(Clone, Serialize, Deserialize)]
struct PendingCall {
    start_ms: i64,
}
fn span(metrics: &mut Metrics, key: String, category: &str, start: Option<i64>, end: Option<i64>) {
    if let (Some(start_ms), Some(end_ms)) = (start, end) {
        if end_ms > start_ms {
            metrics.intervals.insert(
                key,
                Interval {
                    category: category.into(),
                    start_ms,
                    end_ms,
                },
            );
        }
    }
}
fn integer(value: &Value) -> Option<i64> {
    value.as_i64().filter(|v| *v >= 0)
}
fn completed(kind: &str) -> bool {
    [
        "task_complete",
        "turn_complete",
        "turn_completed",
        "turn_aborted",
        "task_aborted",
    ]
    .contains(&kind)
}

fn item_category(item: &Value) -> Option<&'static str> {
    match util::text(&item["type"])
        .replace('_', "")
        .to_lowercase()
        .as_str()
    {
        "reasoning" => Some("reasoning"),
        "agentmessage" => Some("output"),
        "commandexecution" => Some("command"),
        "mcptoolcall" | "dynamictoolcall" | "filechange" | "imageview" | "websearch" => {
            Some("tool")
        }
        "contextcompaction" => Some("compaction"),
        "extension" if util::text(&item["kind"]) == "clock.sleep" => Some("sleep"),
        _ => None,
    }
}

fn item_duration(item: &Value) -> Option<i64> {
    integer(&item["durationMs"]).or_else(|| {
        let duration = &item["duration"];
        integer(&duration["secs"])?
            .checked_mul(1000)?
            .checked_add(integer(&duration["nanos"])? / 1_000_000)
    })
}

pub fn consume(state: &mut State, row: &Value) {
    let payload = &row["payload"];
    if !payload.is_object() {
        return;
    }
    let thread = util::text(&payload["thread_id"]);
    let own = util::text(&state.metadata["id"]);
    if !thread.is_empty() && !own.is_empty() && thread != own {
        return;
    }
    let metadata = &payload["internal_chat_message_metadata_passthrough"];
    let id = payload["turn_id"]
        .as_str()
        .or_else(|| metadata["turn_id"].as_str())
        .or(state.current_turn_id.as_deref());
    let mut position = id.and_then(|id| state.turns.iter().position(|t| t.id == id));
    let call_id = payload["call_id"].as_str();
    let kind = util::text(&payload["type"]);
    let row_kind = util::text(&row["type"]);
    if ["function_call_output", "custom_tool_call_output"].contains(&kind) {
        if let Some(call) = call_id {
            position = state
                .turns
                .iter()
                .position(|t| t.metrics.pending_calls.contains_key(call))
                .or(position);
        }
    }
    let time = util::timestamp(&row["timestamp"]);
    if row_kind == "token_usage_record" {
        let total = usage(&payload["thread_token_usage"]);
        let Some(index) = position else {
            if total.is_some() {
                state.last_thread_usage = total;
            }
            return;
        };
        let metrics = &mut state.turns[index].metrics;
        if payload["response_id"]
            .as_str()
            .is_some_and(|r| metrics.response_usage.contains_key(r))
        {
            return;
        }
        if total.is_some() {
            state.last_thread_usage = total;
        }
        if let Some(response) = payload["response_id"].as_str() {
            metrics.response_usage.insert(
                response.into(),
                usage(&payload["usage"]).unwrap_or_default(),
            );
        }
        if let Some(reported) = usage(&payload["turn_token_usage"]) {
            metrics.reported_usage = Some(reported);
        }
    }
    let mut regressed = false;
    let legacy = if row_kind == "event_msg" && kind == "token_count" {
        usage(&payload["info"]["total_token_usage"])
    } else {
        None
    };
    if let Some(total) = &legacy {
        regressed = state
            .last_thread_usage
            .as_ref()
            .is_some_and(|old| total.iter().any(|(k, v)| old.get(k).is_some_and(|p| v < p)));
        state.last_thread_usage = Some(total.clone());
    }
    let Some(index) = position else {
        return;
    };
    let metrics = &mut state.turns[index].metrics;
    if let Some(time) = time {
        metrics.last_event_ms = Some(time.max(metrics.last_event_ms.unwrap_or(time)));
    }
    if let (Some(total), Some(base)) = (legacy, &metrics.baseline) {
        let mut delta = Usage::new();
        for (k, v) in total {
            if let Some(old) = base.get(&k) {
                if let Some(v) = v.checked_sub(*old) {
                    delta.insert(k, v);
                } else {
                    regressed = true;
                }
            }
        }
        if regressed {
            metrics.legacy_reset = true;
            metrics.legacy_usage = None;
        } else if !metrics.legacy_reset && !delta.is_empty() {
            metrics.legacy_usage = Some(delta);
        }
    }
    if row_kind == "event_msg" && completed(kind) {
        metrics.reported_duration_ms = integer(&payload["duration_ms"]);
        metrics.first_token_ms = integer(&payload["time_to_first_token_ms"]);
    }
    if row_kind == "response_item" {
        if let Some(time) = time {
            let identifier = payload["id"].as_str().or(call_id);
            if let Some(identifier) = identifier {
                if kind == "reasoning"
                    || (kind == "message" && payload["role"] == "assistant")
                    || ["function_call", "custom_tool_call", "local_shell_call"].contains(&kind)
                {
                    // Completed items later replace these point-only fallbacks
                    // with their actual streaming boundaries, regardless of order.
                    metrics
                        .model_windows
                        .entry(identifier.into())
                        .or_insert((time, time));
                } else if kind == "message" && payload["role"] == "user" {
                    metrics
                        .ready_points
                        .insert(format!("user:{identifier}"), time);
                }
            }
            if ["function_call_output", "custom_tool_call_output"].contains(&kind) {
                if let Some(call) = call_id {
                    metrics.ready_points.insert(format!("return:{call}"), time);
                }
            }
        }
        if let Some(call) = call_id {
            if ["function_call", "custom_tool_call", "local_shell_call"].contains(&kind) {
                if let Some(start_ms) = time {
                    metrics
                        .pending_calls
                        .insert(call.into(), PendingCall { start_ms });
                }
            } else if ["function_call_output", "custom_tool_call_output"].contains(&kind) {
                if let Some(pending) = metrics.pending_calls.remove(call) {
                    span(
                        metrics,
                        format!("call:{call}"),
                        "tool_wrapper",
                        Some(pending.start_ms),
                        time,
                    );
                }
            }
        }
    }
    if row_kind == "event_msg" && ["item_started", "item_completed"].contains(&kind) {
        let item = &payload["item"];
        let item_kind = util::text(&item["type"]).replace('_', "").to_lowercase();
        let item_id = util::text(&item["id"]);
        if item_id.is_empty() {
            return;
        }
        if item_kind == "usermessage" {
            if let Some(time) = integer(&payload["completed_at_ms"]).or(time) {
                metrics.ready_points.insert(format!("user:{item_id}"), time);
            }
            return;
        }
        let Some(category) = item_category(item) else {
            metrics
                .unsupported_items
                .insert(item_id.into(), util::text(&item["type"]).into());
            return;
        };
        let start = integer(&payload["started_at_ms"]);
        if kind == "item_started" {
            metrics.pending_items.insert(item_id.into(), start.or(time));
        } else {
            // Always consume the pending entry, even when the end event provides
            // its own start; otherwise completed items remain pending forever.
            let pending = metrics.pending_items.remove(item_id).flatten();
            let end = integer(&payload["completed_at_ms"]).or(time);
            let mut start = start.or(pending);
            if start.is_none() || start == end {
                if let (Some(end), Some(duration)) = (end, item_duration(item)) {
                    if duration > 0 {
                        start = end.checked_sub(duration);
                    }
                }
            }
            if let (Some(start), Some(end)) = (start, end) {
                if start > end {
                    return;
                }
                if category == "reasoning" || category == "output" {
                    metrics.model_windows.insert(item_id.into(), (start, end));
                } else {
                    metrics.ready_points.insert(format!("item:{item_id}"), end);
                }
                if start == end {
                    metrics.zero_duration_items.insert(item_id.into());
                } else {
                    metrics.zero_duration_items.remove(item_id);
                }
            }
            span(metrics, format!("item:{item_id}"), category, start, end);
        }
    }
    if row_kind == "event_msg" {
        if let Some(call) = call_id {
            match kind {
                "exec_command_begin" | "mcp_tool_call_begin" => {
                    metrics.pending_legacy.insert(
                        call.into(),
                        (
                            integer(&payload["started_at_ms"]).or(time),
                            if kind == "exec_command_begin" {
                                "command"
                            } else {
                                "tool"
                            }
                            .into(),
                        ),
                    );
                }
                "exec_command_end" | "mcp_tool_call_end" => {
                    if let Some(time) = time {
                        metrics.ready_points.insert(format!("legacy:{call}"), time);
                    }
                    if let Some((start, category)) = metrics.pending_legacy.remove(call) {
                        span(metrics, format!("legacy:{call}"), &category, start, time);
                    }
                }
                _ => {}
            }
        }
    }
}
fn usage_summary(metrics: &Metrics) -> Value {
    let mut result = metrics.reported_usage.clone();
    let mut source = "turn_record";
    if result.is_none() {
        if !metrics.response_usage.is_empty()
            && metrics
                .response_usage
                .values()
                .all(|r| r.contains_key("total_tokens"))
        {
            result = Some(
                TOKEN_FIELDS
                    .iter()
                    .filter(|k| metrics.response_usage.values().all(|r| r.contains_key(**k)))
                    .map(|k| {
                        (
                            (*k).into(),
                            metrics.response_usage.values().map(|r| r[*k]).sum(),
                        )
                    })
                    .collect(),
            );
            source = "response_records";
        } else if metrics.legacy_usage.is_some() {
            result = metrics.legacy_usage.clone();
            source = "thread_delta";
        } else {
            source = "unavailable";
        }
    }
    json!({"usage":result,"source":source,"response_count":metrics.response_usage.len(),"counter_reset":metrics.legacy_reset && result.is_none()})
}
fn timeline(turn: &Turn) -> Value {
    let metrics = &turn.metrics;
    let end = turn
        .completed_at
        .as_ref()
        .and_then(|s| util::timestamp(&json!(s)));
    let mut start = turn
        .started_at
        .as_ref()
        .and_then(|s| util::timestamp(&json!(s)));
    let mut source = if end.is_some() {
        "boundaries"
    } else {
        "partial"
    };
    if let (Some(end), Some(duration)) = (end, metrics.reported_duration_ms) {
        start = Some(end - duration);
        source = "reported";
    }
    let Some(start) = start else {
        return json!({"source":"unavailable","span_duration_ms":0,"segments":[],"category_totals":[]});
    };
    let end = end.unwrap_or(metrics.last_event_ms.unwrap_or(start));
    let duration = (end - start).max(0);
    let mut intervals: Vec<_> = metrics.intervals.values().cloned().collect();
    let anchors: BTreeSet<i64> = metrics
        .ready_points
        .values()
        .copied()
        .chain(metrics.model_windows.values().map(|(_, end)| *end))
        .collect();
    for (left, _) in metrics.model_windows.values() {
        // Only describe gaps bounded by actual events. Never extrapolate an
        // unfinished request, or call this model computation/network latency.
        if *left <= start {
            continue;
        }
        if metrics
            .pending_calls
            .values()
            .any(|call| call.start_ms < *left)
        {
            continue;
        }
        if let Some(anchor) = anchors.range(start..*left).next_back() {
            intervals.push(Interval {
                category: "response_gap".into(),
                start_ms: *anchor,
                end_ms: *left,
            });
        }
    }
    if let Some(first) = metrics.first_token_ms.filter(|v| *v > 0) {
        intervals.push(Interval {
            category: "first_token_wait".into(),
            start_ms: start,
            end_ms: end.min(start + first),
        });
    }
    let mut events: BTreeMap<i64, Vec<(usize, String, bool)>> = BTreeMap::new();
    events.entry(0).or_default();
    events.entry(duration).or_default();
    for (ordinal, interval) in intervals.iter().enumerate() {
        let left = (interval.start_ms - start).max(0);
        let right = (interval.end_ms - start).min(duration);
        if right > left {
            events
                .entry(left)
                .or_default()
                .push((ordinal, interval.category.clone(), true));
            events
                .entry(right)
                .or_default()
                .push((ordinal, interval.category.clone(), false));
        }
    }
    let mut active: BTreeMap<usize, String> = BTreeMap::new();
    let mut segments: Vec<Value> = Vec::new();
    let mut position = 0;
    for (boundary, changes) in events {
        if boundary > position {
            let mut categories: BTreeSet<String> = active.values().cloned().collect();
            if categories.len() > 1 {
                categories.remove("response_gap");
            }
            // Wrappers include their nested commands; only independent native activities count as overlap.
            if categories.remove("tool_wrapper")
                && !categories.contains("command")
                && !categories.contains("tool")
                && !categories.contains("sleep")
                && !categories.contains("compaction")
            {
                categories.insert("tool".into());
            }
            if categories.len() > 1 {
                categories.remove("first_token_wait");
            }
            let category = if categories.len() > 1 {
                "overlap"
            } else {
                categories.first().map(String::as_str).unwrap_or("unknown")
            };
            let components = json!(categories);
            let evidence = match category {
                "response_gap" => "event_gap",
                "unknown" => "unavailable",
                _ => "recorded",
            };
            if let Some(last) = segments
                .last_mut()
                .filter(|s| s["category"] == category && s["components"] == components)
            {
                last["end_ms"] = json!(boundary);
                last["duration_ms"] =
                    json!(last["duration_ms"].as_i64().unwrap_or(0) + boundary - position);
            } else {
                segments.push(json!({"start_ms":position,"end_ms":boundary,"duration_ms":boundary-position,"category":category,"components":components,"evidence":evidence}));
            }
        }
        for (ordinal, category, begin) in changes {
            if begin {
                active.insert(ordinal, category);
            } else {
                active.remove(&ordinal);
            }
        }
        position = boundary;
    }
    let mut totals: BTreeMap<String, i64> = BTreeMap::new();
    for segment in &segments {
        *totals
            .entry(util::text(&segment["category"]).into())
            .or_default() += segment["duration_ms"].as_i64().unwrap_or(0);
    }
    let mut totals: Vec<_> = totals.into_iter().collect();
    let gap_duration = totals
        .iter()
        .find(|(key, _)| key == "response_gap")
        .map_or(0, |(_, value)| *value);
    let unknown_duration = totals
        .iter()
        .find(|(key, _)| key == "unknown")
        .map_or(0, |(_, value)| *value);
    let unsupported_types: BTreeSet<_> = metrics.unsupported_items.values().collect();
    totals.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    json!({"source":source,"span_duration_ms":duration,"total_duration_ms":turn.completed_at.as_ref().map(|_| duration),"first_token_ms":metrics.first_token_ms,
        "segments":segments,"category_totals":totals.into_iter().map(|(category,duration_ms)| json!({"category":category,"duration_ms":duration_ms})).collect::<Vec<_>>(),"pending_tool_count":metrics.pending_calls.len(),
        "recorded_duration_ms": duration - gap_duration - unknown_duration,
        "response_gap_duration_ms": gap_duration, "unknown_duration_ms": unknown_duration,
        "zero_duration_item_count": metrics.zero_duration_items.len(),
        "unsupported_item_types": unsupported_types})
}
pub fn summary(turn: &Turn) -> Value {
    json!({"tokens":usage_summary(&turn.metrics),"timing":timeline(turn)})
}

pub fn conversation_tokens(turns: &[Turn]) -> Value {
    let records: Vec<_> = turns
        .iter()
        .map(|t| usage_summary(&t.metrics))
        .filter(|s| s["usage"].is_object())
        .collect();
    let totals: Usage = TOKEN_FIELDS
        .iter()
        .filter(|k| !records.is_empty() && records.iter().all(|r| r["usage"][**k].is_u64()))
        .map(|k| {
            (
                (*k).into(),
                records
                    .iter()
                    .map(|r| r["usage"][*k].as_u64().unwrap_or(0))
                    .sum(),
            )
        })
        .collect();
    // Sum attributable turns rather than a thread counter, which can include
    // inherited usage after a fork. Missing turns/fields remain explicitly partial.
    json!({"usage": if records.is_empty() { Value::Null } else { json!(totals) },
        "recorded_turns": records.len(), "total_turns": turns.len(),
        "partial": records.len() < turns.len() || turns.last().is_some_and(|t| t.completed_at.is_none())})
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: i64 = 1792540800000;

    fn state() -> State {
        let turn: Turn = serde_json::from_value(json!({
            "id": "turn", "number": 1, "started_at": "2026-10-21T00:00:00Z",
            "completed_at": "2026-10-21T00:00:10Z", "status": "completed",
            "cwd": null, "model": null, "user_preview": "", "assistant_preview": "",
            "tool_count": 0, "instruction_ids": [], "instruction_sources": [],
            "metrics": Metrics::default(),
        }))
        .unwrap();
        let mut state = State::default();
        state.metadata = json!({"id": "chat"});
        state.current_turn_id = Some("turn".into());
        state.turns.push(turn);
        state
    }

    fn record(state: &mut State, offset: i64, row_type: &str, payload: Value) {
        let timestamp = chrono::DateTime::from_timestamp_millis(BASE + offset)
            .unwrap()
            .to_rfc3339();
        consume(
            state,
            &json!({"timestamp": timestamp, "type": row_type, "payload": payload}),
        );
    }

    fn item(state: &mut State, kind: &str, id: &str, start: i64, end: i64) {
        record(
            state,
            end,
            "event_msg",
            json!({
                "type": "item_completed", "item": {"type": kind, "id": id},
                "started_at_ms": BASE + start, "completed_at_ms": BASE + end,
            }),
        );
    }

    fn totals(state: &State) -> BTreeMap<String, i64> {
        timeline(&state.turns[0])["category_totals"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                (
                    row["category"].as_str().unwrap().into(),
                    row["duration_ms"].as_i64().unwrap(),
                )
            })
            .collect()
    }

    fn assert_partition(state: &State) {
        let timing = timeline(&state.turns[0]);
        let duration = timing["span_duration_ms"].as_i64().unwrap();
        let mut position = 0;
        for segment in timing["segments"].as_array().unwrap() {
            assert_eq!(segment["start_ms"], position);
            position = segment["end_ms"].as_i64().unwrap();
            assert!(segment["duration_ms"].as_i64().unwrap() > 0);
        }
        assert_eq!(position, duration);
        assert_eq!(totals(state).values().sum::<i64>(), duration);
        assert_eq!(
            timing["recorded_duration_ms"].as_i64().unwrap()
                + timing["response_gap_duration_ms"].as_i64().unwrap()
                + timing["unknown_duration_ms"].as_i64().unwrap(),
            duration
        );
    }

    #[test]
    fn compaction_sleep_and_image_activity_are_measured_without_wrapper_overlap() {
        let mut state = state();
        record(
            &mut state,
            1000,
            "response_item",
            json!({"type": "custom_tool_call", "call_id": "sleep"}),
        );
        record(
            &mut state,
            3000,
            "event_msg",
            json!({
                "type": "item_completed", "item": {"type": "Extension", "kind": "clock.sleep", "id": "sleep", "durationMs": 2000},
                "started_at_ms": BASE + 1000, "completed_at_ms": BASE + 3000,
            }),
        );
        record(
            &mut state,
            3000,
            "response_item",
            json!({"type": "custom_tool_call_output", "call_id": "sleep"}),
        );
        item(&mut state, "ContextCompaction", "compact", 3000, 5000);
        item(&mut state, "ImageView", "image", 5000, 5500);
        assert_eq!(
            totals(&state),
            BTreeMap::from([
                ("sleep".into(), 2000),
                ("compaction".into(), 2000),
                ("tool".into(), 500),
                ("unknown".into(), 5500),
            ])
        );
        assert_partition(&state);
    }

    #[test]
    fn response_gaps_are_endpoint_evidence_and_never_override_measured_activity() {
        let mut state = state();
        item(&mut state, "UserMessage", "user", 100, 100);
        item(&mut state, "Reasoning", "reason1", 1000, 2000);
        record(
            &mut state,
            3000,
            "response_item",
            json!({"type": "custom_tool_call", "id": "call", "call_id": "call"}),
        );
        record(
            &mut state,
            5000,
            "response_item",
            json!({"type": "custom_tool_call_output", "call_id": "call"}),
        );
        item(&mut state, "Reasoning", "reason2", 6000, 6500);
        item(&mut state, "AgentMessage", "reply", 7000, 8000);
        assert_eq!(
            totals(&state),
            BTreeMap::from([
                ("response_gap".into(), 3400),
                ("reasoning".into(), 1500),
                ("tool".into(), 2000),
                ("output".into(), 1000),
                ("unknown".into(), 2100),
            ])
        );
        for segment in timeline(&state.turns[0])["segments"].as_array().unwrap() {
            if segment["category"] == "response_gap" {
                assert_eq!(segment["evidence"], "event_gap");
            }
        }
        assert_partition(&state);
    }

    #[test]
    fn precise_stream_boundaries_replace_point_fallbacks_in_both_event_orders() {
        let mut first = state();
        item(&mut first, "UserMessage", "user", 100, 100);
        record(
            &mut first,
            2010,
            "response_item",
            json!({"type": "message", "role": "assistant", "id": "reply"}),
        );
        item(&mut first, "AgentMessage", "reply", 1000, 2000);
        let mut second = state();
        item(&mut second, "UserMessage", "user", 100, 100);
        item(&mut second, "AgentMessage", "reply", 1000, 2000);
        record(
            &mut second,
            2010,
            "response_item",
            json!({"type": "message", "role": "assistant", "id": "reply"}),
        );
        assert_eq!(timeline(&first.turns[0]), timeline(&second.turns[0]));
        assert_eq!(totals(&first)["response_gap"], 900);
        assert_eq!(totals(&first)["output"], 1000);
        assert_partition(&first);
    }

    #[test]
    fn reported_first_token_wait_has_priority_over_response_gaps() {
        let mut state = state();
        item(&mut state, "UserMessage", "user", 100, 100);
        item(&mut state, "AgentMessage", "reply", 2000, 3000);
        record(
            &mut state,
            10000,
            "event_msg",
            json!({"type": "task_complete", "time_to_first_token_ms": 1500}),
        );
        assert_eq!(totals(&state)["first_token_wait"], 1500);
        assert_eq!(totals(&state)["response_gap"], 500);
        assert_partition(&state);
    }

    #[test]
    fn explicit_duration_recovers_collapsed_item_boundaries() {
        let mut state = state();
        record(
            &mut state,
            3000,
            "event_msg",
            json!({
                "type": "item_completed", "item": {"type": "CommandExecution", "id": "cmd", "duration": {"secs": 2, "nanos": 500_000_000}},
                "started_at_ms": BASE + 3000, "completed_at_ms": BASE + 3000,
            }),
        );
        assert_eq!(totals(&state)["command"], 2500);
        assert_eq!(timeline(&state.turns[0])["zero_duration_item_count"], 0);
        assert_partition(&state);
    }

    #[test]
    fn zero_duration_and_unrecognized_items_are_diagnosed_without_fabricated_spans() {
        let mut state = state();
        item(&mut state, "Reasoning", "point", 1000, 1000);
        item(&mut state, "Reasoning", "point", 1000, 1000);
        item(&mut state, "Extension", "extension", 2000, 3000);
        assert_eq!(totals(&state), BTreeMap::from([("unknown".into(), 10000)]));
        let timing = timeline(&state.turns[0]);
        assert_eq!(timing["zero_duration_item_count"], 1);
        assert_eq!(timing["unsupported_item_types"], json!(["Extension"]));
    }

    #[test]
    fn completion_consumes_pending_start_even_with_explicit_timestamps() {
        let mut state = state();
        record(
            &mut state,
            1000,
            "event_msg",
            json!({"type": "item_started", "item": {"type": "Reasoning", "id": "reason"}}),
        );
        item(&mut state, "Reasoning", "reason", 1000, 2000);
        assert!(state.turns[0].metrics.pending_items.is_empty());
    }

    #[test]
    fn out_of_turn_and_independent_overlap_preserve_wall_clock_partition() {
        let mut state = state();
        item(&mut state, "Reasoning", "old", -1000, -500);
        item(&mut state, "CommandExecution", "cmd", -500, 4000);
        item(&mut state, "McpToolCall", "mcp", 2000, 3000);
        item(&mut state, "AgentMessage", "reply", 2500, 3500);
        assert_eq!(totals(&state)["overlap"], 1500);
        assert_partition(&state);
    }

    #[test]
    fn unreturned_calls_remain_unknown_and_do_not_fabricate_response_gaps() {
        let mut state = state();
        record(
            &mut state,
            1000,
            "response_item",
            json!({"type": "custom_tool_call", "id": "pending", "call_id": "pending"}),
        );
        item(&mut state, "Reasoning", "reason", 2000, 3000);
        assert_eq!(
            totals(&state),
            BTreeMap::from([("reasoning".into(), 1000), ("unknown".into(), 9000)])
        );
        assert_eq!(timeline(&state.turns[0])["pending_tool_count"], 1);
        state.turns[0].completed_at = None;
        assert_eq!(timeline(&state.turns[0])["span_duration_ms"], 3000);
        assert_eq!(timeline(&state.turns[0])["total_duration_ms"], Value::Null);
        assert_partition(&state);
    }

    #[test]
    fn foreign_thread_events_cannot_create_timing_evidence() {
        let mut state = state();
        record(
            &mut state,
            3000,
            "event_msg",
            json!({
                "type": "item_completed", "thread_id": "child", "item": {"type": "ContextCompaction", "id": "child"},
                "started_at_ms": BASE + 1000, "completed_at_ms": BASE + 3000,
            }),
        );
        assert_eq!(totals(&state), BTreeMap::from([("unknown".into(), 10000)]));
    }
}
