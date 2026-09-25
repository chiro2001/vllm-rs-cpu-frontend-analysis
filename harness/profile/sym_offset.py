#!/usr/bin/env python3
"""把 perf 采样按「(dso, 文件内偏移)」聚合，并把偏移解回符号。

为什么需要它（口径说明）：

`perf record --call-graph fp` 在这份二进制上只能展开 1–2 帧（见 `docs/02-cpu-profile.md`
§2 的栈深直方图），而且有两类帧**符号名不唯一**：

  * glibc 的向量化 `memcpy/memmove` 等实现是**局部符号**，`.symtab` 已剥离
    ⇒ perf 只报 `[libc.so.6]`（本脚本用动态符号表 + 反汇编定位）；
  * Rust 泛型的 `std::thread::local::LocalKey<T>::with` 在二进制里有 **58 个**同名实例
    ⇒ 只看符号名无法区分是哪一个 TLS 访问点（本脚本给出热点实例的文件内偏移）。

实现：用 `perf script --show-mmap-events` 拿到每个进程里每个 dso 的加载基址
（`PERF_RECORD_MMAP ... [0xBASE(0xLEN) @ 0xFILEOFF]: DSO`），
把每条样本的**叶子帧**地址换算成 `offset = addr - BASE + FILEOFF`，
再用符号表（vllm-rs 用 `.symtab`，glibc 用 `.dynsym`）解析最近的前驱符号。

用法见 `sym_offset.py --help`。
"""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import os
import re
import subprocess
import sys
from collections import Counter

MMAP_RE = re.compile(
    r"PERF_RECORD_MMAP2?\s+\d+/\d+:\s+"
    r"\[(?P<base>0x[0-9a-f]+)\((?P<len>0x[0-9a-f]+)\) @ (?P<off>0x[0-9a-f]+)"
    r"(?: <[0-9a-f]+>)?\]:\s+(?P<perms>\S+)\s+(?P<dso>\S+)$"
)
FRAME_RE = re.compile(r"^\s+(?P<addr>[0-9a-f]+) (?P<sym>.*)$")
DSO_RE = re.compile(r"\((?P<dso>[^()]*)\)\s*$")


def load_symbols(path: str, table: str) -> tuple[list[int], list[tuple[str, int]]]:
    """返回 (排序后的地址列表, [(name, addr)])。table ∈ {symtab, dynsym}。"""
    args = ["readelf", "-sW"]
    if table == "dynsym":
        args.append("--dyn-syms")
    args.append(path)
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    syms: list[tuple[int, str]] = []
    for line in out.splitlines():
        p = line.split()
        if len(p) < 8 or p[3] not in ("FUNC", "IFUNC", "OBJECT"):
            continue
        try:
            addr = int(p[1], 16)
        except ValueError:
            continue
        if addr:
            syms.append((addr, p[7]))
    syms.sort()
    addrs = [a for a, _ in syms]
    return addrs, syms


def resolve(addrs: list[int], syms: list[tuple[int, str]], offset: int) -> tuple[str, int]:
    i = bisect.bisect_right(addrs, offset) - 1
    if i < 0:
        return ("<before-first>", offset)
    name, base = syms[i][1], syms[i][0]
    return (name, offset - base)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="按 (dso, 偏移) 聚合 perf 叶子帧并解符号",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--perf-data", required=True, help="原始 perf.data（只读，不进 git）")
    ap.add_argument("--out", default=None, help="输出 CSV")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--dso-filter", default=None, help="只保留该 dso 的样本（子串匹配）")
    ap.add_argument("--symbol-filter", default=None, help="只保留叶子符号名匹配该正则的样本")
    ap.add_argument("--kind-only", default=None, choices=["unresolved"], help="只看 perf 未解析出符号名的帧")
    ap.add_argument("--script-cache", default=None, help="perf script --show-mmap-events 的输出缓存路径")
    ap.add_argument("--libc-symbols", default=os.path.join(os.path.dirname(__file__), "libc_symbols.json"),
                    help="未导出实现的偏移区间 → 函数名 映射（用于给 `[libc.so.6]` 这类叶子命名）")
    args = ap.parse_args(argv)

    # 人工登记表：只有 >= 0.5% 的叶子帧才需要它，但登记本身不依赖样本量。
    known: list[tuple[str, int, int, str]] = []
    if args.libc_symbols and os.path.exists(args.libc_symbols):
        doc = json.load(open(args.libc_symbols))
        for r in doc.get("ranges", []):
            known.append((r["file"], int(r["start"], 16), int(r["end"], 16), r["name"]))

    def identify(dso: str, off: int) -> str:
        base = os.path.basename(dso)
        for fname, lo, hi, name in known:
            if fname in base and lo <= off < hi:
                return name
        return ""

    cache = args.script_cache
    if not cache or not os.path.exists(cache):
        cmd = ["perf", "script", "-i", args.perf_data, "--show-mmap-events"]
        with open(cache, "w") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.DEVNULL, check=False)

    # mappings: dso -> [(start, end, fileoff)]（同一 dso 可能有多个段）
    mappings: dict[str, list[tuple[int, int, int]]] = {}
    leaf_counter: Counter[tuple[str, int, str]] = Counter()
    n_samples = 0
    seen_first_frame = False
    unresolved_no_map = 0

    sym_cache: dict[str, tuple[list[int], list[tuple[int, str]]]] = {}

    def syms_for(dso: str):
        if dso not in sym_cache:
            if not os.path.exists(dso):
                sym_cache[dso] = ([], [])
                return sym_cache[dso]
            for table in ("symtab", "dynsym"):
                try:
                    addrs, syms = load_symbols(dso, table)
                except (subprocess.CalledProcessError, OSError):
                    continue
                if addrs:
                    sym_cache[dso] = (addrs, syms)
                    break
            else:
                sym_cache[dso] = ([], [])
        return sym_cache[dso]

    def to_offset(dso: str, addr: int) -> int | None:
        for start, end, off in mappings.get(dso, []):
            if start <= addr < end:
                return addr - start + off
        return None

    with open(cache) as f:
        for line in f:
            m = MMAP_RE.search(line.rstrip("\n"))
            if m:
                d = m.groupdict()
                base, ln, off = int(d["base"], 16), int(d["len"], 16), int(d["off"], 16)
                mappings.setdefault(d["dso"], []).append((base, base + ln, off))
                continue
            if not line.startswith(("\t", " ")):
                # 样本头：`comm pid tid time: period event:
                p = line.split()
                if len(p) >= 4 and re.match(r"^\d+$", p[1]):
                    seen_first_frame = False
                    n_samples += 1
                continue
            if line.strip() == "":
                continue
            fr = FRAME_RE.match(line.rstrip("\n"))
            if not fr or seen_first_frame:
                continue
            seen_first_frame = True  # 只取叶子帧（每个样本的第一帧）
            addr = int(fr.group("addr"), 16)
            sym = fr.group("sym").strip()
            dso_m = DSO_RE.search(line.rstrip("\n"))
            dso = dso_m.group("dso") if dso_m else "?"
            # ⚠️ 必须相对 `sym` 截断，不能相对整行（dso_m.start() 是行内位置，
            #    而 sym 已经去掉了地址前缀——踩过一次，会把符号名截短 16 个字符）。
            idx = sym.rfind("(")
            if dso_m and idx >= 0:
                sym = sym[:idx].strip()
            off = to_offset(dso, addr)
            if off is None:
                unresolved_no_map += 1
                continue
            leaf_counter[(dso, off, sym)] += 1

    rows = []
    for (dso, off, sym), n in leaf_counter.most_common():
        if args.dso_filter and args.dso_filter not in dso:
            continue
        if args.symbol_filter and not re.search(args.symbol_filter, sym):
            continue
        if args.kind_only == "unresolved" and not (sym.startswith("[") or sym == "[unknown]"):
            continue
        identified = identify(dso, off)
        if not os.path.exists(dso):
            rows.append({"dso": dso, "offset": hex(off), "symbol_from_perf": sym, "nearest_symbol": "",
                         "delta": "", "identified_function": identified, "samples": n})
            continue
        addrs, syms = syms_for(dso)
        name, delta = resolve(addrs, syms, off)
        rows.append({"dso": dso, "offset": hex(off), "symbol_from_perf": sym,
                     "nearest_symbol": name, "delta": hex(delta),
                     "identified_function": identified, "samples": n})
        if len(rows) >= args.top * 40:
            break

    total_leaf = sum(leaf_counter.values())
    print(f"[sym_offset] 样本 {n_samples}，有映射的叶子帧 {total_leaf}"
          f"（无映射 {unresolved_no_map}）", file=sys.stderr)
    header = ["dso", "offset", "symbol_from_perf", "nearest_symbol", "delta",
              "identified_function", "samples"]
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=header)
            w.writeheader()
            for r in rows[: args.top * 20]:
                w.writerow(r)
        print(f"[sym_offset] CSV -> {args.out}", file=sys.stderr)
    for r in rows[: args.top]:
        print(f"{r['samples']:6d}  {r['dso'].split('/')[-1]:<16} {r['offset']:<10} "
              f"perf='{r['symbol_from_perf'][:28]}' nearest={r['nearest_symbol'][:44]}+{r['delta']} "
              f"-> {r['identified_function']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
