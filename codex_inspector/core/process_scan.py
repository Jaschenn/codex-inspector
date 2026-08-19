"""在 macOS 上发现正在运行的 codex 进程,并读取它的 cwd / env / 命令行参数。

这里的每一个"拿信息"的动作都可能因为权限、系统差异而失败,原则是:
拿不到就诚实地标出「未知/失败」,绝不瞎猜替用户拍脑袋。
"""
from __future__ import annotations

import re
import shlex
import subprocess

from .models import RawProcess, CliOverrides
from .toml_compat import parse_toml_scalar

try:
    import psutil
except ModuleNotFoundError:  # pragma: no cover
    psutil = None  # type: ignore


CODEX_BIN_NAMES = {"codex"}


def _basename_is_codex(cmd_first_token: str) -> bool:
    name = cmd_first_token.rsplit("/", 1)[-1]
    # 允许类似 codex.exe(WSL 场景)、codex-cli 这种变体也被识别,但要求以 codex 开头
    # 且不要被 "codexguide" 之类完全不相关的东西误伤——所以要求精确匹配或加常见后缀。
    return name in CODEX_BIN_NAMES or name in {"codex.exe"}


def find_codex_processes() -> list[RawProcess]:
    """用 `ps` 列出所有进程,过滤出可执行文件名是 codex 的那些。"""
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,user=,etime=,command="],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise RuntimeError(f"无法执行 `ps` 来列出进程: {exc}") from exc

    procs: list[RawProcess] = []
    for line in out.splitlines():
        line = line.rstrip("\n")
        if not line.strip():
            continue
        # 格式: PID USER ETIME COMMAND...  —— 前三个字段之间用空白分隔,COMMAND 可能含空格
        m = re.match(r"\s*(\d+)\s+(\S+)\s+(\S+)\s+(.*)$", line)
        if not m:
            continue
        pid_s, user, etime, cmd = m.groups()
        first_token = cmd.split(" ", 1)[0] if cmd else ""
        # 排除掉 ps/grep 自身,以及这个工具自己(如果它也叫 codex-inspector 不会误伤)
        if _basename_is_codex(first_token):
            procs.append(RawProcess(pid=int(pid_s), user=user, etime=etime, cmdline=cmd))
    return procs


def get_cwd(pid: int) -> tuple[str | None, str | None]:
    """用 lsof 拿进程当前工作目录。返回 (cwd, error)。"""
    try:
        out = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except FileNotFoundError:
        return None, "系统没有 lsof 命令,无法获取 cwd"
    except subprocess.TimeoutExpired:
        return None, "lsof 超时(进程可能处于挂起状态)"

    if out.returncode != 0:
        # 常见原因:进程已退出、或者没有权限访问该进程
        stderr = out.stderr.strip()
        return None, f"lsof 读取失败(可能是权限不足或进程已退出): {stderr or '无详细信息'}"

    for line in out.stdout.splitlines():
        if line.startswith("n"):
            return line[1:], None
    return None, "lsof 未返回 cwd 条目"


def get_env(pid: int) -> tuple[dict[str, str], str]:
    """尝试拿进程环境变量。返回 (env_dict, status),status 是 "ok"/"partial"/"unavailable"。

    macOS 的强化运行时经常会拒绝读取其它进程(哪怕是同一用户)的完整环境变量,这里做了
    两层尝试,都失败就诚实返回 unavailable,而不是编造一份假的。
    """
    if psutil is not None:
        try:
            p = psutil.Process(pid)
            env = p.environ()
            if env:
                return dict(env), "ok"
        except Exception:
            pass

    # 退回到 BSD ps 的 eww 技巧:环境变量会跟在命令行后面,以 KEY=VALUE 形式出现。
    try:
        out = subprocess.run(
            ["ps", "eww", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}, "unavailable"

    lines = out.splitlines()
    if len(lines) < 2:
        return {}, "unavailable"
    tail = lines[1]
    env: dict[str, str] = {}
    for token in tail.split():
        if "=" in token and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            k, _, v = token.partition("=")
            env[k] = v
    if env:
        return env, "partial"  # ps eww 按空格切,值里带空格的会被截断,标记为 partial
    return {}, "unavailable"


def parse_cli_overrides(cmdline: str) -> CliOverrides:
    """从完整命令行里解析出 --profile / --cd / --config / -c key=value。"""
    overrides = CliOverrides()
    try:
        tokens = shlex.split(cmdline)
    except ValueError:
        # 命令行引号不匹配(截断导致),尽力而为按空格切
        tokens = cmdline.split()

    i = 1  # 跳过程序名本身
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("--profile",) and i + 1 < len(tokens):
            overrides.profile = tokens[i + 1]
            i += 2
            continue
        if tok in ("--cd", "-C") and i + 1 < len(tokens):
            overrides.cd = tokens[i + 1]
            i += 2
            continue
        if tok == "--config" and i + 1 < len(tokens):
            overrides.config_path = tokens[i + 1]
            i += 2
            continue
        if tok == "-c" and i + 1 < len(tokens):
            kv = tokens[i + 1]
            key, sep, raw_val = kv.partition("=")
            if sep:
                value = parse_toml_scalar(raw_val)
                if key.strip() == "codex_home":
                    overrides.codex_home = str(value)
                overrides.c_overrides.append((key.strip(), value))
            i += 2
            continue
        i += 1

    return overrides
