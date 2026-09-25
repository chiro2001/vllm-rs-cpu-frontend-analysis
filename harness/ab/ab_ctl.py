#!/usr/bin/env python3
"""A/B 采集工具（C 线）：进程识别 / perf stat 同窗口采集 / 归一化汇总。

子命令：
  pids      识别容器内 前端/引擎/worker/supervisor 四类角色，输出 JSON
  perfstat  对一个 pid 集合做「同事件、同窗口」的 perf stat 采集，输出 JSON
  summary   把 vllm-bench 结果 + procstat 增量 + perfstat 合成一条归一化记录

所有子命令都支持 --help。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

RUST_FRONTEND_BIN = "/usr/local/lib/python3.12/site-packages/vllm/vllm-rs"
ROLES = ("frontend", "engine", "worker", "supervisor")


def _comm(pid: int) -> str:
    try:
        return pathlib.Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return ""


def _cmdline(pid: int) -> str:
    try:
        return pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return ""


def _ppid(pid: int) -> int:
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
        rest = raw.rsplit(")", 1)[1].split()
        return int(rest[1])
    except (OSError, IndexError, ValueError):
        return 0


def _threads(pid: int) -> int:
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return int(raw.rsplit(")", 1)[1].split()[17])
    except (OSError, IndexError, ValueError):
        return 0


def scan_container(container: str) -> list[dict]:
    """在容器 PID 命名空间内枚举进程（docker exec 看到的是容器内 pid）。"""
    code = r"""
import json, os, pathlib
out = []
for p in os.listdir('/proc'):
    if not p.isdigit():
        continue
    pid = int(p)
    try:
        args = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
    except OSError:
        continue
    try:
        raw = pathlib.Path(f'/proc/{pid}/stat').read_text()
        rest = raw.rsplit(')', 1)[1].split()
        state, ppid, nthreads = rest[0], int(rest[1]), int(rest[17])
        comm = raw.split('(', 1)[1].rsplit(')', 1)[0]
    except (OSError, IndexError, ValueError):
        continue
    if state == 'Z':      # 容器里 PID 1 不回收孤儿，会留僵尸；僵尸不占 CPU，排除
        continue
    out.append({'pid': pid, 'ppid': ppid, 'threads': nthreads, 'comm': comm, 'args': args})
print(json.dumps(out))
"""
    raw = subprocess.run(
        ["docker", "exec", container, "python3", "-c", code],
        capture_output=True, text=True, check=True,
    )
    return json.loads(raw.stdout)


def resolve_roles(procs: list[dict], side: str, kind: str = "real",
                  engine_pid: int | None = None, engine_label: str = "vllm-mock-engine") -> dict:
    by_pid = {p["pid"]: p for p in procs}

    if kind == "mock":
        # mock 臂：引擎是宿主上的 vllm-mock-engine（不在容器里），前端是唯一做 HTTP 的进程。
        if side == "rust":
            # vllm-rs serve …（bind handshake，等外部引擎连进来）；没有 Python supervisor。
            frontend = next(
                (p for p in procs
                 if "vllm-rs" in p["args"] and "serve" in p["args"] and "frontend" not in p["args"]),
                None,
            )
        else:
            # python 主进程自己就是 API server（拓扑 A），--data-parallel-size-local 0
            frontend = next(
                (p for p in procs
                 if "vllm" in p["args"] and "serve" in p["args"] and "python" in p["args"]),
                None,
            )
        roles = {"frontend": frontend, "supervisor": None, "engine": None, "worker": None}
        out = {}
        for role, v in roles.items():
            if v is None:
                out[role] = None
            else:
                out[role] = {
                    "host_pid": host_pid(v["pid"]), "container_pid": v["pid"],
                    "ppid": v["ppid"], "threads": v["threads"], "comm": v["comm"],
                    "args": v["args"].strip()[:400],
                }
        if engine_pid:
            out["engine"] = {
                "host_pid": engine_pid, "container_pid": None, "ppid": _ppid_of(engine_pid),
                "threads": _threads(engine_pid), "comm": _comm(engine_pid) or engine_label,
                "args": _cmdline(engine_pid).strip()[:400],
            }
        return out

    # ⚠️ comm 字段只有 15 字符：`VLLM::EngineCore` 会被内核截成 `VLLM::EngineCor`，
    # 而 setproctitle 会把 argv 完整改写成 "VLLM::EngineCore"，所以两个都要认。
    def is_engine(p):
        return p["comm"].startswith("VLLM::EngineCor") or p["args"].strip().startswith("VLLM::EngineCore")

    def is_worker(p):
        return p["comm"].startswith("VLLM::Worker") and not is_engine(p)

    engines = sorted((p for p in procs if is_engine(p)), key=lambda p: p["pid"])
    workers = sorted((p for p in procs if is_worker(p)), key=lambda p: p["pid"])
    # 有多个残留 EngineCore 时，取「祖先链能追到 vllm serve 主进程」的那个
    engine = None
    for cand in engines:
        anc = by_pid.get(cand["ppid"])
        if anc is not None and "vllm" in anc["args"] and "serve" in anc["args"]:
            engine = cand
            break
    if engine is None and engines:
        engine = engines[-1]
    worker = None
    if engine is not None:
        worker = next((w for w in workers if w["ppid"] == engine["pid"]), None)
    if worker is None and workers:
        worker = workers[-1]

    # supervisor = EngineCore 最近的那个 `vllm serve` 祖先（拓扑 A/C 里就是 Python 主进程）
    supervisor = None
    if engine is not None:
        cur = by_pid.get(engine["ppid"])
        if cur is not None and "vllm" in cur["args"] and "serve" in cur["args"] and "python" in cur["args"]:
            supervisor = cur

    rust_frontend = next(
        (p for p in procs if RUST_FRONTEND_BIN in p["args"] and "frontend" in p["args"]), None
    )

    if side == "rust":
        frontend = rust_frontend
        roles = {
            "frontend": rust_frontend,        # vllm-rs 子进程（被分析对象）
            "supervisor": supervisor,          # 只做编排的 Python 主进程（对照基线）
            "engine": engine,
            "worker": worker,
        }
    else:
        # Python 侧：主进程自己就是 API server（拓扑 A），同时承担编排角色
        roles = {"frontend": supervisor, "supervisor": None, "engine": engine, "worker": worker}

    res = {}
    for k, v in roles.items():
        if v is None:
            res[k] = None
        else:
            res[k] = {
                "host_pid": host_pid(v["pid"]), "container_pid": v["pid"],
                "ppid": v["ppid"], "threads": v["threads"], "comm": v["comm"],
                "args": v["args"].strip()[:400],
            }
    return res


_host_pid_cache: dict[int, int] = {}


def host_pid(container_pid: int) -> int | None:
    """把容器内 pid 映射成宿主机 pid（/proc/<host>/status 的 NSpid 末位）。"""
    try:
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            hp = int(entry.name)
            try:
                status = (entry / "status").read_text()
            except OSError:
                continue
            nspid = re.search(r"^NSpid:\s*(.+)$", status, re.M)
            if not nspid:
                continue
            ids = nspid.group(1).split()
            if len(ids) >= 2 and ids[-1] == str(container_pid):
                return hp
    except OSError:
        return None
    return None


def cmd_pids(args: argparse.Namespace) -> int:
    procs = scan_container(args.container)
    roles = resolve_roles(procs, args.side, kind=args.kind, engine_pid=args.engine_pid)
    doc = {
        "side": args.side,
        "kind": args.kind,
        "container": args.container,
        "taken_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "roles": roles,
        "raw_processes": sorted(
            [
                p for p in procs
                if p["comm"].startswith("VLLM::")
                or "vllm-rs" in p["args"]
                or ("vllm" in p["args"] and "serve" in p["args"])
                or "EngineCore" in p["comm"]
            ],
            key=lambda p: p["pid"],
        ),
    }
    for role in ROLES:
        r = roles.get(role)
        doc[f"{role}_host_pid"] = r["host_pid"] if r else None
    if getattr(args, "pid_dir", None) and roles.get("frontend"):
        outdir = pathlib.Path(args.pid_dir)
        outdir.mkdir(parents=True, exist_ok=True)
        for role in ROLES:
            r = roles.get(role)
            if r:
                (outdir / f"{role}.pid").write_text(str(r["host_pid"]) + "\n")
        print(f"[ab][pids] pid files -> {outdir}", file=sys.stderr)
    body = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if args.out:
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(body)
        print(f"[ab][pids] {args.out}", file=sys.stderr)
    if not args.quiet:
        for role in ROLES:
            r = roles.get(role)
            if r:
                cpid = r["container_pid"] if r["container_pid"] is not None else "—"
                print(f"{role:11s} host_pid={str(r['host_pid']):<8} cpid={str(cpid):<7} "
                      f"ppid={r['ppid']:<7} threads={r['threads']:<3} comm={r['comm']} | {r['args'][:90]}")
            else:
                print(f"{role:11s} —")
    return 0 if roles.get("frontend") and roles.get("engine") else 3


CACHE_MISS_EVENTS = "instructions:u,cycles:u,cache-misses:u,branches:u"


def _parse_perf_csv(text: str) -> dict:
    vals, elapsed, note = {}, None, None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.search(r"([\d.]+)\s+seconds time elapsed", line)
        if m:
            elapsed = float(m.group(1))
            continue
        if line.startswith("#"):
            continue
        parts = line.split(",")
        if len(parts) < 3:
            continue
        value, _unit, event = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not event:
            continue
        if value.startswith("<") or not re.match(r"^[\d.]+$", value.replace(",", "")):
            note = f"{event}={value}"
            continue
        # ⚠️ `-e instructions:u` 在 `-x,` 输出里事件名是 `instructions:u`。
        # 归一化到基名，否则下游按 `instructions` 取值会全是 None（踩过）。
        count = float(value.replace(",", ""))
        vals[event] = count
        vals[event.split(":", 1)[0]] = count
    out = {"counters": vals, "window_seconds": elapsed}
    if vals.get("cycles") and vals.get("instructions"):
        out["ipc"] = round(vals["instructions"] / vals["cycles"], 4)
    if note:
        out["note"] = note
    return out


def _perf_one(pid: int, duration: float, events: str, sudo: bool) -> tuple[int, dict]:
    cmd = ["perf", "stat", "-x,", "-p", str(pid), "-e", events, "--"]
    if sudo:
        cmd = ["sudo", "-n"] + cmd
    cmd += ["sleep", str(duration)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    parsed = _parse_perf_csv(proc.stderr)
    parsed["exit_code"] = proc.returncode
    if proc.returncode != 0 and not parsed["counters"]:
        parsed["error"] = (proc.stderr or proc.stdout).strip()[-500:]
    return pid, parsed


def cmd_perfstat(args: argparse.Namespace) -> int:
    if args.pids_file:
        doc = json.loads(pathlib.Path(args.pids_file).read_text())
        items = [(role, r) for role, r in doc["roles"].items() if r]
        pids = [r["host_pid"] for _role, r in items]
        labels = {str(r["host_pid"]): role for role, r in items}
    else:
        pids = [int(p) for p in args.pids.split(",") if p.strip()]
        labels = dict(kv.split("=", 1) for kv in args.label.split(",")) if args.label else {}
    if not pids:
        print("--pids/--pids-file 为空", file=sys.stderr)
        return 2
    if args.require_all:
        missing = [p for p in pids if not pathlib.Path(f"/proc/{p}/stat").exists()]
        if missing:
            print(f"[ab][perfstat] 目标 pid 不存在：{missing}", file=sys.stderr)
            return 2
    started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    t0 = time.time()
    # 每个 pid 一个 perf 进程；窗口由 stop-file 控制（写文件即结束，perf 打印计数）。
    procs: dict[int, subprocess.Popen] = {}
    for p in pids:
        cmd = ["perf", "stat", "-x,", "-p", str(p), "-e", args.events, "-o",
               f"{args.raw_dir}/perf.{p}.txt", "--", "sleep", str(args.duration)]
        if args.sudo:
            cmd = ["sudo", "-n"] + cmd
        procs[p] = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    deadline = time.time() + args.duration
    stop_file = pathlib.Path(args.stop_file) if args.stop_file else None
    while time.time() < deadline:
        if stop_file and stop_file.exists():
            break
        if all(pr.poll() is not None for pr in procs.values()):
            break
        time.sleep(0.2)
    # 结束窗口：给 perf 的 sleep 子进程发 SIGINT，perf 会打印并退出
    # ⚠️ 加了 --sudo 时进程树是 python → sudo → perf → sleep，必须递归找 sleep，
    # 否则窗口关不掉（perf 会一直挂到 --duration 上限）。
    for p, pr in procs.items():
        if pr.poll() is not None:
            continue
        for child in _descendants(pr.pid):
            if _comm(child) == "sleep":
                _sigint(child)
    results = {}
    for p, pr in procs.items():
        try:
            _, err = pr.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            pr.kill()
            _, err = pr.communicate()
        raw_path = pathlib.Path(f"{args.raw_dir}/perf.{p}.txt")
        text = raw_path.read_text() if raw_path.exists() else (err or "")
        parsed = _parse_perf_csv(text)
        parsed["exit_code"] = pr.returncode
        if not parsed["counters"] and err:
            parsed["error"] = err.strip()[-500:]
        results[p] = parsed
    doc = {
        "taken_at": started,
        "window_seconds_requested": args.duration,
        "window_seconds_wall": round(time.time() - t0, 3),
        "stopped_by": "stop-file" if (stop_file and stop_file.exists()) else "timeout",
        "events": args.events,
        "sudo": args.sudo,
        "perf_version": subprocess.run(["perf", "--version"], capture_output=True, text=True).stdout.strip(),
        "pids": {str(p): {"label": labels.get(str(p)), **results[p]} for p in pids},
    }
    body = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if args.out:
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(body)
        print(f"[ab][perfstat] {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(body)
    ok = all("counters" in r and r["counters"] for r in doc["pids"].values())
    return 0 if ok or not args.require_all else 4


def _sigint(pid: int) -> None:
    """给 pid 发 SIGINT；容器/root 进程要经 sudo（EACCES 时回退）。"""
    try:
        os.kill(pid, signal.SIGINT)
        return
    except OSError:
        pass
    subprocess.run(["sudo", "-n", "kill", "-INT", str(pid)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _ppid_of(pid: int) -> int:
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return 0


def _descendants(pid: int) -> list[int]:
    """返回 pid 的所有后代（含 sudo/perf/sleep 这样的多层结构）。"""
    parents: dict[int, list[int]] = {}
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        child = int(entry.name)
        parents.setdefault(_ppid_of(child), []).append(child)
    out, stack = [], [pid]
    while stack:
        cur = stack.pop()
        for child in parents.get(cur, []):
            out.append(child)
            stack.append(child)
    return out


def _load(path: str | None):
    if not path:
        return None
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def reparse_perf_doc(json_path: str | None, raw_dir: str | None):
    """以 raw 目录里的 perf 输出为真源，重建 perf 汇总（返回 doc 或 None）。

    为什么：`perf stat -o <file>` 与「读文件」之间有竞态；raw 文件才是原始证据，
    只要它在，就应当从中恢复计数，而不是相信可能读空的中间 JSON。
    """
    doc = _load(json_path)
    if doc is None:
        return None
    raw_root = pathlib.Path(raw_dir) if raw_dir else None
    if raw_root is not None:
        for pid, entry in doc.get("pids", {}).items():
            raw = raw_root / f"perf.{pid}.txt"
            if not raw.exists():
                continue
            parsed = _parse_perf_csv(raw.read_text())
            if parsed["counters"]:
                if not parsed.get("window_seconds"):
                    parsed["window_seconds"] = doc.get("window_seconds_wall")
                entry.update(parsed)
                entry["counters_source"] = str(raw)
            elif not entry.get("counters"):
                entry["counters_source"] = f"{raw}（空）"
    doc["reparsed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if json_path:
        try:
            pathlib.Path(json_path).write_text(
                json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
            )
        except OSError:
            pass
    return doc


def cmd_reparse(args: argparse.Namespace) -> int:
    doc = reparse_perf_doc(args.perf, args.raw_dir)
    if doc is None:
        print(f"读不到 {args.perf}", file=sys.stderr)
        return 2
    ok = sum(1 for r in doc["pids"].values() if (r.get("counters") or {}))
    print(f"[ab][reparse] {args.perf}：{ok}/{len(doc['pids'])} 个 pid 恢复了计数", file=sys.stderr)
    return 0 if ok else 4


def _norm(cpu_seconds, requests, input_tokens, output_tokens) -> dict:
    if not cpu_seconds:
        return {}
    out = {"cpu_seconds": round(cpu_seconds, 4)}
    if requests:
        out["cpu_s_per_request"] = round(cpu_seconds / requests, 6)
    if input_tokens:
        out["cpu_s_per_1k_input_tokens"] = round(cpu_seconds / input_tokens * 1000, 6)
    if output_tokens:
        out["cpu_s_per_1k_output_tokens"] = round(cpu_seconds / output_tokens * 1000, 6)
    return out


def cmd_summary(args: argparse.Namespace) -> int:
    bench = _load(args.bench) or {}
    pids = _load(args.pids) or {}
    roles = pids.get("roles", {})
    reqs = bench.get("completed") or args.requests
    in_tok = bench.get("total_input_tokens")
    out_tok = bench.get("total_output_tokens")

    window = _load(args.window_diff) or {}
    windows: dict[str, dict] = {}
    for role in ("frontend", "engine", "worker", "supervisor"):
        r = roles.get(role)
        if not r:
            continue
        host_pid = str(r["host_pid"])
        d = window.get("pids", {}).get(host_pid)
        if not d or d.get("missing"):
            continue
        windows[role] = {
            "host_pid": int(host_pid),
            "window_seconds": window.get("wall_seconds"),
            "utime_seconds": d.get("utime_seconds"),
            "stime_seconds": d.get("stime_seconds"),
            "threads_max": d.get("threads_max"),
            "rss_kb_end": d.get("rss_kb_end"),
        }
        windows[role].update(_norm(d.get("cpu_seconds"), reqs, in_tok, out_tok))

    # 客户端单独一个窗口（绝不计入服务端）
    client_diff = _load(args.client_diff)
    if client_diff:
        total = client_diff.get("cpu_seconds_total")
        windows["client"] = {"window_seconds": client_diff.get("wall_seconds"), "cpu_seconds": total}
        windows["client"].update(_norm(total, reqs, in_tok, out_tok))

    # 前端在"客户端启动前"窗口的 CPU（用于量化 prompt 生成期的污染上界）
    pre = _load(args.pre_diff)
    preparse = None
    if pre:
        r = roles.get("frontend")
        fe0 = pre.get("pids", {}).get(str(r["host_pid"])) if r else None
        if fe0 and not fe0.get("missing"):
            preparse = {
                "window_seconds": pre.get("wall_seconds"),
                "cpu_seconds": fe0.get("cpu_seconds"),
                "note": "窗口 = [客户端启动前, 负载结束]，比 win 窗口多包含 vllm-bench 生成 prompt 的空闲期",
            }

    # perf 计数以 raw 文件为唯一真源：`perf stat -o file` 的写入与 Python 侧读取
    # 之间存在竞态（踩过：json 里 counters 为 None，而 raw 文件其实有数）。
    perf_doc = reparse_perf_doc(args.perf, args.perf_raw_dir)
    perf = {}
    if perf_doc:
        for pid, r in perf_doc["pids"].items():
            label = r.get("label") or pid
            c = r.get("counters") or {}
            entry = {"ipc": r.get("ipc"), "counters": c}
            if c.get("instructions") and reqs:
                entry["instructions_per_request"] = round(c["instructions"] / reqs, 1)
            if c.get("cycles") and reqs:
                entry["cycles_per_request"] = round(c["cycles"] / reqs, 1)
            if c.get("instructions") and out_tok:
                entry["instructions_per_1k_output_tokens"] = round(c["instructions"] / out_tok * 1000, 1)
            perf[label] = entry

    doc = {
        "point": args.point,
        "side": args.side,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "end_to_end": {
            k: bench.get(k) for k in (
                "completed", "failed", "duration", "request_throughput", "output_throughput",
                "total_token_throughput", "input_throughput",
                "mean_ttft_ms", "median_ttft_ms", "p99_ttft_ms",
                "mean_tpot_ms", "median_tpot_ms", "p99_tpot_ms",
                "mean_e2el_ms", "median_e2el_ms", "p99_e2el_ms",
                "total_input_tokens", "total_output_tokens", "max_concurrency",
            ) if k in bench
        },
        "windows": windows,
        "frontend_cpu_prep_window": preparse,
        "perf_stat": perf,
        "role_pids": {k: (v or {}).get("host_pid") if isinstance(v, dict) else None for k, v in roles.items()},
        "notes": {
            "frontend_cpu_source": "/proc/<host_pid>/stat 的 utime+stime 增量（不含子进程）",
            "engine_worker_cpu": "引擎进程单独记，绝不并入前端",
            "client_cpu": "压测客户端自身，绝不并入服务端",
            "window_convention": args.window_note,
        },
    }
    body = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if args.out:
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(body)
        print(f"[ab][summary] {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("pids", help="识别容器内 前端/引擎/worker/supervisor")
    q.add_argument("--side", choices=("rust", "python"), required=True)
    q.add_argument("--kind", choices=("real", "mock"), default="real",
                   help="real=真 CPU 引擎；mock=宿主 vllm-mock-engine")
    q.add_argument("--engine-pid", type=int, help="mock 臂：宿主上 mock engine 的 pid")
    q.add_argument("--container", default=os.getenv("AB_CONTAINER", "cab-cpu"))
    q.add_argument("--out")
    q.add_argument("--pid-dir", help="把 <role>.pid（宿主机 pid）写到该目录")
    q.add_argument("--quiet", action="store_true")
    q.set_defaults(func=cmd_pids)

    q = sub.add_parser("perfstat", help="同窗口 perf stat 采集（每 pid 一个 perf 进程，stop-file 结束窗口）")
    q.add_argument("--pids", default="", help="宿主机 pid，逗号分隔")
    q.add_argument("--pids-file", help="ab_ctl.py pids 的输出 JSON（自动带角色标签）")
    q.add_argument("--label", help="pid=名字,pid=名字")
    q.add_argument("--duration", type=float, default=3600, help="窗口上限（秒）；正常由 --stop-file 提前结束")
    q.add_argument("--stop-file", help="该文件出现即结束采集窗口")
    q.add_argument("--raw-dir", default="/tmp/ab-perf-raw", help="perf 原始输出目录")
    q.add_argument("--events", default=CACHE_MISS_EVENTS)
    q.add_argument("--sudo", action="store_true", help="容器内 root 进程需要 sudo")
    q.add_argument("--require-all", action="store_true")
    q.add_argument("--out")
    q.set_defaults(func=cmd_perfstat)

    q = sub.add_parser("summary", help="合成归一化汇总")
    q.add_argument("--point", required=True)
    q.add_argument("--side", choices=("rust", "python"), required=True)
    q.add_argument("--bench")
    q.add_argument("--pids")
    q.add_argument("--perf")
    q.add_argument("--perf-raw-dir", help="perf 原始输出目录（优先于 json 里的计数）")
    q.add_argument("--window-diff", help="procstat diff（覆盖 frontend/engine/worker/supervisor）")
    q.add_argument("--client-diff", help="procstat diff（只覆盖压测客户端）")
    q.add_argument("--pre-diff", help="procstat diff（客户端启动前 → 负载结束，用于量化 prompt 生成污染）")
    q.add_argument("--requests", type=int)
    q.add_argument("--window-note", default="")
    q.add_argument("--out")
    q.set_defaults(func=cmd_summary)

    q = sub.add_parser("reparse-perf", help="以 raw 文件为真源重建 perf 汇总 JSON")
    q.add_argument("--perf", required=True)
    q.add_argument("--raw-dir", required=True)
    q.set_defaults(func=cmd_reparse)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
