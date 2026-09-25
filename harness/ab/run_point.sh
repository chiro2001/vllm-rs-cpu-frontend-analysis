#!/usr/bin/env bash
# 跑一个 A/B 实验点（一侧）：起栈 → 预热 → 打负载 → 同窗口采 CPU/perf → 落盘汇总。
#
# 用法:
#   run_point.sh --point C1 --side rust --run runs/ab/C1-rust --out data/ab/C1/rust \
#     --random-input-len 1024 --random-output-len 128 --max-concurrency 1 --num-prompts 8 \
#     [--no-start] [--no-perf] [--stop] [--fe-cores 4-5]
#   run_point.sh --help
#
# 采集口径（见 docs/ab-design.md）：
#   窗口 = [客户端启动后 2 s, 客户端退出]（排除 vllm-bench 生成 prompt 的一次性开销；
#   另存 pre 窗口用于量化该开销的污染上界）。
#   同时采：前端（被分析对象）/ 引擎 / worker / supervisor（Rust 侧专属对照）/ 客户端（单独记）。
#   perf stat 与负载同起同停（stop-file 控制），两侧事件完全一致。
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

POINT=""; SIDE=""; RUN_DIR=""; OUT_DIR=""; PORT="$AB_PORT"
ISL=1024; OSL=128; CONC=1; N=8; WARMUP=2; DO_PERF=1; DO_START=1; DO_STOP=0
KIND="real"
WINDOW_DELAY=2
TOKENIZER_HOST="${TOKENIZER_HOST:-REPO_HOME/models/Qwen3-0.6B}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --point) POINT="$2"; shift 2 ;;
    --side) SIDE="$2"; shift 2 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --random-input-len) ISL="$2"; shift 2 ;;
    --random-output-len) OSL="$2"; shift 2 ;;
    --max-concurrency) CONC="$2"; shift 2 ;;
    --num-prompts) N="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --fe-cores) AB_FE_CORES="$2"; export AB_FE_CORES; shift 2 ;;
    --perf-duration) PERF_DURATION="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --window-delay) WINDOW_DELAY="$2"; shift 2 ;;
    --no-perf) DO_PERF=0; shift ;;
    --no-start) DO_START=0; shift ;;
    --stop) DO_STOP=1; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$POINT" && -n "$SIDE" && -n "$RUN_DIR" && -n "$OUT_DIR" ]] || { echo "缺少必填参数" >&2; usage; exit 2; }
mkdir -p "$RUN_DIR" "$OUT_DIR"

TAG="$POINT-$SIDE"
PC="$AB_DIR/../common/procstat.sh"

########## 1) 起栈 ##########
if [[ "$DO_START" == "1" ]]; then
  if [[ "$KIND" == "mock" ]]; then
    "$AB_DIR/start_mock_side.sh" --side "$SIDE" --run "$RUN_DIR" --port "$PORT"
  else
    "$AB_DIR/start_side.sh" --side "$SIDE" --run "$RUN_DIR" --port "$PORT"
  fi
else
  [[ -f "$RUN_DIR/frontend.pid" ]] || ab_die "--no-start 但 $RUN_DIR 下没有 frontend.pid"
fi

FE_PID="$(cat "$RUN_DIR/frontend.pid")"
ENG_PID="$(cat "$RUN_DIR/engine.pid" 2>/dev/null || true)"
WORKER_PID="$(cat "$RUN_DIR/worker.pid" 2>/dev/null || true)"
SUP_PID="$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null || true)"
ALL_PIDS="$FE_PID $ENG_PID $WORKER_PID $SUP_PID"

ab_say "[$TAG] 角色 pid：frontend=$FE_PID engine=${ENG_PID:-—} worker=${WORKER_PID:-—} supervisor=${SUP_PID:-—}"

########## 2) 预热（不计入窗口）##########
if [[ "$WARMUP" -gt 0 ]]; then
  ab_say "[$TAG] 预热 $WARMUP 请求（不计入）"
  setsid taskset -c "$AB_CLIENT_CORES" "$BENCH_BIN" \
    --base-url "http://127.0.0.1:$PORT" --backend openai-chat --dataset-name random \
    --tokenizer "$TOKENIZER_HOST" --model "$AB_MODEL_IN_CONTAINER" \
    --random-input-len "$ISL" --random-output-len "$OSL" \
    --num-prompts "$WARMUP" --max-concurrency "$CONC" \
    > "$OUT_DIR/$TAG.warmup.stdout.txt" 2> "$OUT_DIR/$TAG.warmup.stderr.txt" \
    || ab_die "预热失败（$OUT_DIR/$TAG.warmup.stderr.txt）"
  ab_say "[$TAG] 预热完成"
fi

########## 3) 打开测量窗口 ##########
"$PC" snapshot --out "$OUT_DIR/$TAG.pre.before.json" $ALL_PIDS 2>/dev/null

PERF_STOP="$OUT_DIR/$TAG.perf.stop"
PERF_RAW="$OUT_DIR/perf-raw"
rm -f "$PERF_STOP"
mkdir -p "$PERF_RAW"
if [[ "$DO_PERF" == "1" ]]; then
  ab_say "[$TAG] 启动 perf stat（stop-file=$PERF_STOP）"
  python3 "$AB_DIR/ab_ctl.py" perfstat --pids-file "$RUN_DIR/pids.$SIDE.json" \
    --duration "${PERF_DURATION:-3600}" --stop-file "$PERF_STOP" --raw-dir "$PERF_RAW" \
    --sudo --out "$OUT_DIR/$TAG.perf.json" > "$OUT_DIR/$TAG.perf.stdout.txt" 2>&1 &
  PERF_CTL=$!
  sleep 1
fi

########## 4) 打负载 ##########
BENCH_RESULT_DIR="$RUN_DIR/bench-result-$TAG"
mkdir -p "$BENCH_RESULT_DIR"
ab_say "[$TAG] 打负载：ISL=$ISL OSL=$OSL c=$CONC num_prompts=$N client_cores=$AB_CLIENT_CORES"
setsid taskset -c "$AB_CLIENT_CORES" "$BENCH_BIN" \
  --base-url "http://127.0.0.1:$PORT" --backend openai-chat --dataset-name random \
  --tokenizer "$TOKENIZER_HOST" --model "$AB_MODEL_IN_CONTAINER" \
  --random-input-len "$ISL" --random-output-len "$OSL" \
  --num-prompts "$N" --max-concurrency "$CONC" \
  --save-result --result-dir "$BENCH_RESULT_DIR" --label "$TAG" \
  > "$OUT_DIR/$TAG.bench.stdout.txt" 2> "$OUT_DIR/$TAG.bench.stderr.txt" &
CLIENT_PID=$!
echo "$CLIENT_PID" > "$RUN_DIR/client.pid"

sleep "$WINDOW_DELAY"
"$PC" snapshot --out "$OUT_DIR/$TAG.win.before.json" $ALL_PIDS 2>/dev/null
"$PC" snapshot --out "$OUT_DIR/$TAG.client.before.json" "$CLIENT_PID" 2>/dev/null || true
AB_DIR="$AB_DIR" "$AB_DIR/threadcpu.sh" snapshot --out "$OUT_DIR/$TAG.fe.win.before.threads.json" "$FE_PID" 2>/dev/null || true
ab_say "[$TAG] 负载窗口已打开（client_pid=$CLIENT_PID，delay=${WINDOW_DELAY}s）"

if ! wait "$CLIENT_PID"; then
  tail -25 "$OUT_DIR/$TAG.bench.stderr.txt" >&2 || true
  ab_die "[$TAG] vllm-bench 失败（见 $OUT_DIR/$TAG.bench.stderr.txt）"
fi
"$PC" snapshot --out "$OUT_DIR/$TAG.win.after.json" $ALL_PIDS 2>/dev/null
"$PC" snapshot --out "$OUT_DIR/$TAG.client.after.json" "$CLIENT_PID" "$FE_PID" 2>/dev/null || true
"$AB_DIR/threadcpu.sh" snapshot --out "$OUT_DIR/$TAG.fe.win.after.threads.json" "$FE_PID" 2>/dev/null || true
ab_say "[$TAG] 负载窗口已关闭"

if [[ "$DO_PERF" == "1" ]]; then
  touch "$PERF_STOP"
  wait "$PERF_CTL" || ab_say "[$TAG] perf 采集非零退出（见 $OUT_DIR/$TAG.perf.stdout.txt）"
fi

########## 5) 增量与汇总 ##########
"$PC" diff --before "$OUT_DIR/$TAG.win.before.json" --after "$OUT_DIR/$TAG.win.after.json" \
  --out "$OUT_DIR/$TAG.window_cpu.json" >/dev/null
"$PC" diff --before "$OUT_DIR/$TAG.client.before.json" --after "$OUT_DIR/$TAG.client.after.json" \
  --out "$OUT_DIR/$TAG.client_cpu.json" >/dev/null
"$PC" diff --before "$OUT_DIR/$TAG.pre.before.json" --after "$OUT_DIR/$TAG.win.after.json" \
  --out "$OUT_DIR/$TAG.pre_window_cpu.json" >/dev/null
"$AB_DIR/threadcpu.sh" diff --before "$OUT_DIR/$TAG.fe.win.before.threads.json" \
  --after "$OUT_DIR/$TAG.fe.win.after.threads.json" \
  --out "$OUT_DIR/$TAG.fe.threads_cpu.json" >/dev/null 2>&1 || true

BENCH_JSON="$(ls -t "$BENCH_RESULT_DIR"/*.json 2>/dev/null | head -1 || true)"
[[ -n "$BENCH_JSON" ]] || ab_die "[$TAG] 找不到 vllm-bench 的结果 JSON（--save-result 未生效？）"
cp "$BENCH_JSON" "$OUT_DIR/$TAG.bench.result.json"

python3 "$AB_DIR/ab_ctl.py" summary --point "$POINT" --side "$SIDE" \
  --bench "$OUT_DIR/$TAG.bench.result.json" --pids "$RUN_DIR/pids.$SIDE.json" \
  --perf "$OUT_DIR/$TAG.perf.json" --perf-raw-dir "$PERF_RAW" \
  --window-diff "$OUT_DIR/$TAG.window_cpu.json" \
  --client-diff "$OUT_DIR/$TAG.client_cpu.json" \
  --pre-diff "$OUT_DIR/$TAG.pre_window_cpu.json" \
  --window-note "窗口=[客户端启动后2s, 客户端退出]；pre 窗口=[客户端启动前, 负载结束]" \
  --out "$OUT_DIR/$TAG.summary.json"

ab_write_manifest "$OUT_DIR/$TAG.manifest.json" \
  "point=$POINT" "side=$SIDE" "tag=$TAG" "kind=$KIND" "vllm_commit=$VLLM_COMMIT" "vllm_version=0.26.0+cpu" \
  "container_image=$AB_IMAGE" "model=$AB_MODEL_IN_CONTAINER" "base_url=http://127.0.0.1:$PORT" \
  "dataset=random" "backend=openai-chat" "random_input_len=$ISL" "random_output_len=$OSL" \
  "max_concurrency=$CONC" "num_prompts=$N" "warmup_prompts=$WARMUP" \
  "fe_cores=$AB_FE_CORES" "eng_cores=$AB_ENG_CORES" "client_cores=$AB_CLIENT_CORES" \
  "fe_cores_effective=$(ab_ncores "$AB_FE_CORES")" "eng_cores_effective=$(ab_ncores "$AB_ENG_CORES")" \
  "client_cores_effective=$(ab_ncores "$AB_CLIENT_CORES")" \
  "frontend_bin_kind=$SIDE" "rust_frontend_sha256=$(ab_rust_bin_sha 2>/dev/null || echo unknown)" \
  "bench_bin_path=$BENCH_BIN" "loadavg=$(ab_loadavg)" "mem_available_gib=$(ab_mem_avail)" \
  "perf_events=instructions:u,cycles:u,cache-misses:u,branches:u" \
  "window_convention=client_start+2s..client_exit" \
  "summary_path=$OUT_DIR/$TAG.summary.json"

ab_say "[$TAG] 完成 → $OUT_DIR/$TAG.summary.json"
python3 "$AB_DIR/print_point.py" "$OUT_DIR/$TAG.summary.json"

if [[ "$DO_STOP" == "1" ]]; then
  "$AB_DIR/stop_side.sh" --run "$RUN_DIR" || true
fi
