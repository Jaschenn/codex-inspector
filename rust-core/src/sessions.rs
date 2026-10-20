use crate::{
    config,
    statistics::{self, Metrics, TOKEN_FIELDS},
    util,
};
use rusqlite::{Connection, OpenFlags, types::ValueRef};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    rc::Rc,
    time::{Duration, UNIX_EPOCH},
};
use walkdir::WalkDir;
const LIMIT: usize = 300;
const CACHE_VERSION: u32 = 3; // Rebuild indexes that may contain foreign-thread turns.
const PREVIEW: usize = 1800;
const ORIGINATORS: [&str; 5] = [
    "Codex Desktop",
    "codex-tui",
    "codex-vscode",
    "codex_vscode",
    "Codex VS Code",
];

fn child(row: &Value) -> bool {
    util::text(&row["source"])
        .to_lowercase()
        .contains("subagent")
        || row["source"].is_object()
            && row["source"]
                .to_string()
                .to_lowercase()
                .contains("subagent")
        || row["agent_path"]
            .as_str()
            .is_some_and(|p| !p.is_empty() && p != "/root")
}
fn summary(row: &Value, home: &Path) -> Value {
    let id = util::text(&row["id"]);
    let title = ["name", "title", "thread_name"]
        .iter()
        .find_map(|k| row[*k].as_str().filter(|s| !s.is_empty()))
        .unwrap_or("未命名聊天");
    let path = row["rollout_path"]
        .as_str()
        .map(|raw| rollout_path(home, raw));
    json!({"id":format!("{}::{id}",home.display()),"thread_id":id,"title":util::truncate(title,500),"cwd":row["cwd"],"codex_home":home,"rollout_path":path,
        "updated_at":row.get("updated_at").unwrap_or(&json!(0)),"archived":row["archived"].as_bool().unwrap_or_else(|| row["archived"].as_i64().unwrap_or(0) != 0),
        "source":row.get("source").unwrap_or(&json!("unknown")),"model":row["model"],
        "primary_source":row["source"] == "cli" || row["source"] == "vscode" && (util::text(&row["originator"]).is_empty() || ORIGINATORS.contains(&util::text(&row["originator"])))})
}
fn rollout_path(home: &Path, raw: &str) -> PathBuf {
    let path = home.join(util::expand(raw));
    if !path.exists() && path.extension().is_some_and(|s| s == "jsonl") {
        let mut compressed = path.as_os_str().to_os_string();
        compressed.push(".zst");
        let compressed = PathBuf::from(compressed);
        if compressed.is_file() {
            return compressed;
        }
    }
    path
}
fn compressed(path: &Path) -> bool {
    path.extension().is_some_and(|s| s == "zst")
}
fn open_rollout(path: &Path) -> std::io::Result<Box<dyn Read>> {
    let file = fs::File::open(path)?;
    if compressed(path) {
        Ok(Box::new(zstd::stream::read::Decoder::new(file)?))
    } else {
        Ok(Box::new(file))
    }
}
fn database(home: &Path) -> Option<PathBuf> {
    let mut dirs = vec![home.to_path_buf(), home.join("sqlite")];
    if let Ok(path) = std::env::var("CODEX_SQLITE_HOME") {
        dirs.push(util::expand(&path));
    }
    dirs.into_iter()
        .filter_map(|d| fs::read_dir(d).ok())
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter_map(|p| {
            let name = p.file_name()?.to_str()?;
            let number = name
                .strip_prefix("state_")?
                .strip_suffix(".sqlite")?
                .parse::<u64>()
                .ok()?;
            // Upgrades can leave identical state_N.sqlite names in both locations.
            // Compare actual thread activity (including WAL), not directory iteration
            // order or schema version alone, which can select an abandoned database.
            let connection = Connection::open_with_flags(
                &p,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )
            .ok()?;
            connection.busy_timeout(Duration::from_millis(500)).ok()?;
            let updated: i64 = connection
                .query_row(
                    "SELECT COALESCE(MAX(updated_at), 0) FROM threads",
                    [],
                    |row| row.get(0),
                )
                .ok()?;
            let modified = p
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(UNIX_EPOCH);
            Some((updated, number, modified, p))
        })
        .max_by_key(|(updated, number, modified, _)| (*updated, *number, *modified))
        .map(|(_, _, _, p)| p)
}
fn catalog_db(home: &Path, archived: bool) -> Option<Vec<Value>> {
    let path = database(home)?;
    // SQLite is linked from macOS; no bundled database runtime. Never create or migrate Codex state.
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    connection.busy_timeout(Duration::from_millis(500)).ok()?;
    let mut info = connection.prepare("PRAGMA table_info(threads)").ok()?;
    let columns: BTreeSet<String> = info
        .query_map([], |r| r.get(1))
        .ok()?
        .filter_map(Result::ok)
        .collect();
    if !columns.contains("id") || !columns.contains("updated_at") {
        return None;
    }
    let names: Vec<_> = [
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
    ]
    .into_iter()
    .filter(|n| columns.contains(*n))
    .collect();
    let query = format!(
        "SELECT {} FROM threads ORDER BY updated_at DESC",
        names.join(",")
    );
    let mut statement = connection.prepare(&query).ok()?;
    let rows = statement
        .query_map([], |row| {
            let mut value = json!({});
            for (i, name) in names.iter().enumerate() {
                value[*name] = match row.get_ref(i)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(v) => json!(v),
                    ValueRef::Real(v) => json!(v),
                    ValueRef::Text(v) => json!(String::from_utf8_lossy(v)),
                    ValueRef::Blob(_) => Value::Null,
                };
            }
            Ok(value)
        })
        .ok()?;
    let mut result = Vec::new();
    for row in rows {
        let row = row.ok()?;
        if !child(&row) && (archived || row["archived"].as_i64().unwrap_or(0) == 0) {
            result.push(summary(&row, home));
        }
    }
    Some(result)
}
fn catalog_files(home: &Path, archived: bool, other: bool) -> Vec<Value> {
    let mut names = BTreeMap::new();
    if let Ok(file) = fs::File::open(home.join("session_index.jsonl")) {
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if let Some(id) = value["id"].as_str() {
                    names.insert(id.to_owned(), value["thread_name"].clone());
                }
            }
        }
    }
    let dirs = std::iter::once(home.join("sessions"))
        .chain(archived.then(|| home.join("archived_sessions")));
    let mut paths: Vec<_> = dirs
        .flat_map(|dir| WalkDir::new(dir).into_iter().filter_map(Result::ok))
        .filter(|e| {
            e.file_type().is_file()
                && e.file_name().to_str().is_some_and(|s| {
                    s.starts_with("rollout-")
                        && (s.ends_with(".jsonl") || s.ends_with(".jsonl.zst"))
                })
        })
        .map(|e| e.into_path())
        .collect();
    paths.sort_by_cached_key(|p| {
        std::cmp::Reverse(
            p.metadata()
                .and_then(|m| m.modified())
                .unwrap_or(UNIX_EPOCH),
        )
    });
    let mut result = Vec::new();
    for path in paths {
        let Ok(file) = open_rollout(&path) else {
            continue;
        };
        let mut first = String::new();
        if BufReader::new(file.take(1024 * 1024))
            .read_line(&mut first)
            .is_err()
        {
            continue;
        }
        let Ok(row) = serde_json::from_str::<Value>(&first) else {
            continue;
        };
        if row["type"] != "session_meta" || !row["payload"].is_object() {
            continue;
        }
        let mut metadata = row["payload"].clone();
        let id = util::text(&metadata["id"]);
        if id.is_empty() || child(&metadata) {
            continue;
        }
        metadata["title"] = names.get(id).cloned().unwrap_or(Value::Null);
        metadata["rollout_path"] = json!(path);
        metadata["updated_at"] = json!(
            path.metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0)
        );
        metadata["archived"] = json!(
            path.components()
                .any(|c| c.as_os_str() == "archived_sessions")
        );
        let item = summary(&metadata, home);
        if !other && item["primary_source"] != true {
            continue;
        }
        result.push(item);
        if result.len() >= LIMIT {
            break;
        }
    }
    result
}
pub fn list(homes: &[PathBuf], archived: bool, other: bool) -> Vec<Value> {
    let homes: BTreeSet<_> = homes.iter().map(|p| util::canonical(p)).collect();
    let mut result: Vec<_> = homes
        .into_iter()
        .flat_map(|home| {
            catalog_db(&home, archived).unwrap_or_else(|| catalog_files(&home, archived, other))
        })
        .filter(|s| other || s["primary_source"] == true)
        .collect();
    result.sort_by(|a, b| {
        b["updated_at"]
            .as_f64()
            .unwrap_or(0.0)
            .total_cmp(&a["updated_at"].as_f64().unwrap_or(0.0))
    });
    result.truncate(LIMIT);
    result
}
#[derive(Clone, Serialize, Deserialize)]
pub struct State {
    version: u32,
    offset: u64,
    inode: u64,
    mtime_ns: i128,
    file_size: u64,
    boundary_hash: String,
    pub metadata: Value,
    pub turns: Vec<Turn>,
    instructions: BTreeMap<String, Value>,
    active_instructions: Vec<String>,
    pub current_turn_id: Option<String>,
    explicit_boundaries: bool,
    pub last_thread_usage: Option<BTreeMap<String, u64>>,
    malformed_lines: u64,
}
impl Default for State {
    fn default() -> Self {
        Self {
            version: CACHE_VERSION,
            offset: 0,
            inode: 0,
            mtime_ns: 0,
            file_size: 0,
            boundary_hash: String::new(),
            metadata: json!({}),
            turns: Vec::new(),
            instructions: BTreeMap::new(),
            active_instructions: Vec::new(),
            current_turn_id: None,
            explicit_boundaries: false,
            last_thread_usage: None,
            malformed_lines: 0,
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Turn {
    pub id: String,
    number: usize,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    status: String,
    cwd: Option<String>,
    model: Option<String>,
    user_preview: String,
    assistant_preview: String,
    tool_count: u64,
    instruction_ids: Vec<String>,
    instruction_sources: Vec<String>,
    pub metrics: Metrics,
}
fn turn(state: &mut State, payload: &Value, time: Option<&str>) -> usize {
    let id = payload["turn_id"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| state.current_turn_id.clone())
        .unwrap_or_else(|| format!("legacy-turn-{}", state.turns.len() + 1));
    if let Some(index) = state.turns.iter().position(|t| t.id == id) {
        if index + 1 == state.turns.len() {
            state.current_turn_id = Some(id);
        }
        return index;
    }
    let baseline = state.last_thread_usage.clone().or_else(|| {
        (state.turns.is_empty()
            && !util::text(&state.metadata["id"]).is_empty()
            && state.metadata["forked_from_id"].is_null())
        .then(|| TOKEN_FIELDS.iter().map(|k| ((*k).into(), 0)).collect())
    });
    state.current_turn_id = Some(id.clone());
    state.turns.push(Turn {
        id,
        number: state.turns.len() + 1,
        started_at: time.map(str::to_owned),
        completed_at: None,
        status: "in_progress".into(),
        cwd: None,
        model: None,
        user_preview: String::new(),
        assistant_preview: String::new(),
        tool_count: 0,
        instruction_ids: state.active_instructions.clone(),
        instruction_sources: Vec::new(),
        metrics: Metrics::new(baseline),
    });
    state.turns.len() - 1
}
fn preview(turn: &mut Turn, text: &str) {
    if !text.is_empty() && !turn.user_preview.contains(&util::truncate(text, PREVIEW)) {
        turn.user_preview = util::truncate(
            &format!(
                "{}{}{text}",
                turn.user_preview,
                if turn.user_preview.is_empty() {
                    ""
                } else {
                    "\n\n"
                }
            ),
            PREVIEW,
        );
    }
}
fn consume(state: &mut State, row: &Value) {
    let payload = &row["payload"];
    if !payload.is_object() {
        return;
    }
    // Filter before changing the active turn, not just when counting tokens:
    // subsequent records without a turn ID must still belong to this thread.
    let thread = util::text(&payload["thread_id"]);
    let own = util::text(&state.metadata["id"]);
    if !thread.is_empty() && !own.is_empty() && thread != own {
        return;
    }
    let kind = util::text(&payload["type"]);
    let row_kind = util::text(&row["type"]);
    let time = row["timestamp"].as_str();
    match row_kind {
        "session_meta" => {
            state.metadata = json!({});
            for key in [
                "id",
                "cwd",
                "model",
                "source",
                "originator",
                "forked_from_id",
            ] {
                state.metadata[key] = payload[key].clone();
            }
            return;
        }
        "turn_context" => {
            let index = turn(state, payload, time);
            let turn = &mut state.turns[index];
            if let Some(cwd) = payload["cwd"].as_str().filter(|s| !s.is_empty()) {
                turn.cwd = Some(cwd.into());
            }
            if let Some(model) = payload["model"].as_str().filter(|s| !s.is_empty()) {
                turn.model = Some(model.into());
            }
            if let Some(sources) = payload
                .get("instruction_sources")
                .or_else(|| payload.get("instructionSources"))
                .and_then(Value::as_array)
            {
                turn.instruction_sources = sources
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect();
            }
            return;
        }
        "compacted" => {
            state.active_instructions.clear();
            return;
        }
        "event_msg" => match kind {
            "task_started" | "turn_started" => {
                state.explicit_boundaries = true;
                turn(state, payload, time);
                return;
            }
            "task_complete" | "turn_complete" | "turn_completed" | "turn_aborted"
            | "task_aborted" => {
                let index = turn(state, payload, time);
                let turn = &mut state.turns[index];
                turn.completed_at = time.map(str::to_owned);
                turn.status = if kind.contains("aborted") {
                    "interrupted"
                } else {
                    "completed"
                }
                .into();
                if let Some(message) = payload["last_agent_message"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                {
                    turn.assistant_preview = util::truncate(message, PREVIEW);
                }
                return;
            }
            "user_message" => {
                let message = util::text(&payload["message"]);
                if state
                    .current_turn_id
                    .as_ref()
                    .and_then(|id| state.turns.iter().find(|t| &t.id == id))
                    .is_some_and(|t| {
                        t.status != "in_progress"
                            || !state.explicit_boundaries
                                && !t.user_preview.is_empty()
                                && !t.user_preview.contains(&util::truncate(message, PREVIEW))
                    })
                {
                    state.current_turn_id = None;
                }
                let index = turn(state, payload, time);
                preview(&mut state.turns[index], message);
                return;
            }
            _ => {}
        },
        _ => {}
    }
    if row_kind != "response_item"
        || ![
            "message",
            "function_call",
            "custom_tool_call",
            "local_shell_call",
        ]
        .contains(&kind)
    {
        return;
    }
    let metadata = &payload["internal_chat_message_metadata_passthrough"];
    if state.current_turn_id.is_none()
        && metadata["turn_id"].is_null()
        && payload["role"] == "developer"
    {
        return;
    }
    let index = turn(state, metadata, time);
    if kind != "message" {
        state.turns[index].tool_count += 1;
        return;
    }
    let Some(content) = payload["content"].as_array() else {
        return;
    };
    for (i, item) in content.iter().enumerate() {
        let Some(text) = item["text"].as_str() else {
            continue;
        };
        let item_kind = metadata["content_item_kinds"]
            .get(i)
            .and_then(Value::as_str)
            .unwrap_or("");
        if item_kind.contains("agents_md") || text.starts_with("# AGENTS.md instructions") {
            let key = util::hash(text);
            state.instructions.entry(key.clone()).or_insert_with(|| json!({"id":key,"title":util::truncate(text.lines().next().unwrap_or("指令文本"),200),"text":util::truncate(text,128000),"truncated":text.chars().count()>128000,"first_turn_number":state.turns[index].number}));
            if !state.active_instructions.contains(&key) {
                state.active_instructions.push(key.clone());
            }
            if !state.turns[index].instruction_ids.contains(&key) {
                state.turns[index].instruction_ids.push(key);
            }
        } else if payload["role"] == "user"
            && !item_kind.starts_with("environments.")
            && !text.starts_with("<environment_context>")
        {
            preview(&mut state.turns[index], text);
        } else if payload["role"] == "assistant"
            && (payload["phase"].is_null()
                || ["final_answer", "final"].contains(&util::text(&payload["phase"])))
        {
            state.turns[index].assistant_preview = util::truncate(text, PREVIEW);
        }
    }
}
fn boundary(file: &mut fs::File, offset: u64) -> std::io::Result<String> {
    file.seek(SeekFrom::Start(offset.saturating_sub(128)))?;
    let mut bytes = vec![0; offset.min(128) as usize];
    file.read_exact(&mut bytes)?;
    Ok(util::hash(bytes))
}
pub fn write_cache(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    // Create with restrictive permissions before writing; refuse to follow an existing temporary symlink.
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let result = (|| {
        file.write_all(bytes)?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}
pub fn index(path: &Path) -> Result<Rc<State>, String> {
    thread_local! { static INDEXES: RefCell<BTreeMap<PathBuf, Rc<State>>> = const { RefCell::new(BTreeMap::new()) }; }
    INDEXES.with(|indexes| {
        let mut indexes = indexes.borrow_mut();
        // Move the cached index into the incremental parser; do not clone every
        // historical turn and metric twice for each one-second refresh.
        let previous = indexes.remove(path).map(Rc::unwrap_or_clone);
        let state = Rc::new(index_from(path, previous)?);
        // Bound memory when the user browses many large historical conversations.
        if indexes.len() >= 2 {
            indexes.clear();
        }
        indexes.insert(path.to_path_buf(), state.clone());
        Ok(state)
    })
}

fn index_from(path: &Path, memory: Option<State>) -> Result<State, String> {
    let root = std::env::var_os("CODEX_INSPECTOR_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| util::home().join("Library/Caches/CodexInspector"));
    let cache = root.join(format!(
        "rust-{}.json",
        util::hash(path.to_string_lossy().as_bytes())
    ));
    index_with_cache(path, memory, &cache)
}

fn index_with_cache(path: &Path, memory: Option<State>, cache: &Path) -> Result<State, String> {
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    let stat = file.metadata().map_err(|e| e.to_string())?;
    let mtime = i128::from(stat.mtime()) * 1_000_000_000 + i128::from(stat.mtime_nsec());
    let cached = memory.or_else(|| {
        fs::read(cache)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<State>(&bytes).ok())
    });
    let mut state = State::default();
    if let Some(cached) = cached {
        // A Zstd stream cannot seek to a decoded offset. Reuse immutable archive indexes,
        // and rebuild changed archives rather than confusing compressed and decoded bytes.
        if compressed(path)
            && cached.version == CACHE_VERSION
            && cached.inode == stat.ino()
            && cached.mtime_ns == mtime
            && cached.file_size == stat.len()
            && boundary(&mut file, stat.len()).ok().as_deref()
                == Some(cached.boundary_hash.as_str())
        {
            return Ok(cached);
        }
        if !compressed(path)
            && cached.version == CACHE_VERSION
            && cached.inode == stat.ino()
            && cached.offset <= stat.len()
            && cached.mtime_ns <= mtime
            && (cached.offset != stat.len() || cached.mtime_ns == mtime)
            && boundary(&mut file, cached.offset).ok().as_deref()
                == Some(cached.boundary_hash.as_str())
        {
            state = cached;
        }
    }
    let initial = state.offset;
    file.seek(SeekFrom::Start(initial))
        .map_err(|e| e.to_string())?;
    let input: Box<dyn Read> = if compressed(path) {
        Box::new(zstd::stream::read::Decoder::new(file).map_err(|e| e.to_string())?)
    } else {
        Box::new(file)
    };
    let mut reader = BufReader::new(input);
    let mut line = Vec::new();
    loop {
        line.clear();
        let length = reader
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if length == 0 || line.last() != Some(&b'\n') {
            break;
        }
        match serde_json::from_slice::<Value>(&line) {
            Ok(row) if row.is_object() => {
                consume(&mut state, &row);
                statistics::consume(&mut state, &row);
            }
            _ => state.malformed_lines += 1,
        }
        state.offset += length as u64;
    }
    state.inode = stat.ino();
    state.mtime_ns = mtime;
    state.file_size = stat.len();
    let mut raw_file = fs::File::open(path).map_err(|e| e.to_string())?;
    state.boundary_hash = boundary(
        &mut raw_file,
        if compressed(path) {
            stat.len()
        } else {
            state.offset
        },
    )
    .map_err(|e| e.to_string())?;
    if state.offset != initial || !cache.exists() {
        if let Ok(bytes) = serde_json::to_vec(&state) {
            let _ = write_cache(cache, &bytes);
        }
    }
    Ok(state)
}
pub fn inspect(summary: &Value, turn_id: Option<&str>) -> Result<Value, String> {
    inspect_detail(summary, turn_id, true)
}

/// Menu summaries use the same log evidence but avoid generating configuration
/// and instruction previews that are only needed in the detail window.
pub fn menu(summary: &Value) -> Result<Value, String> {
    inspect_detail(summary, None, false)
}

fn inspect_detail(summary: &Value, turn_id: Option<&str>, detailed: bool) -> Result<Value, String> {
    let mut result = summary.clone();
    result["requested_turn_id"] = json!(turn_id);
    result["turns"] = json!([]);
    result["selected_turn"] = Value::Null;
    result["inspection"] = Value::Null;
    let home = util::expand(util::text(&summary["codex_home"]));
    let Some(raw) = summary["rollout_path"].as_str().filter(|s| !s.is_empty()) else {
        result["error"] = json!("这条聊天记录没有可读取的本地日志路径。");
        return Ok(result);
    };
    let path = rollout_path(&home, raw);
    result["rollout_path"] = json!(path);
    let state = match index(&path) {
        Ok(state) => state,
        Err(error) => {
            result["error"] = json!(format!("聊天日志无法读取：{error}\n{}", path.display()));
            return Ok(result);
        }
    };
    if detailed {
        result["turns"] = json!(state.turns.iter().map(|t| json!({"id":t.id,"number":t.number,"started_at":t.started_at,"completed_at":t.completed_at,"status":t.status,"cwd":t.cwd,"model":t.model,"user_preview":t.user_preview,"tool_count":t.tool_count})).collect::<Vec<_>>());
    }
    let selected = if let Some(id) = turn_id {
        state.turns.iter().find(|t| t.id == id)
    } else {
        state.turns.last()
    };
    let Some(selected) = selected else {
        result["error"] = json!(if turn_id.is_some() {
            "该轮次已不在日志中，请切换到最新轮次。"
        } else {
            "聊天尚未记录可检查的轮次。"
        });
        return Ok(result);
    };
    // Metrics can hold thousands of intervals; do not serialize them only to
    // immediately discard them. The public summary includes derived totals.
    let mut selected_value = json!({"id":selected.id,"number":selected.number,
        "started_at":selected.started_at,"completed_at":selected.completed_at,"status":selected.status,
        "cwd":selected.cwd,"model":selected.model,"tool_count":selected.tool_count,
        "user_preview":selected.user_preview,"assistant_preview":selected.assistant_preview,
        "instruction_ids":selected.instruction_ids,"instruction_sources":selected.instruction_sources});
    selected_value["statistics"] = statistics::summary(selected);
    if !detailed {
        for key in [
            "user_preview",
            "assistant_preview",
            "instruction_ids",
            "instruction_sources",
        ] {
            selected_value.as_object_mut().unwrap().remove(key);
        }
        result["conversation_tokens"] = statistics::conversation_tokens(&state.turns);
        result["selected_turn"] = selected_value;
        return Ok(result);
    }
    result["selected_turn"] = selected_value;
    result["recorded_instructions"] = json!(
        selected
            .instruction_ids
            .iter()
            .filter_map(|id| state.instructions.get(id))
            .collect::<Vec<_>>()
    );
    let cwd = selected
        .cwd
        .as_deref()
        .or_else(|| state.metadata["cwd"].as_str())
        .or_else(|| summary["cwd"].as_str());
    result["directory_source"] = json!(if selected.cwd.is_some() {
        "turn_context"
    } else {
        "session_metadata"
    });
    let Some(cwd) = cwd.filter(|s| s.starts_with('/')) else {
        result["error"] = json!("记录中没有可用于本机检查的绝对工作目录。");
        return Ok(result);
    };
    result["cwd"] = json!(cwd);
    if !Path::new(cwd).is_dir() {
        result["error"] = json!("该轮次的工作目录在本机不存在，仍可查看轮次与指令记录。");
        return Ok(result);
    }
    let mut inspection = config::report(&home, Path::new(cwd), None, &[]);
    let mut warnings = Vec::new();
    if selected.cwd.is_none() {
        warnings.push("本轮未记录 cwd；当前使用会话元数据中的目录。".into());
    }
    if state.malformed_lines > 0 {
        warnings.push(format!(
            "日志中有 {} 条无法解析的完整记录，结果可能不完整。",
            state.malformed_lines
        ));
    }
    inspection["warnings"] = json!(warnings);
    result["inspection"] = inspection;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "codex-inspector-sessions-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn log() -> String {
        [
            json!({"type": "session_meta", "payload": {"id": "parent"}}),
            json!({"type": "event_msg", "payload": {"type": "task_started", "turn_id": "parent-turn"}}),
            json!({"type": "event_msg", "payload": {"type": "task_started", "thread_id": "child", "turn_id": "child-turn"}}),
        ]
        .into_iter()
        .map(|row| format!("{row}\n"))
        .collect()
    }

    fn apply(state: &mut State, kind: &str, payload: Value) {
        let row = json!({"type": kind, "timestamp": "2026-10-20T12:00:00Z", "payload": payload});
        consume(state, &row);
        statistics::consume(state, &row);
    }

    #[test]
    fn unknown_originator_preserves_interactive_sessions() {
        for originator in [Value::Null, json!(""), json!("Codex Desktop")] {
            let row = json!({"id": "chat", "source": "vscode", "originator": originator});
            assert_eq!(summary(&row, Path::new("/home"))["primary_source"], true);
        }
        let row = json!({"id": "chat", "source": "vscode"});
        assert_eq!(summary(&row, Path::new("/home"))["primary_source"], true);
        let row = json!({"id": "chat", "source": "vscode", "originator": "OtherClient"});
        assert_eq!(summary(&row, Path::new("/home"))["primary_source"], false);
    }

    #[test]
    fn foreign_events_cannot_change_parent_turns_or_usage_attribution() {
        let mut state = State::default();
        apply(&mut state, "session_meta", json!({"id": "parent"}));
        apply(
            &mut state,
            "event_msg",
            json!({"type": "task_started", "turn_id": "parent-turn"}),
        );
        apply(
            &mut state,
            "event_msg",
            json!({"type": "task_started", "thread_id": "child", "turn_id": "child-turn"}),
        );
        apply(
            &mut state,
            "event_msg",
            json!({"type": "token_count", "info": {"total_token_usage": {"total_tokens": 123}}}),
        );
        assert_eq!(state.turns.len(), 1);
        assert_eq!(state.current_turn_id.as_deref(), Some("parent-turn"));
        assert_eq!(
            statistics::summary(&state.turns[0])["tokens"]["usage"]["total_tokens"],
            123
        );
    }

    #[test]
    fn foreign_context_completion_and_instructions_are_ignored() {
        let mut initial = State::default();
        apply(&mut initial, "session_meta", json!({"id": "parent"}));
        apply(
            &mut initial,
            "event_msg",
            json!({"type": "task_started", "turn_id": "turn"}),
        );
        apply(
            &mut initial,
            "response_item",
            json!({"type": "message", "role": "user", "content": [{"text": "# AGENTS.md instructions\nParent rules"}]}),
        );
        for (kind, payload) in [
            (
                "turn_context",
                json!({"thread_id": "child", "turn_id": "turn", "cwd": "/child"}),
            ),
            (
                "event_msg",
                json!({"type": "task_complete", "thread_id": "child", "turn_id": "turn"}),
            ),
            (
                "response_item",
                json!({"type": "message", "thread_id": "child", "role": "user", "content": [{"text": "# AGENTS.md instructions\nChild rules"}]}),
            ),
            ("compacted", json!({"thread_id": "child"})),
        ] {
            let mut state = initial.clone();
            apply(&mut state, kind, payload);
            assert_eq!(
                serde_json::to_value(state).unwrap(),
                serde_json::to_value(&initial).unwrap(),
                "{kind}"
            );
        }
    }

    #[test]
    fn persisted_older_indexes_are_rebuilt_for_plain_and_compressed_logs() {
        let fixture = Fixture::new();
        for extension in ["jsonl", "jsonl.zst"] {
            let path = fixture.0.join(format!("rollout.{extension}"));
            let cache = fixture.0.join(format!("cache-{extension}.json"));
            let text = log();
            let bytes = if extension == "jsonl" {
                text.into_bytes()
            } else {
                zstd::stream::encode_all(text.as_bytes(), 0).unwrap()
            };
            fs::write(&path, bytes).unwrap();
            let mut old = index_with_cache(&path, None, &cache).unwrap();
            assert_eq!(old.turns.len(), 1);
            // Simulate an index from the prior parser, including a foreign turn.
            old.version = CACHE_VERSION - 1;
            turn(&mut old, &json!({"turn_id": "child-turn"}), None);
            write_cache(&cache, &serde_json::to_vec(&old).unwrap()).unwrap();
            let rebuilt = index_with_cache(&path, None, &cache).unwrap();
            assert_eq!(rebuilt.version, CACHE_VERSION);
            assert_eq!(rebuilt.turns.len(), 1);
            assert_eq!(rebuilt.turns[0].id, "parent-turn");
            let reused = index_with_cache(&path, Some(rebuilt), &cache).unwrap();
            assert_eq!(reused.turns.len(), 1);
        }
    }

    #[test]
    fn partial_append_is_retried_without_duplicate_turns() {
        let fixture = Fixture::new();
        let path = fixture.0.join("rollout.jsonl");
        let cache = fixture.0.join("cache.json");
        fs::write(&path, log()).unwrap();
        let initial = index_with_cache(&path, None, &cache).unwrap();
        let line = format!(
            "{}\n",
            json!({"type": "event_msg", "payload": {"type": "task_started", "turn_id": "next"}})
        );
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&line.as_bytes()[..25]).unwrap();
        let partial = index_with_cache(&path, Some(initial), &cache).unwrap();
        assert_eq!(partial.turns.len(), 1);
        file.write_all(&line.as_bytes()[25..]).unwrap();
        let complete = index_with_cache(&path, Some(partial), &cache).unwrap();
        assert_eq!(
            complete
                .turns
                .iter()
                .map(|t| t.id.as_str())
                .collect::<Vec<_>>(),
            ["parent-turn", "next"]
        );
        assert_eq!(
            index_with_cache(&path, Some(complete), &cache)
                .unwrap()
                .turns
                .len(),
            2
        );
    }
}
