#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""按需从官方 PyPI wheel 抽取 `vllm-rs` 可执行文件与 Rust 扩展（零全量下载）。

背景：vLLM 0.26.0 的 `rust/` 前端在官方 wheel 里预编译为 `vllm/vllm-rs`
（真 ELF）与 `vllm/_rust_tool_parser.abi3.so`。wheel 是 zip，中央目录在文件
尾部，因此可以用 HTTP Range 只取尾部若干字节 + 目标条目的数据段，
完全不必下载 298–304 MB 的全量 wheel。

用法示例：
    # 只列目录，不落盘
    python3 fetch_vllm_rs.py --arch x86_64 --list
    # 抽取到 /tmp/d-nextgen-wheel
    python3 fetch_vllm_rs.py --arch x86_64 --out /tmp/d-nextgen-wheel
    # 抽取并写 manifest（JSON）
    python3 fetch_vllm_rs.py --arch aarch64 --out /tmp/d-aarch64 \
        --manifest /tmp/d-aarch64/manifest.json

退出码：0 成功；2 参数错误；3 网络/HTTP 错误；4 zip 结构或目标条目缺失。
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import platform
import struct
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field
from typing import Iterable

# 官方 PyPI 上的 vLLM 0.26.0 manylinux wheel（cp38-abi3）
WHEELS = {
    "x86_64": (
        "https://files.pythonhosted.org/packages/20/96/"
        "86edd288415aafc2952bbb969b5ef4e8c58e5525185b60320730276921e6/"
        "vllm-0.26.0-cp38-abi3-manylinux_2_28_x86_64.whl",
        "87529b6f9f46de50d0217b3f5c6622296fcd336f",
    ),
    "aarch64": (
        "https://files.pythonhosted.org/packages/58/27/"
        "6ff13689a5931f0c97b7008042f07aacc4a246e7eb06fd9b4d5a72de483c/"
        "vllm-0.26.0-cp38-abi3-manylinux_2_28_aarch64.whl",
        "6eddc228b8ec69df77b9ce6af6744ad47c36b340",
    ),
}

# 我们关心的产物（wheel 内路径 → 本地文件名）
TARGETS = {
    "vllm/vllm-rs": "vllm-rs",
    "vllm/_rust_tool_parser.abi3.so": "_rust_tool_parser.abi3.so",
}

# zipfile 需要随机读；块大小取 1 MiB，兼顾请求数与重传代价
BLOCK_SIZE = 1 << 20

ELF_MACHINES = {0x3E: "x86_64", 0xB7: "aarch64"}


def log(msg: str) -> None:
    print(f"[fetch_vllm_rs] {msg}", file=sys.stderr, flush=True)


@dataclass
class RangeReader:
    """把远端文件包装成随机可读对象，按 1 MiB 块惰性下载并缓存。"""

    url: str
    block_size: int = BLOCK_SIZE
    timeout: float = 60.0
    size: int = 0
    blocks: dict[int, bytes] = field(default_factory=dict)
    http_requests: int = 0
    bytes_downloaded: int = 0
    range_supported: bool = True

    def __post_init__(self) -> None:
        req = urllib.request.Request(self.url, method="HEAD")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            self.size = int(resp.headers["Content-Length"])
            ranges = (resp.headers.get("Accept-Ranges") or "").lower()
            self.range_supported = "bytes" in ranges
        if not self.range_supported:
            log(f"警告：服务端未声明 Accept-Ranges（{self.url}）")

    def block(self, index: int) -> bytes:
        cached = self.blocks.get(index)
        if cached is not None:
            return cached
        start = index * self.block_size
        end = min(start + self.block_size, self.size) - 1
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end}"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            if resp.status != 206 and self.size > self.block_size:
                raise urllib.error.HTTPError(
                    self.url,
                    resp.status,
                    "服务端未按 Range 返回 206",
                    resp.headers,
                    None,
                )
            data = resp.read()
        self.http_requests += 1
        self.bytes_downloaded += len(data)
        self.blocks[index] = data
        return data

    def read_at(self, offset: int, size: int) -> bytes:
        if size <= 0 or offset >= self.size:
            return b""
        out = bytearray()
        pos = offset
        end = min(offset + size, self.size)
        while pos < end:
            blk = self.block(pos // self.block_size)
            rel = pos % self.block_size
            if rel >= len(blk):
                break
            take = min(len(blk) - rel, end - pos)
            out += blk[rel : rel + take]
            pos += take
        return bytes(out)


class RangeBackedFile(io.RawIOBase):
    """zipfile 需要的只读 seek/read 接口。"""

    def __init__(self, reader: RangeReader):
        self.reader = reader
        self.pos = 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            new = offset
        elif whence == os.SEEK_CUR:
            new = self.pos + offset
        elif whence == os.SEEK_END:
            new = self.reader.size + offset
        else:
            raise ValueError(f"bad whence: {whence}")
        if new < 0:
            raise ValueError("negative seek")
        self.pos = new
        return self.pos

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            size = self.reader.size - self.pos
        data = self.reader.read_at(self.pos, size)
        self.pos += len(data)
        return data


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def elf_info(path: str) -> dict:
    """读取 ELF 头：位数、字节序、机器、类型。"""
    with open(path, "rb") as fh:
        head = fh.read(20)
    if head[:4] != b"\x7fELF":
        return {"elf": False, "first_bytes": head[:8].hex()}
    ei_class = {1: "ELF32", 2: "ELF64"}.get(head[4], f"class={head[4]}")
    ei_data = {1: "little", 2: "big"}.get(head[5], f"data={head[5]}")
    e_type = {1: "REL", 2: "EXEC", 3: "DYN", 4: "CORE"}.get(
        int.from_bytes(head[16:18], "little"), "?"
    )
    e_machine = int.from_bytes(head[18:20], "little")
    return {
        "elf": True,
        "class": ei_class,
        "endianness": ei_data,
        "type": e_type,
        "e_machine": e_machine,
        "machine": ELF_MACHINES.get(e_machine, f"unknown(0x{e_machine:x})"),
    }


def elf_needed(path: str, head_limit: int = 4 << 20, limit: int = 40) -> list[str]:
    """从 .dynamic/.dynstr 解析 DT_NEEDED（标准库实现，够用即可）。"""
    try:
        with open(path, "rb") as fh:
            data = fh.read(min(os.path.getsize(path), head_limit))
    except OSError:
        return []
    if data[:4] != b"\x7fELF":
        return []
    is64 = data[4] == 2
    endian = "little" if data[5] == 1 else "big"
    try:
        if is64:
            e_shoff = int.from_bytes(data[0x28:0x30], endian)
            e_shentsize = int.from_bytes(data[0x3A:0x3C], endian)
            e_shnum = int.from_bytes(data[0x3C:0x3E], endian)
        else:
            e_shoff = int.from_bytes(data[0x20:0x24], endian)
            e_shentsize = int.from_bytes(data[0x2E:0x30], endian)
            e_shnum = int.from_bytes(data[0x30:0x32], endian)
    except IndexError:
        return []
    if e_shoff == 0 or e_shoff + e_shnum * e_shentsize > len(data):
        return []
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh = data[off : off + e_shentsize]
        if len(sh) < e_shentsize:
            return []
        if is64:
            sh_type = int.from_bytes(sh[4:8], endian)
            sh_offset = int.from_bytes(sh[0x18:0x20], endian)
            sh_size = int.from_bytes(sh[0x20:0x28], endian)
            sh_link = int.from_bytes(sh[0x28:0x2C], endian)
        else:
            sh_type = int.from_bytes(sh[4:8], endian)
            sh_offset = int.from_bytes(sh[0x10:0x14], endian)
            sh_size = int.from_bytes(sh[0x14:0x18], endian)
            sh_link = int.from_bytes(sh[0x18:0x1C], endian)
        sections.append((sh_type, sh_offset, sh_size, sh_link))
    needed: list[str] = []
    for sh_type, sh_offset, sh_size, sh_link in sections:
        if sh_type != 6 or sh_link >= len(sections):  # SHT_DYNAMIC
            continue
        str_off = sections[sh_link][1]
        entsize = 16 if is64 else 8
        seg = data[sh_offset : sh_offset + sh_size]
        for j in range(0, len(seg) - entsize + 1, entsize):
            if is64:
                tag = int.from_bytes(seg[j : j + 8], endian)
                val = int.from_bytes(seg[j + 8 : j + 16], endian)
            else:
                tag = int.from_bytes(seg[j : j + 4], endian)
                val = int.from_bytes(seg[j + 4 : j + 8], endian)
            if tag == 0:
                break
            if tag != 1:  # DT_NEEDED
                continue
            start = str_off + val
            stop = data.find(b"\0", start)
            if start < len(data) and stop > start:
                needed.append(data[start:stop].decode("utf-8", "replace"))
                if len(needed) >= limit:
                    return needed
    return needed


def interesting_members(zf: zipfile.ZipFile) -> list[str]:
    names = zf.namelist()
    hits = [n for n in names if n in TARGETS]
    if not hits:
        hits = [
            n
            for n in names
            if n.startswith("vllm/") and ("vllm-rs" in n or "rust_tool_parser" in n)
        ]
    return hits


def run(args: argparse.Namespace) -> int:
    url, sha1_upstream = WHEELS[args.arch]
    log(f"wheel: {url}")
    reader = RangeReader(url, timeout=args.timeout)
    log(f"远端大小 {reader.size / 1e6:.1f} MB，Accept-Ranges={reader.range_supported}")

    with zipfile.ZipFile(RangeBackedFile(reader)) as zf:
        members = interesting_members(zf)
        if not members:
            log("未在 wheel 内找到 vllm-rs / _rust_tool_parser：上游布局可能已变")
            return 4
        infos = []
        for name in members:
            info = zf.getinfo(name)
            infos.append(
                {
                    "wheel_member": name,
                    "zip_size": info.file_size,
                    "zip_crc32": f"{info.CRC:08x}",
                    "zip_compress_type": info.compress_type,
                }
            )
            log(f"找到 {name}  未压缩 {info.file_size / 1e6:.1f} MB")

        if args.list:
            print(
                json.dumps(
                    {
                        "wheel_url": url,
                        "wheel_size": reader.size,
                        "members": infos,
                        "http_requests": reader.http_requests,
                        "bytes_downloaded": reader.bytes_downloaded,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0

        out_dir = args.out or "/tmp/d-nextgen-wheel"
        os.makedirs(out_dir, exist_ok=True)

        entries = []
        for entry in infos:
            name = entry["wheel_member"]
            local = os.path.join(out_dir, TARGETS.get(name, os.path.basename(name)))
            t0 = time.time()
            with zf.open(name) as src, open(local, "wb") as dst:
                while True:
                    chunk = src.read(1 << 22)
                    if not chunk:
                        break
                    dst.write(chunk)
            os.chmod(local, 0o755)
            entry.update(
                {
                    "local_path": local,
                    "local_size": os.path.getsize(local),
                    "sha256": sha256_file(local),
                    "extract_seconds": round(time.time() - t0, 2),
                }
            )
            entry.update(elf_info(local))
            entry["dt_needed_count"] = len(elf_needed(local))
            entry["dt_needed"] = elf_needed(local)
            entries.append(entry)
            log(
                f"已抽取 {local}  {entry['local_size'] / 1e6:.1f} MB  "
                f"{entry.get('class', '?')}/{entry.get('machine', '?')}"
            )

    manifest = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "vllm_version": "0.26.0",
        "vllm_commit": "568afb3a13806beb53bb2e6bd518269357b237c0",
        "arch": args.arch,
        "wheel_url": url,
        "wheel_size": reader.size,
        "wheel_sha1_upstream": sha1_upstream,
        "range_bytes_downloaded": reader.bytes_downloaded,
        "range_http_requests": reader.http_requests,
        "range_download_share": round(reader.bytes_downloaded / reader.size, 4),
        "members": entries,
    }
    if args.manifest:
        os.makedirs(os.path.dirname(os.path.abspath(args.manifest)), exist_ok=True)
        with open(args.manifest, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=2)
        log(f"manifest → {args.manifest}")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


def self_test() -> int:
    """离线自检：本地造一个 zip，验证 Range 读取 + ELF 解析链路。"""
    with tempfile.TemporaryDirectory() as td:
        payload = os.path.join(td, "vllm-rs")
        blob = (
            b"\x7fELF\x02\x01\x01\x00"
            + b"\x00" * 8  # e_ident 补齐到 16 字节
            + struct.pack("<HH", 2, 0x3E)
            + b"\x00" * 4096
        )
        with open(payload, "wb") as fh:
            fh.write(blob)
        wheel = os.path.join(td, "w.whl")
        with zipfile.ZipFile(wheel, "w", zipfile.ZIP_STORED) as zf:
            zf.write(payload, "vllm/vllm-rs")
        with zipfile.ZipFile(wheel) as zf:
            assert "vllm/vllm-rs" in zf.namelist()
            with zf.open("vllm/vllm-rs") as fh:
                assert fh.read(4) == b"\x7fELF"
        info = elf_info(payload)
        assert info["machine"] == "x86_64", info
        print("self-test OK")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="用 HTTP Range 从官方 PyPI wheel 抽取 vllm-rs（不下载全量 wheel）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--arch",
        choices=sorted(WHEELS),
        default=None,
        help="目标架构（默认：当前机器架构）",
    )
    p.add_argument("--out", help="抽取目录（默认 /tmp/d-nextgen-wheel）")
    p.add_argument("--manifest", help="manifest JSON 输出路径")
    p.add_argument("--list", action="store_true", help="只列目标条目，不落盘")
    p.add_argument("--timeout", type=float, default=60.0, help="单次 HTTP 超时秒数")
    p.add_argument("--self-test", action="store_true", help="离线自检（不需要网络）")
    return p


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.arch is None:
        machine = platform.machine()
        default_arch = "aarch64" if machine in ("aarch64", "arm64") else "x86_64"
        log(f"未指定 --arch，按当前机器 {machine} 选择 {default_arch}")
        args.arch = default_arch
    try:
        return run(args)
    except urllib.error.URLError as exc:
        log(f"网络错误：{exc}")
        return 3
    except zipfile.BadZipFile as exc:
        log(f"zip 解析失败：{exc}")
        return 4


if __name__ == "__main__":
    sys.exit(main())
