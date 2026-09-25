#!/usr/bin/env bash
# 无卡容器执行器：在本机 x86_64 上跑 vLLM 0.26.0 的 tokenizer / renderer 代码路径。
#
# 为什么需要它：镜像里的 torch_npu 需要 libhccl.so / libascend_hal.so，而本机
# 没有 NPU。镜像自带一套 CPU 桩 + 一个打过环境变量补丁的 wrapper
# （/opt/va26-scripts/run_real_test_official.sh），本脚本只是把它包成稳定入口。
#
# 用法:
#   scripts/docker_run.sh <python 脚本路径>        # 在 /workspace 下执行
#   scripts/docker_run.sh -c '<python 代码>'       # 直接执行代码
#   scripts/docker_run.sh --shell                  # 进交互 shell
#
# 例:
#   scripts/docker_run.sh -c 'from vllm.tokenizers.hf import CachedHfTokenizer; \
#     t = CachedHfTokenizer.from_pretrained("/models/Qwen3-0.6B"); print(t.vocab_size)'
#
# 已验证事实（2026-09-24）:
#   - 返回 CachedQwen2Tokenizer（transformers v5 的 TokenizersBackend 路径）
#   - Qwen3-0.6B: vocab_size=151643, max_token_id=151668, max_chars_per_token=128
#   - 冷启动约 15 s（主要是 import torch / vllm）
#   - 启动时会刷 `[STUBBT] swallowed foreign SIGSEGV/SIGABRT install`，是桩的
#     正常输出，可忽略
#
# 关键坑（都已踩过）:
#   1. LD_LIBRARY_PATH 里 devlib（放 libascend_hal.so）**必须排在真 lib64 之后**，
#      否则 devlib 的 libge_runner.so 会遮蔽真的，报
#      `undefined symbol: _ZN2ge13StatusFactory8InstanceEv`。
#   2. /opt/va26-repo/stubs/acl/ 里的桩是 **aarch64** 的，x86 用不了；
#      x86 桩在 /opt/va26-stubs/。
#   3. 直接设 LD_LIBRARY_PATH 很难一次配对，用镜像自带 wrapper 最省事。
#
# 资源上限（本机脆弱，见 plan/COORDINATION.md §9）:
#   默认 --cpus=6 --memory=8g --memory-swap=8g --shm-size=2g。
#   可用环境变量覆盖：DOCKER_CPUS / DOCKER_MEM。
#   注意：这是**容器级**上限；若容器内还要跑多线程负载，再套 scripts/limit.sh。
set -euo pipefail

IMAGE="${TOKENIZER_IMAGE:-local/vllm-ascend-stub-x86:v0.26.0rc1-a3-cpuonly-20260922}"
MODELS="${TOKENIZER_MODELS:-$HOME/models}"
HOST_ROOT="${TOKENIZER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DOCKER_CPUS="${DOCKER_CPUS:-6}"
DOCKER_MEM="${DOCKER_MEM:-8g}"

# 统一的资源限制参数
CGROUP_ARGS=(--cpus="$DOCKER_CPUS" --memory="$DOCKER_MEM" --memory-swap="$DOCKER_MEM" --shm-size=2g)

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

case "${1:-}" in
  -h|--help|"") usage ;;
  --shell)
    exec docker run --rm -it "${CGROUP_ARGS[@]}" \
      -v "$MODELS:/models:ro" -v "$HOST_ROOT:/workspace" \
      --entrypoint bash "$IMAGE" -l
    ;;
  -c)
    # 走临时文件而不是 `python -c`：避免多层引号把代码啃掉。
    TMP_CODE="$(mktemp -t tokenizer_code_XXXXXX.py)"
    printf '%s\n' "${2:?missing code}" > "$TMP_CODE"
    trap 'rm -f "$TMP_CODE"' EXIT
    exec docker run --rm \
      "${CGROUP_ARGS[@]}" \
      -e PYTHONUNBUFFERED=1 \
      -v "$MODELS:/models:ro" -v "$HOST_ROOT:/workspace" \
      -v "$TMP_CODE:/workspace/_inline_code.py:ro" \
      --entrypoint bash "$IMAGE" \
      -lc "cd /workspace && bash /opt/va26-scripts/run_real_test_official.sh /workspace/_inline_code.py"
    ;;
  *)
    SCRIPT="$1"; shift
    exec docker run --rm \
      "${CGROUP_ARGS[@]}" \
      -e PYTHONUNBUFFERED=1 \
      -v "$MODELS:/models:ro" -v "$HOST_ROOT:/workspace" \
      --entrypoint bash "$IMAGE" \
      -lc "cd /workspace && bash /opt/va26-scripts/run_real_test_official.sh /workspace/${SCRIPT} $*"
    ;;
esac
