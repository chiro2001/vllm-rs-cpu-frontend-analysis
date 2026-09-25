#!/usr/bin/env bash
# 一键复跑 C1–C5 的 A/B 矩阵：每侧起一次栈，跑完该侧全部点再换另一侧。
#
# 用法:
#   run_matrix.sh [--points C1,C2,C3,C4,C5] [--sides rust,python] [--out-root data/ab]
#                 [--runs-root runs/ab] [--port 8300] [--no-perf] [--dry-run]
#   run_matrix.sh --help
#
# ⚠️ 这是重活：请包在 `scripts/heavy_lock.sh scripts/limit.sh ...` 里跑。
# 负载点定义见 docs/ab-design.md §3（与 plan/experiment-matrix.md §3 对齐）。
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

POINTS="C1,C2,C3,C4,C5"; SIDES="rust,python"
OUT_ROOT="$REPO_ROOT/data/ab"; RUNS_ROOT="$REPO_ROOT/runs/ab"; PORT="$AB_PORT"
EXTRA=(); DRY=0; KIND="real"; SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --points) POINTS="$2"; shift 2 ;;
    --sides) SIDES="$2"; shift 2 ;;
    --out-root) OUT_ROOT="$2"; shift 2 ;;
    --runs-root) RUNS_ROOT="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --no-perf) EXTRA+=(--no-perf); shift ;;
    --kind) KIND="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$KIND" == "mock" ]]; then
  EXTRA+=(--kind mock --window-delay 0)
  SUFFIX="-mock"
fi

# 点定义：id:ISL:OSL:concurrency:num_prompts:warmup:前端核
#
# ⚠️ 两条臂的 num_prompts 不同，是**刻意的**：真引擎臂每点受 245 ms/token 限制
#   （见 docs/ab-design.md §5），只能取很小的样本；mock 臂引擎≈免费，取样上千次
#   才能把前端每请求成本压到远超 tick 分辨率。两侧**同一臂内**点数与负载形态完全一致。
POINT_DEFS_REAL=(
  "C1:1024:128:1:4:1:4-5"
  "C2:1024:128:8:8:2:4-5"
  "C3:8192:16:1:1:1:4-5"
  "C4:1024:512:1:2:1:4-5"
  "C5a:1024:128:4:4:1:4-5"
  "C5b:1024:128:4:4:1:4-7"
  "C5c:1024:128:4:4:1:2-7"
)
# mock 臂：引擎≈免费 ⇒ 样本量放大 3 个数量级，前端每请求成本可测到 <0.1% 精度
POINT_DEFS_MOCK=(
  "C1:1024:128:1:2000:20:4-5"
  "C2:1024:128:64:8192:64:4-5"
  "C3:8192:16:1:512:8:4-5"
  "C4:1024:512:1:1024:16:4-5"
  "C5a:1024:128:8:4096:64:4-5"
  "C5b:1024:128:8:4096:64:4-7"
  "C5c:1024:128:8:4096:64:2-7"
)
if [[ "$KIND" == "mock" ]]; then POINT_DEFS=("${POINT_DEFS_MOCK[@]}"); else POINT_DEFS=("${POINT_DEFS_REAL[@]}"); fi

want_point() {  # C5 展开成 C5a/C5b/C5c
  local id="$1" sel
  IFS=',' read -ra sel <<< "$POINTS"
  for s in "${sel[@]}"; do
    [[ "$id" == "$s" ]] && return 0
    [[ "$s" == "C5" && "$id" == C5? ]] && return 0
  done
  return 1
}

IFS=',' read -ra SIDE_LIST <<< "$SIDES"

echo "[ab][matrix] points=$POINTS sides=$SIDES out=$OUT_ROOT runs=$RUNS_ROOT"
if [[ "$DRY" == "1" ]]; then
  for side in "${SIDE_LIST[@]}"; do
for def in "${POINT_DEFS[@]}"; do
      IFS=':' read -r id isl osl conc n warm fe <<< "$def"
      want_point "$id" || continue
      echo "  [dry] side=$side kind=$KIND point=$id ISL=$isl OSL=$osl c=$conc n=$n warmup=$warm fe_cores=$fe"
    done
  done
  exit 0
fi

for side in "${SIDE_LIST[@]}"; do
  RUN_DIR="$RUNS_ROOT/$side"
  mkdir -p "$RUN_DIR"
  first=1
  for def in "${POINT_DEFS[@]}"; do
    IFS=':' read -r id isl osl conc n warm fe <<< "$def"
    want_point "$id" || continue
    out="$OUT_ROOT/$id$SUFFIX/$side"
    mkdir -p "$out"
    args=(--point "$id" --side "$side" --run "$RUN_DIR" --out "$out" --port "$PORT"
          --random-input-len "$isl" --random-output-len "$osl"
          --max-concurrency "$conc" --num-prompts "$n" --warmup "$warm" --fe-cores "$fe")
    if [[ "$first" == "0" ]]; then
      args+=(--no-start)
    fi
    args+=("${EXTRA[@]}")
    echo "[ab][matrix] >>> $side / $id （ISL=$isl OSL=$osl c=$conc n=$n warmup=$warm fe=$fe）"
    "$AB_DIR/run_point.sh" "${args[@]}"
    first=0
  done
  echo "[ab][matrix] $side 全部点完成，停栈"
  "$AB_DIR/stop_side.sh" --run "$RUN_DIR" || true
done

echo "[ab][matrix] 全部完成 → $OUT_ROOT"
