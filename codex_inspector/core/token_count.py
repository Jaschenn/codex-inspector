"""离线统计 Skill 文本；分词表在打包时获取，探测过程绝不下载或调用 API。"""

from __future__ import annotations

import base64
import hashlib
import os
import tempfile
from functools import lru_cache
from pathlib import Path

import tiktoken

ENCODING_NAME = "o200k_base"
TABLE_URL = "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken"
TABLE_HASH = "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d"
# 与 OpenAI tiktoken 的 o200k_base 构造器一致；手动载入本地表，避免其缺表时自动联网。
PATTERN = "|".join(
    [
        r"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?",
        r"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?",
        r"\p{N}{1,3}",
        r" ?[^\s\p{L}\p{N}]+[\r\n/]*",
        r"\s*[\r\n]+",
        r"\s+(?!\S)",
        r"\s+",
    ]
)


@lru_cache(maxsize=1)
def offline_encoding() -> tiktoken.Encoding | None:
    cache = os.environ.get(
        "TIKTOKEN_CACHE_DIR",
        os.environ.get(
            "DATA_GYM_CACHE_DIR", str(Path(tempfile.gettempdir()) / "data-gym-cache")
        ),
    )
    if not cache:
        return None
    table = Path(cache) / hashlib.sha1(TABLE_URL.encode()).hexdigest()
    try:
        data = table.read_bytes()
        if hashlib.sha256(data).hexdigest() != TABLE_HASH:
            return None
        ranks = {
            base64.b64decode(token): int(rank)
            for token, rank in (line.split() for line in data.splitlines() if line)
        }
        return tiktoken.Encoding(
            name=ENCODING_NAME,
            pat_str=PATTERN,
            mergeable_ranks=ranks,
            special_tokens={"<|endoftext|>": 199999, "<|endofprompt|>": 200018},
        )
    except (OSError, ValueError):
        return None


@lru_cache(maxsize=128)
def estimate_text_tokens(text: str) -> tuple[int, str | None, str]:
    encoding = offline_encoding()
    if encoding is not None:
        return len(encoding.encode_ordinary(text)), ENCODING_NAME, "tiktoken"
    # 非打包环境缺少分词表时明确标为粗估；中文不能套用英语的字符数 / 4。
    ascii_count = sum(character.isascii() for character in text)
    estimate = (
        max(1, round(ascii_count / 4 + (len(text) - ascii_count) * 1.5)) if text else 0
    )
    return estimate, None, "character_heuristic"
