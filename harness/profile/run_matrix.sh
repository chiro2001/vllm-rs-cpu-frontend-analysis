#!/usr/bin/env bash
# 一键复跑 B 线采集矩阵（plan/experiment-matrix.md §2）。
#
# 用法:
#   scripts/heavy_lock.sh scripts/limit.sh harness/profile/run_matrix.sh \
#       --run runs/b-matrix --tag-prefix B --out-dir data/profiles [--duration 30] [--only B1,B5]
#   run_matrix.sh --help
#
# 前置：栈已经起来（`harness/common/stack.sh start --run <run>`）。
# 采样参数（固定，写进每份 manifest）：
#   perf record -p <前端pid> -e cpu-clock -F 999 --call-graph fp
#   perf stat  -p <前端pid> -e cycles:u,instructions:u,branches:u,branch-misses:u,cache-references:u,cache-misses:u
#   ⇒ 为什么是 fp 而不是 dwarf：见 docs/02-cpu-profile.md §2（dwarf 在这份二进制上完全失效）
#
# ⚠️ 自己**不要**再套一层 heavy_lock（会死锁：同一把锁不可重入）。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; OUT_DIR="data/profiles"; PREFIX="B"; DURATION=30; WARMUP=3; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --tag-prefix) PREFIX="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; exit 2; }
[[ -f "$RUN_DIR/frontend.pid" ]] || { echo "$RUN_DIR 下没有 frontend.pid，先 stack.sh start" >&2; exit 2; }
mkdir -p "$OUT_DIR" "$RUN_DIR/perf" "$RUN_DIR/bodies"

# 采集点定义：tag|isl|osl|concurrency|tools|采样
POINTS=(
  "B1|1024|128|1|weather|record"
  "B1n|1024|128|1|none|record"
  "B2|8192|16|1|none|record"
  "B3|1024|512|1|none|record"
  "B4|1024|128|64|none|record"
  "B5|1024|128|1|weather|stat"
  "B1x|1024|128|1|weather|loadonly"
)

load_cmd_for() {  # isl osl conc tools tag
  printf '%s\n' "python3 $HERE/raw_load.py --base-url http://127.0.0.1:$PORT \
--model $MODEL --tokenizer $MODEL/tokenizer.json \
--input-len $1 --output-len $2 --concurrency $3 --tools $4 --stream \
--duration $DURATION --num-requests 0 --warmup $WARMUP \
--dump-body $RUN_DIR/bodies/$5.body.json --out $OUT_DIR/$5.load.json"
}

for p in "${POINTS[@]}"; do
  IFS='|' read -r tag isl osl conc tools kind <<< "$p"
  if [[ -n "$ONLY" && ",$ONLY," != *",$tag,"* ]]; then continue; fi
  say "===== $tag：ISL=$isl OSL=$osl c=$conc tools=$tools 采样=$kind 窗口=${DURATION}s ====="
  # shellcheck disable=SC2046
  LOAD=( $(load_cmd_for "$isl" "$osl" "$conc" "$tools" "$tag") )
  if [[ "$kind" == "record" ]]; then
    "$HERE/perf_record.sh" --run "$RUN_DIR" --tag "$tag" --out-dir "$OUT_DIR" \
      --call-graph fp --freq 999 --event cpu-clock \
      -- taskset -c "$CLIENT_CORES" "${LOAD[@]}"
  elif [[ "$kind" == "loadonly" ]]; then
    # 采样开销对照点：**完全不开 perf**，只打同一份负载，用于回答「999 Hz 采样把吞吐压了多少」
    say "$tag=采样开销对照（不开 perf）"
    taskset -c "$CLIENT_CORES" "${LOAD[@]}"
  else
    "$HERE/perf_stat.sh" --run "$RUN_DIR" --tag "$tag" --out-dir "$OUT_DIR" \
      --duration "$DURATION" -- taskset -c "$CLIENT_CORES" "${LOAD[@]}"
  fi
  python3 "$HERE/folded_stats.py" --folded "$OUT_DIR/$tag.folded" --tag "$tag" \
    --outdir "$OUT_DIR" --top 40 --quiet --source "$(basename "$0"): ISL=$isl OSL=$osl c=$conc tools=$tools" \
    2>/dev/null || true
  say "===== $tag 完成 ====="
done
say "矩阵完成。折叠栈/统计写在 $OUT_DIR/，原始 perf.data 同目录（不入 git）"
