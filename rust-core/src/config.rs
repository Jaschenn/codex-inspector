use crate::{tokens, util};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub fn merge(base: &mut Value, over: Value) {
    match (base, over) {
        (Value::Object(base), Value::Object(over)) => {
            for (key, value) in over {
                merge(base.entry(key).or_insert(Value::Null), value);
            }
        }
        (base, over) => *base = over,
    }
}
fn secret_container(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), secret_container(v)))
                .collect(),
        ),
        Value::Array(list) => Value::Array(list.iter().map(secret_container).collect()),
        Value::Null => Value::Null,
        _ => json!("***redacted***"),
    }
}
pub fn redact(value: &Value, hint: &str) -> Value {
    let hint = hint.to_lowercase();
    match value {
        Value::Object(map) if ["http_headers", "headers", "env"].contains(&hint.as_str()) => {
            secret_container(&Value::Object(map.clone()))
        }
        Value::Object(map) => {
            Value::Object(map.iter().map(|(k, v)| (k.clone(), redact(v, k))).collect())
        }
        Value::Array(list) => Value::Array(list.iter().map(|v| redact(v, &hint)).collect()),
        Value::String(_)
            if ["key", "token", "secret", "password", "auth", "credential"]
                .iter()
                .any(|s| hint.contains(s)) =>
        {
            json!("***redacted***")
        }
        _ => value.clone(),
    }
}
pub fn scalar(raw: &str) -> Value {
    format!("value = {raw}")
        .parse::<toml::Table>()
        .ok()
        .and_then(|table| serde_json::to_value(table.get("value")?).ok())
        .unwrap_or_else(|| json!(raw))
}
pub fn git_root(cwd: &Path) -> Option<PathBuf> {
    if let Ok((true, output, _)) = util::command(
        "/usr/bin/git",
        &["-C", &cwd.to_string_lossy(), "rev-parse", "--show-toplevel"],
    ) {
        if !output.trim().is_empty() {
            return Some(PathBuf::from(output.trim()));
        }
    }
    if !cwd.is_dir() {
        return None;
    }
    let cwd = util::canonical(cwd);
    for directory in cwd.ancestors() {
        let marker = directory.join(".git");
        if marker.join("HEAD").is_file() {
            return Some(directory.to_path_buf());
        }
        if let Ok(pointer) = fs::read_to_string(marker) {
            if let Some(target) = pointer
                .lines()
                .next()
                .and_then(|s| s.strip_prefix("gitdir:"))
            {
                let target = PathBuf::from(target.trim());
                if directory.join(target).join("HEAD").is_file() {
                    return Some(directory.to_path_buf());
                }
            }
        }
    }
    None
}
fn directories(root: &Path, cwd: &Path) -> Vec<PathBuf> {
    if let Ok(relative) = cwd.strip_prefix(root) {
        let mut list = vec![root.to_path_buf()];
        let mut path = root.to_path_buf();
        for part in relative.components() {
            path.push(part);
            list.push(path.clone());
        }
        list
    } else {
        vec![cwd.to_path_buf()]
    }
}
fn load(path: &Path) -> (Value, Option<String>) {
    if !path.is_file() {
        return (json!({}), None);
    }
    match fs::read_to_string(path)
        .map_err(|e| e.to_string())
        .and_then(|s| s.parse::<toml::Table>().map_err(|e| e.to_string()))
        .and_then(|t| serde_json::to_value(t).map_err(|e| e.to_string()))
    {
        Ok(value) => (value, None),
        Err(error) => (json!({}), Some(error)),
    }
}
fn layer(path: &Path, kind: &str, allowed: bool) -> (Value, Value) {
    let (config, error) = load(path);
    let applied = allowed && config.as_object().is_some_and(|m| !m.is_empty());
    let entry = json!({"kind": kind, "path": path, "exists": path.is_file(), "applied": applied,
        "skip_reason": if !allowed && path.is_file() { Some("项目未标记为 trusted,该层被跳过") } else { None }, "parse_error": error});
    (if applied { config } else { json!({}) }, entry)
}
pub struct Inspection {
    pub merged: Value,
    pub layers: Vec<Value>,
    pub root: Option<PathBuf>,
    pub trust: String,
}
pub fn build(
    home: &Path,
    cwd: &Path,
    profile: Option<&str>,
    overrides: &[(String, Value)],
) -> Inspection {
    let (mut merged, system) = layer(Path::new("/etc/codex/config.toml"), "system", true);
    let (global, global_layer) = layer(&home.join("config.toml"), "global", true);
    let root = git_root(cwd);
    let trust = root
        .as_ref()
        .and_then(|r| global["projects"][r.to_string_lossy().as_ref()]["trust_level"].as_str())
        .filter(|s| ["trusted", "untrusted"].contains(s))
        .unwrap_or("unknown")
        .to_owned();
    merge(&mut merged, global);
    let mut layers = vec![system, global_layer];
    for directory in directories(root.as_deref().unwrap_or(cwd), cwd) {
        let (config, entry) = layer(
            &directory.join(".codex/config.toml"),
            "project",
            trust == "trusted",
        );
        merge(&mut merged, config);
        layers.push(entry);
    }
    if let Some(profile) = profile {
        let (config, entry) = layer(
            &home.join(format!("{profile}.config.toml")),
            "profile",
            true,
        );
        merge(&mut merged, config);
        layers.push(entry);
    }
    if !overrides.is_empty() {
        let mut config = json!({});
        for (key, value) in overrides {
            let mut node = &mut config;
            let parts: Vec<_> = key.split('.').collect();
            for part in &parts[..parts.len() - 1] {
                if !node[*part].is_object() {
                    node[*part] = json!({});
                }
                node = &mut node[*part];
            }
            node[parts[parts.len() - 1]] = value.clone();
        }
        merge(&mut merged, config);
        layers.push(json!({"kind":"cli","path":null,"exists":true,"applied":true,"skip_reason":null,"parse_error":null}));
    }
    Inspection {
        merged,
        layers,
        root,
        trust,
    }
}
fn agents(home: &Path, cwd: &Path, root: Option<&Path>) -> Vec<Value> {
    let mut result = Vec::new();
    let dirs = std::iter::once((home.to_path_buf(), "global")).chain(
        directories(root.unwrap_or(cwd), cwd)
            .into_iter()
            .map(|p| (p, "project")),
    );
    for (directory, scope) in dirs {
        if let Some(path) = ["AGENTS.override.md", "AGENTS.md"]
            .iter()
            .map(|n| directory.join(n))
            .find(|p| p.is_file())
        {
            result.push(json!({"path":path,"exists":true,"scope":scope}));
        }
    }
    result
}
fn skills(home: &Path, cwd: &Path, root: Option<&Path>, merged: &Value) -> Vec<Value> {
    let mut bases = directories(root.unwrap_or(cwd), cwd);
    bases.reverse();
    let dirs = bases
        .into_iter()
        .flat_map(|d| [d.join(".agents/skills"), d.join(".codex/skills")].map(|p| (p, "project")))
        .chain(std::iter::once((home.join("skills"), "global")));
    let mut result = Vec::new();
    for (directory, scope) in dirs {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        let mut paths: Vec<_> = entries
            .filter_map(Result::ok)
            .map(|e| e.path().join("SKILL.md"))
            .filter(|p| p.is_file())
            .collect();
        paths.sort();
        for path in paths {
            let (text, error) = match fs::read_to_string(&path) {
                Ok(s) => (s, None),
                Err(e) => (String::new(), Some(format!("读取失败: {e}"))),
            };
            let mut name = None;
            let mut description = None;
            let mut parse_error = error.clone();
            if !text.is_empty() {
                let mut lines = text.lines();
                if lines.next().is_some_and(|s| s.trim() == "---") {
                    let mut ended = false;
                    for line in lines {
                        if line.trim() == "---" {
                            ended = true;
                            break;
                        }
                        if let Some(value) = line.trim().strip_prefix("name:") {
                            name = Some(value.trim().trim_matches(['\'', '"']).to_string());
                        }
                        if let Some(value) = line.trim().strip_prefix("description:") {
                            description = Some(value.trim().trim_matches(['\'', '"']).to_string());
                        }
                    }
                    if !ended {
                        parse_error = Some("未找到 --- frontmatter 区块".into());
                    }
                } else {
                    parse_error = Some("未找到 --- frontmatter 区块".into());
                }
            }
            let enabled = merged["skills"]["config"]
                .as_array()
                .and_then(|a| {
                    a.iter()
                        .rev()
                        .find(|e| e["path"].as_str().is_some_and(|p| util::expand(p) == path))
                })
                .and_then(|e| e["enabled"].as_bool())
                .unwrap_or(true);
            let (count, encoding, method) = if error.is_none() {
                tokens::estimate(&text)
            } else {
                (None, None, "unavailable")
            };
            result.push(json!({"name":name,"description":description,"path":path,"scope":scope,"enabled":enabled,
                "disabled_reason":if enabled { None } else { Some("被 ~/.codex/config.toml 的 skills.config 显式禁用") },
                "parse_error":parse_error,"token_count":count,"token_encoding":encoding,"token_method":method}));
        }
    }
    result
}
pub fn report(
    home: &Path,
    cwd: &Path,
    profile: Option<&str>,
    overrides: &[(String, Value)],
) -> Value {
    let inspection = build(home, cwd, profile, overrides);
    let redacted = redact(&inspection.merged, "");
    let servers: Vec<_> = redacted["mcp_servers"]
        .as_object()
        .into_iter()
        .flat_map(|m| m.iter())
        .filter(|(_, v)| v.is_object())
        .map(|(k, v)| json!({"name":k,"raw":v}))
        .collect();
    json!({"cwd":cwd,"cwd_error":null,"codex_home":home,"project_root":inspection.root,"is_git_repo":inspection.root.is_some(),
        "trust_level":inspection.trust,"config_layers":inspection.layers,
        "agents_chain":agents(home,cwd,inspection.root.as_deref()),"skills":skills(home,cwd,inspection.root.as_deref(),&inspection.merged),
        "mcp_servers":servers,"merged_config":redacted,"cli_overrides":{"profile":null,"cd":null,"config_path":null,"codex_home":null,"c_overrides":[]},"warnings":[]})
}
