#!/usr/bin/env bash
# 必采项 ④：每个负载点的**前端进程 CPU 时间**（/proc/<pid>/stat 增量，procstat.sh 口径）。
#
# 用法:
#   scripts/heavy_lock.sh scripts/limit.sh harness/profile/cpu_windows.sh \
#       --run runs/b-matrix --duration 20 [--only B1,B4] [--with-perf-tag B1-perf20]
#   cpu_windows.sh --help
#
# 为什么单独一个脚本、而不是复用 run_matrix.sh：
#   run_matrix.sh 的窗口里 **perf record 正在跑**（999 Hz 采样会改变吞吐，见 docs/02 §10）。
#   「前端 CPU 秒/请求」这类**归一化**指标要回答的是"正常运行时的成本"，
#   因此本脚本默认**不开任何 perf**；开 perf 的对照由 `--with-perf-tag` 单独跑一个点。
#   （火焰图/硬件计数仍由 run_matrix.sh 与 perf_stat.sh 产出，两者互不覆盖：
#    本脚本写 <ID>.cpu-load.json / <ID>.frontend-cpu.json，不动 <ID>.folded / <ID>.perf.data。）
#
# 口径（写进 JSON，引用时必须带上）：
#   * 前端 CPU = `utime + stime`（**不含** cutime/cstime），来自 harness/common/procstat.sh；
#   * before 快照在**预热之后、窗口之前**，after 在**窗口结束之后**；
#   * 压测端自己的 CPU 由 raw_load.py 用 getrusage 记（另有 procstat 交叉校验），
#     **两个进程两个数，绝不相加**；
#   * 每个点共用同一 `--duration`（本次全部 20 s）。
#
# ⚠️ 自己**不要**再套一层 heavy_lock（同一把锁不可重入）。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; OUT_DIR="data/profiles"; DURATION=20; WARMUP=3; ONLY=""; PERF_TAG=""; STAT_TAG=""; NOSTREAM_TAG=""
TAG_SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --with-perf-tag) PERF_TAG="$2"; shift 2 ;;
    --with-stat-tag) STAT_TAG="$2"; shift 2 ;;
    --nostream-tag) NOSTREAM_TAG="$2"; shift 2 ;;
    --tag-suffix) TAG_SUFFIX="$2"; shift 2 ;;   # ⚠️ 换引擎配置（如 chunk size）时必须给，否则会覆盖同 ID 的结果
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; exit 2; }
[[ -f "$RUN_DIR/frontend.pid" ]] || { echo "$RUN_DIR 下没有 frontend.pid，先 stack.sh start" >&2; exit 2; }
mkdir -p "$OUT_DIR" "$RUN_DIR/bodies" "$OUT_DIR/procstat-snapshots"

# 与 run_matrix.sh 完全相同的负载定义（同 body 文件 ⇒ 请求字节一致）
POINTS=(
  "B1|1024|128|1|weather"
  "B1n|1024|128|1|none"
  "B2|8192|16|1|none"
  "B3|1024|512|1|none"
  "B4|1024|128|64|none"
  "B5|1024|128|1|weather"
)

run_point() {  # tag isl osl conc tools outfile [body_tag]
  local tag="$1" isl="$2" osl="$3" conc="$4" tools="$5" outfile="$6"
  # 请求体按**基准 tag**复用（否则 chunk32 变体会因找不到 B1.body.json 而重新合成、
  # 结果与 B1 不可比）；输出文件名用**带后缀的 tag**（避免覆盖）。
  local body="$RUN_DIR/bodies/${7:-$tag}.body.json"
  say "===== $tag：ISL=$isl OSL=$osl c=$conc tools=$tools 窗口=${DURATION}s（无 perf）====="
  if [[ -f "$body" ]]; then
    say "复用已有请求体 $body（与 perf 窗口字节一致）"
    BODY_ARGS=(--body-file "$body")
  else
    BODY_ARGS=(--tokenizer "$MODEL/tokenizer.json")
  fi
  taskset -c "$CLIENT_CORES" python3 "$HERE/raw_load.py" \
    --base-url "http://127.0.0.1:$PORT" --model "$MODEL" \
    --input-len "$isl" --output-len "$osl" --concurrency "$conc" --tools "$tools" --stream \
    --duration "$DURATION" --num-requests 0 --warmup "$WARMUP" \
    --frontend-pid-file "$RUN_DIR/frontend.pid" --procstat "$COMMON_DIR/procstat.sh" \
    --frontend-cpu-out "$OUT_DIR/$tag.frontend-cpu.json" \
    --snapshot-dir "$OUT_DIR/procstat-snapshots" --snapshot-tag "$tag" \
    "${BODY_ARGS[@]}" \
    --out "$outfile" > "$outfile.stdout.json"
}

for p in "${POINTS[@]}"; do
  IFS='|' read -r tag isl osl conc tools <<< "$p"
  base_tag="$tag"
  tag="${tag}${TAG_SUFFIX}"
  if [[ -n "$ONLY" && ",$ONLY," != *",$tag,"* ]]; then continue; fi
  run_point "$tag" "$isl" "$osl" "$conc" "$tools" "$OUT_DIR/$tag.cpu-load.json" "$base_tag"
  python3 - "$OUT_DIR/$tag.cpu-load.json" "$tag" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
n = d.get("normalized") or {}
print(f"[{sys.argv[2]}] 窗口 {d['window']['wall_seconds']}s 请求 {d['requests_completed_in_window']} "
      f"前端CPU {d['frontend_cpu_seconds']}s 客户端CPU {d['client_cpu_seconds_window_only']}s "
      f"| µs/req 前端 {None if n.get('frontend_cpu_s_per_request') is None else round(n['frontend_cpu_s_per_request']*1e6,1)} "
      f"客户端 {None if n.get('client_cpu_s_per_request') is None else round(n['client_cpu_s_per_request']*1e6,1)}")
PY
  say "===== $tag 完成 ====="
done

# 可选：一个**在采样中**的对照点（量化"999 Hz perf record 对前端 CPU/请求的影响"）
if [[ -n "$PERF_TAG" ]]; then
  say "===== 对照点 $PERF_TAG：同 B1 负载，但窗口内 perf record 正在跑 ====="
  "$HERE/perf_record.sh" --run "$RUN_DIR" --tag "$PERF_TAG" --out-dir "$OUT_DIR" \
    --call-graph fp --freq 999 --event cpu-clock \
    -- taskset -c "$CLIENT_CORES" python3 "$HERE/raw_load.py" \
       --base-url "http://127.0.0.1:$PORT" --model "$MODEL" \
       --input-len 1024 --output-len 128 --concurrency 1 --tools weather --stream \
       --duration "$DURATION" --num-requests 0 --warmup "$WARMUP" \
       --body-file "$RUN_DIR/bodies/B1.body.json" \
       --frontend-pid-file "$RUN_DIR/frontend.pid" --procstat "$COMMON_DIR/procstat.sh" \
       --out "$OUT_DIR/$PERF_TAG.load.json"
  say "===== $PERF_TAG 完成（其负载结果在 $OUT_DIR/$PERF_TAG.load.json）====="
fi

# 可选：B5 的**perf stat 窗口**里也补一份前端 CPU（任务书第 2 条：B5 按它的实际窗口时刻补）
if [[ -n "$STAT_TAG" ]]; then
  say "===== $STAT_TAG：同 B1 负载，但窗口内 perf stat 正在跑（B5 的实际窗口）====="
  "$HERE/perf_stat.sh" --run "$RUN_DIR" --tag "$STAT_TAG" --out-dir "$OUT_DIR" \
    --duration "$DURATION" \
    -- taskset -c "$CLIENT_CORES" python3 "$HERE/raw_load.py" \
       --base-url "http://127.0.0.1:$PORT" --model "$MODEL" \
       --input-len 1024 --output-len 128 --concurrency 1 --tools weather --stream \
       --duration "$DURATION" --num-requests 0 --warmup "$WARMUP" \
       --body-file "$RUN_DIR/bodies/B1.body.json" \
       --frontend-pid-file "$RUN_DIR/frontend.pid" --procstat "$COMMON_DIR/procstat.sh" \
       --out "$OUT_DIR/$STAT_TAG.load.json"
  say "===== $STAT_TAG 完成（perf stat 结果在 $OUT_DIR/$STAT_TAG.perf-stat.json）====="
fi

# 可选：B1 负载的**非流式**变体 —— 用来诊断"前端 CPU 里近一半是 stime（内核态）"从哪来。
# 假设：SSE 每 token 一个 chunk ⇒ 每请求 128+ 次 socket 写 + 128+ 次 ZMQ 收包（都是 syscall）。
# 非流式把 chunk 合成一次写；若 stime 明显下降，就坐实"内核时间主要是逐 chunk 的 syscall 放大"。
if [[ -n "$NOSTREAM_TAG" ]]; then
  say "===== 诊断点 $NOSTREAM_TAG：同 B1 负载但**非流式**（不开 perf）====="
  taskset -c "$CLIENT_CORES" python3 "$HERE/raw_load.py" \
    --base-url "http://127.0.0.1:$PORT" --model "$MODEL" \
    --input-len 1024 --output-len 128 --concurrency 1 --tools weather \
    --tokenizer "$MODEL/tokenizer.json" \
    --duration "$DURATION" --num-requests 0 --warmup "$WARMUP" \
    --frontend-pid-file "$RUN_DIR/frontend.pid" --procstat "$COMMON_DIR/procstat.sh" \
    --frontend-cpu-out "$OUT_DIR/$NOSTREAM_TAG.frontend-cpu.json" \
    --snapshot-dir "$OUT_DIR/procstat-snapshots" --snapshot-tag "$NOSTREAM_TAG" \
    --dump-body "$RUN_DIR/bodies/$NOSTREAM_TAG.body.json" \
    --out "$OUT_DIR/$NOSTREAM_TAG.cpu-load.json" > "$OUT_DIR/$NOSTREAM_TAG.cpu-load.json.stdout.json"
  say "===== $NOSTREAM_TAG 完成 ====="
fi

say "前端 CPU 数据写在 $OUT_DIR/<tag>.cpu-load.json 与 <tag>.frontend-cpu.json"
say "汇总成 CSV：python3 $HERE/summary_load.py --out-dir $OUT_DIR"
