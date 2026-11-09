// Context budgeting needs the exact system prompt text and context-window size Codex itself
// uses for a given model. Codex ships both in its own binary (`codex debug models --bundled`
// prints the bundled catalog, including each model's literal `base_instructions` system prompt),
// so this reads them from the user's installed Codex CLI instead of vendoring a copy that would
// drift from whatever version is actually running.
use crate::util;
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

fn cache_path() -> PathBuf {
    std::env::var_os("CODEX_INSPECTOR_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| util::home().join("Library/Caches/CodexInspector"))
        .join("codex-model-catalog-v1.json")
}

/// Candidate `codex` binaries to try, most specific first. GUI apps on macOS do not inherit a
/// login shell's PATH, so a bare `codex` lookup alone is not reliable even when the CLI is
/// installed and on the user's interactive PATH.
fn candidates(hint: Option<&str>) -> Vec<String> {
    let mut result = Vec::new();
    if let Some(hint) = hint.filter(|h| h.starts_with('/')) {
        result.push(hint.to_owned());
    }
    result.push("codex".into());
    let home = util::home();
    for path in [
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
        home.join(".local/bin/codex"),
        home.join(".cargo/bin/codex"),
        home.join(".volta/bin/codex"),
        home.join(".npm-global/bin/codex"),
    ] {
        result.push(path.to_string_lossy().into_owned());
    }
    result
}

#[derive(Clone)]
struct Catalog {
    binary: String,
    version: String,
    models: Vec<Value>,
}

fn fetch(binary: &str) -> Option<Catalog> {
    let (ok, stdout, _) = util::command(binary, &["debug", "models", "--bundled"]).ok()?;
    if !ok {
        return None;
    }
    let models = serde_json::from_str::<Value>(stdout.trim())
        .ok()?
        .get("models")?
        .as_array()?
        .clone();
    let version = util::command(binary, &["--version"])
        .ok()
        .filter(|(ok, _, _)| *ok)
        .map(|(_, out, _)| out.trim().to_owned())
        .unwrap_or_default();
    Some(Catalog {
        binary: binary.to_owned(),
        version,
        models,
    })
}

fn load_disk_cache() -> Option<Catalog> {
    let bytes = fs::read(cache_path()).ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    Some(Catalog {
        binary: value["binary"].as_str()?.to_owned(),
        version: value["version"].as_str().unwrap_or("").to_owned(),
        models: value["models"].as_array()?.clone(),
    })
}

fn store_disk_cache(catalog: &Catalog) {
    let payload =
        json!({"binary": catalog.binary, "version": catalog.version, "models": catalog.models});
    if let Ok(bytes) = serde_json::to_vec(&payload) {
        let _ = crate::sessions::write_cache(&cache_path(), &bytes);
    }
}

type CatalogResult = Result<Catalog, String>;
type Memo = (Option<String>, CatalogResult);

fn resolve(hint: Option<&str>) -> CatalogResult {
    static MEMO: OnceLock<Mutex<Option<Memo>>> = OnceLock::new();
    let memo = MEMO.get_or_init(|| Mutex::new(None));
    let mut guard = memo.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((cached_hint, cached_result)) = guard.as_ref() {
        if cached_hint.as_deref() == hint {
            return cached_result.clone();
        }
    }
    let result = candidates(hint)
        .iter()
        .find_map(|binary| fetch(binary))
        .inspect(store_disk_cache)
        .or_else(load_disk_cache)
        .ok_or_else(|| {
            "无法运行本机 `codex` 命令，模型系统提示词/上下文窗口数据不可用。".to_owned()
        });
    *guard = Some((hint.map(str::to_owned), result.clone()));
    result
}

/// Looks up a model's bundled catalog entry by slug, including its exact system prompt text.
/// Returns an error only when the `codex` CLI cannot be run at all; an unrecognised slug is
/// reported in the `matched` field instead of failing outright.
pub fn lookup(binary_hint: Option<&str>, slug: &str) -> Result<Value, String> {
    let catalog = resolve(binary_hint)?;
    let entry = catalog
        .models
        .iter()
        .find(|m| m["slug"].as_str() == Some(slug));
    let Some(entry) = entry else {
        return Ok(json!({
            "source_binary": catalog.binary, "source_version": catalog.version,
            "matched": false, "slug": slug,
        }));
    };
    let context_window = entry["context_window"]
        .as_i64()
        .or_else(|| entry["max_context_window"].as_i64());
    let percent = entry["effective_context_window_percent"]
        .as_i64()
        .unwrap_or(95);
    Ok(json!({
        "source_binary": catalog.binary, "source_version": catalog.version, "matched": true,
        "slug": slug, "base_instructions": entry["base_instructions"],
        "usable_context_window": context_window.map(|w| w.saturating_mul(percent) / 100),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_matches_a_bundled_model_or_reports_why_not() {
        // No `codex` CLI on the test machine (e.g. CI) is a valid, explicit outcome here, not a
        // failure: this only asserts the function never panics and reports consistent shapes.
        let Ok(catalog) = resolve(None) else {
            return;
        };
        let Some(sample) = catalog.models.first() else {
            return;
        };
        let slug = sample["slug"].as_str().unwrap().to_owned();
        let result = lookup(None, &slug).expect("a resolvable codex binary must not then fail");
        assert_eq!(result["matched"], true);
        assert!(!result["base_instructions"].as_str().unwrap().is_empty());

        let miss = lookup(None, "definitely-not-a-real-model-slug").unwrap();
        assert_eq!(miss["matched"], false);
    }
}
