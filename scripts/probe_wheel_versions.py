#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""跨 vLLM 版本探测：官方 wheel 里有没有 `vllm/vllm-rs`（Rust 前端二进制）。

做法：**不下载整个 wheel**。zip 的「中央目录」在文件末尾，用 HTTP Range 只取尾部
若干字节，就能列出成员名；命中 `vllm/vllm-rs` 即说明该版本的 wheel 自带 Rust 前端。

用法:
  probe_wheel_versions.py --arch x86_64 0.24.0 0.25.0 0.26.0
  probe_wheel_versions.py --arch aarch64 --json out.json 0.26.0 0.30.0
  probe_wheel_versions.py --help

退出码：0 全部探测成功；1 有版本无法判定（网络/无 wheel）。
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
import urllib.error
import urllib.request

PYPI_JSON = "https://pypi.org/pypi/vllm/{version}/json"
TARGET_MEMBERS = ("vllm/vllm-rs", "vllm/_rust_tool_parser.abi3.so")


def http_get(url: str, headers: dict[str, str] | None = None, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def pick_wheel(version: str, arch: str) -> tuple[str, int] | None:
    data = json.loads(http_get(PYPI_JSON.format(version=version)))
    files = data.get("urls", [])
    if not files:
        return None
    cands = [
        f for f in files
        if f["filename"].endswith(".whl")
        and arch in f["filename"]
        and "manylinux" in f["filename"]
        and "cp38-abi3" in f["filename"]
    ]
    if not cands:
        # 老版本可能不是 abi3 命名；退化为任意 manylinux wheel
        cands = [f for f in files if f["filename"].endswith(".whl") and arch in f["filename"]]
    if not cands:
        return None
    f = cands[0]
    return f["url"], f["size"]


def tail_bytes(url: str, n: int, size: int) -> bytes:
    start = max(0, size - n)
    return http_get(url, {"Range": f"bytes={start}-{size - 1}"})


def list_zip_members(tail: bytes) -> list[str]:
    """从尾部数据里扫 End of Central Directory 与中央目录，列出成员名。"""
    # EOCD 签名 PK\x05\x06，注释最长 65535，故在尾部 64 KiB 内找
    idx = tail.rfind(b"PK\x05\x06")
    if idx < 0:
        # zip64：先扫 zip64 EOCD locator 之前的常规 EOCD
        raise ValueError("未找到 EOCD（可能尾部字节不够）")
    cd_size, cd_offset = struct.unpack("<II", tail[idx + 12: idx + 20])
    # 中央目录可能不在 tail 里：用总长与偏移判断
    return cd_size, cd_offset


def members_via_full_cd(url: str, size: int, cd_size: int, cd_offset: int) -> list[str]:
    raw = http_get(url, {"Range": f"bytes={cd_offset}-{cd_offset + cd_size - 1}"})
    names: list[str] = []
    p = 0
    while p + 46 <= len(raw) and raw[p:p + 4] == b"PK\x01\x02":
        name_len, extra_len, comment_len = struct.unpack("<HHH", raw[p + 28: p + 34])
        name = raw[p + 46: p + 46 + name_len].decode("utf-8", "replace")
        names.append(name)
        p += 46 + name_len + extra_len + comment_len
    return names


def probe(version: str, arch: str) -> dict:
    out = {"version": version, "arch": arch}
    picked = pick_wheel(version, arch)
    if not picked:
        out["status"] = "no-wheel"
        return out
    url, size = picked
    out["wheel"] = url.rsplit("/", 1)[-1]
    out["wheel_bytes"] = size
    try:
        tail = tail_bytes(url, 65536, size)
        cd_size, cd_offset = list_zip_members(tail)
        names = members_via_full_cd(url, size, cd_size, cd_offset)
    except Exception as e:  # noqa: BLE001
        out["status"] = f"error: {type(e).__name__}: {e}"
        return out
    out["members_total"] = len(names)
    for m in TARGET_MEMBERS:
        out[m] = m in names
    out["status"] = "ok"
    return out


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("versions", nargs="+", help="要探测的 vLLM 版本号（如 0.25.0 0.26.0）")
    p.add_argument("--arch", default="x86_64", choices=["x86_64", "aarch64"])
    p.add_argument("--json", dest="json_out", default=None, help="把结果写 JSON")
    args = p.parse_args()

    results, bad = [], False
    print(f"{'版本':<10} {'wheel':<12} {'vllm/vllm-rs':<14} {'_rust_tool_parser':<18} 备注")
    print("-" * 78)
    for v in args.versions:
        r = probe(v, args.arch)
        results.append(r)
        if r["status"] != "ok":
            bad = True
            print(f"{v:<10} {'-':<12} {'?':<14} {'?':<18} {r['status']}")
            continue
        print(f"{v:<10} {'有' if True else '':<12} "
              f"{'✅ 有' if r[TARGET_MEMBERS[0]] else '❌ 无':<12} "
              f"{'✅ 有' if r[TARGET_MEMBERS[1]] else '❌ 无':<16} "
              f"成员 {r['members_total']} 项, {r['wheel_bytes']/1e6:.0f} MB")

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(results, f, ensure_ascii=False, indent=1)
        print(f"\n结果已写入 {args.json_out}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
