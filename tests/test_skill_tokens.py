from pathlib import Path

import pytest
import tiktoken

from codex_inspector.core.skills_scan import scan_skills
from codex_inspector.core.token_count import estimate_text_tokens, offline_encoding


@pytest.mark.parametrize(
    "text",
    [
        "Hello, world!",
        "你好，世界。",
        "<|endoftext|>",
        "---\nname: example\n---\n# Test\n",
    ],
)
def test_local_count_matches_official_tokenizer(text: str) -> None:
    if offline_encoding() is None:
        pytest.skip("Local tokenizer table is not installed")
    count, encoding, method = estimate_text_tokens(text)
    assert method == "tiktoken"
    assert encoding == "o200k_base"
    assert count == len(tiktoken.get_encoding("o200k_base").encode_ordinary(text))


def test_skill_count_includes_frontmatter_and_full_body(tmp_path: Path) -> None:
    skill = tmp_path / "skills" / "example" / "SKILL.md"
    skill.parent.mkdir(parents=True)
    text = "---\nname: example\ndescription: test\n---\n# 完整正文\nUse this skill.\n"
    skill.write_text(text, encoding="utf-8")
    result = scan_skills(tmp_path, tmp_path, None, {})
    assert len(result) == 1
    assert result[0].token_count == estimate_text_tokens(text)[0]


def test_missing_table_uses_explicit_offline_fallback(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("TIKTOKEN_CACHE_DIR", str(tmp_path))
    offline_encoding.cache_clear()
    estimate_text_tokens.cache_clear()
    try:
        count, encoding, method = estimate_text_tokens("你好 world")
        assert count > 0
        assert encoding is None
        assert method == "character_heuristic"
        assert estimate_text_tokens("a")[0] == 1
        assert estimate_text_tokens("")[0] == 0
    finally:
        offline_encoding.cache_clear()
        estimate_text_tokens.cache_clear()


def test_unreadable_skill_is_not_reported_as_zero_tokens(tmp_path: Path) -> None:
    skill = tmp_path / "skills" / "example" / "SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_bytes(b"\xff\xfe")
    result = scan_skills(tmp_path, tmp_path, None, {})
    assert result[0].token_count is None
    assert result[0].token_method == "unavailable"
