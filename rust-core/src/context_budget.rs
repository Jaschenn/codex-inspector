// Approximates a Claude-Desktop-style context window breakdown for the current conversation.
// Codex does not expose its own request composition the way a same-vendor client can, so this
// only reports buckets we can actually measure: the model's real system prompt and context
// window (from `model_catalog`, i.e. the installed Codex binary itself), the AGENTS.md/Skills
// text Codex actually recorded sending, and MCP tool/instruction text (from `mcp_probe`, when
// the caller ran it). Everything else -- conversation messages plus Codex's built-in tool
// definitions, which cannot be read from outside the binary -- is left in one explicit
// remainder bucket rather than guessed at per-category.
use crate::{model_catalog, tokens};
use serde_json::{Value, json};

fn sum_instruction_tokens<'a>(instructions: &'a [Value], category: &str) -> (i64, Vec<&'a Value>) {
    let matching: Vec<_> = instructions
        .iter()
        .filter(|i| i["category"].as_str() == Some(category))
        .collect();
    let total = matching
        .iter()
        .map(|i| {
            tokens::estimate(i["text"].as_str().unwrap_or(""))
                .0
                .unwrap_or(0) as i64
        })
        .sum();
    (total, matching)
}

pub fn build(
    model: Option<&str>,
    active_context_tokens: Option<i64>,
    recorded_instructions: &[Value],
    mcp_results: Option<&[Value]>,
    mcp_result_age_secs: Option<i64>,
    codex_binary_hint: Option<&str>,
) -> Value {
    let mut warnings = Vec::new();
    // A model the installed Codex's own bundled catalog does not recognise (alternate backend,
    // version skew) still leaves the instruction/MCP buckets measurable; only the system-prompt
    // and context-window figures become unavailable, so this degrades instead of giving up.
    let catalog = model.and_then(
        |model| match model_catalog::lookup(codex_binary_hint, model) {
            Ok(entry) if entry["matched"] == true => Some(entry),
            Ok(entry) => {
                warnings.push(format!(
                    "已安装的 Codex（{} {}）不认识模型 “{model}”，系统提示词与上下文窗口大小未知。",
                    entry["source_binary"].as_str().unwrap_or("codex"),
                    entry["source_version"].as_str().unwrap_or("?")
                ));
                None
            }
            Err(error) => {
                warnings.push(error);
                None
            }
        },
    );
    if model.is_none() {
        warnings.push("当前轮次未记录模型名称，系统提示词与上下文窗口大小未知。".into());
    }

    let (agents_md_tokens, agents_md_items) =
        sum_instruction_tokens(recorded_instructions, "agents_md");
    let (skills_tokens, skills_items) =
        sum_instruction_tokens(recorded_instructions, "skills_catalog");
    let system_prompt_tokens = catalog
        .as_ref()
        .and_then(|c| c["system_prompt_token_count"].as_i64());

    let mcp_included = mcp_results.is_some();
    let mcp_results = mcp_results.unwrap_or(&[]);
    let mcp_tools_tokens: i64 = mcp_results
        .iter()
        .filter_map(|s| s["tools_token_count"].as_i64())
        .sum();
    let mcp_instructions_tokens: i64 = mcp_results
        .iter()
        .filter_map(|s| s["instructions_token_count"].as_i64())
        .sum();
    let mcp_unavailable: Vec<_> = mcp_results
        .iter()
        .filter(|s| s["status"] != "ok")
        .map(|s| json!({"name": s["name"], "status": s["status"], "error": s["error"]}))
        .collect();
    if !mcp_unavailable.is_empty() {
        warnings.push(format!(
            "{} 个 MCP server 未能在本次探测中给出工具列表，其 token 未计入。",
            mcp_unavailable.len()
        ));
    }

    let known_total = system_prompt_tokens.unwrap_or(0)
        + agents_md_tokens
        + skills_tokens
        + mcp_tools_tokens
        + mcp_instructions_tokens;
    let mut components = vec![
        match &catalog {
            Some(catalog) => {
                json!({"category":"system_prompt","label":"系统提示词","tokens":system_prompt_tokens,"exact":true,
                "source": format!("codex debug models（{}）", catalog["source_version"].as_str().unwrap_or("?"))})
            }
            None => {
                json!({"category":"system_prompt","label":"系统提示词","tokens":Value::Null,"exact":false,
                "note": "当前模型不在已安装 Codex 的内置模型目录中，无法取得其系统提示词原文"})
            }
        },
        json!({"category":"agents_md","label":"AGENTS.md / 项目指令","tokens":agents_md_tokens,"exact":true,
            "item_count": agents_md_items.len()}),
        json!({"category":"skills_catalog","label":"Skills 目录说明","tokens":skills_tokens,"exact":true,
            "item_count": skills_items.len()}),
    ];
    components.push(if mcp_included {
        json!({"category":"mcp_tools","label":"MCP 工具定义","tokens":mcp_tools_tokens,
            "exact": mcp_unavailable.is_empty(), "servers": mcp_results,
            "result_age_seconds": mcp_result_age_secs,
            "stale": mcp_result_age_secs.is_some_and(|age| age > 0)})
    } else {
        json!({"category":"mcp_tools","label":"MCP 工具定义","tokens":Value::Null,
            "exact": false, "note": "未探测：需要点击“刷新 MCP 工具”"})
    });
    if mcp_included {
        components.push(json!({"category":"mcp_instructions","label":"MCP Server 指令","tokens":mcp_instructions_tokens,"exact":true}));
    }

    let active = active_context_tokens.unwrap_or(0);
    let remainder = (active - known_total).max(0);
    if active > 0 && active < known_total {
        warnings.push(
            "已知分类合计超过了实际用量，说明部分内容已被压缩/未计入当前上下文，分类数字仅供参考。"
                .into(),
        );
    }
    components.push(json!({"category":"messages_and_unmeasured","label":"对话消息 + 未逐项统计项（内置工具定义等）",
        "tokens": remainder, "exact": false,
        "note": "Codex 的内置工具定义（shell/apply_patch 等）不对外暴露，与对话内容一起计入此项。"}));

    let context_window = catalog.as_ref().and_then(|c| c["context_window"].as_i64());
    let usable_context_window = catalog
        .as_ref()
        .and_then(|c| c["usable_context_window"].as_i64());
    let free_space = usable_context_window.map(|limit| (limit - active).max(0));
    let percent_used = usable_context_window
        .filter(|&limit| limit > 0)
        .map(|limit| (active as f64 / limit as f64 * 100.0).min(999.0));

    json!({
        "available": true, "model": model, "warnings": warnings,
        "active_context_tokens": active_context_tokens,
        "context_window": context_window,
        "max_context_window": catalog.as_ref().map(|c| c["max_context_window"].clone()),
        "usable_context_window": usable_context_window, "free_space_tokens": free_space,
        "percent_used": percent_used, "mcp_probed": mcp_included,
        "components": components,
    })
}
