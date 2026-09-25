#!/usr/bin/env bash
# 用 vllm-bench 打一轮负载，并在前后各采一次 CPU 时间（前端 + 客户端分别记）。
#
# 用法:
#   run_load.sh --run runs/demo --out data/ab/c1 --tag c1 \
#     --dataset-name random --input-len 1024 --output-len 128 --max-concurrency 1 --num-prompts 50
#   run_load.sh --help
#
# 口径（plan/experiment-matrix.md §3 必采）：
#   ① 端到端吞吐/延迟（vllm-bench 原始 JSON）
#   ② 前端进程 CPU 时间（/proc/<pid>/stat 增量）
#   ③ 压测客户端自身 CPU（单独记录，绝不算进服务端）
#   ④ 采样窗口时长与时间戳
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; OUT_DIR=""; TAG="run"
BENCH_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --) shift; BENCH_ARGS+=("$@"); break ;;
    *) BENCH_ARGS+=("$1"); shift ;;
  esac
done
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run（stack.sh start 的目录）" >&2; exit 2; }
[[ -f "$RUN_DIR/frontend.pid" ]] || { echo "$RUN_DIR 下没有 frontend.pid，先 stack.sh start" >&2; exit 2; }
[[ -x "$BENCH_BIN" ]] || { echo "找不到 vllm-bench：$BENCH_BIN" >&2; exit 2; }
OUT_DIR="${OUT_DIR:-$RUN_DIR}"
mkdir -p "$OUT_DIR"

FE_PID="$(cat "$RUN_DIR/frontend.pid")"
BASE_URL="${BASE_URL:-http://127.0.0.1:$PORT}"

say "负载 $TAG：${BENCH_ARGS[*]}"
say "前端 pid=$FE_PID 绑核=$FE_CORES；客户端绑核=$CLIENT_CORES（分开，避免抢核）"

# ① 前后快照（前端）
"$COMMON_DIR/procstat.sh" snapshot --out "$OUT_DIR/$TAG.fe.before.json" "$FE_PID" 2>/dev/null

# 客户端整轮包一层：setsid + taskset，便于事后按 pid 统计它自己的 CPU
setsid taskset -c "$CLIENT_CORES" "$BENCH_BIN" \
  --base-url "$BASE_URL" "${BENCH_ARGS[@]}" \
  > "$OUT_DIR/$TAG.bench.stdout.json" 2> "$OUT_DIR/$TAG.bench.stderr.txt" &
CLIENT_PID=$!

sleep 2
"$COMMON_DIR/procstat.sh" snapshot --out "$OUT_DIR/$TAG.client.before.json" "$CLIENT_PID" "$FE_PID" 2>/dev/null || true

wait "$CLIENT_PID" || { echo "vllm-bench 失败，见 $OUT_DIR/$TAG.bench.stderr.txt" >&2; tail -20 "$OUT_DIR/$TAG.bench.stderr.txt" >&2; exit 1; }

"$COMMON_DIR/procstat.sh" snapshot --out "$OUT_DIR/$TAG.fe.after.json" "$FE_PID" 2>/dev/null
"$COMMON_DIR/procstat.sh" diff --before "$OUT_DIR/$TAG.fe.before.json" --after "$OUT_DIR/$TAG.fe.after.json" \
  --out "$OUT_DIR/$TAG.frontend_cpu.json" > /dev/null
"$COMMON_DIR/procstat.sh" diff --before "$OUT_DIR/$TAG.client.before.json" --after "$OUT_DIR/$TAG.fe.after.json" \
  --out "$OUT_DIR/$TAG.client_cpu_raw.json" > /dev/null || true

write_manifest "$OUT_DIR/$TAG.manifest.json" \
  "tag=$TAG" "base_url=$BASE_URL" \
  "fe_cores=$FE_CORES" "eng_cores=$ENG_CORES" "client_cores=$CLIENT_CORES" \
  "fe_cores_effective=$(ncores "$FE_CORES")" \
  "loadavg=$(loadavg)" "mem_available_gib=$(mem_available_gib)" \
  "frontend_bin_path=$FRONTEND_BIN" "bench_bin_path=$BENCH_BIN" \
  "bench_args=${BENCH_ARGS[*]}"

say "完成：$OUT_DIR/$TAG.bench.stdout.json"
python3 - "$OUT_DIR/$TAG.frontend_cpu.json" "$OUT_DIR/$TAG.bench.stdout.json" <<'PY'
import json, sys
cpu = json.load(open(sys.argv[1]))
print(f"[summary] 前端 CPU {cpu['cpu_seconds_total']}s / 窗口 {cpu['wall_seconds']}s")
try:
    r = json.load(open(sys.argv[2]))
    keep = {k: r[k] for k in ("completed", "request_throughput", "output_throughput",
                              "total_token_throughput", "mean_ttft_ms", "p99_ttft_ms",
                              "mean_tpot_ms", "p99_tpot_ms", "mean_e2el_ms", "duration")
            if k in r}
    if keep:
        print("[summary] 端到端 " + json.dumps(keep, ensure_ascii=False))
    else:
        print("[summary] vllm-bench 输出键：" + ",".join(sorted(r)[:20]))
except Exception as e:
    print(f"[summary] 解析 bench 输出失败：{e}")
PY
