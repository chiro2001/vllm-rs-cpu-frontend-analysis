#!/usr/bin/env bash
# **在本机运行**：把「同步脚本 → REMOTE_HOST 上在 chip4 锁里跑一个 profiling 点 → 取回结果」
# 打包成一条命令（避免手写三层引号 —— `chip_lock.sh` 走 `bash -c`，引号越简单越安全）。
#
# 用法:
#   harness/profile/a3/run_point_remote.sh --run b-a1 --side rust --tag A1 --port 18300 \
#       --chip 4 --input-len 1024 --output-len 128 --num-prompts 64 --max-concurrency 1 \
#       [--call-graph fp] [--freq 999] [--no-perf] [--perf-stat] [--max-model-len N] [--max-num-seqs N]
#   run_point_remote.sh --help
#
# 它做的事（顺序很关键）：
#   1) `sync.sh push` 把 harness/ 推到 REMOTE_HOST（远端只作执行场所）；
#   2) 若栈没起：`ab_serve.sh start`（带 --max-model-len/--max-num-seqs）；
#   3) 在 `chip_lock.sh` 里跑 `prof_point.sh`（**用卡必须持锁**）；
#   4) `rsync` 取回该点的结果目录（不含 perf.data）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_ROOT="$(cd "$HERE/../../.." && pwd)"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; SIDE=""; TAG=""; PORT="18300"; CHIP=4
INPUT_LEN=1024; OUTPUT_LEN=128; NUM_PROMPTS=64; MAX_CONC=1; WARMUP=4
CALLGRAPH="fp"; FREQ=999; MODE="perf"   # perf | stat | both | none
MAX_MODEL_LEN=""; MAX_NUM_SEQS=""; START_STACK=1; FETCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN="$2"; shift 2 ;;
    --side) SIDE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --chip) CHIP="$2"; shift 2 ;;
    --input-len) INPUT_LEN="$2"; shift 2 ;;
    --output-len) OUTPUT_LEN="$2"; shift 2 ;;
    --num-prompts) NUM_PROMPTS="$2"; shift 2 ;;
    --max-concurrency) MAX_CONC="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --call-graph) CALLGRAPH="$2"; shift 2 ;;
    --freq) FREQ="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --max-num-seqs) MAX_NUM_SEQS="$2"; shift 2 ;;
    --no-start) START_STACK=0; shift ;;
    --no-fetch) FETCH=0; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$SIDE" && -n "$TAG" ]] || { usage; exit 2; }

PERF_FLAGS=""
case "$MODE" in
  perf) PERF_FLAGS="";;
  none) PERF_FLAGS="--no-perf";;
  stat) PERF_FLAGS="--no-perf --perf-stat";;
  both) PERF_FLAGS="--perf-stat";;
  *) echo "--mode 必须是 perf|stat|both|none" >&2; exit 2 ;;
esac

echo "===== [1/4] 同步 harness/ 到 REMOTE_HOST ====="
"$PROFILE_ROOT/harness/a3/sync.sh" push

# ⚠️ 踩过的坑（并发 push 的 `--delete` 竞争）：
#    `sync.sh push` 用 `rsync -a --delete` 把**本 worktree** 的 harness/ 覆盖到
#    REMOTE_HOST 的**同一个** `~/projects/vllm/vllm-rs/harness/`。四条线各有自己的 worktree，
#    C 线的 harness/ 里没有 `profile/a3/`，它 push 一次就会把本目录**删掉**
#    （实测：刚 push 完、轮到我在锁里跑时，脚本已经不在了 ⇒ "No such file or directory"）。
#    所以：push 之后必须**校验**，缺了就再推一次；两处都要在拿锁**之前**完成。
A3_HOST="${A3_HOST:-REMOTE_HOST}"
A3_PROJECT="${A3_PROJECT:-projects/vllm/vllm-rs}"
for attempt in 1 2 3; do
  if ssh -o BatchMode=yes "$A3_HOST" "test -x ~/$A3_PROJECT/harness/profile/a3/prof_point.sh"; then
    break
  fi
  echo "[warn] 远端缺少 harness/profile/a3/prof_point.sh（很可能是别的线并发 push 时被 --delete 删掉）⇒ 重新推送（第 $attempt 次）"
  sleep 3
  "$PROFILE_ROOT/harness/a3/sync.sh" push >/dev/null
done
ssh -o BatchMode=yes "$A3_HOST" "test -x ~/$A3_PROJECT/harness/profile/a3/prof_point.sh" \
  || { echo "[error] 连续 3 次推送后远端仍缺 prof_point.sh，中止" >&2; exit 1; }
echo "    ✓ 远端脚本就位"

if [[ "$START_STACK" == "1" ]]; then
  echo "===== [2/4] 起服务容器（chip$CHIP, side=$SIDE, port=$PORT）====="
  START_ARGS=(start --run "$RUN" --frontend "$SIDE" --chip "$CHIP" --port "$PORT")
  # ⚠️ ab_serve.sh 的 MAX_MODEL_LEN / MAX_NUM_SEQS / GPU_MEM 是**环境变量**，不是命令行参数
  #    （它只接 --run/--frontend/--chip/--port/--model/--tail）。
  echo "     MAX_MODEL_LEN=${MAX_MODEL_LEN:-4096} MAX_NUM_SEQS=${MAX_NUM_SEQS:-8}"
  MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}" MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}" \
    "$PROFILE_ROOT/harness/a3/ab_serve.sh" "${START_ARGS[@]}" 2>&1 | tail -6
else
  echo "===== [2/4] 跳过起栈（--no-start）====="
fi

echo "===== [3/4] 在 chip4 锁里跑 $TAG（$SIDE，$MODE）====="
# ⚠️ 踩过的坑：不要写成 `chip_lock.sh -- bash -lc '<相对路径>'`。
#    `chip_lock.sh` 已经在远端 `cd $HOME/projects/vllm/vllm-rs` 之后再 `bash -c`，
#    而我再套一层 **login shell**（`bash -lc`）会让它在启动时把 cwd 切回 `$HOME`，
#    于是相对路径 `harness/profile/a3/prof_point.sh` 找不到（实测报
#    "No such file or directory"，白等一次锁）。
#    ⇒ 直接把参数原样交给 chip_lock（它内部用 `printf %q` 拼成一条命令），
#      需要环境变量时用 `env VAR=...`。
# shellcheck disable=SC2086
"$PROFILE_ROOT/harness/a3/chip_lock.sh" -- env "CHIP=$CHIP" \
  harness/profile/a3/prof_point.sh --run "$RUN" --side "$SIDE" --tag "$TAG" \
  --port "$PORT" --input-len "$INPUT_LEN" --output-len "$OUTPUT_LEN" \
  --num-prompts "$NUM_PROMPTS" --max-concurrency "$MAX_CONC" --warmup "$WARMUP" \
  --freq "$FREQ" --call-graph "$CALLGRAPH" $PERF_FLAGS 2>&1 | tail -25

if [[ "$FETCH" == "1" ]]; then
  echo "===== [4/4] 取回 runs/$RUN/$TAG-$SIDE ====="
  mkdir -p "$PROFILE_ROOT/runs/$RUN"
  rsync -a --exclude='*.perf.data' --exclude='*.log' --exclude='wc' \
    "REMOTE_HOST:projects/vllm/vllm-rs/runs/$RUN/$TAG-$SIDE/" "$PROFILE_ROOT/runs/$RUN/$TAG-$SIDE/"
  ls -la "$PROFILE_ROOT/runs/$RUN/$TAG-$SIDE/" | head -12
fi

echo "===== 完成。本地折叠："
echo "  harness/profile/a3/collapse_a3.sh --in-dir runs/$RUN/$TAG-$SIDE --tag $TAG-$SIDE \
  --flame figures/02-flame-a3-$TAG-$SIDE.svg"
