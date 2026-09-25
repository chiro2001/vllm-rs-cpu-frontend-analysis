#!/usr/bin/env python3
"""「前端占比 vs 引擎速度」的**实测锚点**表。

为什么单独做：`harness/scale/extrapolate.py` 的引擎速度轴是**假设**（只有两个实测档），
而本项目现在有三个**实测锚点**，可以把这条曲线钉在真实数据上：

  | 装置 | 引擎每请求 | 前端占比 | 出处 |
  |---|---|---|---|
  | 本机 x86 纯 CPU 真引擎 | ~245 ms/token | ~0.003% | C 线（`agents/root/REPORT.md`） |
  | REMOTE_HOST chip4 + Ascend（Rust 前端） | ~4.7 ms/token | 见 `points.csv` | **B 线本轮实测** |
  | REMOTE_HOST chip4 + Ascend（Python 前端） | 同上 | 见 `points.csv` | **B 线本轮实测** |
  | 本机 x86 + mock engine | ≈0 | ≈100% | B 线 x86 主节 |

输出：`data/profiles/a3/share-anchor.csv` + 可选 markdown。

口径警告：
  * 「前端占比」的分母是**每请求的「前端 CPU + 引擎 CPU」**（都是进程 CPU 秒，同口径）；
    不是「前端占端到端墙钟」——后者含排队与客户端，会把占比稀释。
  * 前端与引擎的 CPU 都来自 `procstat`（utime+stime，不含子进程），两侧同一把尺子。

用法见 `share_anchor.py --help`。
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="前端占比 vs 引擎速度的实测锚点表",
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--dir", default="data/profiles/a3")
    ap.add_argument("--x86-note", action="store_true",
                    help="把 x86（mock engine 与纯 CPU 真引擎）两档也并进表里（数值来自既有记录，非本轮重测）")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--out", default=None)
    args = ap.parse_args(argv)

    rows = []
    for f in sorted(glob.glob(os.path.join(args.dir, "*.point.json"))):
        d = json.load(open(f))
        tag = os.path.basename(f).replace(".point.json", "")
        fe = (d.get("frontend_cpu") or {}).get("cpu_seconds")
        eng = (d.get("container_cpu_buckets") or {}).get("engine")
        e2e = d.get("e2e") or {}
        comp = e2e.get("completed") or 0
        otok = e2e.get("total_output_tokens") or 0
        row = {
            "tag": tag,
            "side": d.get("side"),
            "load": (f"ISL={d['load']['input_len']} OSL={d['load']['output_len']} "
                     f"c={d['load']['max_concurrency']}"),
            "completed": comp,
            "frontend_cpu_s": fe,
            "engine_cpu_s": eng,
            "engine_ms_per_token": (round(eng / otok * 1000, 4) if eng and otok else None),
            "mean_tpot_ms": e2e.get("mean_tpot_ms"),
            "frontend_share_cpu_pct": (round(fe / (fe + eng) * 100, 4) if fe and eng else None),
            "engine_over_frontend": (round(eng / fe, 2) if fe else None),
        }
        rows.append(row)

    if args.x86_note:
        rows.append({
            "tag": "x86-mock", "side": "rust", "load": "ISL=1k OSL=128 c=1",
            "completed": None, "frontend_cpu_s": None, "engine_cpu_s": None,
            "engine_ms_per_token": "≈0（mock）", "mean_tpot_ms": 0.0089,
            "frontend_share_cpu_pct": "≈100（引擎近免费）", "engine_over_frontend": None,
        })

    out = args.out or os.path.join(args.dir, "share-anchor.csv")
    cols = ["tag", "side", "load", "completed", "frontend_cpu_s", "engine_cpu_s",
            "engine_ms_per_token", "mean_tpot_ms", "frontend_share_cpu_pct",
            "engine_over_frontend"]
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["# 前端占比 = 前端CPU秒 / (前端CPU秒 + 引擎CPU秒)，均为 procstat 口径",
                    "不是「前端占端到端墙钟」；两侧同一把尺子",
                    "engine_ms_per_token 用引擎 CPU 秒 / 输出 token 数（含 prefill 摊销，故略大于 TPOT）"])
        w.writerow(cols)
        for r in rows:
            w.writerow([r.get(c) for c in cols])
    print(f"[share_anchor] {len(rows)} 行 -> {out}", file=sys.stderr)

    if args.markdown:
        print("| 点 | 前端 | 负载 | 引擎 ms/token | TPOT ms | **前端占比（CPU）** | 引擎/前端 |")
        print("|---|---|---|---:|---:|---:|---:|")
        for r in rows:
            print(f"| {r['tag']} | {r['side']} | {r['load']} | {r['engine_ms_per_token']} | "
                  f"{r['mean_tpot_ms']} | **{r['frontend_share_cpu_pct']}** | "
                  f"{r['engine_over_frontend']} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
