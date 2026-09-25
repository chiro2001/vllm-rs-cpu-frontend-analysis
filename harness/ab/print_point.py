#!/usr/bin/env python3
"""把一个 A/B 点的 summary.json 打印成人类可读的一页（run_point.sh 收尾用）。

用法：
  print_point.py <summary.json>
  print_point.py --help
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


def fmt(v, spec="{:.3f}", dash="—"):
    return dash if v is None else spec.format(v)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("summary")
    args = p.parse_args(argv)
    d = json.loads(pathlib.Path(args.summary).read_text())
    e = d.get("end_to_end", {})
    w = d.get("windows", {})
    print(f"[ab][point] {d['point']}/{d['side']}: completed={e.get('completed')} "
          f"failed={e.get('failed')} duration={fmt(e.get('duration'), '{:.1f}')}s "
          f"req/s={fmt(e.get('request_throughput'))} out_tok/s={fmt(e.get('output_throughput'), '{:.1f}')} "
          f"ttft_mean={fmt(e.get('mean_ttft_ms'), '{:.1f}')}ms e2el_p99={fmt(e.get('p99_e2el_ms'), '{:.1f}')}ms")
    for role in ("frontend", "engine", "worker", "supervisor", "client"):
        g = w.get(role)
        if not g:
            continue
        print(f"    {role:11s} cpu={g.get('cpu_seconds')}s "
              f"s/req={g.get('cpu_s_per_request')} s/1k_in={g.get('cpu_s_per_1k_input_tokens')} "
              f"s/1k_out={g.get('cpu_s_per_1k_output_tokens')} "
              f"(u={g.get('utime_seconds')} sys={g.get('stime_seconds')})")
    for label, r in (d.get("perf_stat") or {}).items():
        c = r.get("counters") or {}
        instr = c.get("instructions")
        cycles = c.get("cycles")
        if instr and cycles:
            print(f"    perf[{label}] ipc={r.get('ipc')} instr={instr / 1e9:.3f}G "
                  f"cycles={cycles / 1e9:.3f}G "
                  f"instr/req={r.get('instructions_per_request')} "
                  f"instr/1k_out_tok={r.get('instructions_per_1k_output_tokens')}")
        else:
            print(f"    perf[{label}] counters 缺失：{(r.get('note') or r.get('error') or 'unknown')[:100]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
