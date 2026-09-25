#!/usr/bin/env python3
"""把 REMOTE_HOST 的 A/B 点结果汇总成一张表（`docs/04` 的表格由它生成）。

输入：本地 `runs/ab-<config>[r<rep>]-<side>/<tag>-<side>/point.json`
      （用 `harness/a3/push_private.sh --pull <run>` 从 REMOTE_HOST 取回）
输出：
  * stdout：Markdown 表格（直接贴进文档）
  * `--out <json>`：结构化汇总（中位数、极差、比值）

用法：
  harness/a3/collect.py --runs-root runs [--configs C1,C2,C3,C4,C5w,C5n] [--out data/ab/a3/summary.json]
  harness/a3/collect.py --help
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import statistics
import sys

CFG_RE = re.compile(r"^ab-(?P<cfg>[A-Za-z0-9]+?)(?:r(?P<rep>\d+))?-(?P<side>rust|python)$")


def load_points(runs_root: pathlib.Path, configs: set[str] | None):
    """收集所有 ab-<cfg>[r<rep>]-<side>/<tag>-<side>/point.json。"""
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
                doc = json.loads(pj.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            rows.append({
                "config": cfg, "side": side, "rep": int(m.group("rep") or 0),
                "run": run.name, "point_json": str(pj), "doc": doc,
            })
    return rows


def pick(doc, *path, default=None):
    cur = doc
    for k in path:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k)
    return default if cur is None else cur


def summarize(rows):
    """按 (config, side) 聚合：中位数 + 极差；再给 Rust/Python 比值。"""
    by = {}
    for r in rows:
        d = r["doc"]
        n = d.get("normalized") or {}
        e2e = d.get("e2e") or {}
        buckets = d.get("container_cpu_buckets") or {}
        fe = (d.get("frontend_cpu") or {}).get("cpu_seconds")
        eng = (d.get("engine_cpu") or {}).get("cpu_seconds")
        server = sum(buckets.get(k) or 0 for k in ("frontend", "engine", "other"))
        by.setdefault((r["config"], r["side"]), []).append({
            "run": r["run"], "rep": r["rep"],
            "completed": e2e.get("completed"), "failed": e2e.get("failed"),
            "frontend_cpu_s": fe, "engine_cpu_s": eng,
            "server_cpu_s": round(server, 4) if server else None,
            "frontend_share_pct": round((fe or 0) / server * 100, 3) if server else None,
            "fe_s_per_req": n.get("frontend_cpu_s_per_request"),
            "fe_s_per_1k_in": n.get("frontend_cpu_s_per_1k_input_tokens"),
            "fe_s_per_1k_out": n.get("frontend_cpu_s_per_1k_output_tokens"),
            "eng_s_per_req": n.get("engine_cpu_s_per_request"),
            "req_s": e2e.get("request_throughput"), "out_tok_s": e2e.get("output_throughput"),
            "mean_ttft_ms": e2e.get("mean_ttft_ms"), "p99_ttft_ms": e2e.get("p99_ttft_ms"),
            "mean_tpot_ms": e2e.get("mean_tpot_ms"), "p99_tpot_ms": e2e.get("p99_tpot_ms"),
            "mean_e2el_ms": e2e.get("mean_e2el_ms"),
            "window_s": pick(d, "window", "seconds"),
            "loadavg": d.get("loadavg"), "cores": d.get("cores"), "load": d.get("load"),
            "perf_file": d.get("perf_file"),
        })

    out = {}
    for (cfg, side), items in sorted(by.items()):
        agg = {"n_reps": len(items), "reps": items}
        for key in ("frontend_cpu_s", "fe_s_per_req", "fe_s_per_1k_in", "fe_s_per_1k_out",
                    "engine_cpu_s", "eng_s_per_req", "frontend_share_pct",
                    "req_s", "out_tok_s", "mean_ttft_ms", "p99_ttft_ms",
                    "mean_tpot_ms", "p99_tpot_ms", "mean_e2el_ms", "window_s"):
            vals = [i[key] for i in items if i.get(key) is not None]
            if not vals:
                continue
            agg[key] = {
                "median": round(statistics.median(vals), 6),
                "min": round(min(vals), 6), "max": round(max(vals), 6),
                "values": [round(v, 6) for v in vals],
            }
        out.setdefault(cfg, {})[side] = agg

    for cfg, sides in out.items():
        if "rust" not in sides or "python" not in sides:
            continue
        r, p = sides["rust"], sides["python"]
        ratio = {}
        for key in ("frontend_cpu_s", "fe_s_per_req", "fe_s_per_1k_in", "fe_s_per_1k_out",
                    "engine_cpu_s", "eng_s_per_req", "req_s", "out_tok_s",
                    "mean_ttft_ms", "mean_tpot_ms", "mean_e2el_ms"):
            if key in r and key in p and p[key]["median"]:
                ratio[key] = round(r[key]["median"] / p[key]["median"], 4)
        if "mean_ttft_ms" in r and "mean_ttft_ms" in p:
            ratio["ttft_delta_ms"] = round(r["mean_ttft_ms"]["median"] - p["mean_ttft_ms"]["median"], 3)
        if ratio.get("fe_s_per_req"):
            ratio["frontend_cpu_saved_x"] = round(1 / ratio["fe_s_per_req"], 2)
        out[cfg]["ratio_rust_over_python"] = ratio
    return out


def md_table(summary) -> str:
    lines = [
        "| 点 | 侧 | 重复 | 前端 CPU s(中位) | ms/请求 | s/千输入tok | s/千输出tok | 引擎 CPU s | 前端占服务端 | req/s | TTFT ms | TPOT ms |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for cfg in sorted(summary):
        sides = summary[cfg]
        for side in ("rust", "python"):
            a = sides.get(side)
            if not a:
                continue

            def m(k, scale=1.0, fmt="{:.3f}"):
                v = (a.get(k) or {}).get("median")
                return "—" if v is None else fmt.format(v * scale)

            lines.append(
                f"| {cfg} | {side} | {a['n_reps']} | {m('frontend_cpu_s')} | "
                f"{m('fe_s_per_req', 1000)} | {m('fe_s_per_1k_in', 1, '{:.5f}')} | "
                f"{m('fe_s_per_1k_out', 1, '{:.5f}')} | {m('engine_cpu_s')} | "
                f"{m('frontend_share_pct', 1, '{:.2f}%')} | {m('req_s')} | "
                f"{m('mean_ttft_ms', 1, '{:.1f}')} | {m('mean_tpot_ms', 1, '{:.3f}')} |")
        rr = sides.get("ratio_rust_over_python")
        if rr:
            lines.append(
                f"| **{cfg}** | **比值 R/P** | | **{rr.get('frontend_cpu_s')}** | "
                f"**{rr.get('fe_s_per_req')}** | **{rr.get('fe_s_per_1k_in')}** | "
                f"**{rr.get('fe_s_per_1k_out')}** | {rr.get('engine_cpu_s')} | | "
                f"{rr.get('req_s')} | Δ{rr.get('ttft_delta_ms')}ms | {rr.get('mean_tpot_ms')} |")
    return "\n".join(lines)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--runs-root", default="runs")
    p.add_argument("--configs", help="逗号分隔；默认全部")
    p.add_argument("--out", help="结构化汇总 JSON")
    p.add_argument("--json-only", action="store_true")
    args = p.parse_args(argv)

    configs = set(args.configs.split(",")) if args.configs else None
    rows = load_points(pathlib.Path(args.runs_root), configs)
    if not rows:
        print(f"[collect] 在 {args.runs_root} 下没找到 ab-*-{{rust,python}} 的点结果", file=sys.stderr)
        return 2
    summary = summarize(rows)
    if args.out:
        doc = {"runs_root": args.runs_root, "n_points": len(rows),
               "configs": sorted(summary), "summary": summary}
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
        print(f"[collect] {args.out}（{len(rows)} 个点）", file=sys.stderr)
    if not args.json_only:
        print(md_table(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
