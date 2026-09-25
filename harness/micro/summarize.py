#!/usr/bin/env python3
"""把 D 线微基准的原始 CSV 汇总成 results.csv / manifest.json / segments.json / checks.json。

三份产出的分工：

* `results.csv`：全部原始行（Rust + Python），列与两侧 harness 一致；
* `checks.json`：**同输入同尺寸的验收证据**——两侧渲染/序列化字节的 sha256 是否
  一致、解析结果是否一致、msgpack payload 各多少字节；
* `segments.json`：按 P2/P3/P6/P7/P10 组装的"每段 µs + 占比"，供 docs/05 与
  docs/06（规模拐点）引用；
* `manifest.json`：脚本 sha256 / 二进制 sha256 / 绑核 / loadavg / 工具版本 / 时间戳。

用法见 --help。
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# 每段选哪一对 op 做"同口径对照"。键是段名，值是 (rust_op, python_op, 说明)。
# 选不中的 op 仍然进 results.csv / segments.json 的 ops 明细，只是不进合计。
# 键是段名；第二/三个元素是 (rust_op, python_op)；第四个元素是"这一段落在哪个
# 负载点"——P10（响应侧）只有 osl128 一个点，其余段在 1k/8k 两个点上都有。
SEGMENT_PAIRS = {
    "p2_json": (
        "serde_json::Value",
        "json.loads",
        "都是「无类型解析」：serde_json::Value ↔ json.loads（主口径）",
        None,
    ),
    "p3_template": (
        "minijinja_render",
        "jinja2_render",
        "同一份模板 + 同一份 messages/tools；Rust 侧另有 context_build 一段（见明细）",
        None,
    ),
    "p6_msgpack": (
        "rmp_serde_encode",
        "msgspec_encode",
        "同字段取值的 EngineCoreRequest（数组式 20 元素）",
        None,
    ),
    "p7_msgpack": (
        "rmp_serde_decode_rust_payload",
        "msgspec_decode_rust_payload",
        "同一份输入字节：Rust rmp-serde 编出来的 payload",
        None,
    ),
    "p10_serialize": (
        "serde_json_response",
        "json.dumps_response",
        "同一份响应对象；两侧产出字节 sha256 必须一致（checks.json）",
        "osl128",
    ),
    "p10_sse_frame": (
        "serde_json_sse_frame",
        "json.dumps_sse_frame",
        "单帧序列化 + `data: ...\\n\\n` 组帧，不写 socket",
        "osl128",
    ),
    "p10_sse_write": (
        "write_frame_tcp",
        "asyncio_write_frame_tcp",
        "⚠️ 机制不同：Rust 是阻塞 write_all，Python 是 asyncio write+drain",
        "osl128",
    ),
    "p10_stream": (
        "stream_request_local",
        "stream_request_local",
        "129 帧序列化+组帧写内存缓冲（不含 socket 写）",
        "osl128",
    ),
}


def segment_point(segment: str, current: str | None) -> str | None:
    """段名 → 数据点：P10 一律取 osl128，其余取当前循环点。"""
    override = SEGMENT_PAIRS[segment][3]
    return override if override else current


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run_cmd(cmd: list[str]) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr) else "unknown"


def load_raw(raw_dir: Path) -> list[dict]:
    rows: list[dict] = []
    for path in sorted(raw_dir.glob("*.csv")):
        with path.open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                row["source_file"] = path.name
                rows.append(row)
    return rows


def to_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return float("nan")


def pick(rows: list[dict], lang: str, op: str, point: str | None = None) -> dict | None:
    for row in rows:
        if row["lang"] == lang and row["op"] == op and (point is None or row["point"] == point):
            return row
    return None


def p50(rows: list[dict], lang: str, ops: list[str], point: str) -> float | None:
    """把若干 op 的 p50 相加（用于 P3/P10 的多步分段）。缺一个就返回 None。"""
    total = 0.0
    for op in ops:
        row = pick(rows, lang, op, point)
        if row is None:
            return None
        total += to_float(row["p50_us"])
    return total


def build_segments(rows: list[dict], points: list[str]) -> dict:
    segments: dict = {
        "caveats": [
            "微基准加总口径：各段 p50 相加，不等于 vllm-rs 进程的总 CPU（无 HTTP/调度/系统调用上下文切换等）",
            "Rust 与 Python 的对照只在同一行 `op` 上成立：两侧跑同一份 fixture 字节、同样的预热/采样纪律",
            "P4/P8（分词与增量解码）不在本表：D5 引用 tokenizer 项目的既有结论，未重测",
        "p3_template 的 Rust 侧另有 context_build（serde 结构 → minijinja Value），Python 侧没有对应的独立段（dict 直接可用），因此对 P3 的公平口径是 `rust context_build+render` vs `python render`",
        "osl128 点的 p10_stream_request_us 是「整流序列化+组帧」与「n×单帧 socket 写」两段实测值相加 ⇒ 标推断；两侧的 socket 写机制不同（Rust 阻塞 write_all vs Python asyncio write+drain）",
        "D6（fastokens 预分词）是 D5 的补充、不是替代：tokenizer 项目测的是 BPE/编码路径，D6 单独量 PCRE2 JIT 正则那一段。**D6 是多线程口径**（fastokens 的 Split 在 ≥16 个 split 时走 rayon，线程数=绑定核数），不能与 D1–D4 的单线程数字直接相加",
    ],
    "points": {},
}
    for point in list(points) + ["osl128"]:
        per_point: dict = {"ops": {}, "segment_p50_us": {}}
        for segment, (rust_op, py_op, note, _override) in SEGMENT_PAIRS.items():
            data_point = segment_point(segment, point)
            rust_row = pick(rows, "rust", rust_op, data_point)
            py_row = pick(rows, "python", py_op, data_point)
            entry = {"note": note}
            if rust_row is not None:
                entry["rust"] = {
                    "op": rust_op,
                    "p50_us": to_float(rust_row["p50_us"]),
                    "mean_us": to_float(rust_row["mean_us"]),
                    "p99_us": to_float(rust_row["p99_us"]),
                    "input_bytes": int(to_float(rust_row["input_bytes"])),
                    "bytes_per_op": to_float(rust_row["bytes_per_op"]),
                }
            if py_row is not None:
                entry["python"] = {
                    "op": py_op,
                    "p50_us": to_float(py_row["p50_us"]),
                    "mean_us": to_float(py_row["mean_us"]),
                    "p99_us": to_float(py_row["p99_us"]),
                    "input_bytes": int(to_float(py_row["input_bytes"])),
                    "bytes_per_op": to_float(py_row["bytes_per_op"]),
                }
            if rust_row is not None and py_row is not None and to_float(py_row["p50_us"]) > 0:
                entry["rust_over_python"] = round(
                    to_float(rust_row["p50_us"]) / to_float(py_row["p50_us"]), 4
                )
            per_point["ops"][segment] = entry

        # 分段合计（只算有数的段）
        rust_parts = {
            "p2_json": ["serde_json::Value"],
            "p3_template": ["context_build", "minijinja_render"],
            "p6_msgpack": ["rmp_serde_encode"],
            "p7_msgpack": ["rmp_serde_decode_rust_payload"],
            "p10_serialize": ["serde_json_response"],
            "p10_sse_frame": ["serde_json_sse_frame"],
        }
        py_parts = {
            "p2_json": ["json.loads"],
            "p3_template": ["jinja2_render"],
            "p6_msgpack": ["msgspec_encode"],
            "p7_msgpack": ["msgspec_decode_rust_payload"],
        }
        if point != "osl128":
            # P10 与 ISL 无关（只跟 OSL/帧数有关），归属 osl128 点。
            # 若把它算进 1k/8k 的合计，"合计"就变成两个不同负载点的和 ⇒ 去掉。
            rust_parts.pop("p10_serialize", None)
            rust_parts.pop("p10_sse_frame", None)
        if point == "osl128":
            # 响应侧只有这一个点：单帧与整流都测了，但**不叠加**进合计，
            # 改成单独给一条「流式请求总成本 = 整流序列化+组帧 + n×单帧 socket 写」。
            derived = {}
            for lang, write_op in (
                ("rust", "write_frame_tcp"),
                ("python", "asyncio_write_frame_tcp"),
            ):
                stream_row = pick(rows, lang, "stream_request_local", point)
                frame_row = pick(rows, lang, write_op, point)
                if stream_row and frame_row:
                    frames = int(to_float(stream_row["tokens"])) or 0
                    write_us = to_float(frame_row["p50_us"])
                    derived[lang] = {
                        "stream_frames": frames,
                        "stream_serialize_frame_us": to_float(stream_row["p50_us"]),
                        "write_frame_us": write_us,
                        "write_total_us": round(write_us * frames, 3),
                        "p10_stream_request_us": round(
                            to_float(stream_row["p50_us"]) + write_us * frames, 3
                        ),
                        "note": "整流序列化+组帧 + n×单帧 socket 写；两段都是实测，相加是「推断」",
                    }
            if derived:
                per_point["derived"] = derived
        for lang, parts in (("rust", rust_parts), ("python", py_parts)):
            values = {}
            for segment, ops in parts.items():
                total = p50(rows, lang, ops, segment_point(segment, point))
                if total is not None:
                    values[segment] = total
            total_us = sum(values.values())
            per_point["segment_p50_us"][lang] = {
                "segments": {key: round(value, 3) for key, value in values.items()},
                "measured_total_us": round(total_us, 3),
                "scope": (
                    "P2+P3+P6+P7（与 ISL 相关的四段）"
                    if point != "osl128"
                    else "P2+P3+P6+P7+P10序列化+单帧组帧（响应侧）"
                ),
                "share_pct": {
                    key: round(value / total_us * 100.0, 2) for key, value in values.items()
                }
                if total_us > 0
                else {},
            }
        segments["points"][point] = per_point
    return segments


def build_d6(rows: list[dict], points: list[str]) -> dict:
    """D6：fastokens 预分词 vs 全量 encode 的拆分（Rust 侧，多线程口径）。"""
    out: dict = {
        "scope": "Rust 侧单臂（Python 侧无对照：tokenizer 项目已覆盖 Python 侧 tokenizer）",
        "caveat": "fastokens 预分词在 ≥16 个 split 时走 rayon（线程数 = 绑定核数 ≤8）⇒ 多线程口径",
        "points": {},
    }
    for point in points:
        label = f"render_{point}"
        pre = pick(rows, "rust", "fastokens_pretokenize", label)
        build = pick(rows, "rust", "fastokens_build_pre_tokenized", label)
        full = pick(rows, "rust", "fastokens_encode_full", label)
        if pre is None or full is None:
            continue
        pre_us = to_float(pre["p50_us"])
        full_us = to_float(full["p50_us"])
        entry = {
            "text_bytes": int(to_float(pre["input_bytes"])),
            "text_label": label,
            "splits": int(to_float(pre["tokens"])),
            "pretokenize_us": pre_us,
            "build_pre_tokenized_us": to_float(build["p50_us"]) if build else None,
            "encode_full_us": full_us,
            "pretokenize_share_pct": round(pre_us / full_us * 100.0, 2) if full_us > 0 else None,
            "bpe_only_us": round(full_us - pre_us, 3),
            "pretokenize_allocs_per_op": to_float(pre["allocs_per_op"]) if pre.get("allocs_per_op") else None,
            "encode_allocs_per_op": to_float(full["allocs_per_op"]) if full.get("allocs_per_op") else None,
            "note": "pretokenize 含 normalizer + added-token 切分 + PCRE2 JIT 正则；bpe_only 是差值（推断）",
        }
        out["points"][point] = entry
    return out


def build_checks(rows: list[dict], raw_dir: Path, fixtures_dir: Path, points: list[str]) -> dict:
    checks: dict = {"points": {}, "verdicts": []}

    def add(name: str, ok: bool, detail: str) -> None:
        checks["verdicts"].append({"check": name, "ok": bool(ok), "detail": detail})

    for point in points:
        entry: dict = {}
        # D1：解析结果摘要必须一致（除 Rust 侧的 value_bytes）
        rust_check = raw_dir / f"rust_d1_check_{point}.json"
        py_check = raw_dir / f"python_d1_check_{point}.json"
        if rust_check.exists() and py_check.exists():
            rust_json = json.loads(rust_check.read_text(encoding="utf-8"))
            py_json = json.loads(py_check.read_text(encoding="utf-8"))
            keys = sorted(set(rust_json) & set(py_json))
            same = all(rust_json[key] == py_json[key] for key in keys)
            entry["d1_parse_summary"] = {
                "rust": {key: rust_json[key] for key in keys},
                "python": {key: py_json[key] for key in keys},
                "identical": same,
            }
            add(f"d1 解析摘要一致 @{point}", same, f"比较字段: {keys}")

        # D2：渲染字节 sha256 必须一致
        rust_render = raw_dir / f"rust_render_{point}.txt"
        py_render = raw_dir / f"python_render_{point}.txt"
        if rust_render.exists() and py_render.exists():
            rust_hash = sha256_file(rust_render)
            py_hash = sha256_file(py_render)
            entry["d2_rendered_prompt"] = {
                "rust_sha256": rust_hash,
                "python_sha256": py_hash,
                "rust_bytes": rust_render.stat().st_size,
                "python_bytes": py_render.stat().st_size,
                "identical": rust_hash == py_hash,
            }
            add(
                f"d2 渲染结果字节一致 @{point}",
                rust_hash == py_hash,
                f"sha256={rust_hash} bytes={rust_render.stat().st_size}",
            )

        # D3：两份 payload 的字节数（两侧编码策略不同，不要求一致）
        rust_payload = raw_dir / f"payload_rust_{point}.msgpack"
        py_payload = raw_dir / f"payload_python_{point}.msgpack"
        if rust_payload.exists() and py_payload.exists():
            fixture_json = json.loads(
                (fixtures_dir / f"engine_core_request_{point}.json").read_text(encoding="utf-8")
            )
            entry["d3_payload"] = {
                "rust_bytes": rust_payload.stat().st_size,
                "python_bytes": py_payload.stat().st_size,
                "python_minus_rust_bytes": py_payload.stat().st_size - rust_payload.stat().st_size,
                "rust_sha256": sha256_file(rust_payload),
                "python_sha256": sha256_file(py_payload),
                "prompt_token_ids": len(fixture_json[1]),
            }
            add(
                f"d3 payload 尺寸可比 @{point}",
                abs(entry["d3_payload"]["python_minus_rust_bytes"])
                <= max(rust_payload.stat().st_size, py_payload.stat().st_size) * 0.1,
                f"rust={rust_payload.stat().st_size}B python={py_payload.stat().st_size}B",
            )

        # 两侧必须都能解对方/自己的 payload（能跑完就说明能解）
        for lang in ("rust", "python"):
            csv_path = raw_dir / f"{lang}_d3_{point}.csv"
            if csv_path.exists():
                text = csv_path.read_text(encoding="utf-8")
                names = [line.split(",")[3] for line in text.strip().splitlines()[1:]]
                entry[f"d3_{lang}_ops"] = names
                add(
                    f"d3 {lang} 解得出两侧 payload @{point}",
                    any("decode" in name for name in names),
                    f"ops={names}",
                )
        checks["points"][point] = entry

    # D4：响应体 / 帧字节一致
    rust_resp = raw_dir / "rust_response_osl128.json"
    py_resp = raw_dir / "python_response_osl128.json"
    if rust_resp.exists() and py_resp.exists():
        rust_hash = sha256_file(rust_resp)
        py_hash = sha256_file(py_resp)
        checks["points"].setdefault("osl128", {})["d4_response_bytes"] = {
            "rust_sha256": rust_hash,
            "python_sha256": py_hash,
            "rust_bytes": rust_resp.stat().st_size,
            "python_bytes": py_resp.stat().st_size,
            "identical": rust_hash == py_hash,
        }
        add(
            "d4 非流式响应体序列化字节一致",
            rust_hash == py_hash,
            f"sha256={rust_hash} bytes={rust_resp.stat().st_size}",
        )

    checks["all_ok"] = all(item["ok"] for item in checks["verdicts"])
    return checks


def build_manifest(
    raw_dir: Path, fixtures_dir: Path, out_dir: Path, rows: list[dict], warmup: float, sample: float, rust_bin: Path
) -> dict:
    def load_text(path: Path) -> str:
        return path.read_text(encoding="utf-8").strip() if path.exists() else "unknown"

    scripts = [
        "harness/micro/run_micro.sh",
        "harness/micro/gen_fixtures.py",
        "harness/micro/summarize.py",
        "harness/micro/setup_py_env.sh",
        "harness/micro/python/micro_py.py",
        "harness/micro/python/ecr_types.py",
        "harness/micro/rust/Cargo.toml",
        "harness/micro/rust/src/main.rs",
        "harness/micro/rust/src/bench.rs",
        "harness/micro/rust/src/hf.rs",
        "harness/micro/rust/src/types.rs",
        "scripts/limit.sh",
        "scripts/heavy_lock.sh",
    ]
    script_hashes = {}
    for script in scripts:
        path = ROOT / script
        script_hashes[script] = sha256_file(path) if path.exists() else "missing"

    cargo_lock = ROOT / "harness/micro/rust/Cargo.lock"
    crate_versions: dict[str, str] = {}
    if cargo_lock.exists():
        import re

        text = cargo_lock.read_text(encoding="utf-8")
        for name in (
            "serde_json",
            "minijinja",
            "minijinja-contrib",
            "rmp-serde",
            "rmpv",
            "serde-json-fmt",
            "indexmap",
            "serde",
        ):
            match = re.search(rf'name = "{re.escape(name)}"\nversion = "([^"]+)"', text)
            if match:
                crate_versions[name] = match.group(1)

    fixtures_manifest = json.loads((fixtures_dir / "fixtures_manifest.json").read_text(encoding="utf-8"))

    return {
        "line": "D-micro",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "generated_at_epoch": int(time.time()),
        "host": {
            "node": platform.node(),
            "uname": load_text(raw_dir / "uname.txt"),
            "nproc": os.cpu_count(),
            "cpu_model": load_text(raw_dir / "cpu_model.txt"),
            "mem_total_kib": load_text(raw_dir / "mem_total_kib.txt"),
        },
        "git": {
            "branch": run_cmd(["git", "-C", str(ROOT), "rev-parse", "--abbrev-ref", "HEAD"]),
            "commit": run_cmd(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
            "worktree_dirty": run_cmd(["git", "-C", str(ROOT), "status", "--porcelain"]) != "",
        },
        "bind": {
            "cores": os.environ.get("DMICRO_CORES", "4-7"),
            "threads_effective": 4,
            "note": "limit.sh 的 CORES 是「绑到哪些核」；4-7 = 4 个核（默认值）",
        },
        "limits": {"mem_gb": 8, "cargo_jobs": 4, "container": "未用容器（微基准直接跑在宿主机，已绑核）"},
        "run_config": {"warmup_s": warmup, "sample_s": sample, "max_samples": 400_000},
        "loadavg": {
            "before": load_text(raw_dir / "loadavg.before"),
            "after": load_text(raw_dir / "loadavg.after"),
        },
        "fixtures": fixtures_manifest,
        "scripts_sha256": script_hashes,
        "binary": {
            "path": str(rust_bin.relative_to(ROOT)) if str(rust_bin).startswith(str(ROOT)) else str(rust_bin),
            "sha256": sha256_file(rust_bin) if rust_bin.exists() else "missing",
            "bytes": rust_bin.stat().st_size if rust_bin.exists() else 0,
        },
        "cargo_lock_sha256": sha256_file(cargo_lock) if cargo_lock.exists() else "missing",
        "crate_versions": crate_versions,
        "tool_versions": {
            "rustc": run_cmd(["rustc", "--version"]),
            "cargo": run_cmd(["cargo", "--version"]),
            "python": run_cmd([str(ROOT / "harness/micro/.venv/bin/python"), "--version"])
            if (ROOT / "harness/micro/.venv/bin/python").exists()
            else run_cmd(["python3", "--version"]),
            "python_packages": run_cmd(
                [
                    str(ROOT / "harness/micro/.venv/bin/python"),
                    "-c",
                    "import jinja2,msgspec,msgpack,orjson,tokenizers;"
                    "print(f'jinja2={jinja2.__version__} msgspec={msgspec.__version__} "
                    "msgpack={msgpack.version} orjson={orjson.__version__} tokenizers={tokenizers.__version__}')",
                ]
            )
            if (ROOT / "harness/micro/.venv/bin/python").exists()
            else "unknown",
        },
        "rows": len(rows),
        "outputs": sorted(path.name for path in out_dir.glob("*") if path.is_file()),
    }


def main() -> int:
    ap = argparse.ArgumentParser(
        description="汇总 D 线微基准：results.csv / manifest.json / segments.json / checks.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--raw-dir", default="data/micro/raw", help="原始 CSV 目录")
    ap.add_argument("--fixtures", default="harness/micro/fixtures", help="fixture 目录")
    ap.add_argument("--out-dir", default="data/micro", help="产出目录")
    ap.add_argument("--points", default="1k,8k", help="参与汇总的负载点")
    ap.add_argument("--warmup", type=float, default=10.0)
    ap.add_argument("--sample", type=float, default=30.0)
    ap.add_argument("--rust-bin", default="harness/micro/rust/target/release/micro-bench")
    args = ap.parse_args()

    raw_dir = (ROOT / args.raw_dir) if not Path(args.raw_dir).is_absolute() else Path(args.raw_dir)
    fixtures_dir = (ROOT / args.fixtures) if not Path(args.fixtures).is_absolute() else Path(args.fixtures)
    out_dir = (ROOT / args.out_dir) if not Path(args.out_dir).is_absolute() else Path(args.out_dir)
    rust_bin = (ROOT / args.rust_bin) if not Path(args.rust_bin).is_absolute() else Path(args.rust_bin)
    points = [item.strip() for item in args.points.split(",") if item.strip()]

    rows = load_raw(raw_dir)
    if not rows:
        print(f"[summarize] {raw_dir} 下没有 CSV，先跑 run_micro.sh", file=sys.stderr)
        return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    results = out_dir / "results.csv"
    fieldnames = [
        "lang",
        "seg",
        "point",
        "op",
        "input_label",
        "input_bytes",
        "tokens",
        "iterations",
        "samples",
        "wall_s",
        "mean_us",
        "p50_us",
        "p90_us",
        "p99_us",
        "min_us",
        "max_us",
        "stdev_us",
        "ops_per_sec",
        "bytes_per_op",
        "allocs_per_op",
        "alloc_bytes_per_op",
        "notes",
        "source_file",
    ]
    with results.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in sorted(rows, key=lambda item: (item["point"], item["lang"], item["seg"], item["op"])):
            writer.writerow({key: row.get(key, "") for key in fieldnames})

    segments = build_segments(rows, points)
    (out_dir / "segments.json").write_text(
        json.dumps(segments, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    checks = build_checks(rows, raw_dir, fixtures_dir, points)
    (out_dir / "checks.json").write_text(
        json.dumps(checks, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    d6 = build_d6(rows, points)
    (out_dir / "d6_pretokenize.json").write_text(
        json.dumps(d6, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    manifest = build_manifest(raw_dir, fixtures_dir, out_dir, rows, args.warmup, args.sample, rust_bin)
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(
        f"[summarize] rows={len(rows)} points={points} checks_all_ok={checks['all_ok']} → {out_dir}",
        file=sys.stderr,
    )
    failed = [item for item in checks["verdicts"] if not item["ok"]]
    for item in failed:
        print(f"[summarize] ⚠️ 校验未过：{item['check']} — {item['detail']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
