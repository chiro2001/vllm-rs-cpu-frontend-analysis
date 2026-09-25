#!/usr/bin/env python3
"""列出某个 A/B 服务容器内**所有**进程的宿主 pid（与 point.sh 同口径）。

用法：
  container_pids.py --run ab-C1r1-rust [--container <name>]
  container_pids.py --help

输出：空格分隔的宿主 pid（供 `procstat.sh snapshot ... $PIDS` 用）。
容器名默认按本线命名规则 `vrs-ab-<AB_OWNER>-<run>` 拼（AB_OWNER 默认 c-ab）；
回落旧命名 `vrs-ab-<run>`。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys


def docker(*args: str) -> str:
    return subprocess.run(["sudo", "-n", "docker", *args],
                          capture_output=True, text=True).stdout


def first_existing(candidates: list[str]) -> str | None:
    for c in candidates:
        out = docker("ps", "-aq", "--filter", f"name=^{c}$")
        if out.strip():
            return c
    return None


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--run", required=True)
    p.add_argument("--owner", default=os.getenv("AB_OWNER", "c-ab"))
    p.add_argument("--container")
    args = p.parse_args(argv)

    name = args.container or first_existing(
        [f"vrs-ab-{args.owner}-{args.run}", f"vrs-ab-{args.run}"]
    )
    if not name:
        print(f"找不到容器（run={args.run}）", file=sys.stderr)
        return 1

    top = docker("top", name, "-eo", "pid,comm")
    pids = []
    for line in top.splitlines()[1:]:
        parts = line.split()
        if parts and parts[0].isdigit():
            pids.append(parts[0])
    if not pids:
        print(f"容器 {name} 内没有进程", file=sys.stderr)
        return 1
    print(" ".join(pids))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
