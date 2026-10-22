//! Offline activity inventory. Keep targets and provenance, never command output,
//! patches, script bodies, or arbitrary MCP arguments in the activity cache.
use crate::util;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::{Component, Path, PathBuf},
};

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Activity {
    calls: BTreeMap<String, Entry>,
    operations: BTreeMap<String, Entry>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Entry {
    tool: String,
    timestamp: Option<String>,
    status: String,
    targets: Vec<Target>,
    unrecognized: bool,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
struct Target {
    path: String,
    action: String,
    evidence: String,
}

fn native_tool(item: &Value) -> Option<String> {
    Some(match util::text(&item["type"]).to_lowercase().as_str() {
        "commandexecution" => match item["source"].as_str() {
            Some("unified_exec_interaction") => "write_stdin".into(),
            _ => "exec_command".into(),
        },
        "filechange" => "apply_patch".into(),
        "mcptoolcall" => format!(
            "{}.{}",
            util::text(&item["server"]),
            util::text(&item["tool"])
        ),
        "dynamictoolcall" => item["tool"].as_str().unwrap_or("dynamic_tool").into(),
        "imageview" => "view_image".into(),
        "websearch" => "web_search".into(),
        "extension" => item["kind"].as_str()?.into(),
        _ => return None,
    })
}

pub fn recognizes(row: &Value) -> bool {
    let p = &row["payload"];
    match row["type"].as_str() {
        Some("response_item") => matches!(
            p["type"].as_str(),
            Some(
                "function_call"
                    | "custom_tool_call"
                    | "local_shell_call"
                    | "function_call_output"
                    | "custom_tool_call_output"
            )
        ),
        Some("event_msg") => {
            matches!(p["type"].as_str(), Some("item_started" | "item_completed"))
                && native_tool(&p["item"]).is_some()
        }
        _ => false,
    }
}

impl Activity {
    pub fn has_call(&self, id: &str) -> bool {
        self.calls.contains_key(id)
    }
    pub fn has_operation(&self, id: &str) -> bool {
        self.operations.contains_key(id)
    }
    pub fn call_count(&self) -> u64 {
        self.calls.len() as u64
    }

    pub fn summary(&self) -> Value {
        let tools = |entries: &BTreeMap<String, Entry>| {
            let mut groups = BTreeMap::<&str, u64>::new();
            for entry in entries.values() {
                *groups.entry(&entry.tool).or_default() += 1;
            }
            groups
                .into_iter()
                .map(|(name, count)| json!({"name":name,"count":count}))
                .collect::<Vec<_>>()
        };
        let mut targets = BTreeMap::<Target, (u64, u64, u64, Vec<String>)>::new();
        for entry in self.operations.values().chain(self.calls.values()) {
            for target in &entry.targets {
                let (count, completed, failed, tools) = targets.entry(target.clone()).or_default();
                *count += 1;
                *completed += u64::from(entry.status == "completed");
                *failed += u64::from(matches!(entry.status.as_str(), "failed" | "declined"));
                if !tools.contains(&entry.tool) {
                    tools.push(entry.tool.clone());
                }
            }
        }
        let targets: Vec<_> = targets.into_iter().map(|(t, (count, completed, failed, tools))| {
            json!({"path":t.path,"action":t.action,"evidence":t.evidence,"count":count,"completed":completed,"failed":failed,"tools":tools})
        }).collect();
        json!({"source":"session_jsonl", "model_call_count":self.calls.len(),
            "operation_count":self.operations.len(), "model_tools":tools(&self.calls),
            "operation_tools":tools(&self.operations), "targets":targets,
            "unrecognized_command_count":self.operations.values().filter(|e| e.unrecognized).count(),
            "operations":self.operations.iter().map(|(id,e)| json!({"id":id,"tool":e.tool,"timestamp":e.timestamp,"status":e.status,"target_count":e.targets.len()})).collect::<Vec<_>>()})
    }
}

pub fn consume(activity: &mut Activity, row: &Value, cwd: Option<&str>) {
    let p = &row["payload"];
    if row["type"] == "response_item" {
        let kind = util::text(&p["type"]);
        let id = p["call_id"].as_str().or_else(|| p["id"].as_str());
        let Some(id) = id else {
            return;
        };
        if kind.ends_with("_output") {
            // A tool returning text is observable; success cannot be inferred
            // from arbitrary output bodies, so don't promote it to "completed".
            if let Some(entry) = activity.calls.get_mut(id) {
                entry.status = "returned".into();
            }
            return;
        }
        let name = p["name"].as_str().unwrap_or("local_shell_call");
        let tool = p["namespace"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(|ns| format!("{ns}.{name}"))
            .unwrap_or_else(|| name.into());
        activity.calls.entry(id.into()).or_insert(Entry {
            tool,
            timestamp: row["timestamp"].as_str().map(str::to_owned),
            status: "recorded".into(),
            ..Entry::default()
        });
        return;
    }
    let item = &p["item"];
    let (Some(id), Some(tool)) = (item["id"].as_str(), native_tool(item)) else {
        return;
    };
    let previous = activity.operations.get(id);
    // Completion replaces the start snapshot instead of counting it twice.
    if p["type"] == "item_started" && previous.is_some() {
        return;
    }
    let timestamp = previous
        .and_then(|e| e.timestamp.clone())
        .or_else(|| row["timestamp"].as_str().map(str::to_owned));
    let mut entry = Entry {
        tool,
        timestamp,
        status: item["status"].as_str().unwrap_or("in_progress").into(),
        ..Entry::default()
    };
    let cwd = item["cwd"].as_str().or(cwd).and_then(decode_path);
    match util::text(&item["type"]).to_lowercase().as_str() {
        "commandexecution" => {
            if let Some(parsed) = item["parsed_cmd"].as_array() {
                for cmd in parsed {
                    // Search `path` can be a display basename, not a filesystem
                    // path. Only structured reads have an unambiguous target.
                    if cmd["type"] == "read" {
                        add(
                            &mut entry.targets,
                            &cmd["path"],
                            "read",
                            "parsed_command",
                            cwd.as_deref(),
                        );
                    }
                }
            }
            if let Some(command) = item["command"].as_array() {
                let words: Vec<_> = command.iter().filter_map(Value::as_str).collect();
                let script = words
                    .iter()
                    .position(|w| matches!(*w, "-lc" | "-c" | "-ic"))
                    .and_then(|i| words.get(i + 1))
                    .copied();
                if let Some(script) = script {
                    entry.unrecognized = !shell_targets(script, cwd.as_deref(), &mut entry.targets);
                } else {
                    entry.unrecognized =
                        !command_targets(&words, cwd.as_deref(), &mut entry.targets);
                }
            } else {
                entry.unrecognized = true;
            }
        }
        "filechange" => {
            if let Some(changes) = item["changes"].as_object() {
                for (path, change) in changes {
                    let action = match change["type"].as_str().or_else(|| change["kind"].as_str()) {
                        Some("add") => "write",
                        Some("update") => "modify",
                        Some("delete") => "delete",
                        _ => "change",
                    };
                    add(
                        &mut entry.targets,
                        &json!(path),
                        action,
                        "file_change",
                        cwd.as_deref(),
                    );
                    if change["move_path"].is_string() {
                        add(
                            &mut entry.targets,
                            &change["move_path"],
                            "write",
                            "file_change",
                            cwd.as_deref(),
                        );
                    }
                }
            }
        }
        "imageview" => add(
            &mut entry.targets,
            &item["path"],
            "read",
            "tool_target",
            cwd.as_deref(),
        ),
        _ => {}
    }
    entry.targets.sort();
    entry
        .targets
        .dedup_by(|a, b| a.path == b.path && a.action == b.action);
    activity.operations.insert(id.into(), entry);
}

fn decode_path(raw: &str) -> Option<String> {
    let Some(raw) = raw.strip_prefix("file://") else {
        return Some(raw.into());
    };
    if !raw.starts_with('/') {
        return None;
    }
    let mut bytes = Vec::new();
    let mut chars = raw.as_bytes().iter().copied();
    while let Some(c) = chars.next() {
        bytes.push(if c == b'%' {
            let h = char::from(chars.next()?).to_digit(16)?;
            let l = char::from(chars.next()?).to_digit(16)?;
            (h * 16 + l) as u8
        } else {
            c
        });
    }
    String::from_utf8(bytes).ok()
}

fn add(targets: &mut Vec<Target>, raw: &Value, action: &str, evidence: &str, cwd: Option<&str>) {
    let Some(raw) = raw.as_str().and_then(decode_path) else {
        return;
    };
    // Don't expand globs against today's disk or invent paths from variables.
    if raw.is_empty()
        || raw == "-"
        || raw.contains(['$', '`', '*', '?', '[', ']', '\n', '\0'])
        || targets.len() >= 256
    {
        return;
    }
    let path = if raw == "~" || raw.starts_with("~/") {
        util::expand(&raw)
    } else {
        PathBuf::from(raw)
    };
    let path = if path.is_absolute() {
        path
    } else {
        let Some(cwd) = cwd.filter(|s| s.starts_with('/')) else {
            return;
        };
        Path::new(cwd).join(path)
    };
    let mut normalized = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    targets.push(Target {
        path: normalized.to_string_lossy().into(),
        action: action.into(),
        evidence: evidence.into(),
    });
}

fn shell_targets(script: &str, cwd: Option<&str>, targets: &mut Vec<Target>) -> bool {
    // Deliberately skip scripts with expansion, heredocs or redirection. This is
    // a target inventory, not a shell interpreter or filesystem audit.
    if script.contains(['$', '`', '<', '>']) {
        return false;
    }
    let mut split = String::new();
    let mut quote = None;
    let mut escaped = false;
    for c in script.chars() {
        if escaped {
            split.push(c);
            escaped = false;
            continue;
        }
        if c == '\\' && quote != Some('\'') {
            escaped = true;
            split.push(c);
            continue;
        }
        if matches!(c, '\'' | '"') {
            if quote == Some(c) {
                quote = None;
            } else if quote.is_none() {
                quote = Some(c);
            }
        }
        if quote.is_none() && matches!(c, ';' | '|' | '&' | '\n') {
            split.push_str(" ; ");
        } else {
            split.push(c);
        }
    }
    let Some(words) = shlex::split(&split) else {
        return false;
    };
    let mut cwd = cwd.map(str::to_owned);
    let mut complete = true;
    for segment in words.split(|s| s == ";").filter(|s| !s.is_empty()) {
        let words: Vec<_> = segment.iter().map(String::as_str).collect();
        if words[0] == "cd" {
            let mut dirs = Vec::new();
            if words.len() == 2 {
                add(
                    &mut dirs,
                    &json!(words[1]),
                    "directory",
                    "command_target",
                    cwd.as_deref(),
                );
            }
            cwd = dirs.first().map(|t| t.path.clone());
            complete &= cwd.is_some();
        } else {
            complete &= command_targets(&words, cwd.as_deref(), targets);
        }
    }
    complete
}

fn command_targets(words: &[&str], cwd: Option<&str>, targets: &mut Vec<Target>) -> bool {
    let Some(command) = words
        .first()
        .and_then(|s| Path::new(s).file_name())
        .and_then(|s| s.to_str())
    else {
        return true;
    };
    let args = &words[1..];
    let (action, mut skip) = match command {
        "cat" | "nl" | "head" | "tail" | "wc" => ("read", 0),
        "sed" => (
            "read",
            usize::from(!args.iter().any(|a| matches!(*a, "-e" | "-f"))),
        ),
        "ls" => ("directory", 0),
        "rg" => (
            if args.contains(&"--files") {
                "directory"
            } else {
                "search"
            },
            usize::from(
                !args.contains(&"--files") && !args.iter().any(|a| matches!(*a, "-e" | "--regexp")),
            ),
        ),
        "pwd" | "echo" | "true" | "false" => return true,
        _ => return false,
    };
    // Mutating sed and file-list indirection cannot be treated as simple reads.
    if command == "sed" && args.iter().any(|a| a.starts_with("-i") || *a == "-f")
        || command == "rg" && args.iter().any(|a| matches!(*a, "-f" | "--file" | "--pre"))
    {
        return false;
    }
    let mut option_value = false;
    let mut complete = true;
    let mut options = true;
    let before = targets.len();
    for arg in args {
        if option_value {
            option_value = false;
            continue;
        }
        if options && *arg == "--" {
            options = false;
            continue;
        }
        if options && arg.starts_with('-') {
            option_value = matches!(
                (command, *arg),
                (
                    "rg",
                    "-g" | "--glob"
                        | "--iglob"
                        | "-t"
                        | "--type"
                        | "-T"
                        | "--type-not"
                        | "-e"
                        | "--regexp"
                        | "-m"
                        | "--max-count"
                        | "-A"
                        | "-B"
                        | "-C"
                        | "--context"
                        | "--encoding"
                        | "--threads"
                        | "--max-depth"
                ) | ("sed", "-e")
                    | ("head" | "tail", "-n" | "-c")
                    | ("nl", "-b" | "-n" | "-w" | "-s" | "-v" | "-i")
            );
            continue;
        }
        if skip > 0 {
            skip -= 1;
            continue;
        }
        let before_arg = targets.len();
        add(targets, &json!(arg), action, "command_target", cwd);
        complete &= targets.len() > before_arg || *arg == "-";
    }
    if targets.len() == before && matches!(action, "directory" | "search") {
        add(targets, &json!("."), action, "command_target", cwd);
    }
    complete
}

#[cfg(test)]
mod tests {
    use super::*;
    fn operation(a: &mut Activity, id: &str, kind: &str, extra: Value, event: &str) {
        let mut item = json!({"id":id,"type":kind,"status":"completed"});
        item.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        consume(
            a,
            &json!({"type":"event_msg","payload":{"type":event,"item":item}}),
            Some("/project"),
        );
    }
    #[test]
    fn lifecycle_deduplicates_and_preserves_failed_patch() {
        let mut a = Activity::default();
        let changes = json!({"changes":{"src/a.rs":{"type":"update"}},"status":"failed"});
        operation(
            &mut a,
            "patch",
            "FileChange",
            changes.clone(),
            "item_started",
        );
        operation(&mut a, "patch", "FileChange", changes, "item_completed");
        let s = a.summary();
        assert_eq!(s["operation_count"], 1);
        assert_eq!(s["targets"][0]["failed"], 1);
        assert_eq!(s["targets"][0]["completed"], 0);
    }
    #[test]
    fn shell_reads_lists_searches_and_decodes_cwd() {
        let mut a = Activity::default();
        operation(
            &mut a,
            "cmd",
            "CommandExecution",
            json!({"cwd":"file:///project/with%20space","command":["/bin/zsh","-lc","cat 'a file.rs' b.rs; sed -n '1,20p' c.rs; rg -n 'needle' src tests; rg --files -g '*.rs'; ls -la"]}),
            "item_completed",
        );
        let targets = a.summary()["targets"].as_array().unwrap().clone();
        assert!(
            targets
                .iter()
                .any(|t| t["path"] == "/project/with space/a file.rs" && t["action"] == "read")
        );
        assert!(
            targets
                .iter()
                .any(|t| t["path"] == "/project/with space/c.rs")
        );
        assert!(
            targets
                .iter()
                .any(|t| t["path"] == "/project/with space/tests" && t["action"] == "search")
        );
        assert!(
            !targets
                .iter()
                .any(|t| t["path"].as_str().unwrap().contains("needle"))
        );
    }
    #[test]
    fn scripts_globs_and_search_basenames_do_not_invent_files() {
        let mut a = Activity::default();
        operation(
            &mut a,
            "cmd",
            "CommandExecution",
            json!({"parsed_cmd":[{"type":"search","path":"missing.rs"}],"command":["sh","-c","uv run python - <<'PY'\nprint('a')\nPY"]}),
            "item_completed",
        );
        assert!(a.summary()["targets"].as_array().unwrap().is_empty());
        assert_eq!(a.summary()["unrecognized_command_count"], 1);
        let mut targets = Vec::new();
        shell_targets("cat src/*.rs", Some("/project"), &mut targets);
        assert!(targets.is_empty());
        shell_targets("cd src; cat ../README.md", Some("/project"), &mut targets);
        assert_eq!(targets[0].path, "/project/README.md");
    }
    #[test]
    fn model_calls_and_native_operations_are_separate() {
        let mut a = Activity::default();
        let call = json!({"type":"response_item","payload":{"type":"custom_tool_call","call_id":"c","name":"exec","input":"private script"}});
        consume(&mut a, &call, None);
        consume(&mut a, &call, None);
        operation(
            &mut a,
            "mcp",
            "McpToolCall",
            json!({"server":"docs","tool":"search","arguments":{"token":"secret"}}),
            "item_completed",
        );
        assert_eq!(a.call_count(), 1);
        assert_eq!(a.summary()["operation_tools"][0]["name"], "docs.search");
        let cache = serde_json::to_string(&a).unwrap();
        assert!(!cache.contains("private script"));
        assert!(!cache.contains("secret"));
    }
    #[test]
    fn changes_include_add_delete_and_move_without_disk_lookup() {
        let mut a = Activity::default();
        operation(
            &mut a,
            "patch",
            "FileChange",
            json!({"changes":{"a.rs":{"type":"update","move_path":"b.rs"},"new.rs":{"type":"add"},"old.rs":{"type":"delete"}}}),
            "item_completed",
        );
        assert_eq!(a.summary()["targets"].as_array().unwrap().len(), 4);
        let cached: Activity = serde_json::from_str(&serde_json::to_string(&a).unwrap()).unwrap();
        assert_eq!(cached.summary(), a.summary());
    }
}
