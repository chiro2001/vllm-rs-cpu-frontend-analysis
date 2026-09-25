#!/usr/bin/env bash
# **在 REMOTE_HOST 上运行**：一次锁窗口里做完整事务 —— 起容器 → 跑 N 个 profiling 点 → 停容器。
#
# 为什么要有"批量"：每次 `ab_serve.sh start` 都要加载模型（实测 ~60–90 s），
# 而 chip4 锁是四条线共享的稀缺资源。把「同一个容器配置下的多个点」放进一次事务，
# 可以把每次锁持有时间压到几分钟，且不重复付模型加载的成本。
#
# 用法（**由 harness/profile/a3/run_batch.sh 调用**，也可手动在锁里跑）:
#   env CHIP=4 harness/profile/a3/batch_remote.sh \
#       --run b-a1 --side rust --port 18300 --max-model-len 4096 --max-num-seqs 8 \
#       --point A1:1024:128:64:1:perf:fp \
#       --point A1-noperf:1024:128:64:1:none
#   （--point 的格式：tag:isl:osl:num_prompts:max_concurrency:mode[:callgraph]，
#     mode = perf | stat | none）
#   batch_remote.sh --help
#
# 容器起停**复用共享的 `harness/a3/ab_serve.sh`**（`A3_LOCAL=1` 让它就地执行而不是 ssh 回自己）。
# 早期版本在这里复制了一份 docker run 参数 —— 那是重复实现，容易与共享脚本漂移，已放弃。
set -euo pipefail

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; SIDE=""; PORT="18300"; CHIP="${CHIP:-4}"
MAX_MODEL_LEN="4096"; MAX_NUM_SEQS="8"; WARMUP=4; START=1; STOP=1; TAG_SUFFIX=""
POINTS=()
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
    --no-start) START=0; shift ;;
    --no-stop) STOP=0; shift ;;
    --prune-perf-data) export KEEP_PERF_DATA=0; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$SIDE" && ${#POINTS[@]} -gt 0 ]] || { usage; exit 2; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# 远端的项目根（本仓库被 push 到的位置）：由 RUN 的父目录推出，
# 这样无论推在共享目录还是私有子树（`--into b-profile`）都能正确工作。
A3_PROJECT="${A3_PROJECT:-$(cd "$REPO_ROOT/.." && pwd)}"
say() { printf '[batch] %s\n' "$*"; }

# 默认**保留**远端 perf.data：重采一个点要再排一次 chip4 锁 + 90 s 模型加载，
# 而符号解析（symfs）可能要迭代几次 ⇒ 磁盘（几十 MB/点）比锁便宜得多。
# 体积敏感时用 `--prune-perf-data`（或远端手动清）。
export KEEP_PERF_DATA="${KEEP_PERF_DATA:-1}"

CONTAINER="vrs-ab-$RUN"

start_container() {
  # A3_PROJECT / MAX_MODEL_LEN / MAX_NUM_SEQS 都是 ab_serve.sh 认的环境变量
  A3_LOCAL=1 A3_PROJECT="$A3_PROJECT" \
  MAX_MODEL_LEN="$MAX_MODEL_LEN" MAX_NUM_SEQS="$MAX_NUM_SEQS" \
    "$REPO_ROOT/harness/a3/ab_serve.sh" start --run "$RUN" --frontend "$SIDE" \
      --chip "$CHIP" --port "$PORT" 2>&1 | tail -8
}

stop_container() { sudo -n docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "[batch] 已停 $CONTAINER" || true; }

# 容器内的模型由 ab_serve.sh 用 --max-model-len/--max-num-seqs 决定；
# 这里把本次配置记到运行目录，便于事后核对（口径纪律）。
mkdir -p "$REPO_ROOT/runs/$RUN"
printf 'side=%s port=%s chip=%s max_model_len=%s max_num_seqs=%s points=%s\n' \
  "$SIDE" "$PORT" "$CHIP" "$MAX_MODEL_LEN" "$MAX_NUM_SEQS" "${POINTS[*]}" \
  > "$REPO_ROOT/runs/$RUN/batch-config-$SIDE.txt"

cleanup() { [[ "$STOP" == "1" ]] && stop_container || true; }
trap cleanup EXIT INT TERM

if [[ "$START" == "1" ]]; then
  say "起容器：side=$SIDE max_model_len=$MAX_MODEL_LEN max_num_seqs=$MAX_NUM_SEQS"
  start_container
  say "容器就绪"
fi

for spec in "${POINTS[@]}"; do
  IFS=':' read -r tag isl osl n conc mode cg <<< "$spec"
  cg="${cg:-fp}"
  say "── 点 $tag：ISL=$isl OSL=$osl n=$n c=$conc mode=$mode callgraph=$cg"
  ARGS=(--run "$RUN" --side "$SIDE" --tag "$tag" --port "$PORT" --chip "$CHIP"
        --input-len "$isl" --output-len "$osl" --num-prompts "$n"
        --max-concurrency "$conc" --warmup "$WARMUP" --call-graph "$cg")
  case "$mode" in
    perf) ARGS+=(--perf);;
    stat) ARGS+=(--no-perf --perf-stat);;
    trace) ARGS+=(--no-perf --perf-stat --syscall-stat);;   # 只记 perf stat + syscall tracepoint
    none) ARGS+=(--no-perf);;
    *) echo "未知 mode：$mode" >&2; exit 2 ;;
  esac
  "$REPO_ROOT/harness/profile/a3/prof_point.sh" "${ARGS[@]}" || say "⚠️ 点 $tag 失败（继续下一个）"
done

if [[ "$STOP" == "1" ]]; then
  say "停容器"
  cleanup
  trap - EXIT INT TERM
fi
say "事务完成"
