"""msgspec 版的 EngineCoreRequest / SamplingParams（vLLM 0.26.0 同形）。

形状直接抄自 `vllm/v1/engine/__init__.py` 与 `vllm/sampling_params.py`：
`array_like=True`（msgpack 里就是数组）、`omit_defaults=True`（默认值不编码）、
`gc=False`。**真实 vLLM 的 SamplingParams 字段更多（约 40 个）**，这里保留
Rust 侧同款的 24 个字段，好让两侧"同尺寸"成立；差异写进 docs/05。

单独成模块的原因：msgspec 在解析注解时需要**模块级**的名字空间，
函数内定义嵌套 Struct 会因为 `SamplingParams` 找不到而报 NameError。
"""

from __future__ import annotations

import msgspec


class RepetitionDetectionParams(msgspec.Struct, omit_defaults=True):
    max_pattern_size: int
    min_pattern_size: int = 0
    min_count: int = 0


class SamplingParams(msgspec.Struct, omit_defaults=True):
    temperature: float = 1.0
    top_p: float = 1.0
    top_k: int = 0
    seed: int | None = None
    max_tokens: int = 16
    min_tokens: int = 0
    thinking_token_budget: int | None = None
    logprobs: int | None = None
    prompt_logprobs: int | None = None
    min_p: float = 0.0
    frequency_penalty: float = 0.0
    presence_penalty: float = 0.0
    repetition_penalty: float = 1.0
    repetition_detection: RepetitionDetectionParams | None = None
    stop_token_ids: list[int] = msgspec.field(default_factory=list)
    eos_token_id: int | None = None
    all_stop_token_ids: list[int] = msgspec.field(default_factory=list)
    logit_bias: dict[int, float] | None = None
    allowed_token_ids: list[int] | None = None
    bad_words_token_ids: list[list[int]] | None = None
    structured_outputs: dict | None = None
    logprob_token_ids: list[int] | None = None
    skip_reading_prefix_cache: bool | None = None
    extra_args: dict | None = None


class EngineCoreRequest(msgspec.Struct, array_like=True, omit_defaults=True, gc=False):
    request_id: str
    prompt_token_ids: list[int] | None
    mm_features: list | None
    sampling_params: SamplingParams | None
    pooling_params: dict | None
    arrival_time: float
    lora_request: dict | None = None
    cache_salt: str | None = None
    data_parallel_rank: int | None = None
    prompt_embeds: object | None = None
    prompt_is_token_ids: list[bool] | None = None
    client_index: int = 0
    current_wave: int = 0
    priority: int = 0
    trace_headers: dict[str, str] | None = None
    resumable: bool = False
    external_req_id: str | None = None
    reasoning_ended: bool | None = None
    reasoning_parser_kwargs: dict | None = None
    abort_immediately: bool = False
