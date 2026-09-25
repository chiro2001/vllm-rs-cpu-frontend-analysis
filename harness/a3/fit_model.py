#!/usr/bin/env python3
"""把 A/B 各点的「窗口内进程 CPU」拟合成一个可解释的成本模型（`docs/04` 用）。

模型（对每个臂分别拟合）：

    CPU_total = r × W  +  a × N  +  b × T_in  +  c × T_out

其中
    W     窗口秒数（procstat 两个快照之间的墙上时间）
    N     完成的请求数
    T_in  输入 token 总数
    T_out 输出 token 总数
    r     空转速率（CPU 秒 / 墙上秒；与请求无关的那部分）
    a     每请求固定成本（秒）
    b     每输入 token 边际成本（秒）
    c     每输出 token 边际成本（秒）

为什么必须这么拆：在真引擎装置上单个请求要跑几十秒，窗口里**同时**存在
「前端一直在跑的空转」与「随请求线性增长的处理成本」。只报
`CPU_total / N` 会把空转按请求数摊进去，**在低请求率下把前端成本高估数倍**；
而 `docs/06` 的容量拐点必须用**边际成本**（a/b/c），不能用含空转的均值。

用法：
  harness/a3/fit_model.py --runs-root runs [--configs C1,C2,...] [--out data/ab/a3/fit.json]
  harness/a3/fit_model.py --help
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

CFG_RE = re.compile(r"^ab-(?P<cfg>[A-Za-z0-9]+?)(?:r(?P<rep>\d+))?-(?P<side>rust|python)$")


def solve(A, y):
    """最小二乘（正规方程 + 高斯消元），纯 Python，不依赖 numpy。"""
    n = len(A[0])
    ATA = [[sum(A[k][i] * A[k][j] for k in range(len(A))) for j in range(n)] for i in range(n)]
    ATy = [sum(A[k][i] * y[k] for k in range(len(A))) for i in range(n)]
    # 高斯消元（带部分主元）
    M = [row[:] + [ATy[i]] for i, row in enumerate(ATA)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(M[r][col]))
        if abs(M[piv][col]) < 1e-12:
            raise ValueError("矩阵奇异：样本不足以区分这些项")
        M[col], M[piv] = M[piv], M[col]
        for r in range(n):
            if r == col:
                continue
            f = M[r][col] / M[col][col]
            for c in range(col, n + 1):
                M[r][c] -= f * M[col][c]
    return [M[i][n] / M[i][i] for i in range(n)]


def collect(runs_root: pathlib.Path, configs: set[str] | None):
    rows = []
    for run in sorted(runs_root.glob("ab-*")):
        m = CFG_RE.match(run.name)
        if not m:
            continue
        cfg, side = m.group("cfg"), m.group("side")
        if configs and cfg not in configs:
            continue
        for pj in sorted(run.glob("*/point.json")):
            try:
                d = json.loads(pj.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            e2e = d.get("e2e") or {}
            n = e2e.get("completed") or 0
            tin = e2e.get("total_input_tokens") or 0
            tout = e2e.get("total_output_tokens") or 0
            w = (d.get("window") or {}).get("seconds") or 0
            fe = (d.get("frontend_cpu") or {}).get("cpu_seconds") or 0
            eng = (d.get("engine_cpu") or {}).get("cpu_seconds") or 0
            if not (n and tin and tout and w):
                continue
            rows.append({
                "config": cfg, "side": side, "rep": int(m.group("rep") or 0),
                "run": run.name, "W": w, "N": n, "Tin": tin, "Tout": tout,
                "frontend_cpu": fe, "engine_cpu": eng,
            })
    return rows


def fit_side(rows):
    """对单侧拟合。

    ⚠️ 直接四参数最小二乘在这里**不可靠**：`W`（窗口）与 `N`、`Tin`、`Tout`
    在各点之间高度共线（请求数多 → 窗口也长），Python 侧会解出非物理的负系数
    （实测 −147 ns/输入 token、−1.5 ms/请求）。所以主方法分两步：

      第 1 步：**两点法**（M32 与 M128，同负载形态只变请求数）精确解出 (r, m)
                —— 不需要估计空转，斜率本身就是「空转 + 每请求」的合计；
      第 2 步：把 r 固定成第 1 步的值，再用**受约束**最小二乘解 (a, b, c)
                （此时只剩 3 个参数，且 ISL/OSL 在各点间有真实变化）。
    """
    A = [[r["W"], r["N"], r["Tin"], r["Tout"]] for r in rows]
    out = {}
    for key in ("frontend_cpu", "engine_cpu"):
        y = [r[key] for r in rows]
        r_idle, a, b, c, method = None, None, None, None, None
        two_point_m = None

        # ---- 第 1 步：两点法（优先）----
        p1 = next((i for i, r in enumerate(rows) if r["config"] == "M32"), None)
        p2 = next((i for i, r in enumerate(rows) if r["config"] == "M128"), None)
        if p1 is not None and p2 is not None:
            dN = rows[p2]["N"] - rows[p1]["N"]
            dW = rows[p2]["W"] - rows[p1]["W"]
            if dN and dW:
                # 用两式精确解 (r, m)：y = r*W + m*N
                det = rows[p1]["W"] * rows[p2]["N"] - rows[p2]["W"] * rows[p1]["N"]
                if abs(det) > 1e-9:
                    r_idle = (y[p1] * rows[p2]["N"] - y[p2] * rows[p1]["N"]) / det
                    two_point_m = (rows[p1]["W"] * y[p2] - rows[p2]["W"] * y[p1]) / det
                    method = "two_point(M32,M128)"

        # ---- 第 2 步：固定 r 解 (a, b, c)。
        #      ⚠️ **只对前端做**：引擎的 CPU 几乎全是「随请求的算力」，
        #      用 (N, Tin, Tout) 三参数分解会与 N 共线（实测 R² 为负）。
        #      引擎只报两点法的边际值（≈840 ms/请求），不做 token 级拆分。
        if key == "frontend_cpu":
            if r_idle is not None and r_idle >= 0:
                A2 = [[r["N"], r["Tin"], r["Tout"]] for r in rows]
                y2 = [y[i] - r_idle * rows[i]["W"] for i in range(len(rows))]
                try:
                    a, b, c = solve(A2, y2)
                except ValueError:
                    a, b, c = two_point_m or 0.0, 0.0, 0.0
            else:
                r_idle = 0.0
                A2 = [[r["N"], r["Tin"], r["Tout"]] for r in rows]
                try:
                    a, b, c = solve(A2, y)
                    method = (method or "") + "；空转钳为0"
                except ValueError as e:
                    out[key] = {"error": str(e)}
                    continue
        else:
            # 引擎：只给两点法边际 + 空转（可能为负 ⇒ 物理上就是 0）
            r_idle = max(0.0, r_idle or 0.0)
            a, b, c = (two_point_m or 0.0), 0.0, 0.0
            method = (method or "") + "；引擎只报边际值（不做 token 拆分）"
        # 拟合出的边际量若为负（多参数分解欠定），钳到 0 并标注，避免报非物理数
        clamped = []
        for name, val in (("per_request", a), ("per_input_token", b), ("per_output_token", c)):
            if val < 0:
                clamped.append(name)
        if clamped:
            method = (method or "") + f"；负系数已钳为0: {','.join(clamped)}"
            if a < 0:
                a = 0.0
            if b < 0:
                b = 0.0
            if c < 0:
                c = 0.0
        pred = [A[i][0] * r_idle + A[i][1] * a + A[i][2] * b + A[i][3] * c for i in range(len(rows))]
        resid = [round(y[i] - pred[i], 4) for i in range(len(rows))]
        ss_res = sum((y[i] - pred[i]) ** 2 for i in range(len(rows)))
        mean_y = sum(y) / len(y)
        ss_tot = sum((v - mean_y) ** 2 for v in y) or 1e-12
        out[key] = {
            "idle_cpu_s_per_s": round(r_idle, 6),
            "idle_pct_of_one_core": round(r_idle * 100, 4),
            "per_request_s": round(a, 6),
            "per_1k_input_tokens_s": round(b * 1000, 6),
            "per_1k_output_tokens_s": round(c * 1000, 6),
            "per_input_token_ns": round(b * 1e9, 3),
            "per_output_token_us": round(c * 1e6, 3),
            "r2": round(1 - ss_res / ss_tot, 5),
            "residuals_s": resid,
            "n_points": len(rows),
            "method": method,
            "clamped_negative": clamped,
        }
    return out


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--runs-root", default="runs")
    p.add_argument("--configs")
    p.add_argument("--out")
    args = p.parse_args(argv)

    configs = set(args.configs.split(",")) if args.configs else None
    rows = collect(pathlib.Path(args.runs_root), configs)
    if not rows:
        print("[fit] 没有可用样本", file=sys.stderr)
        return 2

    doc = {"model": "CPU = r*W + a*N + b*Tin + c*Tout", "n_samples": len(rows)}
    for side in ("rust", "python"):
        sub = [r for r in rows if r["side"] == side]
        if len(sub) < 4:
            doc[side] = {"error": f"样本不足（{len(sub)} < 4）"}
            continue
        doc[side] = fit_side(sub)
        doc[side]["points"] = [r["run"] for r in sub]

    if args.out:
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
        print(f"[fit] {args.out}（{len(rows)} 个样本）", file=sys.stderr)

    for side in ("rust", "python"):
        d = doc.get(side) or {}
        fe = d.get("frontend_cpu") or {}
        if "error" in fe:
            print(f"{side}: {fe['error']}")
            continue
        print(f"\n=== {side} 前端（{fe['n_points']} 点，R²={fe['r2']}）===")
        print(f"  空转速率      {fe['idle_cpu_s_per_s']} CPU秒/秒（单核 {fe['idle_pct_of_one_core']}%）")
        print(f"  每请求固定    {fe['per_request_s']*1000:.3f} ms")
        print(f"  每千输入 tok  {fe['per_1k_input_tokens_s']*1000:.4f} ms（{fe['per_input_token_ns']} ns/token）")
        print(f"  每千输出 tok  {fe['per_1k_output_tokens_s']*1000:.4f} ms（{fe['per_output_token_us']} µs/token）")
        eng = d.get("engine_cpu") or {}
        if "error" not in eng:
            print(f"  [引擎] 空转 {eng['idle_pct_of_one_core']}% 每请求 {eng['per_request_s']*1000:.1f} ms "
                  f"（R²={eng['r2']}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
