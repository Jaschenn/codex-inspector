// Approximates a Claude-Desktop-style context window breakdown for the current conversation.
// Codex does not expose its own request composition the way a same-vendor client can, so this
// only reports buckets we can actually measure: the system prompt and effective context window
// Codex recorded in the session log (falling back to the installed Codex binary's bundled model
// catalog for older logs), the AGENTS.md/Skills text Codex actually recorded sending, and MCP
// tool/instruction text (from `mcp_probe`, when the caller ran it). Everything else --
// conversation messages plus Codex's built-in tool definitions, which cannot be read from
// outside the binary -- is left in one explicit remainder bucket rather than guessed at.
use crate::{
    model_catalog,
    tokens::{self, Encoding},
};
use serde_json::{Value, json};

/// What the session log recorded about the conversation's latest turn (see `sessions::context`).
pub struct Recorded<'a> {
    pub model: Option<&'a str>,
    /// Tokens of the latest single model request: its prompt plus output.
    pub context_tokens: Option<i64>,
    /// Codex's effective context window for that turn (`model_context_window`).
    pub context_window: Option<i64>,
    pub system_prompt: Option<&'a str>,
    pub instructions: &'a [Value],
}

fn count(encoding: Encoding, text: &str) -> i64 {
    tokens::estimate_with(encoding, text).0.unwrap_or(0) as i64
}

fn sum_instruction_tokens(
    encoding: Encoding,
    instructions: &[Value],
    category: &str,
) -> (i64, usize) {
    let matching: Vec<_> = instructions
        .iter()
        .filter(|i| i["category"].as_str() == Some(category))
        .collect();
    let total = matching
        .iter()
        .map(|i| count(encoding, i["text"].as_str().unwrap_or("")))
        .sum();
    (total, matching.len())
}

/// Re-counts probed MCP text with the conversation model's tokenizer; probes count with
/// `o200k_base` because they run independently of any conversation.
fn recount_server(encoding: Encoding, server: &Value) -> Value {
    let mut server = server.clone();
    if server["status"] != "ok" {
        return server;
    }
    let mut total = 0;
    if let Some(tools) = server["tools"].as_array_mut() {
        for tool in tools {
            let tokens = count(encoding, &tool["formatted_as"].to_string());
            tool["token_count"] = json!(tokens);
            total += tokens;
        }
    }
    server["tools_token_count"] = json!(total);
    if let Some(instructions) = server["instructions"].as_str() {
        server["instructions_token_count"] = json!(count(encoding, instructions));
    }
    server
}

pub fn build(
    recorded: &Recorded,
    mcp_results: Option<&[Value]>,
    mcp_result_age_secs: Option<i64>,
    codex_binary_hint: Option<&str>,
) -> Value {
    let mut warnings = Vec::new();
    let model = recorded.model;
    let system_prompt = recorded.system_prompt.filter(|text| !text.is_empty());
    // Newer Codex logs record both the system prompt and the effective window, for every
    // provider. Only older logs need Codex's bundled (OpenAI-only) catalog, which also tells
    // apart OpenAI models whose tokenizer is known.
    let needs_catalog = system_prompt.is_none() || recorded.context_window.is_none();
    let catalog = model.filter(|_| needs_catalog).and_then(|model| {
        match model_catalog::lookup(codex_binary_hint, model) {
            Ok(entry) if entry["matched"] == true => Some(entry),
            Ok(entry) => {
                warnings.push(format!(
                    "已安装的 Codex（{} {}）不认识模型 “{model}”，且日志未记录系统提示词或上下文窗口。",
                    entry["source_binary"].as_str().unwrap_or("codex"),
                    entry["source_version"].as_str().unwrap_or("?")
                ));
                None
            }
            Err(error) => {
                warnings.push(error);
                None
            }
        }
    });
    if model.is_none() {
        warnings.push("当前轮次未记录模型名称，按 o200k_base 估算 Token。".into());
    }
    let (encoding, tokenizer_known) = Encoding::for_model(model);
    if model.is_some() && !tokenizer_known {
        warnings.push(format!(
            "未内置模型 “{}” 的分词器，各项 Token 按 o200k_base 估算，可能与实际计费有偏差。",
            model.unwrap_or_default()
        ));
    }

    let (agents_md_tokens, agents_md_count) =
        sum_instruction_tokens(encoding, recorded.instructions, "agents_md");
    let (skills_tokens, skills_count) =
        sum_instruction_tokens(encoding, recorded.instructions, "skills_catalog");
    let system_prompt_component = match (system_prompt, &catalog) {
        (Some(text), _) => {
            let tokens = count(encoding, text);
            (
                Some(tokens),
                json!({"category":"system_prompt","label":"系统提示词","tokens":tokens,
                "exact":tokenizer_known,"source":"会话日志记录的系统提示词原文"}),
            )
        }
        (None, Some(catalog)) => {
            let tokens = count(
                encoding,
                catalog["base_instructions"].as_str().unwrap_or(""),
            );
            (
                Some(tokens),
                json!({"category":"system_prompt","label":"系统提示词","tokens":tokens,
                "exact":tokenizer_known,
                "source": format!("codex debug models（{}）", catalog["source_version"].as_str().unwrap_or("?"))}),
            )
        }
        (None, None) => (
            None,
            json!({"category":"system_prompt","label":"系统提示词","tokens":Value::Null,
            "exact":false,"note":"日志未记录系统提示词，且已安装 Codex 的内置模型目录中没有该模型"}),
        ),
    };
    let (system_prompt_tokens, system_prompt_component) = system_prompt_component;

    let mcp_included = mcp_results.is_some();
    let mcp_results: Vec<Value> = mcp_results
        .unwrap_or(&[])
        .iter()
        .map(|server| recount_server(encoding, server))
        .collect();
    let mcp_tools_tokens: i64 = mcp_results
        .iter()
        .filter_map(|s| s["tools_token_count"].as_i64())
        .sum();
    let mcp_instructions_tokens: i64 = mcp_results
        .iter()
        .filter_map(|s| s["instructions_token_count"].as_i64())
        .sum();
    let mcp_unavailable = mcp_results.iter().filter(|s| s["status"] != "ok").count();
    if mcp_unavailable > 0 {
        warnings.push(format!(
            "{mcp_unavailable} 个 MCP server 未能在本次探测中给出工具列表，其 token 未计入。"
        ));
    }

    let known_total = system_prompt_tokens.unwrap_or(0)
        + agents_md_tokens
        + skills_tokens
        + mcp_tools_tokens
        + mcp_instructions_tokens;
    let mut components = vec![
        system_prompt_component,
        json!({"category":"agents_md","label":"AGENTS.md / 项目指令","tokens":agents_md_tokens,
            "exact":tokenizer_known,"item_count":agents_md_count}),
        json!({"category":"skills_catalog","label":"Skills 目录说明","tokens":skills_tokens,
            "exact":tokenizer_known,"item_count":skills_count}),
    ];
    components.push(if mcp_included {
        json!({"category":"mcp_tools","label":"MCP 工具定义","tokens":mcp_tools_tokens,
            "exact": tokenizer_known && mcp_unavailable == 0, "servers": mcp_results,
            "result_age_seconds": mcp_result_age_secs})
    } else {
        json!({"category":"mcp_tools","label":"MCP 工具定义","tokens":Value::Null,
            "exact": false, "note": "未探测：需要点击“刷新 MCP 工具”"})
    });
    if mcp_included {
        components.push(
            json!({"category":"mcp_instructions","label":"MCP Server 指令",
            "tokens":mcp_instructions_tokens,"exact":tokenizer_known}),
        );
    }

    let active = recorded.context_tokens;
    if active.is_none() {
        warnings.push("当前轮次尚未记录模型请求的 Token 用量。".into());
    }
    let active_tokens = active.unwrap_or(0);
    if active_tokens > 0 && active_tokens < known_total {
        warnings.push(
            "已知分类合计超过了实际用量，说明部分内容已被压缩/未计入当前上下文，分类数字仅供参考。"
                .into(),
        );
    }
    components.push(json!({"category":"messages_and_unmeasured","label":"对话消息 + 未逐项统计项（内置工具定义等）",
        "tokens": active.map(|a| (a - known_total).max(0)), "exact": false,
        "note": "Codex 的内置工具定义（shell/apply_patch 等）不对外暴露，与对话内容一起计入此项。"}));

    let usable_context_window = recorded.context_window.or_else(|| {
        catalog
            .as_ref()
            .and_then(|c| c["usable_context_window"].as_i64())
    });
    let free_space = usable_context_window
        .zip(active)
        .map(|(limit, active)| (limit - active).max(0));
    let percent_used = usable_context_window
        .zip(active)
        .filter(|&(limit, _)| limit > 0)
        .map(|(limit, active)| (active as f64 / limit as f64 * 100.0).min(999.0));

    json!({
        "available": true, "model": model, "warnings": warnings,
        "token_encoding": encoding.name(),
        "active_context_tokens": active,
        "usable_context_window": usable_context_window,
        "context_window_source": if recorded.context_window.is_some() { "session_log" }
            else if usable_context_window.is_some() { "codex_catalog" } else { "unknown" },
        "free_space_tokens": free_space,
        "percent_used": percent_used, "mcp_probed": mcp_included,
        "components": components,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recorded_session_data_drives_a_deepseek_budget_without_the_catalog() {
        let instructions = [json!({"category":"agents_md","text":"使用 uv 管理 Python。"})];
        let recorded = Recorded {
            model: Some("deepseek-v4.1-flash"),
            context_tokens: Some(50_000),
            context_window: Some(950_000),
            system_prompt: Some("You are a coding agent running in the Codex CLI."),
            instructions: &instructions,
        };
        // No `codex` binary is consulted when the log already recorded everything.
        let budget = build(&recorded, None, None, Some("/nonexistent/codex"));
        assert_eq!(budget["token_encoding"], "deepseek_v3");
        assert_eq!(budget["usable_context_window"], 950_000);
        assert_eq!(budget["context_window_source"], "session_log");
        assert_eq!(budget["free_space_tokens"], 900_000);
        assert!(
            budget["warnings"].as_array().unwrap().is_empty(),
            "{budget}"
        );
        let system = &budget["components"][0];
        assert_eq!(system["exact"], true);
        assert_eq!(
            system["tokens"],
            count(Encoding::DeepSeekV3, recorded.system_prompt.unwrap())
        );
    }

    #[test]
    fn missing_usage_stays_unknown_instead_of_zero() {
        let recorded = Recorded {
            model: Some("some-other-model"),
            context_tokens: None,
            context_window: Some(100_000),
            system_prompt: Some("prompt"),
            instructions: &[],
        };
        let budget = build(&recorded, None, None, None);
        assert!(budget["active_context_tokens"].is_null());
        assert!(budget["free_space_tokens"].is_null());
        assert!(budget["components"][4]["tokens"].is_null());
        assert_eq!(budget["components"][0]["exact"], false);
    }
}
