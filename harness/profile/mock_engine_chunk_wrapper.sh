#!/usr/bin/env bash
# 把上游 `vllm-mock-engine` 包一层，**追加** `--output-token-chunk-size`。
#
# 为什么需要：`harness/common/stack.sh` 用固定的参数起 mock engine（chunk size 写死默认值 1），
# 而 B 线的原始数据是 chunk=1 的（每 output token 一个 `EngineCoreOutput` ⇒ 每 token 一次
# ZMQ 收包）。要回答「前端 CPU 里约一半的 stime 是不是"每 token 一次系统调用"造成的」，
# 必须能改这个旋钮。shared harness 对本线只读，所以这里走**环境变量覆盖**
# `MOCK_ENGINE_BIN=<本脚本>`，不修改共享文件。
#
# 用法（由 cpu_windows.sh --engine-chunk 自动调用，也可手用）：
#   MOCK_ENGINE_BIN=harness/profile/mock_engine_chunk_wrapper.sh \
#   MOCK_CHUNK_SIZE=32 harness/common/stack.sh start --run runs/demo
set -euo pipefail
REAL_BIN="${MOCK_ENGINE_REAL_BIN:-$HOME/.cache/d-nextgen-mock/target/release/vllm-mock-engine}"
[[ -x "$REAL_BIN" ]] || { echo "[chunk-wrapper] 找不到真实 mock engine：$REAL_BIN" >&2; exit 2; }
exec "$REAL_BIN" --output-token-chunk-size "${MOCK_CHUNK_SIZE:-1}" "$@"
