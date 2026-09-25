#!/usr/bin/env python3
"""把空载窗口的 procstat 增量压成「空转速率」并落盘。

用法：
  idle_summary.py --cpu <idle_cpu.json> --side rust --out <idle_summary.json>
  idle_summary.py --help

输出字段：
  idle_cpu_seconds_per_second —— 空转速率（单位：CPU 秒 / 墙上秒；1.0 = 吃满一个核）
  idle_percent_of_one_core    —— 同上，换算成「单核百分比」
  processes                   —— 逐进程明细（便于看是哪个线程/进程在烧）
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--cpu", required=True, help="procstat diff 输出（idle_cpu.json）")
    p.add_argument("--side", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args(argv)

    d = json.loads(pathlib.Path(args.cpu).read_text())
    wall = d.get("wall_seconds") or 0
    rows = []
    for pid, v in (d.get("pids") or {}).items():
        if v.get("missing"):
            continue
        rows.append({"pid": int(pid), "comm": v.get("comm", "?"),
                     "cpu_seconds": v.get("cpu_seconds"),
                     "utime_seconds": v.get("utime_seconds"),
                     "stime_seconds": v.get("stime_seconds")})
    total = sum(r["cpu_seconds"] or 0 for r in rows)
    doc = {
        "side": args.side,
        "window_seconds": wall,
        "idle_cpu_seconds_total": round(total, 4),
        "idle_cpu_seconds_per_second": round(total / wall, 6) if wall else None,
        "idle_percent_of_one_core": round(total / wall * 100, 3) if wall else None,
        "processes": sorted(rows, key=lambda r: -(r["cpu_seconds"] or 0)),
    }
    pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    print(f"[idle] {args.side}: 空载 {doc['idle_cpu_seconds_total']}s / {wall:.1f}s "
          f"= {doc['idle_cpu_seconds_per_second']} CPU秒/秒（单核 {doc['idle_percent_of_one_core']}%）")
    for r in doc["processes"][:6]:
        print(f"    {r['pid']:>8} {r['comm']:<18} {r['cpu_seconds']}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
