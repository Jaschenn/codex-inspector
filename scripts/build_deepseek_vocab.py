#!/usr/bin/env python3
"""Regenerate rust-core/vocab/deepseek_v3.bin from an official DeepSeek tokenizer.json.

DeepSeek-V3 through DeepSeek-V4.1-Flash ship the same byte-level BPE (128,000 ids, 127,741
merges); only their added special tokens differ, and those are not used for ordinary-text
counting. Source used for the committed file:

    https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash/resolve/main/tokenizer.json (MIT)

Output layout (little-endian u32): 256 ids for raw bytes 0..=255, then one (left, right) id pair
per merge in priority order. Merge i produces id FIRST_MERGE_ID + i, which this script asserts,
so the Rust side needs neither token strings nor a rank table.

Usage: python3 scripts/build_deepseek_vocab.py path/to/tokenizer.json
"""

import json
import struct
import sys
from pathlib import Path

FIRST_MERGE_ID = 259
OUTPUT = Path(__file__).resolve().parent.parent / "rust-core" / "vocab" / "deepseek_v3.bin"


def gpt2_byte_alphabet():
    printable = (
        list(range(ord("!"), ord("~") + 1))
        + list(range(ord("¡"), ord("¬") + 1))
        + list(range(ord("®"), ord("ÿ") + 1))
    )
    chars = printable[:]
    extra = 0
    for byte in range(256):
        if byte not in printable:
            printable.append(byte)
            chars.append(256 + extra)
            extra += 1
    return {chr(c): b for b, c in zip(printable, chars)}


def main(source: str) -> None:
    model = json.loads(Path(source).read_text(encoding="utf-8"))["model"]
    assert model["type"] == "BPE" and not model.get("byte_fallback")
    vocab = model["vocab"]
    char_to_byte = gpt2_byte_alphabet()
    byte_ids = [None] * 256
    for char, byte in char_to_byte.items():
        byte_ids[byte] = vocab[char]
    pairs = []
    for index, merge in enumerate(model["merges"]):
        left, right = merge.split(" ") if isinstance(merge, str) else merge
        assert vocab[left + right] == FIRST_MERGE_ID + index, merge
        pairs.append((vocab[left], vocab[right]))
    assert FIRST_MERGE_ID + len(pairs) == len(vocab)
    data = struct.pack("<256I", *byte_ids) + b"".join(struct.pack("<II", *p) for p in pairs)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(data)
    print(f"wrote {OUTPUT} ({len(pairs)} merges, {len(data)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1])
