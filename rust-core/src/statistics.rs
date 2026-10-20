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
        let category = match item_kind.as_str() {
            "reasoning" => "reasoning",
            "agentmessage" => "output",
            "commandexecution" => "command",
            "mcptoolcall" | "dynamictoolcall" | "filechange" => "tool",
            _ => "",
        };
        let item_id = util::text(&item["id"]);
        if category.is_empty() || item_id.is_empty() {
            return;
        }
        let start = integer(&payload["started_at_ms"]);
        if kind == "item_started" {
            metrics.pending_items.insert(item_id.into(), start.or(time));
        } else {
            let start = start.or_else(|| metrics.pending_items.remove(item_id).flatten());
            span(
                metrics,
                format!("item:{item_id}"),
                category,
                start,
                integer(&payload["completed_at_ms"]).or(time),
            );
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
            // Wrappers include their nested commands; only independent native activities count as overlap.
            if categories.remove("tool_wrapper")
                && !categories.contains("command")
                && !categories.contains("tool")
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
            if let Some(last) = segments
                .last_mut()
                .filter(|s| s["category"] == category && s["components"] == components)
            {
                last["end_ms"] = json!(boundary);
                last["duration_ms"] =
                    json!(last["duration_ms"].as_i64().unwrap_or(0) + boundary - position);
            } else {
                segments.push(json!({"start_ms":position,"end_ms":boundary,"duration_ms":boundary-position,"category":category,"components":components}));
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
    totals.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    json!({"source":source,"span_duration_ms":duration,"total_duration_ms":turn.completed_at.as_ref().map(|_| duration),"first_token_ms":metrics.first_token_ms,
        "segments":segments,"category_totals":totals.into_iter().map(|(category,duration_ms)| json!({"category":category,"duration_ms":duration_ms})).collect::<Vec<_>>(),"pending_tool_count":metrics.pending_calls.len()})
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
