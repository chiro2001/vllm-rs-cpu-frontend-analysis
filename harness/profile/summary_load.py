#!/usr/bin/env python3
"""把每个负载点的窗口结果（`<ID>.cpu-load.json` / `<ID>.load.json`）汇总成一张 CSV。

输出 `data/profiles/load.csv`，列与 `docs/02-cpu-profile.md` §13 的表一一对应：

    ID, 负载, 窗口s, 请求数, 前端CPU s, 前端CPU s/请求, 前端CPU s/千输入token,
    前端CPU s/千输出token, 压测端CPU s, 压测端CPU s/请求, 吞吐 req/s, 采样中?

口径（写进 CSV 头注释，引用时必须带上）：
  * **前端 CPU** = `utime+stime`（不含子进程），来自 `harness/common/procstat.sh`，
    before 取在预热之后/窗口之前、after 取在窗口之后；
  * **压测端 CPU** = 客户端进程自己的 getrusage 差值（窗口内），与前端**分开报、不相加**；
  * 输入/输出 token 数取自响应体的 `usage`（不是本地估计）。

用法见 `summary_load.py --help`。
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys


def load_point(path: str) -> dict | None:
    try:
        d = json.load(open(path))
    except (OSError, json.JSONDecodeError):
        return None
    tag = os.path.basename(path).split(".")[0]
    n = d.get("normalized") or {}
    return {
        "ID": tag,
        "note": d.get("note") or "",
        "load": f"ISL={d.get('prompt_tokens_mean') or 0:.0f} OSL={d.get('output_len_target')} "
                f"c={d.get('concurrency')} tools={d.get('tools')} stream={int(bool(d.get('stream')))}",
        "window_s": d["window"]["wall_seconds"],
        "requests": d["requests_completed_in_window"],
        "failed": d["requests_failed_in_window"],
        "frontend_cpu_s": d.get("frontend_cpu_seconds"),
        "frontend_utime_s": d.get("frontend_utime_seconds"),
        "frontend_stime_s": d.get("frontend_stime_seconds"),
        "frontend_cpu_us_per_request": _us(n.get("frontend_cpu_s_per_request")),
        "frontend_cpu_s_per_1k_in_tok": n.get("frontend_cpu_s_per_1k_input_tokens"),
        "frontend_cpu_s_per_1k_out_tok": n.get("frontend_cpu_s_per_1k_output_tokens"),
        "client_cpu_s": d.get("client_cpu_seconds_window_only"),
        "client_cpu_us_per_request": _us(n.get("client_cpu_s_per_request")),
        "throughput_req_s": d.get("throughput_req_s"),
        "prompt_tokens_total": d.get("prompt_tokens_total"),
        "completion_tokens_total": d.get("completion_tokens_total"),
        "perf_running": "no" if "cpu-load" in os.path.basename(path) else "yes",
        "source_file": os.path.basename(path),
    }


def _us(sec):
    return None if sec is None else round(sec * 1e6, 3)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="汇总每负载点的前端/客户端 CPU 与吞吐",
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--out-dir", default="data/profiles")
    ap.add_argument("--patterns", default="*.cpu-load.json,*.load.json",
                    help="逗号分隔；同一 ID 同时命中两个模式时，优先第一个（cpu-load = 无 perf 窗口）")
    ap.add_argument("--out", default=None, help="CSV 输出路径（默认 <out-dir>/load.csv）")
    ap.add_argument("--markdown", action="store_true", help="同时把 markdown 表打到 stdout")
    ap.add_argument("--include-legacy", action="store_true",
                    help="也输出**本次补采之前**的老文件（那些没有 frontend_cpu_seconds 的 30 s 跑法）")
    args = ap.parse_args(argv)

    rows: dict[str, dict] = {}
    for pat in args.patterns.split(","):
        for path in sorted(glob.glob(os.path.join(args.out_dir, pat.strip()))):
            r = load_point(path)
            if not r:
                continue
            if r["frontend_cpu_s"] is None and not args.include_legacy:
                continue
            prev = rows.get(r["ID"])
            # 优先保留 patterns 里靠前的模式（*.cpu-load.json 在无 perf 模式下更干净）
            if prev is None or "cpu-load" in os.path.basename(path):
                rows[r["ID"]] = r

    def sort_key(r):
        t = r["ID"]
        base = "".join(ch for ch in t if ch.isdigit())
        return (int(base) if base else 99, t)

    ordered = sorted(rows.values(), key=sort_key)
    out = args.out or os.path.join(args.out_dir, "load.csv")
    header = ["ID", "load", "window_s", "requests", "failed", "frontend_cpu_s",
              "frontend_utime_s", "frontend_stime_s",
              "frontend_cpu_us_per_request", "frontend_cpu_s_per_1k_in_tok",
              "frontend_cpu_s_per_1k_out_tok", "client_cpu_s", "client_cpu_us_per_request",
              "throughput_req_s", "prompt_tokens_total", "completion_tokens_total",
              "perf_running", "note", "source_file"]
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["# 前端 CPU = utime+stime（不含子进程），harness/common/procstat.sh；"
                    "before=预热后/窗口前，after=窗口后",
                    "压测端 CPU = 客户端 getrusage 差值（窗口内）", "两者分开报，绝不相加",
                    "输入/输出 token 取自响应体 usage"])
        w.writerow(header)
        for r in ordered:
            w.writerow([r[h] for h in header])
    print(f"[summary_load] {len(ordered)} 个负载点 -> {out}", file=sys.stderr)

    if args.markdown:
        print("| ID | 窗口 s | 请求数 | 前端 CPU s | 前端 CPU s/请求 | s/千输入 token | "
              "s/千输出 token | 其中 utime / stime | 压测端 CPU s | 吞吐 req/s |")
        print("|---|---:|---:|---:|---:|---:|---:|---|---:|---:|")
        for r in ordered:
            print(f"| {r['ID']} | {r['window_s']} | {r['requests']} | {r['frontend_cpu_s']} | "
                  f"{r['frontend_cpu_us_per_request']} µs | {r['frontend_cpu_s_per_1k_in_tok']} | "
                  f"{r['frontend_cpu_s_per_1k_out_tok']} | "
                  f"{r['frontend_utime_s']} / {r['frontend_stime_s']} | {r['client_cpu_s']} | "
                  f"{r['throughput_req_s']} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
