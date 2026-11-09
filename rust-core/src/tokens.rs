use crate::util;
use rustc_hash::FxHashMap;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

/// Tokenizer families Codex Inspector can count exactly. OpenAI models use `o200k_base`;
/// DeepSeek-V3 through V4.1 share one byte-level BPE vocabulary (see
/// `scripts/build_deepseek_vocab.py`). Anything else falls back to `o200k_base`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoding {
    O200kBase,
    DeepSeekV3,
}

impl Encoding {
    /// The tokenizer for a model slug, and whether it is known to be that model's own
    /// tokenizer (rather than the `o200k_base` stand-in used for unrecognised models).
    pub fn for_model(model: Option<&str>) -> (Self, bool) {
        let model = model.unwrap_or_default().to_ascii_lowercase();
        // Provider-prefixed slugs (`openrouter/deepseek-v3.2`) name the model last.
        let name = model.rsplit('/').next().unwrap_or_default();
        if name.contains("deepseek") {
            (Self::DeepSeekV3, true)
        } else {
            let openai = name.starts_with("gpt-")
                || name.starts_with("codex")
                || (name.starts_with('o') && name[1..].starts_with(|c: char| c.is_ascii_digit()));
            (Self::O200kBase, openai)
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::O200kBase => "o200k_base",
            Self::DeepSeekV3 => "deepseek_v3",
        }
    }
}

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
        .join("rust-tokens-v2.json")
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

fn compressed_o200k() -> Option<tiktoken_rs::CoreBPE> {
    let vocabulary = zstd::stream::decode_all(
        include_bytes!(concat!(env!("OUT_DIR"), "/o200k_base.bin.zst")).as_slice(),
    )
    .ok()?;
    let mut remaining = vocabulary.as_slice();
    let mut encoder = FxHashMap::default();
    for rank in 0..199_998 {
        let length = u16::from_le_bytes(remaining.get(..2)?.try_into().ok()?) as usize;
        remaining = remaining.get(2..)?;
        encoder.insert(remaining.get(..length)?.to_vec(), rank);
        remaining = remaining.get(length..)?;
    }
    if !remaining.is_empty() || encoder.len() != 199_998 {
        return None;
    }
    let mut special_tokens = FxHashMap::default();
    special_tokens.insert("<|endoftext|>".to_owned(), 199_999);
    special_tokens.insert("<|endofprompt|>".to_owned(), 200_018);
    // Use the upstream BPE implementation and pattern unchanged. Compression only changes
    // storage; the original table is reconstructed once, on the first uncached text.
    tiktoken_rs::CoreBPE::new(encoder, special_tokens, tiktoken_rs::O200K_BASE_PAT_STR).ok()
}

/// DeepSeek's Hugging Face tokenizer: three isolating regex splits applied in sequence, then
/// byte-level BPE driven by the official merge list. Merge `i` produces id `FIRST_MERGE_ID + i`,
/// so a merged id doubles as its priority (lower merges first), exactly like HF `BPE`.
struct DeepSeek {
    byte_ids: [u32; 256],
    merges: FxHashMap<(u32, u32), u32>,
    digits: regex::Regex,
    kana_han: regex::Regex,
    words: fancy_regex::Regex,
}

const DEEPSEEK_FIRST_MERGE_ID: u32 = 259;
const DEEPSEEK_MERGES: usize = 127_741;

impl DeepSeek {
    fn load() -> Option<Self> {
        let data = zstd::stream::decode_all(
            include_bytes!(concat!(env!("OUT_DIR"), "/deepseek_v3.bin.zst")).as_slice(),
        )
        .ok()?;
        if data.len() != 4 * 256 + 8 * DEEPSEEK_MERGES {
            return None;
        }
        let word = |i: usize| u32::from_le_bytes(data[i * 4..i * 4 + 4].try_into().unwrap());
        let mut byte_ids = [0; 256];
        for (byte, id) in byte_ids.iter_mut().enumerate() {
            *id = word(byte);
        }
        let mut merges = FxHashMap::default();
        merges.reserve(DEEPSEEK_MERGES);
        for index in 0..DEEPSEEK_MERGES {
            let pair = (word(256 + index * 2), word(257 + index * 2));
            merges.insert(pair, DEEPSEEK_FIRST_MERGE_ID + index as u32);
        }
        Some(Self {
            byte_ids,
            merges,
            digits: regex::Regex::new(r"\p{N}{1,3}").ok()?,
            kana_han: regex::Regex::new("[一-龥\u{3040}-ゟ゠-ヿ]+").ok()?,
            words: fancy_regex::Regex::new(
                r##"[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~][A-Za-z]+|[^\r\n\p{L}\p{P}\p{S}]?[\p{L}\p{M}]+| ?[\p{P}\p{S}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"##,
            )
            .ok()?,
        })
    }

    fn count(&self, text: &str) -> usize {
        let mut total = 0;
        for coarse in isolate(text, |s| {
            self.digits.find_iter(s).map(|m| m.range()).collect()
        }) {
            for middle in isolate(coarse, |s| {
                self.kana_han.find_iter(s).map(|m| m.range()).collect()
            }) {
                for piece in isolate(middle, |s| {
                    self.words
                        .find_iter(s)
                        .filter_map(Result::ok)
                        .map(|m| m.range())
                        .collect()
                }) {
                    total += self.bpe_len(piece.as_bytes());
                }
            }
        }
        total
    }

    fn bpe_len(&self, piece: &[u8]) -> usize {
        let mut ids: Vec<u32> = piece.iter().map(|&b| self.byte_ids[b as usize]).collect();
        let rank = |ids: &[u32], i: usize| {
            ids.get(i + 1)
                .and_then(|&right| self.merges.get(&(ids[i], right)).copied())
                .unwrap_or(u32::MAX)
        };
        let mut ranks: Vec<u32> = (0..ids.len()).map(|i| rank(&ids, i)).collect();
        // Lowest merged id (= highest priority) first; ties go to the leftmost pair, as in HF.
        while let Some((i, best)) = ranks
            .iter()
            .copied()
            .enumerate()
            .filter(|&(_, r)| r != u32::MAX)
            .min_by_key(|&(i, r)| (r, i))
        {
            ids[i] = best;
            ids.remove(i + 1);
            ranks.remove(i + 1);
            ranks[i] = rank(&ids, i);
            if i > 0 {
                ranks[i - 1] = rank(&ids, i - 1);
            }
        }
        ids.len()
    }
}

/// HF `Split` with `Isolated` behaviour: every match and every gap between matches is its own piece.
fn isolate(text: &str, matches: impl Fn(&str) -> Vec<std::ops::Range<usize>>) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut last = 0;
    for range in matches(text) {
        if range.start > last {
            pieces.push(&text[last..range.start]);
        }
        if range.end > range.start {
            pieces.push(&text[range.clone()]);
        }
        last = range.end;
    }
    if last < text.len() {
        pieces.push(&text[last..]);
    }
    pieces
}

#[derive(Default)]
struct Tokenizers {
    o200k: Option<tiktoken_rs::CoreBPE>,
    deepseek: Option<DeepSeek>,
}

static TOKENIZERS: Mutex<Tokenizers> = Mutex::new(Tokenizers {
    o200k: None,
    deepseek: None,
});

fn count_uncached(encoding: Encoding, text: &str) -> Option<usize> {
    let mut loaded = TOKENIZERS.lock().unwrap_or_else(|e| e.into_inner());
    match encoding {
        Encoding::O200kBase => {
            if loaded.o200k.is_none() {
                loaded.o200k = compressed_o200k();
            }
            loaded
                .o200k
                .as_ref()
                .map(|bpe| bpe.encode_ordinary(text).len())
        }
        Encoding::DeepSeekV3 => {
            if loaded.deepseek.is_none() {
                loaded.deepseek = DeepSeek::load();
            }
            loaded.deepseek.as_ref().map(|bpe| bpe.count(text))
        }
    }
}

/// `o200k_base` estimate, for callers with no model context (Skill files, MCP probes).
pub fn estimate(text: &str) -> (Option<usize>, Option<&'static str>, &'static str) {
    estimate_with(Encoding::O200kBase, text)
}

pub fn estimate_with(
    encoding: Encoding,
    text: &str,
) -> (Option<usize>, Option<&'static str>, &'static str) {
    let key = format!("{}:{}", encoding.name(), util::hash(text));
    if let Some(count) = cache()
        .lock()
        .ok()
        .and_then(|c| c.counts.get(&key).copied())
    {
        return (Some(count), Some(encoding.name()), "tokenizer");
    }
    if let Some(count) = count_uncached(encoding, text) {
        if let Ok(mut cache) = cache().lock() {
            if cache.counts.len() >= 2048 {
                cache.counts.clear();
            }
            cache.counts.insert(key, count);
            cache.dirty = true;
        }
        (Some(count), Some(encoding.name()), "tokenizer")
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
    // Uncached texts in one report share the vocabularies. Afterwards only their small counts
    // are needed; retaining a 128k-200k token BPE defeats a small idle footprint.
    let released = {
        let mut loaded = TOKENIZERS.lock().unwrap_or_else(|e| e.into_inner());
        let released = loaded.o200k.is_some() || loaded.deepseek.is_some();
        *loaded = Tokenizers::default();
        released
    };
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
        let embedded = compressed_o200k().expect("embedded vocabulary");
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

    #[test]
    fn deepseek_counts_match_hugging_face_reference() {
        // Expected counts come from `tokenizers` (HF) loading the official DeepSeek-V4.1-Flash
        // tokenizer.json with `add_special_tokens=False`.
        let deepseek = DeepSeek::load().expect("embedded DeepSeek vocabulary");
        for (text, expected) in include!("../vocab/deepseek_v3_reference.rs") {
            assert_eq!(deepseek.count(text), expected, "{text:?}");
        }
    }

    #[test]
    fn models_select_their_tokenizer() {
        use Encoding::*;
        assert_eq!(
            Encoding::for_model(Some("deepseek-v4.1-flash")),
            (DeepSeekV3, true)
        );
        assert_eq!(
            Encoding::for_model(Some("openrouter/DeepSeek-V3.2")),
            (DeepSeekV3, true)
        );
        assert_eq!(Encoding::for_model(Some("gpt-5.5")), (O200kBase, true));
        assert_eq!(Encoding::for_model(Some("o3")), (O200kBase, true));
        assert_eq!(Encoding::for_model(Some("qwen3-coder")), (O200kBase, false));
        assert_eq!(Encoding::for_model(None), (O200kBase, false));
    }
}
