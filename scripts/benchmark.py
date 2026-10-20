"""Reproducible local measurements; emits metrics, never chat/configuration contents.

Run with uv run python scripts/benchmark.py --help. This developer-only script is
not bundled with the native app and uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import resource
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import cast

Json = dict[str, object]


def command(arguments: list[str]) -> str:
    return subprocess.check_output(arguments, text=True).strip()


def environment() -> Json:
    return {
        "measured_at_utc": datetime.now(timezone.utc).isoformat(),
        "machine": command(["sysctl", "-n", "hw.model"]),
        "processor": command(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "cores": int(command(["sysctl", "-n", "hw.ncpu"])),
        "memory_bytes": int(command(["sysctl", "-n", "hw.memsize"])),
        "os": command(["sw_vers"]),
        "python": platform.python_version(),
    }


def describe(app: Path) -> Json:
    return {
        "app_bytes": sum(p.stat().st_size for p in app.rglob("*") if p.is_file()),
        "ui_sha256": hashlib.sha256(
            (app / "Contents/MacOS/CodexInspector").read_bytes()
        ).hexdigest(),
        "core_sha256": hashlib.sha256(
            (app / "Contents/MacOS/codex-inspector-core").read_bytes()
        ).hexdigest(),
    }


def distribution(samples: list[float]) -> Json:
    ordered = sorted(samples)
    return {
        "count": len(samples),
        "median": statistics.median(samples),
        "p95": ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)],
        "min": min(samples),
        "max": max(samples),
        "samples": samples,
    }


def snapshot(data: bytes) -> Json:
    result = json.loads(data)
    if not isinstance(result, dict) or "error" in result:
        raise RuntimeError("Engine did not return a successful report")
    return cast(Json, result)


def workload(report: Json, output_bytes: int) -> Json:
    sessions = report.get("sessions")
    selected = report.get("selected_session")
    turns = selected.get("turns") if isinstance(selected, dict) else None
    return {
        "process_count": report.get("process_count"),
        "session_count": len(sessions) if isinstance(sessions, list) else None,
        "selected_turn_count": len(turns) if isinstance(turns, list) else None,
        "snapshot_bytes": output_bytes,
        "selected_session_sha256": hashlib.sha256(
            json.dumps(selected, sort_keys=True, ensure_ascii=False).encode()
        ).hexdigest(),
    }


def children_cpu() -> float:
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def one_shot(core: Path, arguments: list[str], iterations: int) -> Json:
    times = []
    workloads = []
    cpu_start = children_cpu()
    for _ in range(iterations):
        start = time.perf_counter_ns()
        result = subprocess.run(
            [str(core), *arguments], check=True, capture_output=True
        )
        times.append((time.perf_counter_ns() - start) / 1e6)
        workloads.append(workload(snapshot(result.stdout), len(result.stdout)))
    return {
        "wall_ms": distribution(times),
        "children_cpu_ms_per_check": (children_cpu() - cpu_start) * 1000 / iterations,
        "workloads": workloads,
    }


def served(core: Path, request: Json, iterations: int) -> Json:
    encoded = json.dumps(request).encode() + b"\n"
    times = []
    workloads = []
    cpu_start = children_cpu()
    start = time.perf_counter_ns()
    with subprocess.Popen(
        [str(core), "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    ) as process:
        assert process.stdin is not None and process.stdout is not None
        for index in range(iterations + 1):
            if index > 0:
                start = time.perf_counter_ns()
            process.stdin.write(encoded)
            process.stdin.flush()
            data = process.stdout.readline()
            times.append((time.perf_counter_ns() - start) / 1e6)
            workloads.append(workload(snapshot(data), len(data)))
        # EOF is the production lifecycle: engine must shut down with its parent.
        process.stdin.close()
        process.wait(timeout=20)
        if process.returncode != 0:
            raise RuntimeError("Engine did not exit cleanly")
    return {
        "first_snapshot_ms": times[0],
        "warm_wall_ms": distribution(times[1:]),
        "children_cpu_ms_per_check_including_startup": (children_cpu() - cpu_start)
        * 1000
        / len(times),
        "workloads": workloads,
    }


def live_memory(samples: int, interval: float) -> Json:
    ui_values = []
    engine_values = []
    pids = set()
    for _ in range(samples):
        rows = command(["ps", "-axo", "pid=,ppid=,rss=,comm="]).splitlines()
        processes = [row.strip().split(maxsplit=3) for row in rows]
        ui = [
            row
            for row in processes
            if len(row) == 4 and Path(row[3]).name == "CodexInspector"
        ]
        if len(ui) != 1:
            raise RuntimeError("Run exactly one Inspector app before memory sampling")
        pid = ui[0][0]
        pids.add(pid)
        ui_values.append(float(ui[0][2]))
        children = [
            row
            for row in processes
            if len(row) == 4
            and row[1] == pid
            and Path(row[3]).name == "codex-inspector-core"
        ]
        # None is intentional: a one-shot engine may be absent between polls.
        engine_values.append(float(children[0][2]) if children else None)
        time.sleep(interval)
    if len(pids) != 1:
        raise RuntimeError("App restarted during memory sampling")
    observed = [value for value in engine_values if value is not None]
    return {
        "ui_rss_kib": distribution(ui_values),
        "engine_rss_kib_when_observed": distribution(observed) if observed else None,
        "engine_rss_kib_samples": engine_values,
        "interval_seconds": interval,
        "note": "RSS includes resident shared pages; it is not heap size or physical footprint. Do not add process RSS as unique physical memory.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-app", type=Path)
    parser.add_argument("--baseline-revision")
    parser.add_argument("--memory-state", default="unspecified")
    parser.add_argument("--settle-seconds", type=float, default=20)
    parser.add_argument(
        "--candidate-app", type=Path, default=Path("/Applications/CodexInspector.app")
    )
    parser.add_argument("--session-id")
    parser.add_argument("--iterations", type=int, default=50)
    parser.add_argument("--startup-samples", type=int, default=10)
    parser.add_argument("--live-memory", action="store_true")
    parser.add_argument("--memory-samples", type=int, default=40)
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if (
        options.iterations < 1
        or options.startup_samples < 1
        or options.memory_samples < 1
        or options.interval < 0
        or options.settle_seconds < 0
    ):
        parser.error("Sample counts must be positive; interval must be nonnegative")
    result: Json = {"environment": environment()}
    if options.live_memory:
        result["binary"] = describe(options.candidate_app.resolve())
        time.sleep(options.settle_seconds)
        result["ui_state"] = options.memory_state
        result["settle_seconds"] = options.settle_seconds
        result["memory"] = live_memory(options.memory_samples, options.interval)
    else:
        if options.baseline_app is None:
            parser.error("--baseline-app is required for comparative measurements")
        baseline = options.baseline_app.resolve()
        candidate = options.candidate_app.resolve()
        old_core = baseline / "Contents/MacOS/codex-inspector-core"
        new_core = candidate / "Contents/MacOS/codex-inspector-core"
        session_id = options.session_id
        if not session_id:
            catalog = snapshot(
                subprocess.check_output([str(new_core), "--json", "--sessions"])
            )
            sessions = catalog.get("sessions")
            if not isinstance(sessions, list) or not sessions:
                raise RuntimeError("A local chat is required for this workload")
            session_id = sessions[0]["id"]
        arguments = ["--json", "--sessions", "--session-id", session_id]
        request: Json = {"sessions": True, "menu": True, "session_id": session_id}
        # Prewarm disk caches in both engines. Startup samples below describe a
        # new OS process with existing indexes/token cache, not empty-cache startup.
        subprocess.run(
            [str(old_core), *arguments], check=True, stdout=subprocess.DEVNULL
        )
        subprocess.run(
            [str(new_core), *arguments], check=True, stdout=subprocess.DEVNULL
        )
        # Let asynchronously flushed rollout/SQLite records settle before A/B samples.
        time.sleep(2)
        result["baseline_binary"] = describe(baseline)
        result["candidate_binary"] = describe(candidate)
        result["baseline_revision"] = options.baseline_revision
        result["method"] = (
            "Baseline: new CLI process per check. Candidate: one pipe-owned engine, latest-turn detail plus menu summary. Disk caches prewarmed; sequential unthrottled requests, JSON decoding outside wall-time interval. CPU includes all measured child processes, excludes UI/Python parent."
        )
        result["baseline"] = one_shot(old_core, arguments, options.iterations)
        result["candidate"] = served(new_core, request, options.iterations)
        old_workloads = cast(dict[str, object], result["baseline"])["workloads"]
        new_workloads = cast(dict[str, object], result["candidate"])["workloads"]
        fingerprints = {
            entry["selected_session_sha256"]
            for entry in cast(list[Json], old_workloads)
            + cast(list[Json], new_workloads)
        }
        if len(fingerprints) != 1:
            raise RuntimeError(
                "Selected chat changed during A/B samples; retry when its log is quiet"
            )
        result["selected_snapshot_identical_across_all_timed_requests"] = True
        result["candidate_new_process_first_snapshot_ms"] = distribution(
            [
                cast(float, served(new_core, request, 1)["first_snapshot_ms"])
                for _ in range(options.startup_samples)
            ]
        )
        result["baseline_new_process_first_snapshot_ms"] = one_shot(
            old_core, arguments, options.startup_samples
        )["wall_ms"]
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"Evidence saved to {options.output}")


if __name__ == "__main__":
    main()
