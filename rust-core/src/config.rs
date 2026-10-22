use crate::{tokens, util};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    fs,
    io::Read,
    os::unix::fs::MetadataExt,
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
        // Unusual Git layouts retain the authoritative CLI fallback. Ordinary
        // repos/worktrees and non-repo directories need no external command.
        if directory.join(".git").exists() {
            if let Ok((true, output, _)) = util::command(
                "/usr/bin/git",
                &["-C", &cwd.to_string_lossy(), "rev-parse", "--show-toplevel"],
            ) {
                if !output.trim().is_empty() {
                    return Some(PathBuf::from(output.trim()));
                }
            }
            return None;
        }
    }
    None
}
fn directories(root: &Path, cwd: &Path) -> Vec<PathBuf> {
    let root = util::canonical(root);
    let cwd = util::canonical(cwd);
    if let Ok(relative) = cwd.strip_prefix(&root) {
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
    build_at(
        home,
        cwd,
        profile,
        overrides,
        Path::new("/etc/codex/config.toml"),
    )
}

fn build_at(
    home: &Path,
    cwd: &Path,
    profile: Option<&str>,
    overrides: &[(String, Value)],
    system_path: &Path,
) -> Inspection {
    let (mut merged, system) = layer(system_path, "system", true);
    let (global, global_layer) = layer(&home.join("config.toml"), "global", true);
    let root = git_root(cwd);
    let trust = global["projects"][root.as_deref().unwrap_or(cwd).to_string_lossy().as_ref()]["trust_level"]
        .as_str()
        .filter(|s| ["trusted", "untrusted"].contains(s))
        .unwrap_or("unknown")
        .to_owned();
    merge(&mut merged, global);
    let mut layers = vec![system, global_layer];
    // Profiles supply defaults; a trusted project must be able to override them.
    if let Some(profile) = profile {
        let (config, entry) = layer(
            &home.join(format!("{profile}.config.toml")),
            "profile",
            true,
        );
        merge(&mut merged, config);
        layers.push(entry);
    }
    for directory in directories(root.as_deref().unwrap_or(cwd), cwd) {
        let (mut config, mut entry) = layer(
            &directory.join(".codex/config.toml"),
            "project",
            trust == "trusted",
        );
        let mut ignored = Vec::new();
        if let Some(map) = config.as_object_mut() {
            // Codex rejects project settings that redirect provider/auth or host commands.
            for key in [
                "openai_base_url",
                "chatgpt_base_url",
                "apps_mcp_product_sku",
                "model_provider",
                "model_providers",
                "notify",
                "profile",
                "profiles",
                "experimental_realtime_ws_base_url",
                "otel",
            ] {
                if map.remove(key).is_some() {
                    ignored.push(key);
                }
            }
        }
        entry["ignored_keys"] = json!(ignored);
        merge(&mut merged, config);
        layers.push(entry);
    }
    if !overrides.is_empty() {
        for (key, value) in overrides {
            // Apply sequentially: later scalar/table overrides may replace earlier ones.
            if let Ok(table) = format!("{key} = 0").parse::<toml::Table>() {
                if let Ok(mut config) = serde_json::to_value(table) {
                    fn replace_leaf(node: &mut Value, value: &Value) {
                        if let Some(map) = node.as_object_mut() {
                            for child in map.values_mut() {
                                replace_leaf(child, value);
                            }
                        } else {
                            *node = value.clone();
                        }
                    }
                    replace_leaf(&mut config, value);
                    merge(&mut merged, config);
                }
            }
        }
        layers.push(json!({"kind":"cli","path":null,"exists":true,"applied":true,"skip_reason":null,"parse_error":null}));
    }
    Inspection {
        merged,
        layers,
        root,
        trust,
    }
}
fn instruction_sample(path: &Path, limit: u64) -> Result<Option<Vec<u8>>, String> {
    let mut file = fs::File::open(path).map_err(|error| error.to_string())?;
    let mut sample = Vec::new();
    let mut pending = Vec::new();
    let mut chunk = [0_u8; 4096];
    let mut nonempty = false;
    let cap = usize::try_from(limit.saturating_add(4)).unwrap_or(usize::MAX);
    // Scan whitespace-only prefixes without retaining an arbitrarily large file.
    // A nonempty file must not accidentally fall through to a lower-priority name.
    loop {
        let count = file.read(&mut chunk).map_err(|error| error.to_string())?;
        if count == 0 {
            if !pending.is_empty() {
                return Err("文件末尾不是完整 UTF-8 字符".into());
            }
            break;
        }
        sample.extend_from_slice(&chunk[..count.min(cap.saturating_sub(sample.len()))]);
        pending.extend_from_slice(&chunk[..count]);
        let valid_len = match std::str::from_utf8(&pending) {
            Ok(text) => {
                nonempty |= !text.trim().is_empty();
                pending.len()
            }
            Err(error) if error.error_len().is_none() => {
                let text = std::str::from_utf8(&pending[..error.valid_up_to()])
                    .map_err(|error| error.to_string())?;
                nonempty |= !text.trim().is_empty();
                error.valid_up_to()
            }
            Err(error) => return Err(error.to_string()),
        };
        pending.drain(..valid_len);
        if nonempty && sample.len() >= cap {
            break;
        }
    }
    Ok(nonempty.then_some(sample))
}

fn agents(
    home: &Path,
    cwd: &Path,
    root: Option<&Path>,
    merged: &Value,
) -> (Vec<Value>, Vec<String>) {
    let mut result = Vec::new();
    let mut warnings = Vec::new();
    let mut remaining = merged["project_doc_max_bytes"].as_u64().unwrap_or(32768);
    let fallbacks: Vec<_> = merged["project_doc_fallback_filenames"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let dirs = std::iter::once((home.to_path_buf(), "global")).chain(
        directories(root.unwrap_or(cwd), cwd)
            .into_iter()
            .map(|p| (p, "project")),
    );
    for (directory, scope) in dirs {
        let separator = if result.is_empty() { 0 } else { 2 };
        if remaining <= separator {
            break;
        }
        let names = ["AGENTS.override.md", "AGENTS.md"]
            .into_iter()
            .chain(fallbacks.iter().copied().filter(|_| scope == "project"));
        for name in names {
            let path = directory.join(name);
            if !path.is_file() {
                continue;
            }
            let limit = remaining - separator;
            // Discovery needs presence/size, never retain full instruction text in the report.
            let bytes = match instruction_sample(&path, limit) {
                Ok(Some(bytes)) => bytes,
                Ok(None) => continue,
                Err(error) => {
                    warnings.push(format!("指令文件无法读取：{}：{error}", path.display()));
                    continue;
                }
            };
            let valid = match std::str::from_utf8(&bytes) {
                Ok(text) => text,
                Err(error) if error.error_len().is_none() => {
                    std::str::from_utf8(&bytes[..error.valid_up_to()]).unwrap_or("")
                }
                Err(error) => {
                    warnings.push(format!("指令文件不是 UTF-8：{}：{error}", path.display()));
                    continue;
                }
            };
            let mut included = valid
                .len()
                .min(usize::try_from(limit).unwrap_or(usize::MAX));
            while !valid.is_char_boundary(included) {
                included -= 1;
            }
            let truncated = bytes.len() as u64 > limit;
            result.push(json!({"path":path,"exists":true,"scope":scope,"included_bytes":included,"truncated":truncated}));
            remaining = remaining.saturating_sub(separator + included as u64);
            if truncated {
                warnings.push(format!("指令长度达到 project_doc_max_bytes，{} 只纳入前 {included} 字节，后续文件被跳过。", path.display()));
                return (result, warnings);
            }
            break;
        }
    }
    (result, warnings)
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
fn uncached_report(
    home: &Path,
    cwd: &Path,
    profile: Option<&str>,
    overrides: &[(String, Value)],
) -> Value {
    let inspection = build(home, cwd, profile, overrides);
    let (agents_chain, mut warnings) =
        agents(home, cwd, inspection.root.as_deref(), &inspection.merged);
    for entry in &inspection.layers {
        if let Some(keys) = entry["ignored_keys"]
            .as_array()
            .filter(|keys| !keys.is_empty())
        {
            warnings.push(format!(
                "项目配置 {} 中的受限字段已忽略：{}",
                util::text(&entry["path"]),
                keys.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    }
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
        "agents_chain":agents_chain,"skills":skills(home,cwd,inspection.root.as_deref(),&inspection.merged),
        "mcp_servers":servers,"merged_config":redacted,"cli_overrides":{"profile":null,"cd":null,"codex_home":null,"c_overrides":[]},"warnings":warnings})
}

type FileStamp = Option<(u64, u64, u32, u64, i64, i64, i64, i64)>;
type Signature = Vec<(PathBuf, FileStamp)>;

fn stamp(path: PathBuf, signature: &mut Signature) {
    let metadata = fs::metadata(&path).ok().map(|m| {
        (
            m.dev(),
            m.ino(),
            m.mode(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        )
    });
    signature.push((path, metadata));
}

fn signature(
    home: &Path,
    cwd: &Path,
    profile: Option<&str>,
    fallback_names: &[String],
) -> Signature {
    let mut result = Vec::new();
    stamp(PathBuf::from("/etc/codex/config.toml"), &mut result);
    stamp(home.join("config.toml"), &mut result);
    if let Some(profile) = profile {
        stamp(home.join(format!("{profile}.config.toml")), &mut result);
    }
    // Include missing files and directory listings: creating an override, deleting
    // a Skill, replacing a symlink, chmod and Git-root changes must invalidate too.
    for base in std::iter::once(home).chain(cwd.ancestors()) {
        stamp(base.to_path_buf(), &mut result);
        stamp(base.join(".git"), &mut result);
        stamp(base.join("AGENTS.override.md"), &mut result);
        stamp(base.join("AGENTS.md"), &mut result);
        for name in fallback_names {
            stamp(base.join(name), &mut result);
        }
        stamp(base.join(".codex/config.toml"), &mut result);
        for directory in [base.join(".agents/skills"), base.join(".codex/skills")]
            .into_iter()
            .chain((base == home).then(|| home.join("skills")))
        {
            stamp(directory.clone(), &mut result);
            let mut paths: Vec<_> = fs::read_dir(directory)
                .into_iter()
                .flatten()
                .filter_map(Result::ok)
                .map(|e| e.path().join("SKILL.md"))
                .collect();
            paths.sort();
            for path in paths {
                stamp(path, &mut result);
            }
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
    type Cache = BTreeMap<String, (Signature, Value)>;
    thread_local! { static CACHE: RefCell<Cache> = const { RefCell::new(BTreeMap::new()) }; }
    let key = json!([home, cwd, profile, overrides]).to_string();
    CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some((previous, value)) = cache.get(&key) {
            let names: Vec<String> = value["merged_config"]["project_doc_fallback_filenames"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            let current = signature(home, cwd, profile, &names);
            if previous == &current {
                return value.clone();
            }
        }
        let value = uncached_report(home, cwd, profile, overrides);
        let names: Vec<String> = value["merged_config"]["project_doc_fallback_filenames"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        let current = signature(home, cwd, profile, &names);
        if cache.len() >= 32 {
            cache.clear();
        }
        cache.insert(key, (current, value.clone()));
        value
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let folder = std::env::temp_dir().join(format!(
                "inspector-config-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(folder.join("repo/sub")).unwrap();
            fs::create_dir_all(folder.join("home")).unwrap();
            Self(fs::canonicalize(folder).unwrap())
        }
        fn write(&self, path: &str, text: &str) {
            let path = self.0.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
        fn home(&self) -> PathBuf {
            self.0.join("home")
        }
        fn cwd(&self) -> PathBuf {
            self.0.join("repo/sub")
        }
        fn trusted(&self) {
            self.write("repo/.git/HEAD", "ref: refs/heads/main\n");
            self.write(
                "home/config.toml",
                &format!(
                    "model = 'user'\n[projects.'{}']\ntrust_level = 'trusted'\n",
                    self.0.join("repo").display()
                ),
            );
        }
        fn build(&self, profile: Option<&str>, overrides: &[(String, Value)]) -> Inspection {
            build_at(
                &self.home(),
                &self.cwd(),
                profile,
                overrides,
                &self.0.join("system.toml"),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn project_precedes_profile_and_cli_precedes_project() {
        let f = Fixture::new();
        f.trusted();
        f.write(
            "system.toml",
            "model = 'system'\nsandbox_mode = 'read-only'",
        );
        f.write(
            "home/review.config.toml",
            "model = 'profile'\nmodel_reasoning_effort = 'high'",
        );
        f.write("repo/.codex/config.toml", "model = 'root'");
        f.write("repo/sub/.codex/config.toml", "model = 'nested'");
        let inspected = f.build(Some("review"), &[]);
        assert_eq!(inspected.merged["model"], "nested");
        assert_eq!(inspected.merged["sandbox_mode"], "read-only");
        assert_eq!(inspected.merged["model_reasoning_effort"], "high");
        assert_eq!(
            inspected
                .layers
                .iter()
                .map(|layer| util::text(&layer["kind"]))
                .collect::<Vec<_>>(),
            ["system", "global", "profile", "project", "project"]
        );
        assert_eq!(
            f.build(Some("review"), &[("model".into(), json!("cli"))])
                .merged["model"],
            "cli"
        );
    }

    #[test]
    fn headers_and_environment_are_redacted_without_mutating_input() {
        let input = json!({"mcp_servers":{"example":{
            "command":"example-server",
            "headers":{"X-Custom":"private-value"},
            "http_headers":{"X-Access":"private-value"},
            "env":{"CUSTOM_ACCESS":"private-value","PORT":1234}
        }},"model":"example-model","args":["serve"],"enabled":true});
        let output = redact(&input, "");
        let server = &output["mcp_servers"]["example"];
        assert_eq!(server["command"], "example-server");
        assert_eq!(server["headers"]["X-Custom"], "***redacted***");
        assert_eq!(server["http_headers"]["X-Access"], "***redacted***");
        assert_eq!(
            server["env"],
            json!({"CUSTOM_ACCESS":"***redacted***","PORT":"***redacted***"})
        );
        assert_eq!(
            input["mcp_servers"]["example"]["headers"]["X-Custom"],
            "private-value"
        );
        for key in ["model", "args", "enabled"] {
            assert_eq!(output[key], input[key]);
        }
    }

    #[test]
    fn mcp_report_contains_only_redacted_headers() {
        let f = Fixture::new();
        f.write(
            "home/config.toml",
            "[mcp_servers.example.headers]\nX-Custom = 'private-value'",
        );
        let output = uncached_report(&f.home(), &f.cwd(), None, &[]);
        assert_eq!(
            output["mcp_servers"][0]["raw"]["headers"]["X-Custom"],
            "***redacted***"
        );
        assert_eq!(
            output["merged_config"]["mcp_servers"]["example"]["headers"]["X-Custom"],
            "***redacted***"
        );
    }

    #[test]
    fn skill_tokens_include_frontmatter_and_full_body() {
        let f = Fixture::new();
        let text = "---\nname: example\ndescription: test\n---\n# 完整正文\nUse this skill.\n";
        f.write("home/skills/example/SKILL.md", text);
        let result = skills(&f.home(), &f.cwd(), None, &json!({}));
        let expected = tiktoken_rs::o200k_base()
            .unwrap()
            .encode_ordinary(text)
            .len();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0]["token_count"], expected);
        assert_eq!(result[0]["token_encoding"], "o200k_base");
        assert_eq!(result[0]["token_method"], "tiktoken");
    }

    #[test]
    fn unreadable_skill_tokens_remain_unavailable() {
        let f = Fixture::new();
        f.write("home/skills/example/SKILL.md", "placeholder");
        fs::write(f.home().join("skills/example/SKILL.md"), [0xff, 0xfe]).unwrap();
        let result = skills(&f.home(), &f.cwd(), None, &json!({}));
        assert_eq!(result.len(), 1);
        assert!(result[0]["token_count"].is_null());
        assert_eq!(result[0]["token_method"], "unavailable");
        assert!(result[0]["parse_error"].is_string());
    }

    #[test]
    fn untrusted_project_is_skipped_and_trusted_non_git_directory_loads() {
        let f = Fixture::new();
        f.write("home/config.toml", "model = 'user'");
        f.write("repo/sub/.codex/config.toml", "model = 'project'");
        assert_eq!(f.build(None, &[]).merged["model"], "user");
        f.write(
            "home/config.toml",
            &format!(
                "[projects.'{}']\ntrust_level = 'trusted'",
                f.cwd().display()
            ),
        );
        assert_eq!(f.build(None, &[]).merged["model"], "project");
    }

    #[test]
    fn project_cannot_override_provider_or_host_commands() {
        let f = Fixture::new();
        f.trusted();
        f.write(
            "home/review.config.toml",
            "model_provider = 'user-provider'\nnotify = ['user-command']",
        );
        f.write(
            "repo/.codex/config.toml",
            "model = 'project'\nmodel_provider = 'project-provider'\nnotify = ['project-command']",
        );
        let result = f.build(Some("review"), &[]);
        assert_eq!(result.merged["model_provider"], "user-provider");
        assert_eq!(result.merged["notify"], json!(["user-command"]));
        assert_eq!(result.merged["model"], "project");
        assert_eq!(
            result.layers[3]["ignored_keys"],
            json!(["model_provider", "notify"])
        );
    }

    #[test]
    fn quoted_keys_and_scalar_table_replacement_follow_override_order() {
        let f = Fixture::new();
        let result = f.build(
            None,
            &[
                ("settings".into(), json!(false)),
                ("settings.enabled".into(), json!(true)),
                ("mcp_servers.\"with.dot\".enabled".into(), json!(false)),
                ("".into(), json!(1)),
            ],
        );
        assert_eq!(result.merged["settings"], json!({"enabled":true}));
        assert_eq!(result.merged["mcp_servers"]["with.dot"]["enabled"], false);
        assert_eq!(
            f.build(
                None,
                &[
                    ("settings.enabled".into(), json!(true)),
                    ("settings".into(), json!(false))
                ]
            )
            .merged["settings"],
            false
        );
    }

    #[test]
    fn instruction_discovery_skips_empty_overrides_and_uses_project_fallbacks() {
        let f = Fixture::new();
        f.trusted();
        f.write("home/AGENTS.override.md", " \n\t");
        f.write("home/AGENTS.md", "global");
        f.write("repo/AGENTS.override.md", "");
        f.write("repo/AGENTS.md", " \n");
        f.write("repo/TEAM.txt", "root");
        f.write("repo/sub/AGENTS.md", "nested");
        let (chain, warnings) = agents(
            &f.home(),
            &f.cwd(),
            Some(&f.0.join("repo")),
            &json!({"project_doc_fallback_filenames":["TEAM.txt"]}),
        );
        assert!(warnings.is_empty());
        assert_eq!(chain.len(), 3);
        assert_eq!(chain[0]["path"], json!(f.home().join("AGENTS.md")));
        assert_eq!(chain[1]["path"], json!(f.0.join("repo/TEAM.txt")));
        assert_eq!(chain[2]["scope"], "project");
    }

    #[test]
    fn instruction_budget_preserves_utf8_and_stops_later_files() {
        let f = Fixture::new();
        f.write("home/AGENTS.md", "G");
        f.write("repo/AGENTS.md", "你好x");
        f.write("repo/sub/AGENTS.md", "later");
        let (chain, warnings) = agents(
            &f.home(),
            &f.cwd(),
            Some(&f.0.join("repo")),
            &json!({"project_doc_max_bytes":8}),
        );
        assert_eq!(chain.len(), 2);
        assert_eq!(chain[1]["included_bytes"], 3);
        assert_eq!(chain[1]["truncated"], true);
        assert_eq!(warnings.len(), 1);
        assert!(
            agents(
                &f.home(),
                &f.cwd(),
                None,
                &json!({"project_doc_max_bytes":0})
            )
            .0
            .is_empty()
        );
    }

    #[test]
    fn whitespace_prefix_does_not_hide_nonempty_priority_file() {
        let f = Fixture::new();
        f.write(
            "repo/sub/AGENTS.override.md",
            &("\u{2003}".repeat(2000) + "rules"),
        );
        f.write("repo/sub/AGENTS.md", "fallback");
        let (chain, _) = agents(
            &f.home(),
            &f.cwd(),
            None,
            &json!({"project_doc_max_bytes":6}),
        );
        assert_eq!(chain[0]["path"], json!(f.cwd().join("AGENTS.override.md")));
        assert_eq!(chain[0]["truncated"], true);
        f.write("repo/sub/AGENTS.override.md", &"\u{2003}".repeat(2000));
        let (chain, _) = agents(
            &f.home(),
            &f.cwd(),
            None,
            &json!({"project_doc_max_bytes":6}),
        );
        assert_eq!(chain[0]["path"], json!(f.cwd().join("AGENTS.md")));
    }

    #[test]
    fn fallback_content_changes_invalidate_cached_discovery() {
        let f = Fixture::new();
        f.trusted();
        f.write(
            "repo/.codex/config.toml",
            "project_doc_fallback_filenames = ['TEAM.txt']\nproject_doc_max_bytes = 5",
        );
        f.write("repo/TEAM.txt", "small");
        let before = report(&f.home(), &f.cwd(), None, &[]);
        assert_eq!(before["agents_chain"][0]["truncated"], false);
        f.write("repo/TEAM.txt", "larger contents");
        let after = report(&f.home(), &f.cwd(), None, &[]);
        assert_eq!(after["agents_chain"][0]["truncated"], true);
    }
}
