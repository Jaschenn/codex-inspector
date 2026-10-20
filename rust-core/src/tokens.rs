use crate::util;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

#[derive(Default, Deserialize, Serialize)]
struct TokenCache {
    counts: BTreeMap<String, usize>,
    #[serde(skip)]
    dirty: bool,
}
fn cache_path() -> PathBuf {
    std::env::var_os("CODEX_INSPECTOR_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| util::home().join("Library/Caches/CodexInspector"))
        .join("rust-o200k-tokens-v1.json")
}
fn cache() -> &'static Mutex<TokenCache> {
    static CACHE: OnceLock<Mutex<TokenCache>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(
            fs::read(cache_path())
                .ok()
                .and_then(|data| serde_json::from_slice(&data).ok())
                .unwrap_or_default(),
        )
    })
}
pub fn estimate(text: &str) -> (Option<usize>, Option<&'static str>, &'static str) {
    let key = util::hash(text);
    if let Some(count) = cache()
        .lock()
        .ok()
        .and_then(|c| c.counts.get(&key).copied())
    {
        return (Some(count), Some("o200k_base"), "tiktoken");
    }
    // The official o200k_base ranks are embedded by tiktoken-rs. No runtime downloads or Python.
    static ENCODING: OnceLock<Option<tiktoken_rs::CoreBPE>> = OnceLock::new();
    if let Some(encoding) = ENCODING.get_or_init(|| tiktoken_rs::o200k_base().ok()) {
        let count = encoding.encode_ordinary(text).len();
        if let Ok(mut cache) = cache().lock() {
            if cache.counts.len() >= 2048 {
                cache.counts.clear();
            }
            cache.counts.insert(key, count);
            cache.dirty = true;
        }
        (Some(count), Some("o200k_base"), "tiktoken")
    } else {
        let ascii = text.chars().filter(char::is_ascii).count();
        let count = if text.is_empty() {
            0
        } else {
            ((ascii as f64 / 4.0 + (text.chars().count() - ascii) as f64 * 1.5).round() as usize)
                .max(1)
        };
        (Some(count), None, "character_heuristic")
    }
}
pub fn save() {
    if let Ok(cache) = cache().lock() {
        if !cache.dirty {
            return;
        }
        if let Ok(bytes) = serde_json::to_vec(&*cache) {
            let _ = crate::sessions::write_cache(&cache_path(), &bytes);
        }
    }
}
