#!/usr/bin/env python3
"""把 REMOTE_HOST 的采集点（`data/profiles/a3/<tag>.point.json` 等）汇总成文档用的表。

产出：
  * `data/profiles/a3/points.csv`   —— 每点的负载、窗口、前端/引擎 CPU、吞吐、TTFT/TPOT
  * `data/profiles/a3/ipc.csv`      —— A5 的 `perf stat` 拆解（IPC / 分支失败 / cache）
  * 可选 markdown 表打到 stdout（`--markdown`）

口径（与 `docs/02` 的 REMOTE_HOST 主节一致）：
  * **只在 REMOTE_HOST chip4 上、同一个镜像、同一个引擎、同一张卡下**取数；
  * 前端 CPU = 容器内前端进程的 `utime+stime`（`harness/common/procstat.sh` 口径，不含子进程）；
  * 吞吐/TTFT/TPOT 来自 `vllm bench serve`（**含引擎**，不是前端成本）；
  * `perf` 是否在窗口内跑，由 `perf_record`/`perf-stat.txt` 是否存在决定，表里显式标出。

用法见 `summarize_a3.py --help`。
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import re
import sys


def load_point(path: str) -> dict:
    d = json.load(open(path))
    tag = os.path.basename(path).replace(".point.json", "")
    e2e = d.get("e2e") or {}
    nz = d.get("normalized") or {}
    fe = d.get("frontend_cpu") or {}
    return {
        "tag": tag,
        "side": d.get("side"),
        "load": (f"ISL={d['load']['input_len']} OSL={d['load']['output_len']} "
                 f"c={d['load']['max_concurrency']} n={d['load']['num_prompts']}"),
        "window_s": d.get("window", {}).get("seconds"),
        "completed": e2e.get("completed"),
        "failed": e2e.get("failed"),
        "frontend_cpu_s": fe.get("cpu_seconds"),
        "frontend_utime_s": fe.get("utime_seconds"),
        "frontend_stime_s": fe.get("stime_seconds"),
        "engine_cpu_s": (d.get("container_cpu_buckets") or {}).get("engine"),
        "fe_cpu_s_per_req": nz.get("frontend_cpu_s_per_request"),
        "fe_cpu_s_per_1k_in": nz.get("frontend_cpu_s_per_1k_input_tokens"),
        "fe_cpu_s_per_1k_out": nz.get("frontend_cpu_s_per_1k_output_tokens"),
        "fe_cpu_per_window_s": nz.get("frontend_cpu_over_window"),
        "req_throughput": e2e.get("request_throughput"),
        "out_throughput": e2e.get("output_throughput"),
        "mean_ttft_ms": e2e.get("mean_ttft_ms"),
        "mean_tpot_ms": e2e.get("mean_tpot_ms"),
        "mean_e2el_ms": e2e.get("mean_e2el_ms"),
        "perf_record": "yes" if d.get("perf_record") else "no",
        "perf_stat_file": None,
    }


STAT_MAP = {
    "instructions:u": "instructions", "cycles:u": "cycles", "branches:u": "branches",
    "branch-misses:u": "branch_misses", "cache-misses:u": "cache_misses",
    "cache-references:u": "cache_references",
    "instructions": "instructions", "cycles": "cycles", "branches": "branches",
    "branch-misses": "branch_misses", "cache-misses": "cache_misses",
    "cache-references": "cache_references",
}


def parse_stat(path: str) -> dict:
    """解析 `perf stat` 文本（aarch64 与 x86 的排版一致）。"""
    out: dict[str, float] = {}
    for line in open(path, errors="replace"):
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("Performance counter"):
            continue
        toks = s.split()
        if len(toks) >= 3 and toks[1] == "seconds":
            out["seconds_" + toks[2]] = float(toks[0])
            continue
        if toks[0].startswith("<") or len(toks) < 2:
            out.setdefault("not_counted", 0)
            out["not_counted"] = out["not_counted"] + 1 if isinstance(out.get("not_counted"), (int, float)) else 1
            continue
        key = STAT_MAP.get(toks[1])
        if not key:
            continue
        try:
            out[key] = float(toks[0].replace(",", ""))
        except ValueError:
            pass
    cyc, ins = out.get("cycles"), out.get("instructions")
    if cyc and ins:
        out["ipc"] = round(ins / cyc, 4)
    if out.get("branches"):
        out["branch_miss_pct"] = round(out.get("branch_misses", 0) / out["branches"] * 100, 4)
    if out.get("cache_references"):
        out["cache_miss_pct"] = round(out.get("cache_misses", 0) / out["cache_references"] * 100, 4)
    return out


def top_frames(topn_csv: str, k: int = 5) -> str:
    if not os.path.exists(topn_csv):
        return ""
    with open(topn_csv) as f:
        f.readline()
        rows = list(csv.DictReader(f))
    return " / ".join(f"{r['frame'][:34]} {r['self_pct']}%" for r in rows[:k])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="汇总 REMOTE_HOST 的 profiling 采集点",
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--dir", default="data/profiles/a3")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--top", type=int, default=5, help="markdown 里附带的 top-N 帧数")
    args = ap.parse_args(argv)

    pts = []
    for f in sorted(glob.glob(os.path.join(args.dir, "*.point.json"))):
        try:
            pts.append(load_point(f))
        except (json.JSONDecodeError, KeyError) as e:
            print(f"[warn] 跳过 {f}：{e}", file=sys.stderr)
    if not pts:
        print(f"[summarize_a3] {args.dir} 下没有 *.point.json", file=sys.stderr)
        return 1

    # perf stat
    for p in pts:
        for cand in (f"{p['tag']}.perf-stat.txt", f"{p['tag']}.perf-stat.txt"):
            path = os.path.join(args.dir, cand)
            if os.path.exists(path):
                p["stat"] = parse_stat(path)
                p["perf_stat_file"] = os.path.basename(path)
                break

    # 折叠栈的 top-N（若已折叠）
    for p in pts:
        p["top_frames"] = top_frames(os.path.join(args.dir, f"{p['tag']}.topn.csv"), args.top)

    cols = ["tag", "side", "load", "window_s", "completed", "failed", "req_throughput",
            "mean_ttft_ms", "mean_tpot_ms", "frontend_cpu_s", "frontend_utime_s",
            "frontend_stime_s", "engine_cpu_s", "fe_cpu_s_per_req",
            "fe_cpu_s_per_1k_in", "fe_cpu_s_per_1k_out", "fe_cpu_per_window_s",
            "perf_record", "perf_stat_file"]
    out = os.path.join(args.dir, "points.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["# REMOTE_HOST chip4 profiling 采集点",
                    "前端 CPU=utime+stime（procstat，不含子进程）",
                    "吞吐/TTFT/TPOT 含引擎，不是前端成本",
                    "同一镜像/引擎/卡，只有前端语言不同"])
        w.writerow(cols)
        for p in pts:
            w.writerow([p.get(c) for c in cols])
    print(f"[summarize_a3] {len(pts)} 个点 -> {out}", file=sys.stderr)

    ipc_rows = [p for p in pts if p.get("stat")]
    if ipc_rows:
        ipc_out = os.path.join(args.dir, "ipc.csv")
        icols = ["tag", "side", "load", "ipc", "cycles", "instructions", "branches",
                 "branch_misses", "branch_miss_pct", "cache_references", "cache_misses",
                 "cache_miss_pct"]
        with open(ipc_out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["# perf stat（用户态事件，perf_event_paranoid 限制）",
                        "IPC = instructions/cycles（比值，与窗口长度无关）",
                        "绝对计数受窗口内的采样开销影响，跨点比较要小心"])
            w.writerow(icols)
            for p in ipc_rows:
                w.writerow([p.get("tag"), p.get("side"), p.get("load"),
                            p["stat"].get("ipc"), p["stat"].get("cycles"),
                            p["stat"].get("instructions"), p["stat"].get("branches"),
                            p["stat"].get("branch_misses"), p["stat"].get("branch_miss_pct"),
                            p["stat"].get("cache_references"), p["stat"].get("cache_misses"),
                            p["stat"].get("cache_miss_pct")])
        print(f"[summarize_a3] {len(ipc_rows)} 个 perf stat 点 -> {ipc_out}", file=sys.stderr)

    if args.markdown:
        print("### REMOTE_HOST 采集点\n")
        print("| 点 | 前端 | 负载 | 窗口 s | 完成 | 吞吐 req/s | TTFT ms | TPOT ms | "
              "前端 CPU s | 其中 utime/stime | 引擎 CPU s | 前端 CPU s/请求 | 采样 |")
        print("|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|")
        for p in pts:
            print(f"| {p['tag']} | {p['side']} | {p['load']} | {p['window_s']} | {p['completed']} | "
                  f"{_f(p['req_throughput'], 2)} | {_f(p['mean_ttft_ms'], 1)} | {_f(p['mean_tpot_ms'], 2)} | "
                  f"{_f(p['frontend_cpu_s'], 3)} | {_f(p['frontend_utime_s'], 2)}/{_f(p['frontend_stime_s'], 2)} | "
                  f"{_f(p['engine_cpu_s'], 2)} | {_f(p['fe_cpu_s_per_req'], 6)} | {p['perf_record']} |")
        if ipc_rows:
            print("\n### perf stat（A5）\n")
            print("| 点 | 前端 | IPC | cycles | instructions | 分支失败率 | cache miss 率 |")
            print("|---|---|---:|---:|---:|---:|---:|")
            for p in ipc_rows:
                s = p["stat"]
                print(f"| {p['tag']} | {p['side']} | **{s.get('ipc')}** | {_si(s.get('cycles'))} | "
                      f"{_si(s.get('instructions'))} | {s.get('branch_miss_pct')}% | "
                      f"{s.get('cache_miss_pct')}% |")
        with_top = [p for p in pts if p.get("top_frames")]
        if with_top:
            print("\n### 火焰图 top-N（self 占比，用户态）\n")
            for p in with_top:
                print(f"- **{p['tag']}**（{p['side']}）：{p['top_frames']}")
    return 0


def _f(v, nd):
    return "" if v is None else f"{v:.{nd}f}"


def _si(v):
    return "" if v is None else f"{int(v):,}"


if __name__ == "__main__":
    raise SystemExit(main())
