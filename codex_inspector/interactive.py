"""POSIX 终端的非阻塞按键读取,只用标准库,专为 --watch 的交互模式服务。

设计成一个上下文管理器:进入时把 stdin 切到 cbreak 模式(不回显、不等回车),
退出时无论如何都恢复原状态——这个恢复必须可靠,否则用户 Ctrl+C 退出后终端会变得很怪。
"""
from __future__ import annotations

import select
import sys

try:
    import termios
    import tty
    HAS_TERMIOS = True
except ImportError:  # Windows 没有这两个模块,交互模式直接不可用
    HAS_TERMIOS = False


class RawKeyboard:
    def __init__(self) -> None:
        self._fd = sys.stdin.fileno() if sys.stdin.isatty() else None
        self._old_settings = None

    @property
    def available(self) -> bool:
        return HAS_TERMIOS and self._fd is not None

    def __enter__(self) -> "RawKeyboard":
        if self.available:
            self._old_settings = termios.tcgetattr(self._fd)
            tty.setcbreak(self._fd)
        return self

    def __exit__(self, *exc_info) -> None:
        if self.available and self._old_settings is not None:
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_settings)

    def read_key(self, timeout: float = 0.0) -> str | None:
        """非阻塞读取一个按键,归一化成 'up'/'down'/'left'/'right'/'q'/'r' 或原始字符。

        没有按键时返回 None。方向键是多字节 ESC 序列,这里在读到 ESC 后短暂等待
        后续字节,拼不出完整序列就当成单独的 ESC 处理。
        """
        if not self.available:
            return None
        ready, _, _ = select.select([self._fd], [], [], timeout)
        if not ready:
            return None
        ch = sys.stdin.read(1)
        if ch != "\x1b":
            return ch
        # 可能是方向键:ESC [ A/B/C/D
        ready, _, _ = select.select([self._fd], [], [], 0.02)
        if not ready:
            return "esc"
        ch2 = sys.stdin.read(1)
        if ch2 != "[":
            return "esc"
        ready, _, _ = select.select([self._fd], [], [], 0.02)
        if not ready:
            return "esc"
        ch3 = sys.stdin.read(1)
        return {"A": "up", "B": "down", "C": "right", "D": "left"}.get(ch3, "esc")
