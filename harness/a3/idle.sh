#!/usr/bin/env bash
# **在 REMOTE_HOST 上运行**：空载对照 —— 服务起好、`/health` 200 之后**不发任何请求**，
# 只开一个固定窗口，采容器内所有进程的 CPU 增量。
#
# 用法:
#   harness/a3/idle.sh --run ab-C1r1-rust --side rust --seconds 30
#   harness/a3/idle.sh --help
#
# 为什么要它：
#   C1 的窗口长 38 s 但只完成 32 个请求（1.4 req/s）。前端在这 38 s 里一直活着
#   （tokio runtime + ZMQ io 线程在 epoll 上等），**空转**的 epoll/futex 唤醒
#   也会记进 `/proc/<pid>/stat`。若空转占 0.5% 个核，38 s 就是 0.19 s ——
#   占了实测前端 CPU（0.34 s）的一半以上。
#   ⇒ 「窗口内前端 CPU / 完成请求数」是**含空转**的口径；
#     「拐点分析」（单核能支撑多少 req/s）必须用**扣掉空转的边际成本**。
#
#   对比参照：x86 的 mock 臂窗口 5 s 跑几千个请求（400–1200 req/s），空转可忽略 ——
#   所以 x86 的 µs/请求与 REMOTE_HOST 的 ms/请求**不是同一个口径**，不可直接相比。
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; SIDE=""; WINDOW=30; TAG="idle"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN="$2"; shift 2 ;;
    --side) SIDE="$2"; shift 2 ;;
    --seconds) WINDOW="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$SIDE" ]] || { echo "需要 --run --side" >&2; usage; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROCSTAT="$REPO_ROOT/harness/common/procstat.sh"
OUT="$REPO_ROOT/runs/$RUN/$TAG-$SIDE"
mkdir -p "$OUT"
say() { printf '[idle] %s\n' "$*"; }

PIDS="$(python3 "$REPO_ROOT/harness/a3/container_pids.py" --run "$RUN")" \
  || { echo "取容器 pid 失败" >&2; exit 1; }
[[ -n "$PIDS" ]] || { echo "容器内没有进程（容器没起？）" >&2; exit 1; }

say "run=$RUN side=$SIDE 窗口=${WINDOW}s pids=$PIDS"
"$PROCSTAT" snapshot --out "$OUT/idle.before.json" $PIDS 2>/dev/null
say "空载窗口开始（不发任何请求）…"
sleep "$WINDOW"
"$PROCSTAT" snapshot --out "$OUT/idle.after.json" $PIDS 2>/dev/null
"$PROCSTAT" diff --before "$OUT/idle.before.json" --after "$OUT/idle.after.json" \
  --out "$OUT/idle_cpu.json" >/dev/null

python3 "$REPO_ROOT/harness/a3/idle_summary.py" --cpu "$OUT/idle_cpu.json" \
  --side "$SIDE" --out "$OUT/idle_summary.json"
