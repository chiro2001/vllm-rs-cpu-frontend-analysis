#!/usr/bin/env bash
# 在**同一个重活锁窗口内**完成「起栈 → 采内核态 perf → 打负载 → 停栈」。
#
# 为什么必须一次做完（踩过的坑，已记录在 docs/02 §13.7）：
#   mock engine 在**空闲**状态下约 60 s 就会退出（不挂任何 perf、没有任何负载也会死；
#   有持续负载时不出现，`runs/b-matrix` 连续跑了 21 分钟）。
#   而 `perf_kernel.sh` 单独跑时要先排队等重活锁——等锁常常超过 60 s，
#   于是轮到它时栈里的引擎已经没了，负载全部 500（broken pipe）。
#
# ⚠️ 调用方**只在外层**加一次 `scripts/heavy_lock.sh`（本脚本内部会自己起栈）。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/../.." && pwd)"
# shellcheck source=../common/env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_NAME="runs/b-kernel"; TAG="KB1"; OUT_DIR="/tmp/kern"; DURATION=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_NAME="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
RUN_DIR="$REPO_ROOT/$RUN_NAME"
mkdir -p "$OUT_DIR" "$RUN_DIR/bodies"

cleanup_stack() { "$COMMON_DIR/stack.sh" stop --run "$RUN_DIR" >/dev/null 2>&1 || true; }
trap cleanup_stack EXIT INT TERM

say "1/4 起栈 → $RUN_NAME"
"$COMMON_DIR/stack.sh" start --run "$RUN_DIR" >/dev/null

# 请求体：复用 B 线矩阵里的 B1 body（保证与用户态那次的字节一致）
if [[ ! -f "$RUN_DIR/bodies/B1.body.json" ]]; then
  cp "$REPO_ROOT/runs/b-matrix/bodies/B1.body.json" "$RUN_DIR/bodies/B1.body.json"
fi

say "2/4 采内核态（sudo perf record -p <前端pid>，含内核态符号）"
"$HERE/perf_kernel.sh" --run "$RUN_DIR" --tag "$TAG" --out-dir "$OUT_DIR" \
  --sudo --freq 999 --call-graph fp \
  -- taskset -c "$CLIENT_CORES" python3 "$HERE/raw_load.py" \
     --base-url "http://127.0.0.1:$PORT" --model "$MODEL" \
     --input-len 1024 --output-len 128 --concurrency 1 --tools weather --stream \
     --duration "$DURATION" --num-requests 0 --warmup 3 \
     --body-file "$RUN_DIR/bodies/B1.body.json" \
     --frontend-pid-file "$RUN_DIR/frontend.pid" --procstat "$COMMON_DIR/procstat.sh" \
     --frontend-cpu-out "$OUT_DIR/$TAG.frontend-cpu.json" \
     --note "内核态采样窗口（sudo perf，含 [k] 符号）：与 B1 同负载、同窗口时长" \
     --out "$OUT_DIR/$TAG.load.json"

say "3/4 校验：这次窗口的用户态/内核态拆分"
python3 - "$OUT_DIR/$TAG.load.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ut, st, tot = d.get("frontend_utime_seconds"), d.get("frontend_stime_seconds"), d.get("frontend_cpu_seconds")
print(f"  前端 CPU {tot} s = utime {ut} s + stime {st} s（stime 占 {st / tot * 100:.1f}%）")
print(f"  请求 {d['requests_completed_in_window']}，失败 {d['requests_failed_in_window']}，"
      f"吞吐 {d['throughput_req_s']} req/s")
PY
say "4/4 停栈"
cleanup_stack
trap - EXIT INT TERM
say "完成：报告在 $OUT_DIR/$TAG.kernel-report.txt"
