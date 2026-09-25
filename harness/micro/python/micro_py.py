#!/usr/bin/env python3
"""D 线微基准（Python 侧）—— 与 Rust 侧同输入、同口径的对照臂。

口径与 `rust/src/bench.rs` 逐条对齐：

* 预热 ≥ `--warmup` 秒（默认 10，下限 10），采样 ≥ `--sample` 秒（默认 30，下限 30）；
* 每次**只夹一次操作**：`t0 = perf_counter_ns()` → op → `t1`；
* 采样按 stride 抽稀，样本上限 `--max-samples`（默认 400000），跑满时间优先；
* 百分位用**最近秩法**，与 Rust 侧同一实现；
* 输出 CSV 列与 Rust 侧完全一致，runner 直接拼。

各段对照口径（对应 plan/experiment-matrix.md §4）：

    d1  `json.loads`（主）/ `orjson.loads`（次，Python 侧上界）
    d2  `Jinja2`（transformers 同款 ImmutableSandboxedEnvironment + tojson）
    d3  `msgspec.msgpack`（vLLM 真实路径）/ `msgpack`（通用基线）
    d4  `json.dumps` + `asyncio` 写 socket（SSE）

注意：Python 侧的数字**含解释器逐条派发的成本**（这正是 Q1 要说的事），
引用时必须连口径一起引用。用法见 --help。
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import statistics
import sys
import time
from pathlib import Path

CSV_HEADER = (
    "lang,seg,point,op,input_label,input_bytes,tokens,iterations,samples,wall_s,"
    "mean_us,p50_us,p90_us,p99_us,min_us,max_us,stdev_us,ops_per_sec,bytes_per_op,"
    "allocs_per_op,alloc_bytes_per_op,notes"
)

# 分配计数列：只有 Rust 侧能采（它带计数分配器，见 rust/src/alloc.rs），
# Python 侧留空 —— 空列比编一个数诚实。
ALLOC_COLUMNS = ("", "")

MIN_WARMUP_S = 10.0
MIN_SAMPLE_S = 30.0


# ------------------------------------------------------------------ 计时核心


def percentile(sorted_ns: list[float], q: float) -> float:
    """最近秩法（与 Rust 侧 bench.rs 同一实现）。"""
    if not sorted_ns:
        return float("nan")
    rank = max(1, int(-(-q * len(sorted_ns) // 1)))
    return sorted_ns[min(rank, len(sorted_ns)) - 1]


def _stats(samples_ns: list[float]) -> dict:
    samples = sorted(samples_ns)
    n = len(samples)
    mean = sum(samples) / n if n else float("nan")
    stdev = statistics.stdev(samples) if n > 1 else 0.0
    return {
        "samples": n,
        "mean_us": mean / 1000.0,
        "p50_us": percentile(samples, 0.50) / 1000.0,
        "p90_us": percentile(samples, 0.90) / 1000.0,
        "p99_us": percentile(samples, 0.99) / 1000.0,
        "min_us": samples[0] / 1000.0 if n else float("nan"),
        "max_us": samples[-1] / 1000.0 if n else float("nan"),
        "stdev_us": stdev / 1000.0,
    }


def measure_group(
    ops: list[tuple[str, object]],
    *,
    warmup_s: float,
    sample_s: float,
    max_samples: int = 400_000,
) -> list[dict]:
    """一组独立的 op 在同一个窗口里轮转测量（口径与 Rust 侧 bench.rs 一致）。

    返回顺序与 `ops` 一致，每行带 `op` 名字。窗口满足 ≥10 s 预热 + ≥30 s 采样；
    每个 op 各自计时、各自统计。
    """
    n = len(ops)
    assert n > 0

    # 1) 试跑：每个 op 单独估一次耗时，定各自 stride
    per_op = []
    for _name, fn in ops:
        t0 = time.perf_counter()
        for _ in range(200):
            fn()
        per_op.append(max((time.perf_counter() - t0) / 200, 1e-12))

    # 2) 预热：轮转跑满 warmup_s
    deadline = time.perf_counter() + warmup_s
    while time.perf_counter() < deadline:
        for _name, fn in ops:
            fn()

    # 3) 采样：轮转跑满 sample_s；每个 op 按自己的 stride 抽稀
    #    轮转按**时间片**批量跑（每批目标 ~1 ms）：否则一个 300 µs 的慢 op
    #    会把一个 5 µs 的快 op 饿死（30 s 窗口里只剩几十个样本）。
    target_batch_s = 1e-3
    batch_sizes = [max(1, round(target_batch_s / per_op[i])) for i in range(n)]
    strides = [
        max(1, int((sample_s / per_op[i]) / n / max_samples)) for i in range(n)
    ]
    samples: list[list[float]] = [[] for _ in range(n)]
    iterations = [0] * n
    bytes_sum = [0.0] * n
    start = time.perf_counter()
    cycles = 0
    while True:
        for index, (_name, fn) in enumerate(ops):
            for _ in range(batch_sizes[index]):
                if iterations[index] % strides[index] == 0 and len(samples[index]) < max_samples:
                    t0 = time.perf_counter_ns()
                    nbytes = fn()
                    samples[index].append(float(time.perf_counter_ns() - t0))
                    bytes_sum[index] += float(nbytes or 0)
                else:
                    fn()
                iterations[index] += 1
        cycles += 1
        if cycles % 4 == 0 and (time.perf_counter() - start) >= sample_s:
            break
    wall_s = time.perf_counter() - start

    rows = []
    for index, (name, _fn) in enumerate(ops):
        row = _stats(samples[index])
        row.update(
            op=name,
            iterations=iterations[index],
            wall_s=wall_s,
            ops_per_sec=iterations[index] / wall_s,
            bytes_per_op=(bytes_sum[index] / row["samples"]) if row["samples"] else 0.0,
        )
        rows.append(row)
    return rows


def measure(fn, *, warmup_s: float, sample_s: float, max_samples: int = 400_000) -> dict:
    """单个 op 独占一个窗口。"""
    return measure_group(
        [("op", fn)], warmup_s=warmup_s, sample_s=sample_s, max_samples=max_samples
    )[0]


async def measure_async(
    ops: list[tuple[str, object]], *, warmup_s: float, sample_s: float, max_samples: int = 400_000
) -> list[dict]:
    """异步版：`ops` 是 (名字, 协程函数) 列表，用于 asyncio 写 socket 的那一段。"""
    n = len(ops)
    assert n > 0
    per_op = []
    for _name, fn in ops:
        t0 = time.perf_counter()
        for _ in range(50):
            await fn()
        per_op.append(max((time.perf_counter() - t0) / 50, 1e-12))

    deadline = time.perf_counter() + warmup_s
    while time.perf_counter() < deadline:
        for _name, fn in ops:
            await fn()

    strides = [max(1, int((sample_s / per_op[i]) / n / max_samples)) for i in range(n)]
    target_batch_s = 1e-3
    batch_sizes = [max(1, round(target_batch_s / per_op[i])) for i in range(n)]
    samples: list[list[float]] = [[] for _ in range(n)]
    iterations = [0] * n
    bytes_sum = [0.0] * n
    start = time.perf_counter()
    cycles = 0
    while True:
        for index, (_name, fn) in enumerate(ops):
            for _ in range(batch_sizes[index]):
                if iterations[index] % strides[index] == 0 and len(samples[index]) < max_samples:
                    t0 = time.perf_counter_ns()
                    nbytes = await fn()
                    samples[index].append(float(time.perf_counter_ns() - t0))
                    bytes_sum[index] += float(nbytes or 0)
                else:
                    await fn()
                iterations[index] += 1
        cycles += 1
        if cycles % 4 == 0 and (time.perf_counter() - start) >= sample_s:
            break
    wall_s = time.perf_counter() - start

    rows = []
    for index, (name, _fn) in enumerate(ops):
        row = _stats(samples[index])
        row.update(
            op=name,
            iterations=iterations[index],
            wall_s=wall_s,
            ops_per_sec=iterations[index] / wall_s,
            bytes_per_op=(bytes_sum[index] / row["samples"]) if row["samples"] else 0.0,
        )
        rows.append(row)
    return rows


class Csv:
    def __init__(self, path: str) -> None:
        import csv

        self.file = open(path, "w", encoding="utf-8", newline="")
        self.writer = csv.writer(self.file, quoting=csv.QUOTE_MINIMAL)
        self.writer.writerow(CSV_HEADER.split(","))

    def push(self, row: dict) -> None:
        fields = [
            row["lang"],
            row["seg"],
            row["point"],
            row["op"],
            row["input_label"],
            row["input_bytes"],
            row["tokens"],
            row["iterations"],
            row["samples"],
            f"{row['wall_s']:.3f}",
            f"{row['mean_us']:.3f}",
            f"{row['p50_us']:.3f}",
            f"{row['p90_us']:.3f}",
            f"{row['p99_us']:.3f}",
            f"{row['min_us']:.3f}",
            f"{row['max_us']:.3f}",
            f"{row['stdev_us']:.3f}",
            f"{row['ops_per_sec']:.1f}",
            f"{row['bytes_per_op']:.1f}",
            *ALLOC_COLUMNS,
            row["notes"],
        ]
        self.writer.writerow(fields)

    def close(self) -> None:
        self.file.close()


def stamp(row: dict, **kwargs) -> dict:
    row = dict(row)
    row["lang"] = "python"
    row.update(kwargs)
    return row


def clock_row(point: str) -> dict:
    sink = 0

    def fn() -> int:
        nonlocal sink
        sink += 1
        return 0

    row = measure(fn, warmup_s=2.0, sample_s=3.0, max_samples=200_000)
    return stamp(
        row,
        seg="meta",
        point=point,
        op="clock_overhead",
        input_label="empty-loop",
        input_bytes=0,
        tokens=0,
        notes="perf_counter_ns 的单次开销（比较 <1µs 的操作前先看这行）",
    )


# ------------------------------------------------------------------- 工具


def load_bytes(path: str) -> bytes:
    return Path(path).read_bytes()


def short_label(path: str) -> str:
    name = Path(path).name
    for prefix in ("chat_request_", "engine_core_request_"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
    return name.removesuffix(".json")


def check_guard(args: argparse.Namespace) -> None:
    if (args.warmup < MIN_WARMUP_S or args.sample < MIN_SAMPLE_S) and (
        os.environ.get("DMICRO_ALLOW_SHORT") != "1"
    ):
        print(
            f"[micro-py] 拒绝运行：warmup={args.warmup}s sample={args.sample}s 低于纪律下限"
            "（10s/30s）。只做冒烟时设 DMICRO_ALLOW_SHORT=1。",
            file=sys.stderr,
        )
        raise SystemExit(2)


# --------------------------------------------------------------------- D1


def cmd_d1(args: argparse.Namespace) -> int:
    raw = load_bytes(args.fixture)
    label = short_label(args.fixture)
    parsed = json.loads(raw)
    tools = parsed.get("tools") or []
    summary = {
        "messages": len(parsed["messages"]),
        "first_role": parsed["messages"][0]["role"],
        "content_bytes": len(parsed["messages"][0]["content"].encode("utf-8")),
        "tools": len(tools),
        "first_tool": tools[0]["function"]["name"] if tools else None,
        "max_tokens": parsed.get("max_tokens"),
        "stream": parsed.get("stream"),
    }
    if args.check:
        Path(args.check).write_text(
            json.dumps(summary, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    print(f"[d1] {label} check={json.dumps(summary, ensure_ascii=False)}", file=sys.stderr)

    cfg = dict(warmup_s=args.warmup, sample_s=args.sample, max_samples=args.max_samples)
    size = len(raw)
    holder: dict = {}
    csv = Csv(args.out)

    def parse_stdlib() -> int:
        holder["value"] = json.loads(raw)
        return size

    ops: list[tuple[str, object]] = [("json.loads", parse_stdlib)]
    try:
        import orjson  # type: ignore
    except ImportError:
        print("[d1] orjson 未安装，跳过 orjson.loads", file=sys.stderr)
    else:
        ops.append(("orjson.loads", lambda: orjson.loads(raw) and size))

    notes = {
        "json.loads": "无类型解析，标准库 C 加速 json（vLLM 侧另有 pydantic/msgspec 校验层，未测）",
        "orjson.loads": "Rust 实现的 Python JSON 解析器：Python 侧上界（非 vLLM 依赖，参考用）",
    }
    for row in measure_group(ops, **cfg):
        csv.push(
            stamp(
                row,
                seg="p2_json",
                point=args.point,
                input_label=label,
                input_bytes=size,
                tokens=len(holder["value"]["messages"]) if "value" in holder else 0,
                notes=notes.get(row["op"], ""),
            )
        )

    csv.push(clock_row(args.point))
    csv.close()
    return 0


# --------------------------------------------------------------------- D2


def build_jinja_env():
    from jinja2.sandbox import ImmutableSandboxedEnvironment

    def tojson(value, indent=None, ensure_ascii=False, sort_keys=False, separators=None):
        # 与 transformers `_tojson` 同义：不 HTML 转义，支持 json.dumps 的 kwargs
        return json.dumps(
            value,
            ensure_ascii=ensure_ascii,
            indent=indent,
            sort_keys=sort_keys,
            separators=separators,
        )

    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    env.filters["tojson"] = tojson
    return env


def cmd_d2(args: argparse.Namespace) -> int:
    template_text = Path(args.template).read_text(encoding="utf-8")
    raw = load_bytes(args.fixture)
    label = short_label(args.fixture)
    request = json.loads(raw)
    kwargs = dict(request.get("chat_template_kwargs") or {})
    kwargs.pop("tools", None)

    env = build_jinja_env()
    template = env.from_string(template_text)

    cfg = dict(warmup_s=args.warmup, sample_s=args.sample, max_samples=args.max_samples)
    size = len(raw)
    csv = Csv(args.out)
    holder: dict = {}

    def render_once() -> int:
        context = {
            "messages": request["messages"],
            "add_generation_prompt": True,
            "tools": request.get("tools"),
            **kwargs,
        }
        holder["rendered"] = template.render(context)
        # 与 Rust 侧对齐：按 **UTF-8 字节数** 计（不是字符数）
        holder["rendered_bytes"] = len(holder["rendered"].encode("utf-8"))
        return holder["rendered_bytes"]

    row = measure_group([("jinja2_render", render_once)], **cfg)[0]
    csv.push(
        stamp(
            row,
            seg="p3_template",
            point=args.point,
            input_label=label,
            input_bytes=size,
            tokens=holder["rendered_bytes"],
            notes="编译一次后每请求 render（上下文是上面的 dict 组装，一并计入）",
        )
    )

    rendered = holder["rendered"]
    if args.dump:
        Path(args.dump).write_bytes(rendered.encode("utf-8"))
    print(
        f"[d2] {label} rendered_bytes={len(rendered.encode('utf-8'))} "
        f"rendered_sha256={hashlib.sha256(rendered.encode('utf-8')).hexdigest()}",
        file=sys.stderr,
    )

    csv.push(clock_row(args.point))
    csv.close()
    return 0


# --------------------------------------------------------------------- D3


def msgspec_types():
    """与 vLLM 0.26.0 `vllm/v1/engine/__init__.py` 同形的 msgspec 结构体。

    真实 vLLM 的 `SamplingParams` 字段更多（约 40 个，见 vllm/sampling_params.py），
    这里保留 Rust 侧同款的 24 个字段；两侧字段集一致才谈得上"同尺寸"。
    `omit_defaults=True` 是 vLLM 的真实设置。

    实现放在同目录的 `ecr_types.py`：msgspec 解析注解需要模块级名字空间。
    """
    from ecr_types import EngineCoreRequest

    return EngineCoreRequest


def cmd_d3(args: argparse.Namespace) -> int:
    import msgspec

    request_type = msgspec_types()
    raw = load_bytes(args.fixture)
    label = short_label(args.fixture)
    request = msgspec.json.decode(raw, type=request_type)
    encoder = msgspec.msgpack.Encoder()
    decoder = msgspec.msgpack.Decoder(type=request_type)
    payload_py = encoder.encode(request)

    if args.payload_out:
        Path(args.payload_out).write_bytes(payload_py)
    foreign = load_bytes(args.decode_file) if args.decode_file else None

    cfg = dict(warmup_s=args.warmup, sample_s=args.sample, max_samples=args.max_samples)
    csv = Csv(args.out)
    holder: dict = {}

    def encode_once() -> int:
        out = encoder.encode(request)
        holder["encoded"] = out
        return len(out)

    def decode_py_once() -> int:
        holder["decoded"] = decoder.decode(payload_py)
        return len(payload_py)

    ops: list[tuple[str, object]] = [
        ("msgspec_encode", encode_once),
        ("msgspec_decode_python_payload", decode_py_once),
    ]
    notes = {
        "msgspec_encode": "msgspec.msgpack + array_like + omit_defaults（vLLM 前端真实路径）",
        "msgspec_decode_python_payload": "解码 msgspec 自己编码的稀疏字节",
    }
    if foreign is not None:

        def decode_rust_once() -> int:
            holder["foreign"] = decoder.decode(foreign)
            return len(foreign)

        ops.append(("msgspec_decode_rust_payload", decode_rust_once))
        notes["msgspec_decode_rust_payload"] = (
            "解码 Rust rmp-serde 的全量 map 字节（engine core 侧真实收包路径）"
        )

    try:
        import msgpack  # type: ignore
    except ImportError:
        print("[d3] msgpack 未安装，跳过通用 msgpack 基线", file=sys.stderr)
    else:
        raw_list = json.loads(raw)
        packed = msgpack.packb(raw_list, use_bin_type=True)
        ops.append(
            ("msgpack_packb", lambda: msgpack.packb(raw_list, use_bin_type=True) and len(packed))
        )
        notes["msgpack_packb"] = (
            "通用 C 扩展 msgpack（纯基线，vLLM 不用它）；输入是 20 元素 list"
        )

    print(f"[d3] {label} python_payload_bytes={len(payload_py)}", file=sys.stderr)
    for row in measure_group(ops, **cfg):
        op = row["op"]
        if op == "msgspec_encode":
            seg, input_bytes, tokens = "p6_msgpack", len(payload_py), len(request.prompt_token_ids or [])
        elif op == "msgspec_decode_python_payload":
            seg, input_bytes, tokens = (
                "p7_msgpack",
                len(payload_py),
                len(holder["decoded"].prompt_token_ids or []),
            )
        elif op == "msgspec_decode_rust_payload":
            seg, input_bytes, tokens = "p7_msgpack", len(foreign), len(foreign)
        else:
            seg, input_bytes, tokens = "p6_msgpack", len(packed), 0
        csv.push(
            stamp(
                row,
                seg=seg,
                point=args.point,
                input_label=label,
                input_bytes=input_bytes,
                tokens=tokens,
                notes=notes.get(op, ""),
            )
        )

    csv.push(clock_row(args.point))
    csv.close()
    return 0


def cmd_emit_payload(args: argparse.Namespace) -> int:
    """只做一次 msgspec 编码并落盘（供 Rust 侧 --decode-file 使用）。"""
    import msgspec

    request_type = msgspec_types()
    request = msgspec.json.decode(load_bytes(args.fixture), type=request_type)
    payload = msgspec.msgpack.Encoder().encode(request)
    Path(args.out).write_bytes(payload)
    print(f"[emit-payload] {args.out} bytes={len(payload)}", file=sys.stderr)
    return 0


# --------------------------------------------------------------------- D4


def cmd_d4(args: argparse.Namespace) -> int:
    return asyncio.run(_run_d4(args))


async def _run_d4(args: argparse.Namespace) -> int:
    response = json.loads(load_bytes(args.response))
    chunks = json.loads(load_bytes(args.chunks))
    dumps_kwargs = dict(ensure_ascii=False, separators=(",", ":"))

    response_body = json.dumps(response, **dumps_kwargs).encode("utf-8")
    chunk_body = json.dumps(chunks[-1], **dumps_kwargs).encode("utf-8")
    chunk_frame = b"data: " + chunk_body + b"\n\n"
    if args.dump:
        Path(args.dump).write_bytes(response_body)
    print(
        f"[d4] response_bytes={len(response_body)} "
        f"response_sha256={hashlib.sha256(response_body).hexdigest()} "
        f"chunk_bytes={len(chunk_body)} chunk_sha256={hashlib.sha256(chunk_body).hexdigest()} "
        f"chunks={len(chunks)}",
        file=sys.stderr,
    )

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while await reader.read(1 << 16):
                pass
        finally:
            writer.close()

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    _reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.transport.set_write_buffer_limits(high=1 << 20)

    cfg = dict(warmup_s=args.warmup, sample_s=args.sample, max_samples=args.max_samples)
    csv = Csv(args.out)
    holder: dict = {}

    def dump_response() -> int:
        out = json.dumps(response, **dumps_kwargs).encode("utf-8")
        holder["body"] = out
        return len(out)

    def dump_frame() -> int:
        body = json.dumps(chunks[-1], **dumps_kwargs).encode("utf-8")
        holder["frame"] = b"data: " + body + b"\n\n"
        return len(holder["frame"])

    def build_stream() -> int:
        # 一次完整流式请求的 129 帧“序列化 + 组帧”，写进内存缓冲（不碰 socket）
        buf = bytearray()
        for chunk in chunks:
            buf += b"data: "
            buf += json.dumps(chunk, **dumps_kwargs).encode("utf-8")
            buf += b"\n\n"
        buf += b"data: [DONE]\n\n"
        holder["stream"] = bytes(buf)
        return len(buf)

    sync_ops: list[tuple[str, object]] = [
        ("json.dumps_response", dump_response),
        ("json.dumps_sse_frame", dump_frame),
        ("stream_request_local", build_stream),
    ]
    notes = {
        "json.dumps_response": "标准库 json.dumps(separators=(',',':'))，对应 Rust 侧 serde_json_response",
        "json.dumps_sse_frame": "单个 SSE 帧（json.dumps + `data: ...\\n\\n` 组帧，不写 socket）",
        "stream_request_local": "一次完整流式请求的 129 帧序列化+组帧（内存缓冲，不含 socket 写）",
        "orjson.dumps_response": "Rust 实现的 Python JSON 序列化器：Python 侧上界（非 vLLM 依赖）",
    }
    try:
        import orjson  # type: ignore
    except ImportError:
        print("[d4] orjson 未安装，跳过 orjson 对照", file=sys.stderr)
    else:
        sync_ops.append(("orjson.dumps_response", lambda: orjson.dumps(response) and len(response_body)))

    for row in measure_group(sync_ops, **cfg):
        op = row["op"]
        if op == "json.dumps_response":
            seg, label_, input_bytes = "p10_serialize", "nonstream_body", len(response_body)
        elif op == "json.dumps_sse_frame":
            seg, label_, input_bytes = "p10_serialize", "finish_chunk", len(chunk_body)
        elif op == "stream_request_local":
            seg, label_, input_bytes = "p10_sse", f"osl_{len(chunks)}_chunks", len(holder["stream"])
        else:
            seg, label_, input_bytes = "p10_serialize", "nonstream_body", len(response_body)
        csv.push(
            stamp(
                row,
                seg=seg,
                point=args.point,
                input_label=label_,
                input_bytes=input_bytes,
                tokens=len(chunks) if op == "stream_request_local" else 0,
                notes=notes.get(op, ""),
            )
        )

    async def write_frame() -> int:
        writer.write(chunk_frame)
        await writer.drain()
        return len(chunk_frame)

    for row in await measure_async([("asyncio_write_frame_tcp", write_frame)], **cfg):
        csv.push(
            stamp(
                row,
                seg="p10_sse",
                point=args.point,
                input_label="finish_chunk",
                input_bytes=len(chunk_body),
                tokens=0,
                notes="一个 SSE 帧写 loopback TCP（asyncio write+drain，含事件循环调度）",
            )
        )

    csv.push(clock_row(args.point))
    csv.close()

    writer.close()
    await writer.wait_closed()
    server.close()
    await server.wait_closed()
    return 0


# --------------------------------------------------------------------- CLI


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="D 线微基准（Python 侧对照臂）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = ap.add_subparsers(dest="command", required=True)

    def common(parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--out", required=True, help="输出 CSV 路径")
        parser.add_argument("--point", default="unnamed", help="负载点标签（1k / 8k / osl128）")
        parser.add_argument("--warmup", type=float, default=10.0, help="预热秒数（≥10）")
        parser.add_argument("--sample", type=float, default=30.0, help="采样秒数（≥30）")
        parser.add_argument("--max-samples", type=int, default=400_000, help="样本上限")
        parser.add_argument("--check", default=None, help="d1：写出解析结果摘要 JSON")
        parser.add_argument("--dump", default=None, help="d2/d4：写出渲染/序列化结果")
        parser.add_argument(
            "--payload-out", default=None, help="d3：写出 msgspec 编码的 msgpack 字节"
        )
        parser.add_argument(
            "--decode-file", default=None, help="d3：额外解码这份外部 payload（Rust 侧产出）"
        )

    p1 = sub.add_parser("d1", help="P2 JSON 反序列化")
    p1.add_argument("--fixture", required=True)
    common(p1)
    p1.set_defaults(func=cmd_d1)

    p2 = sub.add_parser("d2", help="P3 chat 模板渲染")
    p2.add_argument("--template", required=True)
    p2.add_argument("--fixture", required=True)
    common(p2)
    p2.set_defaults(func=cmd_d2)

    p3 = sub.add_parser("d3", help="P6/P7 msgpack 编解码")
    p3.add_argument("--fixture", required=True)
    common(p3)
    p3.set_defaults(func=cmd_d3)

    p4 = sub.add_parser("d4", help="P10 JSON 序列化 + SSE")
    p4.add_argument("--response", required=True)
    p4.add_argument("--chunks", required=True)
    common(p4)
    p4.set_defaults(func=cmd_d4)

    p5 = sub.add_parser("emit-payload", help="只编码一份 msgspec payload 落盘（不测）")
    p5.add_argument("--fixture", required=True)
    p5.add_argument("--out", required=True)
    p5.set_defaults(func=cmd_emit_payload)
    return ap


def main() -> int:
    args = build_parser().parse_args()
    if hasattr(args, "warmup"):
        check_guard(args)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
