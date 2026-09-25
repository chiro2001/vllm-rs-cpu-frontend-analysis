#!/usr/bin/env python3
"""用 procstat（utime+stime）口径解「每请求总 CPU = C + a×ISL + b×OSL」，
并把**用户态（utime）与内核态（stime）分开解**。

为什么必须分开：[`docs/02` §13.4] 两条斜率的物理来源不同——
  * `utime` 随 **token / 字节**走（分词、JSON、msgpack、SSE 编码）；
  * `stime` 随 **tick 数**走（每 tick 一次 ZMQ 收包 → recvmsg / epoll / futex），
    在 mock engine `chunk=1` 下 tick 数 ≈ 输出 token 数。
合成一个数会掩盖这件事，所以本脚本对 tot / utime / stime 各解一次。

默认拟合点 = **B1n / B2 / B3**（三个 c=1、只有长度不同的点），
留一点验证 = **B1**（不参与拟合）。B4 是 c=64，模型外推只用于看"并发摊薄"。

用法见 `procstat_model.py --help`。
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys


def solve3(m, y):
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


def ols3(rows, y):
    """普通最小二乘解 y ≈ C + a·ISL + b·OSL（3 参数，n≥4 时才有意义）。

    返回 (coefs, residuals, r2)。3 点拟合没有残差自由度，所以三点模型**只能**靠留一点验证；
    一旦把 5 个 c=1 点都放进来，OLS 才第一次给出"模型误差"这个量。
    """
    n = len(rows)
    if n < 4:
        return None
    # 构造 (XᵀX)Xᵀy，用高斯消元解 3×3 法方程
    A = [[0.0] * 3 for _ in range(3)]
    b = [0.0] * 3
    for r, yi in zip(rows, y):
        x = [1.0, r["isl"], r["osl"]]
        for i in range(3):
            b[i] += x[i] * yi
            for j in range(3):
                A[i][j] += x[i] * x[j]
    # 消元
    M = [A[i][:] + [b[i]] for i in range(3)]
    for c in range(3):
        p = max(range(c, 3), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-9:
            return None
        M[c], M[p] = M[p], M[c]
        for r in range(3):
            if r != c:
                f = M[r][c] / M[c][c]
                for k in range(c, 4):
                    M[r][k] -= f * M[c][k]
    coef = [M[i][3] / M[i][i] for i in range(3)]
    res, ss_res, ss_tot = [], 0.0, 0.0
    mean = sum(y) / n
    for r, yi in zip(rows, y):
        pred = coef[0] + coef[1] * r["isl"] + coef[2] * r["osl"]
        res.append({"tag": r["tag"], "observed_ns": round(yi, 1), "predicted_ns": round(pred, 1),
                    "error_pct": round((pred - yi) / yi * 100, 2)})
        ss_res += (yi - pred) ** 2
        ss_tot += (yi - mean) ** 2
    return coef, res, (1 - ss_res / ss_tot if ss_tot else None)


def point(path: str) -> dict:
    d = json.load(open(path))
    req = d["requests_completed_in_window"]
    return {
        "tag": os.path.basename(path).split(".")[0],
        "isl": d["prompt_tokens_mean"],
        "osl": d["output_len_target"],
        "c": d["concurrency"],
        "req": req,
        "wall": d["window"]["wall_seconds"],
        "tot_ns": d["frontend_cpu_seconds"] / req * 1e9,
        "ut_ns": d["frontend_utime_seconds"] / req * 1e9,
        "st_ns": d["frontend_stime_seconds"] / req * 1e9,
        "in_tok_total": d["prompt_tokens_total"],
        "out_tok_total": d["completion_tokens_total"],
        "note": d.get("note") or "",
    }


PRETTY = {"tot": "总 CPU（utime+stime）", "ut": "用户态 utime", "st": "内核态 stime"}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="procstat 口径的每请求线性模型（分别解总/用户态/内核态）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--dir", default="data/profiles")
    ap.add_argument("--points", default="B1n,B2,B3", help="三个拟合点（c=1，只有长度不同）")
    ap.add_argument("--validate", default="B1", help="留一点验证（不参与拟合）")
    ap.add_argument("--extra", default="B4", help="额外外推点（如 c=64）")
    ap.add_argument("--out", default="data/profiles/cpu-model.json")
    ap.add_argument("--ols-points", default="B1,B1n,B2,B3,B5",
                    help="最小二乘用的全部 c=1 点（3 点拟合无残差自由度，这里才有）")
    args = ap.parse_args(argv)

    def load(tag):
        for name in (f"{tag}.cpu-load.json", f"{tag}.load.json"):
            p = os.path.join(args.dir, name)
            if os.path.exists(p) and json.load(open(p)).get("frontend_cpu_seconds"):
                return point(p)
        raise SystemExit(f"找不到带 frontend_cpu_seconds 的点：{tag}")

    pts = [load(t.strip()) for t in args.points.split(",")]
    val = load(args.validate) if args.validate else None
    extra = [load(t.strip()) for t in args.extra.split(",") if t.strip()]

    M = [[1.0, p["isl"], p["osl"]] for p in pts]
    doc = {
        "basis": "前端 CPU = utime+stime（不含子进程），harness/common/procstat.sh；"
                 "before 取在预热后/窗口前、after 在窗口后",
        "unit": "ns / 请求",
        "fit_points": [{k: p[k] for k in ("tag", "isl", "osl", "c", "req", "tot_ns", "ut_ns", "st_ns")}
                       for p in pts],
        "measurements": {p["tag"]: {k: round(p[k], 1) for k in ("tot_ns", "ut_ns", "st_ns")}
                         for p in pts + ([val] if val else []) + extra},
        "models": {},
    }

    print("## 每请求 CPU 线性模型（procstat 口径，拟合点 "
          + "/".join(p["tag"] for p in pts) + "）\n")
    for key in ("tot", "ut", "st"):
        y = [p[f"{key}_ns"] for p in pts]
        c, a, b = solve3(M, y)
        entry = {"C_ns": round(c, 1), "per_isl_token_ns": round(a, 4), "per_osl_token_ns": round(b, 4)}
        # 留一点验证
        if val:
            pred = c + a * val["isl"] + b * val["osl"]
            obs = val[f"{key}_ns"]
            entry["validate"] = {"tag": val["tag"], "observed_ns": round(obs, 1),
                                 "predicted_ns": round(pred, 1),
                                 "error_pct": round((pred - obs) / obs * 100, 2)}
        for e in extra:
            pred = c + a * e["isl"] + b * e["osl"]
            obs = e[f"{key}_ns"]
            entry.setdefault("extra", {})[e["tag"]] = {
                "observed_ns": round(obs, 1), "predicted_ns": round(pred, 1),
                "shrink_pct": round((pred - obs) / pred * 100, 1),
                "note": e["note"]}
        doc["models"][key] = entry

        print(f"### {PRETTY[key]}")
        print(f"```\n{key}_ns_per_request ≈ {c:,.0f} + {a:.3f} × ISL + {b:,.1f} × OSL\n```")
        print(f"- 常数项 **{c / 1000:.1f} µs/请求**；"
              f"每输入 token **{a:.3f} ns**；每输出 token **{b / 1000:.3f} µs**")
        for p in pts:
            pred = c + a * p["isl"] + b * p["osl"]
            print(f"  - [拟合点] {p['tag']}: 实测 {p[f'{key}_ns'] / 1000:.1f} µs / 模型 "
                  f"{pred / 1000:.1f} µs（3 点 3 参数 ⇒ 误差恒 0，不构成检验）")
        if val:
            v = entry["validate"]
            print(f"  - **[留一点验证] {v['tag']}**: 未参与拟合；实测 {v['observed_ns'] / 1000:.1f} µs / "
                  f"模型 {v['predicted_ns'] / 1000:.1f} µs ⇒ **误差 {v['error_pct']:+.1f}%**")
        for e in extra:
            x = entry["extra"][e["tag"]]
            print(f"  - [额外点 c={e['c']}] {e['tag']}: 实测 {x['observed_ns'] / 1000:.1f} µs / "
                  f"模型外推 {x['predicted_ns'] / 1000:.1f} µs ⇒ **并发摊薄 {x['shrink_pct']:+.1f}%**")
        print()

    # 边际成本的构成（每条斜率里，用户态/内核态各占多少）
    t, u, s = (doc["models"][k] for k in ("tot", "ut", "st"))
    print("### 边际成本的构成\n")
    print("| 轴 | 总 | 用户态 utime | 内核态 stime | stime 占比 |")
    print("|---|---:|---:|---:|---:|")
    for label, key in (("每请求（常数项）", "C_ns"), ("每 ISL token", "per_isl_token_ns"),
                       ("每 OSL token", "per_osl_token_ns")):
        tv, uv, sv = t[key], u[key], s[key]
        unit = "µs" if key == "C_ns" else "ns"
        scale = 1000 if key == "C_ns" else 1
        print(f"| {label} | {tv / scale:,.2f} {unit} | {uv / scale:,.2f} {unit} | "
              f"{sv / scale:,.2f} {unit} | {sv / tv * 100:.1f}% |")
    print()

    # ---- 最小二乘：把全部 c=1 点一起拟合（第一次给出真实的模型误差/R²）----
    if args.ols_points:
        allpts = [load(t.strip()) for t in args.ols_points.split(",") if t.strip()]
        Mo = [[1.0, p["isl"], p["osl"]] for p in allpts]
        doc["ols"] = {"points": [p["tag"] for p in allpts], "n": len(allpts)}
        print(f"### 最小二乘（{len(allpts)} 个 c=1 点："
              f"{', '.join(p['tag'] for p in allpts)}）\n")
        for key in ("tot", "ut", "st"):
            y = [p[f"{key}_ns"] for p in allpts]
            r = ols3(allpts, y)
            if not r:
                continue
            (c, a, b), res, r2 = r
            doc["ols"][key] = {"C_ns": round(c, 1), "per_isl_token_ns": round(a, 4),
                               "per_osl_token_ns": round(b, 4), "r2": round(r2, 6) if r2 else None,
                               "residuals": res,
                               "max_abs_error_pct": max(abs(x["error_pct"]) for x in res)}
            print(f"- **{PRETTY[key]}**：`{key}_ns ≈ {c:,.0f} + {a:.3f}×ISL + {b:,.1f}×OSL` "
                  f"（R²={r2:.5f}，最大单点误差 {doc['ols'][key]['max_abs_error_pct']:.1f}%）")
            for x in res:
                print(f"    - {x['tag']}: 实测 {x['observed_ns'] / 1000:.1f} / "
                      f"模型 {x['predicted_ns'] / 1000:.1f} µs（{x['error_pct']:+.1f}%）")
        print()

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print(f"[procstat_model] JSON -> {args.out}")

    # 同时落一份 CSV，便于外部取数
    csv_path = os.path.splitext(args.out)[0] + ".csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["# 前端 CPU = utime+stime（procstat 口径，不含子进程）",
                    f"拟合点={'/'.join(p['tag'] for p in pts)}",
                    f"留一点验证={args.validate or '无'}"])
        w.writerow(["quantity", "C_ns", "per_isl_token_ns", "per_osl_token_ns",
                    "validate_tag", "validate_observed_ns", "validate_predicted_ns",
                    "validate_error_pct"])
        for key, name in (("tot", "total"), ("ut", "utime"), ("st", "stime")):
            e = doc["models"][key]
            v = e.get("validate", {})
            w.writerow([name, e["C_ns"], e["per_isl_token_ns"], e["per_osl_token_ns"],
                        v.get("tag", ""), v.get("observed_ns", ""),
                        v.get("predicted_ns", ""), v.get("error_pct", "")])
    print(f"[procstat_model] CSV -> {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
