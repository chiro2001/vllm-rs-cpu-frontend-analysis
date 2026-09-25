#!/usr/bin/env bash
# 资源受限执行器 —— **本项目所有 CPU 密集/内存密集操作都必须经它**。
#
# 背景：本机 LOCAL_HOST 是共享开发机（12 核 / 29 GiB），比较脆弱。
# 用户明确要求：不要长时间占用过多 CPU（>75%）与过大内存。
#
# 本脚本做的事：
#   1. 把进程绑到指定核（默认 4-7，共 4 核），避免干扰其他用户与交互
#   2. 限制线程池规模（rayon / OpenMP / MKL / tokenizers / numpy）
#   3. 限制地址空间（默认 8 GiB，防止 OOM 拖垮整机）
#   4. 若是 cargo 调用，自动限制并行编译 job 数
#
# 用法:
#   scripts/limit.sh <命令...>                 # 默认 4 核 + 8 GiB
#   CORES=4-5 scripts/limit.sh <命令...>        # 绑到核 4、5（即 2 核）
#   CORES=2 scripts/limit.sh <命令...>          # ⚠️ 绑到核 2，**只有 1 核**！
#   MEM_GB=4 scripts/limit.sh <命令...>         # 收紧内存
#   NO_ULIMIT=1 scripts/limit.sh <命令...>      # 不设 ulimit（少数场景需要）
#
# 例:
#   scripts/limit.sh cargo bench -p vllm-tokenizer
#   CORES=4-5 scripts/limit.sh ./target/release/demo
#
# ⚠️ **CORES 是"绑到哪些核"，不是"多少个核"**（踩过的坑）：
#   CORES=2   → taskset -c 2   → 1 个核
#   CORES=4-5 → taskset -c 4-5 → 2 个核
#   CORES=4-7 → 默认           → 4 个核
#   要 N 个核请写区间（如 2 核 = `4-5`）。运行时会把实际核数打出来，
#   引用数据时请以那行输出或 manifest 里的 `threads_effective` / `cpu_affinity` 为准。
#
# 注意：ulimit -v 对 Rust/C 程序有效，但某些 JIT / 大页分配会误伤。
# 若命令因 "out of memory" 之类的分配失败退出，先确认是否 ulimit 所致。
set -euo pipefail

CORES="${CORES:-4-7}"
MEM_GB="${MEM_GB:-8}"
JOBS="${JOBS:-4}"

if [[ $# -eq 0 ]]; then
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# 线程池上限：按绑定的核数来，避免"绑了 4 核却开 12 线程"这种自相矛盾的配置
NCORES=$(python3 - "$CORES" <<'PY'
import sys
spec = sys.argv[1]
total = 0
for part in spec.split(','):
    if '-' in part:
        a, b = part.split('-')
        total += int(b) - int(a) + 1
    else:
        total += 1
print(total)
PY
)

export RAYON_NUM_THREADS="$NCORES"
export OMP_NUM_THREADS="$NCORES"
export MKL_NUM_THREADS="$NCORES"
export NUMEXPR_NUM_THREADS="$NCORES"
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"
export CARGO_BUILD_JOBS="$JOBS"

if [[ "${NO_ULIMIT:-0}" != "1" ]]; then
  # 地址空间上限（KiB）。取 1.6× 的名义值，给 mmap/vm 留余量，
  # 否则 Rust 的 arena 与 Python 的虚拟地址占用会假性触顶。
  LIMIT_KB=$(( MEM_GB * 1024 * 1024 * 8 / 5 ))
  ulimit -v "$LIMIT_KB" 2>/dev/null || echo "[limit] 警告: 无法设置 ulimit -v（已忽略）" >&2
fi

echo "[limit] cores=$CORES ($NCORES) mem=${MEM_GB}GiB jobs=$JOBS cmd=$*" >&2
echo "[limit] 注意：CORES=$CORES 表示绑到这些核（共 $NCORES 个核），不是核数" >&2
exec taskset -c "$CORES" "$@"
