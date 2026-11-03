mod activity;
mod config;
mod context_budget;
mod mcp_probe;
mod model_catalog;
mod process;
mod sessions;
mod statistics;
mod tokens;
mod util;

use clap::Parser;
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, BufRead, Read, Write};

#[derive(Parser, Deserialize, Default)]
#[serde(default)]
#[command(version, about = "Native offline Codex inspection engine")]
struct Options {
    #[arg(long)]
    json: bool,
    #[arg(long)]
    sessions: bool,
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long)]
    turn_id: Option<String>,
    #[arg(long)]
    include_archived: bool,
    #[arg(long)]
    include_other_sources: bool,
    #[arg(long)]
    validate_toml: bool,
    #[arg(long)]
    pid: Option<u32>,
    /// Serve one compact JSON response per newline-delimited request on stdin.
    #[arg(long)]
    serve: bool,
    #[arg(long)]
    menu: bool,
    #[arg(long)]
    menu_pid: Option<u32>,
    #[arg(long)]
    menu_session_id: Option<String>,
    /// Attach a context-window usage breakdown for the active menu conversation.
    #[arg(long)]
    context_budget: bool,
    /// Also query configured MCP servers' real tool lists (slower; spawns each server).
    #[arg(long)]
    probe_mcp: bool,
}

fn report(options: &Options) -> Result<Value, String> {
    let mut phase_start = std::time::Instant::now();
    let mut phase = |name: &str| {
        if std::env::var_os("CODEX_INSPECTOR_PROFILE").is_some() {
            eprintln!(
                "{name}: {:.2} ms",
                phase_start.elapsed().as_secs_f64() * 1000.0
            );
        }
        phase_start = std::time::Instant::now();
    };
    let processes = process::scan()?;
    phase("process scan");
    let mut reports = Vec::new();
    let mut errors = Vec::new();
    for process in processes {
        if options.pid.is_some_and(|pid| process.pid != pid) {
            continue;
        }
        match process::inspect(&process) {
            Ok(report) => reports.push(report),
            Err(error) => errors.push(json!({"pid": process.pid, "error": error})),
        }
    }
    phase("process inspection");
    let mut homes = vec![util::home().join(".codex")];
    homes.extend(
        reports
            .iter()
            .filter_map(|p| p["codex_home"].as_str())
            .map(util::expand),
    );
    let mut result = json!({
        "generated_at": chrono::Local::now().to_rfc3339(), "process_count": reports.len(),
        "processes": reports, "process_errors": errors,
    });
    if options.sessions {
        let catalog = sessions::list(
            &homes,
            options.include_archived,
            options.include_other_sources,
        );
        phase("session catalog");
        result["selected_session"] =
            options
                .session_id
                .as_ref()
                .and_then(|id| {
                    catalog.iter().find(|s| s["id"].as_str() == Some(id)).map(|s| {
                sessions::inspect(s, options.turn_id.as_deref()).unwrap_or_else(|error| {
                    json!({"id": id, "requested_turn_id": options.turn_id, "error": error})
                })
            })
                })
                .unwrap_or(Value::Null);
        result["sessions"] = json!(catalog);
        phase("selected session");
    }
    if options.menu {
        // Menu scope is independent of the detail window's historical selection.
        let catalog =
            if options.sessions && !options.include_archived && !options.include_other_sources {
                result["sessions"].as_array().cloned().unwrap_or_default()
            } else {
                sessions::list(&homes, false, false)
            };
        let processes = result["processes"].as_array().cloned().unwrap_or_default();
        let selected_process = options
            .menu_pid
            .and_then(|pid| {
                processes
                    .iter()
                    .find(|p| p["pid"].as_u64() == Some(u64::from(pid)))
            })
            .or_else(|| {
                catalog.iter().find_map(|s| {
                    processes
                        .iter()
                        .find(|p| p["codex_home"] == s["codex_home"] && p["cwd"] == s["cwd"])
                })
            })
            .or_else(|| processes.first());
        if let Some(process) = selected_process {
            let same_home: Vec<_> = catalog
                .iter()
                .filter(|s| s["codex_home"] == process["codex_home"])
                .collect();
            let matching: Vec<_> = same_home
                .iter()
                .copied()
                .filter(|s| s["cwd"] == process["cwd"])
                .collect();
            let candidates = if matching.is_empty() {
                same_home
            } else {
                matching
            };
            let manual = options.menu_session_id.as_ref().and_then(|id| {
                catalog.iter().find(|s| {
                    s["id"].as_str() == Some(id) && s["codex_home"] == process["codex_home"]
                })
            });
            let selected = manual.or_else(|| candidates.first().copied());
            result["menu_pid"] = process["pid"].clone();
            result["menu_candidates"] = json!(
                catalog
                    .iter()
                    .filter(|s| s["codex_home"] == process["codex_home"])
                    .collect::<Vec<_>>()
            );
            result["menu_association"] = json!(if manual.is_some() {
                "manual"
            } else if selected.is_some_and(|s| s["cwd"] == process["cwd"]) {
                "cwd"
            } else {
                "home"
            });
            result["menu_session"] = selected
                .map(|s| sessions::menu(s).unwrap_or_else(|e| json!({"error":e})))
                .unwrap_or(Value::Null);
            if options.context_budget {
                result["menu_context_budget"] = selected
                    .map(|s| context_budget_for(s, process, options.probe_mcp))
                    .unwrap_or(Value::Null);
            }
        }
    }
    phase("menu summary");
    Ok(result)
}

fn context_budget_for(session: &Value, process: &Value, probe_mcp: bool) -> Value {
    let detail = match sessions::inspect(session, None) {
        Ok(detail) => detail,
        Err(error) => return json!({"available": false, "reason": error}),
    };
    if detail["error"].is_string() {
        return json!({"available": false, "reason": detail["error"]});
    }
    let model = detail["selected_turn"]["model"].as_str().map(str::to_owned);
    let active_tokens =
        detail["selected_turn"]["statistics"]["tokens"]["usage"]["total_tokens"].as_i64();
    let recorded_instructions = detail["recorded_instructions"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let binary_hint = process["cmdline"]
        .as_str()
        .and_then(shlex::split)
        .and_then(|tokens| tokens.into_iter().next())
        .filter(|first| first.starts_with('/'));
    let servers = process["mcp_servers"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    // A fresh probe is explicit (user action); otherwise reuse a recent one so the automatic
    // 1s poll does not silently re-spawn every configured MCP server.
    let (mcp_results, mcp_result_age_secs) = if probe_mcp {
        (Some(mcp_probe::probe(&servers)), Some(0))
    } else {
        match mcp_probe::cached(&servers) {
            Some((results, age)) => (Some(results), Some(age.as_secs() as i64)),
            None => (None, None),
        }
    };
    context_budget::build(
        model.as_deref(),
        active_tokens,
        &recorded_instructions,
        mcp_results.as_deref(),
        mcp_result_age_secs,
        binary_hint.as_deref(),
    )
}

fn run() -> Result<(), String> {
    let options = Options::parse();
    if options.validate_toml {
        let mut text = String::new();
        io::stdin()
            .read_to_string(&mut text)
            .map_err(|e| e.to_string())?;
        text.parse::<toml::Table>().map_err(|e| e.to_string())?;
        return Ok(());
    }
    if options.serve {
        let stdin = io::stdin();
        let stdout = io::stdout();
        let mut output = stdout.lock();
        // One parent app owns the pipe; EOF shuts down the engine. No socket,
        // extra service, network listener or persistent access to Codex databases.
        for line in stdin.lock().lines() {
            let line = line.map_err(|e| e.to_string())?;
            let response = match serde_json::from_str::<Options>(&line) {
                Ok(request) => report(&request).unwrap_or_else(|error| json!({"error":error})),
                Err(error) => json!({"error":format!("Invalid request: {error}")}),
            };
            tokens::save();
            serde_json::to_writer(&mut output, &response).map_err(|e| e.to_string())?;
            writeln!(output).map_err(|e| e.to_string())?;
            output.flush().map_err(|e| e.to_string())?;
        }
        return Ok(());
    }
    let report = report(&options)?;
    tokens::save();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    if options.json {
        serde_json::to_writer(&mut output, &report).map_err(|e| e.to_string())?;
    } else {
        serde_json::to_writer_pretty(&mut output, &report).map_err(|e| e.to_string())?;
    }
    writeln!(output).map_err(|e| e.to_string())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
