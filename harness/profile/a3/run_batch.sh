#!/usr/bin/env bash
# **在本机运行**：同步 + 校验 → 在 chip4 锁里跑一个 batch 事务 → 取回结果。
#
# 这是 B 线在 REMOTE_HOST 上的主入口（比 `run_point_remote.sh` 更常用：
# 一次锁里跑多个点，摊掉模型加载时间）。
#
# 用法:
#   harness/profile/a3/run_batch.sh --run b-a1 --side rust --port 18300 \
#       --max-model-len 4096 --max-num-seqs 8 \
#       --point A1:1024:128:64:1:perf:fp --point A1-noperf:1024:128:64:1:none
#   run_batch.sh --help
#
# --point 格式：tag:ISL:OSL:num_prompts:max_concurrency:mode[:callgraph]
#   mode = perf（火焰图）| stat（perf stat）| none（只记吞吐/CPU，做采样开销对照）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_ROOT="$(cd "$HERE/../../.." && pwd)"
# 私有子树：四条线共用同一个远端项目根，`sync.sh --delete` 时代曾经互相删过脚本。
# 现在默认不删，但**仍然隔离**更干净：B 线一律推/读 `~/projects/vllm/vllm-rs/b-profile/`。
A3_PROJECT="${A3_PROJECT:-projects/vllm/vllm-rs/b-profile}"
A3_HOST="${A3_HOST:-REMOTE_HOST}"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; SIDE=""; PORT="18300"; CHIP=4; MAX_MODEL_LEN="4096"; MAX_NUM_SEQS="8"
WARMUP=4; POINTS=(); FETCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN="$2"; shift 2 ;;
    --side) SIDE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --chip) CHIP="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --max-num-seqs) MAX_NUM_SEQS="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --point) POINTS+=("$2"); shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$SIDE" && ${#POINTS[@]} -gt 0 ]] || { usage; exit 2; }

echo "===== [1/3] 同步到私有子树 $A3_PROJECT ====="
"$PROFILE_ROOT/harness/a3/sync.sh" push --into b-profile
ssh -o BatchMode=yes "$A3_HOST" "test -x ~/$A3_PROJECT/harness/profile/a3/batch_remote.sh" \
  || { echo "[error] 远端缺少 batch_remote.sh（$A3_PROJECT）；检查 sync.sh --into 的路径拼接" >&2; exit 1; }
echo "    ✓ 远端脚本就位（$A3_PROJECT）"

echo "===== [2/3] 在 chip4 锁里跑 batch（$SIDE，${#POINTS[@]} 个点）====="
# chip_lock.sh 在远端先 `cd $HOME/projects/vllm/vllm-rs`，所以这里要给**相对该根**的路径
REMOTE_SCRIPT="${A3_PROJECT#projects/vllm/vllm-rs/}/harness/profile/a3/batch_remote.sh"
ARGS=(env "CHIP=$CHIP" "A3_PROJECT=$A3_PROJECT" "$REMOTE_SCRIPT"
      --run "$RUN" --side "$SIDE" --port "$PORT" --chip "$CHIP"
      --max-model-len "$MAX_MODEL_LEN" --max-num-seqs "$MAX_NUM_SEQS" --warmup "$WARMUP")
# ⚠️ 这一行曾经在一次 patch 中被误删，后果是**所有 --point 参数都没传**，
#    远端 batch_remote.sh 因 POINTS 为空而打印 usage 并退出码 2，
#    白白占掉一个 chip4 锁窗口（实测 b-t5 踩过）。改动本文件后请冒烟一次。
for p in "${POINTS[@]}"; do ARGS+=(--point "$p"); done
# ⚠️ 不能让远端失败直接终止本脚本：`set -o pipefail` 下 chip_lock 的非零退出会
#    跳过 [3/3] 取回结果 —— 那意味着**已经采到的点也白采了**（实测踩过：
#    一次 b-t4 在 [2/3] 静默退出，远端一个点都没取回）。
#    所以这里显式吃掉 rc，把「取回」当作无条件动作。
set +e
"$PROFILE_ROOT/harness/a3/chip_lock.sh" -- "${ARGS[@]}" 2>&1 | tail -60
LOCK_RC=${PIPESTATUS[0]}
set -e
[[ "$LOCK_RC" == "0" ]] || echo "[warn] chip_lock/远端 batch 退出码 $LOCK_RC（继续取回已有结果）"

if [[ "$FETCH" == "1" ]]; then
  echo "===== [3/3] 取回结果 ====="
  mkdir -p "$PROFILE_ROOT/runs/$RUN"
  for p in "${POINTS[@]}"; do
    tag="${p%%:*}"
    # ⚠️ `--exclude='*.perf.data'` 挡不住 `perf.data` 本身（它不匹配 `*.perf.data`），
    #    而远端那个文件属主是 root（sudo perf 创建）⇒ rsync 会因 Permission denied
    #    报 code 23 并中断整轮取回（实测）。用显式排除 + 容忍部分失败。
    rsync -a --exclude='perf.data' --exclude='perf.data.old' --exclude='*.log' \
      --exclude='symfs/' \
      "$A3_HOST:$A3_PROJECT/runs/$RUN/$tag-$SIDE/" "$PROFILE_ROOT/runs/$RUN/$tag-$SIDE/" \
      && echo "  ✓ runs/$RUN/$tag-$SIDE" || echo "  ⚠️ runs/$RUN/$tag-$SIDE 取回不完整（续下一个）"
  done
fi
echo "===== 完成。本地折叠："
for p in "${POINTS[@]}"; do
  tag="${p%%:*}"
  echo "  harness/profile/a3/collapse_a3.sh --in-dir runs/$RUN/$tag-$SIDE --tag a3-$tag-$SIDE --by-segment"
done
