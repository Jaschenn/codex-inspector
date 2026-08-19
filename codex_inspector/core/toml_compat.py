"""统一的 TOML 读取入口,兼容 py3.11+ 内置 tomllib 和更老环境的 tomli。"""
from __future__ import annotations

from pathlib import Path
from typing import Any

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - 老版本 Python 兜底
    import tomli as tomllib  # type: ignore


def load_toml(path: Path) -> tuple[dict[str, Any], str | None]:
    """读取一个 TOML 文件。

    返回 (数据, 错误信息)。文件不存在时返回 ({}, None)——这不算错误,只是没有这一层。
    文件存在但解析失败时返回 ({}, "错误描述"),调用方应该把这个错误展示给用户,而不是
    静默吞掉——一个语法错误的 config.toml 对用户来说是很重要的信息。
    """
    if not path.is_file():
        return {}, None
    try:
        with path.open("rb") as f:
            return tomllib.load(f), None
    except tomllib.TOMLDecodeError as exc:  # type: ignore[attr-defined]
        return {}, f"TOML 解析失败: {exc}"
    except OSError as exc:
        return {}, f"读取失败: {exc}"


def parse_toml_scalar(raw: str) -> Any:
    """把一个形如 `-c` 参数里的值(TOML 字面量语法)解析成 Python 值。

    例如 `gpt-5` 会被当作裸字符串处理(不是合法 TOML 字面量),但 Codex 的 `-c` 语法
    要求值本身符合 TOML 语法,比如字符串要带引号:`-c model="gpt-5"`。
    如果解析失败,就原样当字符串返回,保证工具不会因为一个奇怪的参数而崩溃。
    """
    try:
        wrapped = tomllib.loads(f"v = {raw}")
        return wrapped["v"]
    except Exception:
        return raw
