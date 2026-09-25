#!/usr/bin/env python3
"""用「三点线性分解」把每个帧的成本拆成 常数 / 每输入 token / 每输出 token。

为什么需要它：fp 栈太浅（`docs/02` §2.2），六成样本没有调用方 ⇒ 像
`[libc.so.6]`（memmove）、`Map::try_fold`、`LocalKey::with` 这类帧，
只看符号名判不出属于哪个 P 段。但**它们的成本随什么增长**是可以测的：

取三个同为 c=1、只有长度不同的点——

    A = B1n : ISL≈1043,  OSL=128
    B = B2  : ISL≈8211,  OSL=16
    C = B3  : ISL≈1043,  OSL=512

对每个帧解 3×3 线性方程组 `cost = const + a·ISL + b·OSL`（单位：ns/请求），
再按系数符号与量级判「ISL 驱动 / OSL 驱动 / 常数」。

⚠️ 口径：这是**模型分解**，不是直接测到的作用域归属。三点定一个平面，
**在拟合点上没有残差自由度（误差恒为 0）**——所以「拟合点误差」不能当检验。
唯一的检验是**留一点验证**：B1（ISL≈1221、OSL=128、c=1）不参与解方程，
用解出来的平面去预测它，与实测比（`docs/02` §8.1：误差 -2.6%）。
即便如此，本工具的输出只用来**排序和定性**（谁是 ISL 驱动、谁是 OSL 驱动），
不能当作「该帧精确耗时」。

用法见 `slope_model.py --help`。
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from collections import Counter


def read_folded(path: str) -> tuple[dict[str, int], int]:
    self_ns: Counter[str] = Counter()
    total = 0
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
            total += n
            self_ns[stack.split(";")[-1]] += n
    return self_ns, total


def solve3(m, y):
    """3×3 线性方程组（克拉默法则）；返回 None 表示奇异。"""
    def det(a):
        return (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    D = det(m)
    if abs(D) < 1e-9:
        return None
    out = []
    for col in range(3):
        mm = [row[:] for row in m]
        for r in range(3):
            mm[r][col] = y[r]
        out.append(det(mm) / D)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="按 ISL/OSL 三点线性分解每个帧的成本",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--profil-dir", default="data/profiles")
    ap.add_argument("--points", default="B1n:128,B2:16,B3:512",
                    help="tag:OSL,由三个点确定解（默认用三个 c=1 的点）")
    ap.add_argument("--extra-points", default="B1,B4",
                    help="额外打印这些点的每请求成本（不参与解方程）")
    ap.add_argument("--validate", default="B1",
                    help="用解出的平面预测这个**未参与拟合**的点，作为唯一有效的检验；留空则跳过")
    ap.add_argument("--min-pct", type=float, default=0.15,
                    help="任一工况里 self 占比 ≥ 该值的帧才输出")
    ap.add_argument("--out", default="data/profiles/slope-model.csv")
    ap.add_argument("--top", type=int, default=28)
    ap.add_argument("--segments-out", default="data/profiles/slope-segments.csv",
                    help="同时对 <tag>.segments.csv 做同一套三点分解（分段级趋势）")
    args = ap.parse_args(argv)

    base = args.profil_dir
    pts = []
    for p in args.points.split(","):
        tag, osl = p.split(":")
        load = json.load(open(f"{base}/{tag}.load.json"))
        pts.append({"tag": tag, "osl": int(osl),
                    "isl": load["prompt_tokens_mean"],
                    "req": load["requests_completed_in_window"]})
    extra = []
    for tag in args.extra_points.split(","):
        if not tag:
            continue
        load = json.load(open(f"{base}/{tag}.load.json"))
        extra.append({"tag": tag, "osl": load["output_len_target"],
                      "isl": load["prompt_tokens_mean"],
                      "req": load["requests_completed_in_window"]})

    frames: dict[str, dict[str, float]] = {}
    totals = {}
    totals_per_req: dict[str, float] = {}
    for p in pts + extra:
        self_ns, total = read_folded(f"{base}/{p['tag']}.folded")
        totals[p["tag"]] = total
        totals_per_req[p["tag"]] = total / p["req"]
        for fr, n in self_ns.items():
            frames.setdefault(fr, {})[p["tag"]] = n / p["req"]   # ns/请求

    M = [[1.0, p["isl"], p["osl"]] for p in pts]
    rows = []
    for fr, per in frames.items():
        pcts = [per.get(p["tag"], 0) / totals_per_req[p["tag"]] * 100 for p in pts + extra]
        if max(pcts) < args.min_pct:
            continue
        y = [per.get(p["tag"], 0.0) for p in pts]
        sol = solve3(M, y)
        const, a_isl, a_osl = sol if sol else (float("nan"),) * 3
        if sol:
            if a_isl > 0.05 and a_osl <= 0.05:
                kind = "ISL 驱动"
            elif a_osl > 0.05 and a_isl <= 0.05:
                kind = "OSL 驱动"
            elif a_isl > 0.05 and a_osl > 0.05:
                kind = "ISL+OSL"
            else:
                kind = "常数级"
        else:
            kind = "不可解"
        rows.append({
            "frame": fr, "kind": kind,
            "const_ns": round(const, 1),
            "per_isl_token_ns": round(a_isl, 3),
            "per_osl_token_ns": round(a_osl, 3),
            **{f"{p['tag']}_ns_per_req": round(per.get(p["tag"], 0), 1) for p in pts + extra},
            **{f"{p['tag']}_self_pct": round(x, 3) for p, x in zip(pts + extra, pcts)},
        })
    rows.sort(key=lambda r: -max(r[f"{p['tag']}_self_pct"] for p in pts + extra))

    # 总成本模型：拟合点误差恒为 0（3 点 3 参数，无残差自由度）⇒ 只有留一点验证才有意义
    ytot = [totals[p["tag"]] / p["req"] for p in pts]
    sol = solve3(M, ytot)
    print(f"[slope_model] 每请求总 CPU（on-CPU 时间/请求数）线性分解，拟合点 = "
          f"{'/'.join(p['tag'] for p in pts)}：")
    print(f"  每请求 ns ≈ {sol[0]:.0f} + {sol[1]:.4f}×ISL + {sol[2]:.4f}×OSL")
    for p, y in zip(pts, ytot):
        pred = sol[0] + sol[1] * p["isl"] + sol[2] * p["osl"]
        print(f"  [拟合点] {p['tag']}: 实测 {y / 1000:.1f} µs / 模型 {pred / 1000:.1f} µs"
              f"（误差 {(pred - y) / y * 100:+.1f}%，3 点 3 参数 ⇒ 恒为 0，不构成检验）")
    if args.validate:
        for e in extra:
            if e["tag"] != args.validate:
                continue
            y = totals_per_req[e["tag"]]
            pred = sol[0] + sol[1] * e["isl"] + sol[2] * e["osl"]
            print(f"  [留一点验证] {e['tag']}: 未参与拟合；实测 {y / 1000:.1f} µs / "
                  f"模型 {pred / 1000:.1f} µs ⇒ 误差 {(pred - y) / y * 100:+.1f}%")
    # 额外点（不参与拟合）也逐点打印，便于看并发效应
    for e in extra:
        if e["tag"] == args.validate:
            continue
        y = totals_per_req[e["tag"]]
        pred = sol[0] + sol[1] * e["isl"] + sol[2] * e["osl"]
        print(f"  [额外点] {e['tag']}（c≠1，模型不适用）: 实测 {y / 1000:.1f} µs / "
              f"模型外推 {pred / 1000:.1f} µs ⇒ 并发摊薄 {(pred - y) / pred * 100:+.1f}%")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"[slope_model] CSV -> {args.out}（{len(rows)} 帧）")

    print(f"\n{'帧':<62} {'类型':<9} {'ns/req':>8} {'ns/ISLtok':>10} {'ns/OSLtok':>10}")
    for r in rows[: args.top]:
        print(f"{r['frame'][:61]:<62} {r['kind']:<9} {r['B1n_ns_per_req']:8.0f} "
              f"{r['per_isl_token_ns']:10.4f} {r['per_osl_token_ns']:10.4f}")

    # ---- 分段级：同一套三点分解（回答"每段随 ISL/OSL 怎么变"）----
    seg_rows = []
    seg_total: dict[str, float] = {}
    seg_self: dict[str, dict[str, float]] = {}
    for p in pts + extra:
        with open(f"{base}/{p['tag']}.segments.csv") as f:
            f.readline()
            for r in csv.DictReader(f):
                if r["segment"].startswith("#"):
                    continue
                seg_self.setdefault(r["segment"], {})[p["tag"]] = int(r["self_ns"]) / p["req"]
                seg_total[p["tag"]] = seg_total.get(p["tag"], 0.0) + int(r["self_ns"]) / p["req"]
    for seg, per in seg_self.items():
        y = [per.get(p["tag"], 0.0) for p in pts]
        sol = solve3(M, y)
        if not sol:
            continue
        c, a_i, a_o = sol
        if a_i > 0.05 and a_o <= 0.05:
            kind = "ISL 驱动"
        elif a_o > 0.05 and a_i <= 0.05:
            kind = "OSL 驱动"
        elif a_i > 0.05 and a_o > 0.05:
            kind = "ISL+OSL"
        else:
            kind = "常数级"
        seg_rows.append({"segment": seg, "kind": kind, "const_ns": round(c, 1),
                         "per_isl_token_ns": round(a_i, 4), "per_osl_token_ns": round(a_o, 4),
                         **{f"{p['tag']}_ns_per_req": round(per.get(p["tag"], 0), 1) for p in pts + extra}})
    seg_rows.sort(key=lambda r: -r["B1_ns_per_req"])
    if args.segments_out:
        with open(args.segments_out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(seg_rows[0].keys()))
            w.writeheader()
            w.writerows(seg_rows)
        print(f"[slope_model] 分段级 CSV -> {args.segments_out}")
    print(f"\n{'分段':<14} {'类型':<9} {'B1 µs/req':>10} {'B1n µs/req':>11} {'ns/ISLtok':>10} "
          f"{'ns/OSLtok':>10}")
    for r in seg_rows:
        print(f"{r['segment']:<14} {r['kind']:<9} {r['B1_ns_per_req']/1000:10.1f} "
              f"{r['B1n_ns_per_req']/1000:11.1f} {r['per_isl_token_ns']:10.3f} "
              f"{r['per_osl_token_ns']:10.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
