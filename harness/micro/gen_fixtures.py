#!/usr/bin/env python3
"""生成 D 线微基准的公共 fixture（Rust / Python 两侧共用同一份字节）。

设计原则（对齐 plan/experiment-matrix.md §4 的验收判据）：

* **同输入**：chat 请求体 / 渲染出的 prompt / EngineCoreRequest / 响应体
  都是文件，两侧读同一份，sha256 进 manifest。
* **同尺寸**：ISL 档位不用字符数拍脑袋，用**真实 Qwen3-0.6B tokenizer**
  （`tokenizers` 0.22.2）编码后计数，目标 1024 / 8192 token；
  prompt 里的 `prompt_token_ids` 也是同一支 tokenizer 的**真实 id**。
* **可引用**：语料 unit 与 tools 规格沿用 `tokenizer` 项目
  `harness/python/corpora.py`（同一支模型、同一套 tools），
  这样本文件的尺寸与那份 Python 基线可以直接对照。

产出（默认 `<repo>/harness/micro/fixtures/`）：

    chat_template.jinja             Qwen3-0.6B 的 chat template（来自 tokenizer_config.json）
    chat_request_<tag>.json         OpenAI chat 请求体（含 tools），tag = 1k / 8k
    engine_core_request_<tag>.json  EngineCoreRequest 的字段取值（JSON，便于两侧读同一份）
    response_osl128.json            非流式响应体（OSL=128）
    stream_chunks_osl128.json       流式分块（128 个 content delta + finish chunk）
    fixtures_manifest.json          尺寸 / token 数 / sha256 / 渲染结果 sha256

用法见 --help。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import time
from pathlib import Path

# --------------------------------------------------------------------- 语料
# 与 tokenizer/harness/python/corpora.py 同源（同一支模型、同一套 unit），
# 便于与本项目引用的 Python 侧基线（encode 1.47 µs/token、Jinja 50–70 µs）对齐。
EN_UNIT = (
    "The quick brown fox jumps over the lazy dog, and the pipeline moves "
    "tokens through the frontend renderer before the engine core ever sees "
    "them. "
)

ZH_UNIT = (
    "分词器把用户消息渲染成聊天模板，再编码成 token 序列送进推理引擎；"
    "在线服务的首字延迟里包含了这段纯 CPU 的前端开销。"
)

CODE_UNIT = (
    "def tokenize(text: str, *, add_special_tokens: bool = True) -> list[int]:\n"
    "    ids = tokenizer.encode(text, add_special_tokens=add_special_tokens)\n"
    "    return [int(i) for i in ids]\n\n"
)

MIX_UNIT = EN_UNIT + ZH_UNIT + CODE_UNIT

# 与 tokenizer 项目同一套两个 function 定义（tools 会整体渲染进 prompt）。
TOOL_SPECS = [
    {
        "type": "function",
        "function": {
            "name": "get_current_weather",
            "description": "Get the current weather in a given location.",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "City and state, e.g. 'Shanghai, CN'.",
                    },
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
                },
                "required": ["location"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_forecast",
            "description": "Get the multi-day weather forecast for a location.",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {"type": "string", "description": "City name."},
                    "days": {
                        "type": "integer",
                        "description": "How many days ahead (1-14).",
                        "minimum": 1,
                        "maximum": 14,
                    },
                },
                "required": ["location", "days"],
            },
        },
    },
]

ISL_TAGS = [("1k", 1024), ("8k", 8192)]
OSL = 128


# ------------------------------------------------------------------- 工具函数
def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def make_text(tok, target_tokens: int, unit: str = MIX_UNIT) -> tuple[str, int]:
    """生成恰好≈ target_tokens 个 token 的文本（转写自 tokenizer 项目 corpora.py）。"""
    unit_ids = tok.encode(unit, add_special_tokens=False).ids
    if not unit_ids:
        raise ValueError("unit tokenizes to 0 ids")

    if target_tokens < len(unit_ids):
        lo, hi = 1, len(unit)
        while lo < hi:
            mid = (lo + hi) // 2
            if len(tok.encode(unit[:mid], add_special_tokens=False).ids) >= target_tokens:
                hi = mid
            else:
                lo = mid + 1
        text = unit[:lo]
        while len(tok.encode(text, add_special_tokens=False).ids) > target_tokens and len(text) > 1:
            text = text[:-1]
        return text, len(tok.encode(text, add_special_tokens=False).ids)

    reps = max(1, round(target_tokens / len(unit_ids)))
    text = unit * reps
    ids = tok.encode(text, add_special_tokens=False).ids
    while len(ids) < target_tokens:
        text += unit
        ids = tok.encode(text, add_special_tokens=False).ids
    while len(ids) > target_tokens and len(text) > len(unit):
        text = text[: -len(unit)]
        ids = tok.encode(text, add_special_tokens=False).ids
    return text, len(ids)


def write_json(path: Path, payload) -> dict:
    """紧凑写出 JSON（模拟真实客户端 / 服务端的线上字节）。"""
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    data = text.encode("utf-8")
    path.write_bytes(data)
    return {
        "path": path.name,
        "bytes": len(data),
        "sha256": sha256_bytes(data),
        "lines": 1,
    }


# --------------------------------------------------------------- 各类 fixture
def build_chat_request(content: str) -> dict:
    return {
        "model": "Qwen3-0.6B",
        "messages": [{"role": "user", "content": content}],
        "tools": TOOL_SPECS,
        "tool_choice": "auto",
        "max_tokens": OSL,
        "temperature": 0.6,
        "top_p": 0.95,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }


def build_engine_core_request(token_ids: list[int], request_id: str) -> list:
    """EngineCoreRequest 的字段取值 —— **20 元素数组**，与线上 msgpack 同形。

    为什么是数组而不是对象：两侧的 `EngineCoreRequest` 都是"数组式"结构
    （Rust `serde_tuple`、Python `msgspec.Struct(array_like=True)`），
    真实 payload 就是 msgpack 数组。fixture 用数组才能让两侧解同一份输入。

    注意：这是**共享输入**，不是线上字节。两侧各自把它装进自己的结构体：
      * Rust：`serde_tuple` 的 20 元素数组 + 全量 map（不做 omit_defaults）
      * Python：msgspec 的 `array_like=True, omit_defaults=True`（默认值会被省掉）
    两侧编码出的字节数**本来就不同**，这正是 D3 要测的一个结论。
    """
    # 顺序与 rust/src/engine-core-client/src/protocol/request.rs 的
    # `EngineCoreRequest` 字段顺序一致（20 个）。
    return [
        request_id,
        token_ids,
        None,
        {
            "temperature": 0.6,
            "top_p": 0.95,
            "top_k": 0,
            "seed": 42,
            "max_tokens": OSL,
            "min_tokens": 0,
            "thinking_token_budget": None,
            "logprobs": None,
            "prompt_logprobs": None,
            "min_p": 0.0,
            "frequency_penalty": 0.0,
            "presence_penalty": 0.0,
            "repetition_penalty": 1.0,
            "repetition_detection": None,
            "stop_token_ids": [151643, 151645],
            "eos_token_id": 151645,
            "all_stop_token_ids": [151643, 151645],
            "logit_bias": None,
            "allowed_token_ids": None,
            "bad_words_token_ids": None,
            "structured_outputs": None,
            "logprob_token_ids": None,
            "skip_reading_prefix_cache": False,
            "extra_args": None,
        },
        None,
        1758770000.125,
        None,
        None,
        None,
        None,
        None,
        0,
        0,
        0,
        None,
        False,
        request_id,
        None,
        None,
        False,
    ]


def build_response_body(completion_text: str, prompt_tokens: int) -> dict:
    return {
        "id": "chatcmpl-dmicro-0001",
        "object": "chat.completion",
        "created": 1758770000,
        "model": "Qwen3-0.6B",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": completion_text},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": OSL,
            "total_tokens": prompt_tokens + OSL,
        },
    }


def build_stream_chunks(piece_texts: list[str]) -> list[dict]:
    """OSL=128 的流式分块：每 token 一个 delta + 一个 finish chunk。"""
    chunks = []
    for index, piece in enumerate(piece_texts):
        chunks.append(
            {
                "id": "chatcmpl-dmicro-0002",
                "object": "chat.completion.chunk",
                "created": 1758770001,
                "model": "Qwen3-0.6B",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"content": piece} if index else {"role": "assistant", "content": piece},
                        "finish_reason": None,
                    }
                ],
            }
        )
    chunks.append(
        {
            "id": "chatcmpl-dmicro-0002",
            "object": "chat.completion.chunk",
            "created": 1758770001,
            "model": "Qwen3-0.6B",
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
        }
    )
    return chunks


def render_prompt(template_text: str, request: dict) -> str:
    """用 Python Jinja2（3.1.6，与 vLLM 依赖同版本）渲染，用于记录 prompt token 数。"""
    from jinja2.sandbox import ImmutableSandboxedEnvironment

    def tojson(value, indent=None, ensure_ascii=False, sort_keys=False, separators=None):
        return json.dumps(
            value,
            ensure_ascii=ensure_ascii,
            indent=indent,
            sort_keys=sort_keys,
            separators=separators,
        )

    # 与 transformers 的 chat template 环境一致（默认 Undefined；Qwen3 模板里
    # 有 `{%- if message.tool_calls %}` 这类对缺失字段的宽松判断）。
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    env.filters["tojson"] = tojson
    template = env.from_string(template_text)
    return template.render(
        messages=request["messages"],
        add_generation_prompt=True,
        tools=request["tools"],
        **request.get("chat_template_kwargs", {}),
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="生成 D 线微基准 fixture（chat 请求 / EngineCoreRequest / 响应 / SSE 分块）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "--tokenizer",
        default=os.environ.get("DMICRO_TOKENIZER", "REPO_HOME/models/Qwen3-0.6B/tokenizer.json"),
        help="HF tokenizer.json（默认 Qwen3-0.6B，与 tokenizer 项目同一支）",
    )
    ap.add_argument(
        "--tokenizer-config",
        default=os.environ.get(
            "DMICRO_TOKENIZER_CONFIG", "REPO_HOME/models/Qwen3-0.6B/tokenizer_config.json"
        ),
        help="含 chat_template 的 tokenizer_config.json",
    )
    ap.add_argument("--out", default=None, help="输出目录（默认 harness/micro/fixtures）")
    ap.add_argument("--isl", default="1k,8k", help="生成哪些 ISL 档（默认 1k,8k）")
    args = ap.parse_args()

    from tokenizers import Tokenizer

    root = Path(__file__).resolve().parents[2]
    out = Path(args.out) if args.out else Path(__file__).resolve().parent / "fixtures"
    out.mkdir(parents=True, exist_ok=True)

    tok = Tokenizer.from_file(args.tokenizer)
    cfg = json.loads(Path(args.tokenizer_config).read_text(encoding="utf-8"))
    template_text = cfg["chat_template"]

    manifest: dict = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "generated_at_epoch": int(time.time()),
        "host": platform.node(),
        "generator_script": Path(__file__).name,
        "generator_script_sha256": sha256_file(Path(__file__)),
        "tokenizer_json": {
            "path": args.tokenizer,
            "sha256": sha256_file(Path(args.tokenizer)),
            "bytes": Path(args.tokenizer).stat().st_size,
        },
        "tokenizer_config": {
            "path": args.tokenizer_config,
            "sha256": sha256_file(Path(args.tokenizer_config)),
        },
        "notes": [
            "chat_template 取自 tokenizer_config.json（Qwen3-0.6B），与 tokenizer 项目基线同一支模型",
            "语料 unit 与 tools 规格沿用 tokenizer/harness/python/corpora.py",
            "所有尺寸都用真实 tokenizer 计数，不用字符数折算",
        ],
        "fixtures": {},
        "inputs": {},
    }

    template_path = out / "chat_template.jinja"
    template_path.write_text(template_text, encoding="utf-8")
    tmpl_bytes = template_path.read_bytes()
    manifest["fixtures"]["chat_template.jinja"] = {
        "bytes": len(tmpl_bytes),
        "sha256": sha256_bytes(tmpl_bytes),
    }

    wanted = {tag.strip() for tag in args.isl.split(",") if tag.strip()}
    for tag, target_tokens in ISL_TAGS:
        if tag not in wanted:
            continue
        content, actual_tokens = make_text(tok, target_tokens)
        request = build_chat_request(content)
        req_info = write_json(out / f"chat_request_{tag}.json", request)

        prompt = render_prompt(template_text, request)
        prompt_tokens = len(tok.encode(prompt, add_special_tokens=False).ids)
        content_tokens = len(tok.encode(content, add_special_tokens=False).ids)

        request_ids = tok.encode(prompt, add_special_tokens=False).ids
        ecr = build_engine_core_request(request_ids[:target_tokens], f"chatcmpl-dmicro-{tag}")
        ecr_info = write_json(out / f"engine_core_request_{tag}.json", ecr)

        manifest["fixtures"][req_info["path"]] = req_info
        manifest["fixtures"][ecr_info["path"]] = ecr_info
        manifest["inputs"][tag] = {
            "requested_isl_tokens": target_tokens,
            "user_content_tokens": content_tokens,
            "user_content_chars": len(content),
            "user_content_bytes": len(content.encode("utf-8")),
            "user_content_tokens_actual": actual_tokens,
            "rendered_prompt_chars": len(prompt),
            "rendered_prompt_bytes": len(prompt.encode("utf-8")),
            "rendered_prompt_tokens": prompt_tokens,
            "rendered_prompt_sha256": sha256_bytes(prompt.encode("utf-8")),
            "chat_request_bytes": req_info["bytes"],
            "chat_request_sha256": req_info["sha256"],
            "engine_core_request_fields": len(ecr),
            "engine_core_prompt_token_ids": len(ecr[1]),
            "engine_core_request_bytes": ecr_info["bytes"],
        }

    # 响应体：OSL=128。先编码一段够长的文本，切出**恰好 128 个 token id**，
    # 再逐个 id 解码成文本分片（与流式 SSE 的逐 token 分片同构）。
    seed_text, _ = make_text(tok, OSL * 2)
    ids = tok.encode(seed_text, add_special_tokens=False).ids[:OSL]
    pieces = [tok.decode([i]) for i in ids]
    completion_text = "".join(pieces)
    completion_tokens = len(ids)
    assert completion_tokens == OSL, completion_tokens
    response = build_response_body(completion_text, prompt_tokens=1291)
    resp_info = write_json(out / f"response_osl{OSL}.json", response)
    chunks = build_stream_chunks(pieces)
    chunk_info = write_json(out / f"stream_chunks_osl{OSL}.json", chunks)
    manifest["fixtures"][resp_info["path"]] = resp_info
    manifest["fixtures"][chunk_info["path"]] = chunk_info
    manifest["inputs"]["osl"] = {
        "osl_tokens": OSL,
        "completion_tokens": len(ids),
        "completion_chars": len(completion_text),
        "completion_bytes": len(completion_text.encode("utf-8")),
        "response_bytes": resp_info["bytes"],
        "response_sha256": resp_info["sha256"],
        "stream_chunks": len(chunks),
        "stream_chunk_file_bytes": chunk_info["bytes"],
        "stream_chunk_file_sha256": chunk_info["sha256"],
        "stream_chunk_avg_bytes": round(chunk_info["bytes"] / len(chunks), 1),
    }

    manifest_path = out / "fixtures_manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest["inputs"], ensure_ascii=False, indent=2))
    print(f"[gen_fixtures] 写出 {len(manifest['fixtures'])} 个文件 → {out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
