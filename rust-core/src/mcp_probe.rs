// Codex only stores an MCP server's launch command in config.toml; the actual tool list and
// `instructions` text are negotiated at runtime over the Model Context Protocol. To measure
// what an MCP server really contributes to the context window, this speaks minimal MCP
// (stdio, newline-delimited JSON-RPC) to each configured server directly, independent of Codex.
// This is read-only: it only sends `initialize` and `tools/list`, and the servers are the same
// ones the user already configured Codex to launch, so spawning them here carries no new trust.
use crate::tokens;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{BufRead, BufReader, Write},
    os::unix::process::CommandExt,
    process::{Child, Command, Stdio},
    sync::{Mutex, OnceLock, mpsc},
    thread,
    time::{Duration, Instant},
};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(8);
// The Swift host force-kills the whole long-lived engine process (losing every other cache, not
// just this probe) if one request runs past 20s, so every server's timeout must leave headroom
// under that even when every server is probed in parallel.
const MAX_TIMEOUT: Duration = Duration::from_secs(12);

fn send(child: &mut Child, message: &Value) -> Result<(), String> {
    let mut line = serde_json::to_string(message).map_err(|e| e.to_string())?;
    line.push('\n');
    child
        .stdin
        .as_mut()
        .ok_or("stdin unavailable")?
        .write_all(line.as_bytes())
        .map_err(|e| e.to_string())
}

/// Kills the server's whole process group (npx/uvx/sh wrappers spawn grandchildren that would
/// otherwise keep stdout open and outlive the probe) and reaps it so no zombie remains in the
/// long-lived `--serve` engine.
fn terminate(child: &mut Child) {
    if let Ok(pid) = i32::try_from(child.id()) {
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Reads lines from the child's stdout on a background thread so a server that never responds
/// cannot hang this probe; the thread is abandoned (not joined) once the deadline passes.
fn read_response(rx: &mpsc::Receiver<String>, deadline: Instant, expect_id: i64) -> Option<Value> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return None;
        }
        let line = rx.recv_timeout(remaining).ok()?;
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if value.get("id").and_then(Value::as_i64) == Some(expect_id) {
            return Some(value);
        }
    }
}

fn tool_definition_tokens(server: &str, tool: &Value) -> (Option<usize>, Value) {
    let name = tool["name"].as_str().unwrap_or("");
    let spec = json!({
        "type": "function",
        "name": format!("mcp__{server}__{name}"),
        "description": tool["description"],
        "parameters": tool.get("inputSchema").cloned().unwrap_or(json!({})),
    });
    let (count, _, _) = tokens::estimate(&spec.to_string());
    (count, spec)
}

/// Probes one configured MCP server. `env` overlays the current process environment and `cwd`
/// sets the working directory, matching how Codex itself launches MCP servers from
/// config.toml (some use a relative `command` that only resolves under their configured `cwd`).
/// `timeout` honors a server's own `startup_timeout_sec`, if configured, capped at `MAX_TIMEOUT`
/// so one slow-starting server cannot stall the whole probe.
struct Launch<'a> {
    command: &'a str,
    args: &'a [String],
    /// The Codex process's environment; empty means "inherit this engine's".
    base_env: &'a BTreeMap<String, String>,
    env: &'a BTreeMap<String, String>,
    cwd: Option<&'a str>,
    timeout: Duration,
}

fn probe_one(name: &str, launch: &Launch) -> Value {
    let deadline = Instant::now() + launch.timeout;
    // A Finder-launched app has launchd's minimal PATH; resolve bare commands (npx, uvx) with
    // the Codex process's PATH and run them in its environment.
    let program = launch
        .base_env
        .get("PATH")
        .and_then(|path| resolve_in_path(launch.command, path))
        .unwrap_or_else(|| launch.command.into());
    let mut command_builder = Command::new(program);
    if !launch.base_env.is_empty() {
        command_builder.env_clear().envs(launch.base_env);
    }
    command_builder.args(launch.args).envs(launch.env);
    if let Some(cwd) = launch.cwd {
        command_builder.current_dir(cwd);
    }
    let mut child = match command_builder
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // Never read; a piped stderr would block a chatty server once the pipe buffer fills.
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
    {
        Ok(child) => child,
        Err(error) => return json!({"name": name, "status": "error", "error": error.to_string()}),
    };
    let Some(stdout) = child.stdout.take() else {
        terminate(&mut child);
        return json!({"name": name, "status": "error", "error": "stdout unavailable"});
    };
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    let init_sent = send(
        &mut child,
        &json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "codex-inspector", "version": env!("CARGO_PKG_VERSION")},
            },
        }),
    );
    if let Err(error) = init_sent {
        terminate(&mut child);
        return json!({"name": name, "status": "error", "error": error});
    }
    let Some(init_response) = read_response(&rx, deadline, 1) else {
        terminate(&mut child);
        return json!({"name": name, "status": "timeout", "error": "initialize 未在超时内响应"});
    };
    if let Some(error) = init_response.get("error") {
        terminate(&mut child);
        return json!({"name": name, "status": "error", "error": error});
    }
    let instructions = init_response["result"]["instructions"]
        .as_str()
        .map(str::to_owned);

    let notified = send(
        &mut child,
        &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    );
    let tools_sent = notified.and_then(|()| {
        send(
            &mut child,
            &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        )
    });
    if let Err(error) = tools_sent {
        terminate(&mut child);
        return json!({"name": name, "status": "error", "error": error});
    }
    let tools_response = read_response(&rx, deadline, 2);
    terminate(&mut child);

    let Some(tools_response) = tools_response else {
        return json!({
            "name": name, "status": "timeout", "error": "tools/list 未在超时内响应",
            "instructions": instructions,
        });
    };
    if let Some(error) = tools_response.get("error") {
        return json!({"name": name, "status": "error", "error": error, "instructions": instructions});
    }
    let tools: Vec<_> = tools_response["result"]["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|tool| {
            let (count, spec) = tool_definition_tokens(name, tool);
            json!({
                "name": tool["name"], "description": tool["description"],
                "token_count": count, "formatted_as": spec,
            })
        })
        .collect();
    let tools_tokens: usize = tools
        .iter()
        .filter_map(|t| t["token_count"].as_u64())
        .sum::<u64>() as usize;
    let (instructions_tokens, _, _) = tokens::estimate(instructions.as_deref().unwrap_or(""));
    json!({
        "name": name, "status": "ok", "tool_count": tools.len(), "tools": tools,
        "tools_token_count": tools_tokens, "instructions": instructions,
        "instructions_token_count": if instructions.is_some() { instructions_tokens } else { None },
    })
}

fn probe_entry(entry: &Value) -> Value {
    let name = entry["name"].as_str().unwrap_or("");
    let raw = &entry["raw"];
    let Some(command) = raw["command"].as_str() else {
        return json!({"name": name, "status": "error", "error": "未配置启动命令（可能是远程/托管 MCP server）"});
    };
    let args: Vec<String> = raw["args"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    let env: BTreeMap<String, String> = raw["env"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
        .collect();
    let base_env: BTreeMap<String, String> = entry["base_env"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
        .collect();
    let timeout = raw["startup_timeout_sec"]
        .as_f64()
        .filter(|s| s.is_finite() && *s > 0.0)
        .map_or(DEFAULT_TIMEOUT, |s| {
            Duration::from_secs_f64(s).min(MAX_TIMEOUT)
        });
    let launch = Launch {
        command,
        args: &args,
        base_env: &base_env,
        env: &env,
        cwd: raw["cwd"].as_str(),
        timeout,
    };
    filter_tools(probe_one(name, &launch), raw)
}

fn resolve_in_path(command: &str, path: &str) -> Option<std::path::PathBuf> {
    if command.contains('/') {
        return None;
    }
    path.split(':')
        .map(|dir| std::path::Path::new(dir).join(command))
        .find(|candidate| candidate.is_file())
}

/// Applies the server's `enabled_tools` allowlist and `disabled_tools` denylist, as Codex does,
/// so filtered-out tools are not counted as context.
fn filter_tools(mut result: Value, raw: &Value) -> Value {
    let names = |key: &str| -> Option<Vec<String>> {
        raw[key].as_array().map(|list| {
            list.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
    };
    let (enabled, disabled) = (names("enabled_tools"), names("disabled_tools"));
    let Some(tools) = result["tools"].as_array_mut() else {
        return result;
    };
    tools.retain(|tool| {
        let name = tool["name"].as_str().unwrap_or_default().to_owned();
        enabled.as_ref().is_none_or(|list| list.contains(&name))
            && !disabled.as_ref().is_some_and(|list| list.contains(&name))
    });
    let total: u64 = tools.iter().filter_map(|t| t["token_count"].as_u64()).sum();
    result["tool_count"] = json!(tools.len());
    result["tools_token_count"] = json!(total);
    result
}

/// `launch` entries look like `{"name": .., "raw": {"command": .., "args": [..], "env": {..}},
/// "base_env": {..}}` with unredacted values (see `process::mcp_launch_specs`); results are
/// cached under the redacted `servers` list the report shows. Probed in parallel so total wall
/// time tracks the slowest single server, not their sum -- staying well under the host's 20s
/// hard timeout for the whole (persistent, cache-owning) engine process.
pub fn probe(servers: &[Value], launch: &[Value]) -> Vec<Value> {
    let results = thread::scope(|scope| {
        launch
            .iter()
            .map(|entry| scope.spawn(|| probe_entry(entry)))
            .collect::<Vec<_>>()
            .into_iter()
            .map(|handle| {
                handle
                    .join()
                    .unwrap_or_else(|_| json!({"status": "error", "error": "probe线程崩溃"}))
            })
            .collect::<Vec<_>>()
    });
    store_cache(servers, &results);
    results
}

/// Reuses a recent `probe()` result for an unchanged server list instead of re-probing on every
/// automatic refresh; MCP servers are a side-effecting external process, so probing them stays
/// an explicit, user-triggered action, not something the 1s background poll repeats silently.
pub fn cached(servers: &[Value]) -> Option<(Vec<Value>, Duration)> {
    let cache = CACHE.get_or_init(|| Mutex::new(None));
    let guard = cache.lock().ok()?;
    let entry = guard.as_ref()?;
    let age = entry.at.elapsed();
    (entry.signature == signature(servers) && age <= CACHE_TTL)
        .then(|| (entry.results.clone(), age))
}

const CACHE_TTL: Duration = Duration::from_secs(600);
static CACHE: OnceLock<Mutex<Option<CacheEntry>>> = OnceLock::new();

struct CacheEntry {
    signature: String,
    at: Instant,
    results: Vec<Value>,
}

fn signature(servers: &[Value]) -> String {
    crate::util::hash(serde_json::to_string(servers).unwrap_or_default())
}

fn store_cache(servers: &[Value], results: &[Value]) {
    if let Ok(mut guard) = CACHE.get_or_init(|| Mutex::new(None)).lock() {
        *guard = Some(CacheEntry {
            signature: signature(servers),
            at: Instant::now(),
            results: results.to_vec(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probes_a_real_local_stdio_mcp_server_when_available() {
        // `codegraph serve --mcp` is a real stdio MCP server when the CodeGraph CLI is
        // installed; a missing binary is a valid, explicit outcome, not a test failure.
        let launch = Launch {
            command: "codegraph",
            args: &["serve".into(), "--mcp".into()],
            base_env: &BTreeMap::new(),
            env: &BTreeMap::new(),
            cwd: None,
            timeout: DEFAULT_TIMEOUT,
        };
        let result = probe_one("codegraph", &launch);
        if result["status"] == "error"
            && result["error"]
                .as_str()
                .is_some_and(|e| e.contains("No such file"))
        {
            return;
        }
        assert_eq!(result["status"], "ok", "{result}");
        assert!(result["tool_count"].as_u64().unwrap() > 0);
        assert!(result["tools"][0]["token_count"].as_u64().unwrap() > 0);
    }

    #[test]
    fn tool_filters_and_bad_timeouts_are_handled() {
        let result = json!({"status":"ok","tools":[
            {"name":"a","token_count":1},{"name":"b","token_count":2},{"name":"c","token_count":4}]});
        let raw = json!({"enabled_tools":["a","b"],"disabled_tools":["b"]});
        let filtered = filter_tools(result, &raw);
        assert_eq!(filtered["tool_count"], 1);
        assert_eq!(filtered["tools_token_count"], 1);
        // A negative timeout must not panic; the missing command fails fast instead.
        let entry =
            json!({"name":"x","raw":{"command":"/nonexistent/server","startup_timeout_sec":-1}});
        assert_eq!(probe_entry(&entry)["status"], "error");
    }
}
