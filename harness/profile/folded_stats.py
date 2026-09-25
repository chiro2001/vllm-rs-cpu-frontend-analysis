#!/usr/bin/env python3
"""折叠栈（inferno 格式）统计：帧级 top-N、栈深直方图、线程归属、P1–P10 分段占比。

输入是 `perf_record.sh` 产出的 `<tag>.folded`。计数单位是 **perf period 之和（纳秒）**，
即「该帧的 on-CPU 时间」——`--call-graph fp` + `-e cpu-clock -F 999` 下 period ≈ 1001001 ns，
所以「占比」= 时间占比，与样本数占比等价。

三段口径必须同时给，否则会误读：
  * **self（自耗）**：该帧是栈叶子的样本 —— 用于「热点函数」和分段占比；
  * **inclusive（内含）**：只要该帧出现在栈里 —— 受栈深限制（fp 栈浅），仅供参考；
  * **thread（线程）**：栈底第一列是线程名（`vllm-request` / `vllm-zmq-0` / `tokio-rt-worker`），
    是这把数据里唯一可靠的「粗粒度调用方」信息。

用法见 `folded_stats.py --help`。
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from collections import Counter


def read_folded(path: str):
    """返回 (total_ns, stacks) : stacks = [(frames, count_ns)]。"""
    total = 0
    out = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            stack, _, cnt = line.rpartition(" ")
            try:
                n = int(cnt)
            except ValueError:
                continue
            frames = stack.split(";")
            out.append((frames, n))
            total += n
    return total, out


def load_rules(path: str):
    doc = json.load(open(path))
    rules = [(r["segment"], re.compile(r["match"]), r.get("basis", ""), r.get("note", ""))
             for r in doc["rules"]]
    return rules


def classify(frame: str, rules) -> tuple[str, str]:
    for seg, rx, basis, _note in rules:
        if rx.search(frame):
            return seg, basis
    return "X-unclassified", "none"


SEG_ORDER = [f"P{i}" for i in range(1, 11)] + [
    # Python 前端专属桶（REMOTE_HOST A4 对照用）：CPython 解释器本体 与 Python 侧事件循环。
    # 它们**不对应 P1–P10 的任何一段**——正是「被 Rust 换掉的那一层」。
    "X-py-interp", "X-py-venv",
    "X-alloc", "X-copy", "X-serde", "X-hash", "X-runtime", "X-tls", "X-park", "X-str",
    "X-log", "X-metrics", "X-bytes", "X-kernel", "X-unknown", "X-rust", "X-unclassified",
]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="折叠栈统计：top-N / 栈深 / 线程 / 分段",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--folded", required=True)
    ap.add_argument("--tag", default=None, help="标签（默认取文件名）")
    ap.add_argument("--segments", default=os.path.join(os.path.dirname(__file__), "segments.json"))
    ap.add_argument("--outdir", default=None, help="输出目录（写 <tag>.topn.csv / .segments.csv）")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--source", default=None, help="数据来源说明，写进 CSV 头注释（如 B1 负载描述）")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    tag = args.tag or os.path.basename(args.folded).rsplit(".", 1)[0]
    total, stacks = read_folded(args.folded)
    if not total:
        print("折叠栈为空", file=sys.stderr)
        return 2

    rules = load_rules(args.segments)
    selfc: Counter[str] = Counter()
    incl: Counter[str] = Counter()
    thread: Counter[str] = Counter()
    seg_self: Counter[str] = Counter()
    seg_self_p: Counter[str] = Counter()   # 只算 P 段的帧（用于"P 段内部占比"）
    depth: Counter[int] = Counter()
    seg_frames: dict[str, Counter[str]] = {}
    basis_of: dict[str, str] = {}

    for frames, n in stacks:
        thread[frames[0]] += n
        depth[len(frames)] += n
        leaf = frames[-1]
        selfc[leaf] += n
        seg, basis = classify(leaf, rules)
        basis_of[leaf] = basis
        seg_self[seg] += n
        if seg.startswith("P"):
            seg_self_p[seg] += n
        seg_frames.setdefault(seg, Counter())[leaf] += n
        for f in frames[1:]:
            incl[f] += n

    p_total = sum(seg_self_p.values())

    if not args.quiet:
        print(f"### {tag}：on-CPU {total / 1e9:.3f} core-s（{total / 1001001:.0f} 样本 @999Hz）")
        if args.source:
            print(f"来源：{args.source}")
        print("\n**线程归属（叶子帧所在线程）**")
        print("| 线程 | core-s | 占比 |")
        print("|---|---:|---:|")
        for t, n in thread.most_common():
            print(f"| `{t}` | {n / 1e9:.3f} | {n / total * 100:.2f}% |")
        print("\n**栈深直方图（fp 展开质量）**")
        print("| 栈深 | 样本 | 占比 |")
        print("|---|---:|---:|")
        for d in sorted(depth):
            print(f"| {d} | {depth[d] / 1001001:.0f} | {depth[d] / total * 100:.2f}% |")
        print(f"\n**帧级 self top-{args.top}**")
        print("| # | 帧 | core-ms | self% | 分段 | 依据 |")
        print("|---:|---|---:|---:|---|---|")
        for i, (f, n) in enumerate(selfc.most_common(args.top), 1):
            seg, basis = classify(f, rules)
            print(f"| {i} | `{f[:100]}` | {n / 1e6:.1f} | {n / total * 100:.2f}% | {seg} | {basis} |")
        print("\n**分段 self-time 占比**")
        print("| 分段 | core-ms | 占全部 self | 占 P1–P10 |")
        print("|---|---:|---:|---:|")
        for seg in SEG_ORDER:
            n = seg_self.get(seg, 0)
            if not n:
                continue
            pcol = f"{n / p_total * 100:.2f}%" if seg.startswith("P") and p_total else "—"
            print(f"| {seg} | {n / 1e6:.1f} | {n / total * 100:.2f}% | {pcol} |")
        print(f"| **合计** | {total / 1e6:.1f} | 100.00% | 100.00% |")
        print(f"\nP1–P10 合计 self = {p_total / total * 100:.2f}%；"
              f"跨段桶合计 = {(total - p_total) / total * 100:.2f}%")

    if args.outdir:
        os.makedirs(args.outdir, exist_ok=True)
        with open(os.path.join(args.outdir, f"{tag}.topn.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["# tag", tag, "total_cpu_ns", total, "source", args.source or ""])
            w.writerow(["rank", "frame", "self_ns", "self_pct", "inclusive_ns", "inclusive_pct",
                        "segment", "basis"])
            for i, (fr, n) in enumerate(selfc.most_common(args.top), 1):
                seg, basis = classify(fr, rules)
                w.writerow([i, fr, n, round(n / total * 100, 4), incl.get(fr, 0),
                            round(incl.get(fr, 0) / total * 100, 4), seg, basis])
        with open(os.path.join(args.outdir, f"{tag}.segments.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["# tag", tag, "total_cpu_ns", total, "source", args.source or ""])
            w.writerow(["segment", "self_ns", "self_pct_of_all", "self_pct_of_P1_P10",
                        "top_frames_in_segment"])
            for seg in SEG_ORDER:
                n = seg_self.get(seg, 0)
                if not n:
                    continue
                top = " | ".join(f"{fr}={c / 1e6:.1f}ms" for fr, c in seg_frames[seg].most_common(4))
                pcol = round(n / p_total * 100, 3) if seg.startswith("P") and p_total else ""
                w.writerow([seg, n, round(n / total * 100, 4), pcol, top])
        with open(os.path.join(args.outdir, f"{tag}.threads.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["# tag", tag, "total_cpu_ns", total])
            w.writerow(["thread", "cpu_ns", "pct", "samples"])
            for t, n in thread.most_common():
                w.writerow([t, n, round(n / total * 100, 4), round(n / 1001001)])
        with open(os.path.join(args.outdir, f"{tag}.depth.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["# tag", tag, "total_cpu_ns", total])
            w.writerow(["stack_depth", "cpu_ns", "pct", "samples"])
            for d in sorted(depth):
                w.writerow([d, depth[d], round(depth[d] / total * 100, 4), round(depth[d] / 1001001)])
        if not args.quiet:
            print(f"\n[folded_stats] CSV -> {args.outdir}/{tag}.{{topn,segments,threads,depth}}.csv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
