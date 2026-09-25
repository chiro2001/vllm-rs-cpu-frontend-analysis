#!/usr/bin/env python3
"""最小 raw-payload 压测器 —— 逐字节固定的请求体，用于 perf 采样窗口。

为什么不用 `vllm-bench`（见 `harness/profile/README.md` §1）：

1. `vllm-bench` 的 openai-chat 后端**不支持在请求体里发 `tools`**，而 B1 的负载定义
   是「chat + tools」；
2. `random` 数据集每次都要现场生成 prompt（一次性前置开销），且 prompt 内容随
   seed/顺序变化；本脚本**只构造一次 body，之后每条请求的字节完全相同**，
   前置开销被完全排除在采样窗口之外（plan/experiment-matrix.md §2 要求）。

口径（写进结果 JSON，引用数字时必须带上）：
  * `throughput_req_s`  = 采样窗口内**成功完成**的请求数 ÷ 窗口墙钟秒数；
  * `throughput_out_tok_s` = 窗口内成功请求的 completion_tokens 之和 ÷ 窗口秒数
    （completion_tokens 取自响应体里的 `usage`，不是本地估计）；
  * 延迟只统计窗口内的请求（warmup 与窗口外的余量请求不计）；
  * 客户端自身 CPU（utime+stime）单独记录，**绝不算进服务端**。
  * **前端进程 CPU**：`--frontend-pid-file`/`--frontend-pid` + `--procstat`
    交给 `harness/common/procstat.sh`，在**预热之后 / 窗口之前**取 before、
    **窗口结束之后**取 after，两者相减得 utime+stime（**不含子进程**）。
    这与客户端 CPU 是**两个进程、两个数**，绝不合并。

用法见 `raw_load.py --help`。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import resource
import statistics
import subprocess
import sys
import time
from typing import Any

DEFAULT_TOKENIZER = "REPO_HOME/models/Qwen3-0.6B/tokenizer.json"

# 一个很小的 tools 定义（真实形状：OpenAI function calling）。
# 目的是让前端走「渲染 tools → tojson → 模板」这条路径，而不是伪造一个巨型 schema。
TOOLS_WEATHER: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "get_current_weather",
            "description": "Get the current weather in a given location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "The city and state, e.g. San Francisco, CA",
                    },
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
                },
                "required": ["location"],
            },
        },
    }
]


def _build_word_pool(tokenizer_path: str, seed: int, size: int = 20000) -> list[str]:
    """从 tokenizer 的词表里抽出一批「干净的 ASCII 单词」，用于合成 prompt 文本。"""
    from tokenizers import Tokenizer  # 局部 import：--body-file 模式下不需要它

    tok = Tokenizer.from_file(tokenizer_path)
    vocab_size = tok.get_vocab_size()
    decoder = tok.get_added_tokens_decoder()
    special = {i for i, t in decoder.items() if t.special}
    rng = random.Random(seed)
    pool: list[str] = []
    tries = 0
    while len(pool) < size and tries < size * 60:
        tries += 1
        i = rng.randrange(0, vocab_size)
        if i in special:
            continue
        s = tok.decode([i], skip_special_tokens=False)
        if (
            2 <= len(s) <= 12
            and s.isascii()
            and s.strip()
            and all(32 < ord(c) < 127 for c in s)
            and "\\" not in s
        ):
            pool.append(s.strip())
    if not pool:
        raise SystemExit("无法从 tokenizer 词表构造词池")
    return pool


def _synth_text(tokenizer_path: str, target_tokens: int, seed: int) -> tuple[str, int]:
    """合成一段 ≈ target_tokens 个 token 的文本，返回 (文本, 本地实测编码长度)。"""
    from tokenizers import Tokenizer

    tok = Tokenizer.from_file(tokenizer_path)
    rng = random.Random(seed)
    pool = _build_word_pool(tokenizer_path, seed)

    def encode_len(words: list[str]) -> int:
        return len(tok.encode(" ".join(words)).ids)

    # 用「每个词平均几个 token」的实测比例做两三步缩放，再线性微调
    n = target_tokens
    words = [rng.choice(pool) for _ in range(n)]
    for _ in range(4):
        got = encode_len(words)
        if got == target_tokens:
            break
        n = max(1, round(len(words) * target_tokens / max(got, 1)))
        words = [rng.choice(pool) for _ in range(n)]
        if abs(got - target_tokens) <= 1:
            break
    # 线性微调：先补齐，再逐词裁剪
    got = encode_len(words)
    guard = 0
    while got < target_tokens and guard < 20000:
        words.append(rng.choice(pool))
        got = encode_len(words)
        guard += 1
    while got > target_tokens and words and guard < 40000:
        words.pop()
        got = encode_len(words)
        guard += 1
    return " ".join(words), got


def build_body(args: argparse.Namespace) -> tuple[bytes, dict[str, Any]]:
    """构造请求体（只做一次）。返回 (字节, 元信息)。"""
    meta: dict[str, Any] = {}
    text = ""
    local_tokens = 0
    if args.input_len > 0:
        text, local_tokens = _synth_text(args.tokenizer, args.input_len, args.seed)
        meta["prompt_text_sha256"] = __import__("hashlib").sha256(text.encode()).hexdigest()
        meta["prompt_text_bytes"] = len(text.encode())
        meta["local_token_count"] = local_tokens
    messages: list[dict[str, Any]] = []
    if args.system_prompt:
        messages.append({"role": "system", "content": args.system_prompt})
    messages.append({"role": "user", "content": args.user_prefix + text})

    body: dict[str, Any] = {
        "model": args.model,
        "messages": messages,
        "max_tokens": args.output_len,
        "temperature": args.temperature,
        "stream": bool(args.stream),
    }
    if args.tools != "none":
        weather = TOOLS_WEATHER if args.tools == "weather" else json.loads(args.tools)
        body["tools"] = weather
        if args.tool_choice != "auto":
            body["tool_choice"] = args.tool_choice
    if args.stream:
        body["stream_options"] = {"include_usage": True}
    if args.extra_body:
        body.update(json.loads(args.extra_body))
    raw = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
    meta["body_bytes"] = len(raw)
    meta["body_sha256"] = __import__("hashlib").sha256(raw).hexdigest()
    return raw, meta


def _cpu_seconds() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF)
    return r.ru_utime + r.ru_stime


DEFAULT_PROCSTAT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common", "procstat.sh")


def _procstat_snapshot(procstat: str, out: str, pids: list[str]) -> bool:
    """调 harness/common/procstat.sh 取一次 /proc/<pid>/stat 快照。失败不致命（记录即可）。"""
    try:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        r = subprocess.run([procstat, "snapshot", "--out", out, *pids],
                           capture_output=True, text=True, check=False)
        return r.returncode == 0 and os.path.exists(out)
    except OSError:
        return False


def _procstat_diff(procstat: str, before: str, after: str, out: str) -> dict | None:
    try:
        r = subprocess.run([procstat, "diff", "--before", before, "--after", after, "--out", out],
                           capture_output=True, text=True, check=False)
        if r.returncode != 0:
            return None
        return json.loads(open(out).read())
    except (OSError, json.JSONDecodeError):
        return None


async def _one(
    session: "Any",
    url: str,
    body: bytes,
    stream: bool,
    timeout_s: float,
) -> dict[str, Any]:
    t0 = time.perf_counter()
    out: dict[str, Any] = {"start": t0, "ok": False}
    try:
        async with session.post(
            url,
            data=body,
            headers={"Content-Type": "application/json", "Accept": "text/event-stream" if stream else "application/json"},
        ) as resp:
            out["status"] = resp.status
            if resp.status != 200:
                out["error"] = (await resp.text())[:200]
                out["end"] = time.perf_counter()
                return out
            if stream:
                completion = 0
                ttft = None
                usage_seen = False
                async for raw_line in resp.content:
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    line = raw_line.strip()
                    if not line.startswith(b"data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == b"[DONE]":
                        break
                    try:
                        chunk = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    usage = chunk.get("usage")
                    if usage:
                        usage_seen = True
                        completion = usage.get("completion_tokens", completion)
                        out["prompt_tokens"] = usage.get("prompt_tokens")
                    else:
                        completion += 1  # 每 chunk 一个 delta（后端 chunk_size=1）
                out["completion_tokens"] = completion
                out["usage_seen"] = usage_seen
                out["ttft_s"] = ttft
            else:
                payload = await resp.read()
                try:
                    doc = json.loads(payload)
                except json.JSONDecodeError:
                    out["error"] = "响应不是 JSON"
                    out["end"] = time.perf_counter()
                    return out
                usage = doc.get("usage") or {}
                out["completion_tokens"] = usage.get("completion_tokens", 0)
                out["prompt_tokens"] = usage.get("prompt_tokens")
                choices = doc.get("choices") or []
                if choices:
                    out["finish_reason"] = choices[0].get("finish_reason")
        out["ok"] = True
    except Exception as e:  # noqa: BLE001 — 压测器要记录任何异常而不是中断
        out["error"] = f"{type(e).__name__}: {e}"
    out["end"] = time.perf_counter()
    return out


async def run(args: argparse.Namespace, body: bytes) -> dict[str, Any]:
    import aiohttp

    url = args.base_url.rstrip("/") + args.path
    timeout = aiohttp.ClientTimeout(total=args.timeout, sock_connect=10)
    connector = aiohttp.TCPConnector(limit=args.concurrency, ttl_dns_cache=600)
    results: list[dict[str, Any]] = []
    cpu0 = _cpu_seconds()
    t_start = time.perf_counter()

    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        # ---- warmup（不计入窗口）----
        for _ in range(args.warmup):
            await _one(session, url, body, args.stream, args.timeout)

        # ---- 采样窗口 ----
        # 前端 CPU 的 before 快照：**预热之后、窗口之前**（plan/EXECUTION.md §8 必采项 ④）
        fe_pids = _resolve_frontend_pids(args)
        snap_before = snap_after = None
        if args.procstat and fe_pids:
            snap_before = os.path.join(args.snapshot_dir, f"{args.snapshot_tag}.before.json")
            snap_after = os.path.join(args.snapshot_dir, f"{args.snapshot_tag}.after.json")
            _procstat_snapshot(args.procstat, snap_before, fe_pids + [str(os.getpid())])
        cpu_win0 = _cpu_seconds()
        window_open = time.perf_counter()
        window_open_epoch = time.time()
        done = 0
        issued = 0
        sem = asyncio.Semaphore(args.concurrency)
        stop_at = window_open + args.duration if args.duration else None
        lock = asyncio.Lock()
        exhausted = False

        async def worker() -> None:
            nonlocal done, issued, exhausted
            while True:
                async with lock:
                    if stop_at is not None and time.perf_counter() >= stop_at:
                        return
                    if args.num_requests and issued >= args.num_requests:
                        exhausted = True
                        return
                    issued += 1
                async with sem:
                    if stop_at is not None and time.perf_counter() >= stop_at:
                        return
                    r = await _one(session, url, body, args.stream, args.timeout)
                async with lock:
                    results.append(r)
                    done += 1

        t1 = time.perf_counter()
        await asyncio.gather(*(worker() for _ in range(args.concurrency)))
        t2 = time.perf_counter()
        window_close = t2
        cpu_win1 = _cpu_seconds()
        if snap_after:
            _procstat_snapshot(args.procstat, snap_after, fe_pids + [str(os.getpid())])

    cpu1 = _cpu_seconds()
    wall = window_close - window_open

    # ---- 前端进程 CPU（procstat 口径：utime+stime，不含子进程）----
    frontend_cpu = None
    client_cpu_procstat = None
    frontend_cpu_split = {}
    procstat_doc = None
    if snap_after and args.frontend_cpu_out:
        procstat_doc = _procstat_diff(args.procstat, snap_before, snap_after, args.frontend_cpu_out)
        if procstat_doc:
            pids = procstat_doc.get("pids", {})
            for pid, v in pids.items():
                if int(pid) == os.getpid():
                    client_cpu_procstat = v.get("cpu_seconds")
                else:
                    frontend_cpu = v.get("cpu_seconds")
                    frontend_cpu_split = {"utime_seconds": v.get("utime_seconds"),
                                          "stime_seconds": v.get("stime_seconds")}

    ok = [r for r in results if r["ok"]]
    bad = [r for r in results if not r["ok"]]
    lat = sorted((r["end"] - r["start"]) * 1000 for r in ok)
    ttfts = sorted(r["ttft_s"] * 1000 for r in ok if r.get("ttft_s") is not None)
    out_tok = sum(r.get("completion_tokens") or 0 for r in ok)
    prompt_tokens = [r.get("prompt_tokens") for r in ok if r.get("prompt_tokens")]
    in_tok_total = sum(prompt_tokens) if prompt_tokens else None

    def pct(xs: list[float], q: float) -> float | None:
        if not xs:
            return None
        i = min(len(xs) - 1, max(0, int(round(q / 100 * (len(xs) - 1)))))
        return round(xs[i], 3)

    doc: dict[str, Any] = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "note": args.note,
        "base_url": args.base_url,
        "path": args.path,
        "concurrency": args.concurrency,
        "num_requests_requested": args.num_requests,
        "duration_requested_s": args.duration,
        "stream": bool(args.stream),
        "input_len_target": args.input_len,
        "output_len_target": args.output_len,
        "tools": args.tools,
        "warmup": args.warmup,
        "window": {
            "open_epoch": window_open_epoch,
            "open_monotonic": window_open,
            "close_monotonic": window_close,
            "wall_seconds": round(wall, 4),
            "ok_before_first_request_s": round(t1 - window_open, 6),
        },
        "requests_issued_in_window": issued,
        "requests_completed_in_window": len(ok),
        "requests_failed_in_window": len(bad),
        "window_exhausted_num_requests": exhausted,
        "throughput_req_s": round(len(ok) / wall, 3) if wall > 0 else None,
        "throughput_out_tok_s": round(out_tok / wall, 1) if wall > 0 else None,
        "completion_tokens_total": out_tok,
        "prompt_tokens_total": in_tok_total,
        "prompt_tokens_mean": round(statistics.fmean(prompt_tokens), 2) if prompt_tokens else None,
        # 客户端（压测端）自己的 CPU —— 与前端**分开报**
        "client_cpu_seconds": round(cpu1 - cpu0, 4),
        "client_cpu_percent_of_one_core": round((cpu1 - cpu0) / wall * 100, 2) if wall > 0 else None,
        "client_cpu_seconds_window_only": round(cpu_win1 - cpu_win0, 4),
        # 前端进程 CPU（procstat 口径，含 os.getpid() 作为客户端交叉校验）
        "frontend_cpu_seconds": frontend_cpu,
        # utime/stime 拆分很重要：perf_event_paranoid=2 下 `perf record -e cpu-clock` 只能采**用户态**
        # （perf 自己报的 event 名就是 `cpu-clock:u`），所以火焰图看不见 stime。
        "frontend_utime_seconds": frontend_cpu_split.get("utime_seconds"),
        "frontend_stime_seconds": frontend_cpu_split.get("stime_seconds"),
        "client_cpu_seconds_procstat": client_cpu_procstat,
        "procstat": {
            "basis": "utime+stime（不含子进程 cutime/cstime）",
            "script": args.procstat if args.procstat else None,
            "window": "预热之后 / 窗口之前取 before；窗口结束之后取 after",
            "pids_sampled": fe_pids + [str(os.getpid())] if fe_pids else [],
            "snapshot_before": snap_before,
            "snapshot_after": snap_after,
            "frontend_pid": fe_pids[0] if fe_pids else None,
            "diff_out": args.frontend_cpu_out if procstat_doc else None,
            "note": "frontend_cpu_seconds 与 client_cpu_* 是两个进程的两个数，绝不相加",
        },
        "latency_ms": {
            "p50": pct(lat, 50),
            "p90": pct(lat, 90),
            "p99": pct(lat, 99),
            "mean": round(statistics.fmean(lat), 3) if lat else None,
        },
        "ttft_ms": {"p50": pct(ttfts, 50), "p99": pct(ttfts, 99)} if ttfts else None,
        "failures": [{"status": r.get("status"), "error": r.get("error")} for r in bad[:5]],
    }

    # ---- 归一化列（本次补采的核心产出）----
    n_ok = len(ok)
    if n_ok:
        doc["normalized"] = {
            "_units": "秒 / 请求、秒 / 千 token；CPU 为 utime+stime",
            "frontend_cpu_s_per_request": _div(frontend_cpu, n_ok),
            "frontend_cpu_s_per_1k_input_tokens": _div(frontend_cpu, in_tok_total, 1000),
            "frontend_cpu_s_per_1k_output_tokens": _div(frontend_cpu, out_tok, 1000),
            "client_cpu_s_per_request": _div(doc["client_cpu_seconds_window_only"], n_ok),
            "client_cpu_s_per_1k_input_tokens": _div(doc["client_cpu_seconds_window_only"], in_tok_total, 1000),
            "client_cpu_s_per_1k_output_tokens": _div(doc["client_cpu_seconds_window_only"], out_tok, 1000),
            "frontend_cpu_s_per_window_s": _div(frontend_cpu, wall),
        }
    return doc


def _div(a, b, scale=1):
    """安全除法（保留 6 位有效数字）；缺任一侧返回 None 而不是 0。"""
    if a is None or b in (None, 0):
        return None
    return round(a / (b / scale), 9)


def _resolve_frontend_pids(args) -> list[str]:
    """前端 pid 来源：--frontend-pid 直接给，或 --frontend-pid-file 读文件。"""
    pids: list[str] = []
    if args.frontend_pid:
        pids.append(str(args.frontend_pid))
    if args.frontend_pid_file:
        try:
            v = open(args.frontend_pid_file).read().strip()
            if v:
                pids.append(v)
        except OSError:
            pass
    out = []
    for p in pids:
        if p.isdigit() and p not in out:
            out.append(p)
    return out


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="raw-payload 压测器（逐字节固定的 body，用于 perf 采样窗口）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--base-url", default="http://127.0.0.1:8199")
    p.add_argument("--path", default="/v1/chat/completions")
    p.add_argument("--model", default="REPO_HOME/models/Qwen3-0.6B")
    p.add_argument("--tokenizer", default=DEFAULT_TOKENIZER)
    p.add_argument("--input-len", type=int, default=1024, help="目标 prompt token 数（0=空 prompt）")
    p.add_argument("--output-len", type=int, default=128)
    p.add_argument("--tools", default="weather", help="weather | none | 内联 JSON 数组")
    p.add_argument("--tool-choice", default="auto")
    p.add_argument("--system-prompt", default="You are a helpful assistant.")
    p.add_argument("--user-prefix", default="")
    p.add_argument("--temperature", type=float, default=0.0)
    p.add_argument("--extra-body", default=None, help="JSON 对象字符串，合并进请求体")
    p.add_argument("--stream", action="store_true")
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--num-requests", type=int, default=0, help="0 表示只按 --duration 停止")
    p.add_argument("--duration", type=float, default=30.0, help="采样窗口秒数（0=按 num-requests）")
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--timeout", type=float, default=120.0)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--body-file", default=None, help="复用已有的请求体文件（跳过文本合成）")
    p.add_argument("--dump-body", default=None, help="把构造出的请求体写到这里（便于审计/复跑）")
    p.add_argument("--out", default=None, help="结果 JSON 路径")
    # ---- 前端进程 CPU（plan/EXECUTION.md §8 必采项 ④）----
    p.add_argument("--frontend-pid", default=None, help="被压服务（前端）的 pid")
    p.add_argument("--frontend-pid-file", default=None,
                   help="读前端 pid 的文件（如 runs/<name>/frontend.pid）")
    p.add_argument("--procstat", default=DEFAULT_PROCSTAT,
                   help="harness/common/procstat.sh 的路径（空字符串=不采）")
    p.add_argument("--frontend-cpu-out", default=None,
                   help="前端 CPU 增量 JSON 的输出路径（默认由 --out 推导：<tag>.load.json → <tag>.frontend-cpu.json）")
    p.add_argument("--snapshot-dir", default=None, help="procstat 快照存放目录（默认与 --frontend-cpu-out 同目录）")
    p.add_argument("--snapshot-tag", default=None, help="快照文件名前缀（默认由 --out 推导）")
    p.add_argument("--note", default=None,
                   help="本点的说明（写进结果 JSON 的 note；诊断点/对照点必须写清）")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    # 推导 procstat 相关路径
    if args.out and not args.frontend_cpu_out:
        base = args.out[:-len(".load.json")] if args.out.endswith(".load.json") else args.out.rsplit(".", 1)[0]
        args.frontend_cpu_out = base + ".frontend-cpu.json"
    if args.frontend_cpu_out and not args.snapshot_tag:
        args.snapshot_tag = os.path.basename(args.frontend_cpu_out).rsplit(".frontend-cpu", 1)[0]
    if args.frontend_cpu_out and not args.snapshot_dir:
        args.snapshot_dir = os.path.join(os.path.dirname(args.frontend_cpu_out) or ".", "procstat-snapshots")
    args.snapshot_dir = args.snapshot_dir or "."
    if args.procstat == "":
        args.procstat = None
    if args.body_file:
        body = open(args.body_file, "rb").read()
        meta = {"body_bytes": len(body), "body_sha256": __import__("hashlib").sha256(body).hexdigest(),
                "body_source": os.path.abspath(args.body_file)}
    else:
        body, meta = build_body(args)
        meta["body_source"] = "synthesized"
    if args.dump_body:
        os.makedirs(os.path.dirname(args.dump_body) or ".", exist_ok=True)
        with open(args.dump_body, "wb") as f:
            f.write(body)
    doc = asyncio.run(run(args, body))
    doc["body"] = meta
    text = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w") as f:
            f.write(text)
        print(f"[raw_load] 结果 -> {args.out}", file=sys.stderr)
    sys.stdout.write(text)
    return 0 if doc["requests_failed_in_window"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
