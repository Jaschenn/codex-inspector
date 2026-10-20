mod config;
mod process;
mod sessions;
mod statistics;
mod tokens;
mod util;

use clap::Parser;
use serde_json::{Value, json};
use std::io::{self, Read, Write};

#[derive(Parser)]
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
}

fn report(options: &Options) -> Result<Value, String> {
    let processes = process::scan()?;
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
    }
    Ok(result)
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
