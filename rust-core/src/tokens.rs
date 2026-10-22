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

fn compressed_encoding() -> Option<tiktoken_rs::CoreBPE> {
    let vocabulary = zstd::stream::decode_all(
        include_bytes!(concat!(env!("OUT_DIR"), "/o200k_base.bin.zst")).as_slice(),
    )
    .ok()?;
    let mut remaining = vocabulary.as_slice();
    let mut encoder = rustc_hash::FxHashMap::default();
    for rank in 0..199_998 {
        let length = u16::from_le_bytes(remaining.get(..2)?.try_into().ok()?) as usize;
        remaining = remaining.get(2..)?;
        encoder.insert(remaining.get(..length)?.to_vec(), rank);
        remaining = remaining.get(length..)?;
    }
    if !remaining.is_empty() || encoder.len() != 199_998 {
        return None;
    }
    let mut special_tokens = rustc_hash::FxHashMap::default();
    special_tokens.insert("<|endoftext|>".to_owned(), 199_999);
    special_tokens.insert("<|endofprompt|>".to_owned(), 200_018);
    // Use the upstream BPE implementation and pattern unchanged. Compression only changes
    // storage; the original table is reconstructed once, on the first uncached Skill.
    tiktoken_rs::CoreBPE::new(encoder, special_tokens, tiktoken_rs::O200K_BASE_PAT_STR).ok()
}

static ENCODING: Mutex<Option<tiktoken_rs::CoreBPE>> = Mutex::new(None);

pub fn estimate(text: &str) -> (Option<usize>, Option<&'static str>, &'static str) {
    let key = util::hash(text);
    if let Some(count) = cache()
        .lock()
        .ok()
        .and_then(|c| c.counts.get(&key).copied())
    {
        return (Some(count), Some("o200k_base"), "tiktoken");
    }
    let mut encoder = ENCODING.lock().unwrap_or_else(|e| e.into_inner());
    if encoder.is_none() {
        *encoder = compressed_encoding();
    }
    if let Some(encoding) = encoder.as_ref() {
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
    // Uncached Skills in one report share the vocabulary. Afterwards only their
    // small counts are needed; retaining the 200k-token BPE defeats a small idle footprint.
    let released = ENCODING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
        .is_some();
    #[cfg(target_os = "macos")]
    if released {
        unsafe extern "C" {
            fn malloc_zone_pressure_relief(zone: *mut libc::c_void, goal: usize) -> usize;
        }
        // Return freed vocabulary pages to macOS, not live data or file-backed caches.
        unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
    }
    #[cfg(not(target_os = "macos"))]
    let _ = released;
    if let Ok(mut cache) = cache().lock() {
        if !cache.dirty {
            return;
        }
        if let Ok(bytes) = serde_json::to_vec(&*cache) {
            if crate::sessions::write_cache(&cache_path(), &bytes).is_ok() {
                cache.dirty = false;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_vocabulary_matches_official_tokenizer() {
        // Keep the tokenizer equivalence check in Rust after retiring the Python
        // implementation: compression must preserve ordinary/special-token text.
        let embedded = compressed_encoding().expect("embedded vocabulary");
        let official = tiktoken_rs::o200k_base().expect("official vocabulary");
        for text in [
            "",
            "Hello, world!",
            "你好，世界。",
            "<|endoftext|>",
            "---\nname: example\n---\n# Test\n",
        ] {
            assert_eq!(
                embedded.encode_ordinary(text),
                official.encode_ordinary(text),
                "{text:?}"
            );
        }
    }
}
