#!/usr/bin/env bash
# 采**内核态**样本（`perf_event_paranoid=2` 下普通用户只能采 `:u`，需要 sudo）。
#
# 为什么需要：procstat 显示前端 CPU 里约一半是 `stime`（内核态，`docs/02` §13.4），
# 而 `perf_record.sh` 用的 `cpu-clock` 在 paranoid=2 下被内核降级成 `cpu-clock:u`
# ⇒ 内核态在火焰图里**完全不可见**。本脚本用 `sudo -n perf` 采内核态符号，
# 只做 `perf report` 的符号级 top-N（**不**做火焰图），用来回答"那几十秒 stime 花在哪"。
#
# 用法:
#   scripts/heavy_lock.sh harness/profile/perf_kernel.sh --run runs/<name> --tag K1 \
#       [--freq 999] [--event cpu-clock] [--call-graph fp] [--attach-sleep 1] \
#       [--sudo] -- <负载命令...>
#   perf_kernel.sh --help
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; TAG="kernel"; OUT_DIR="/tmp"; FREQ=999; EVENT="cpu-clock"
CALLGRAPH="fp"; ATTACH_SLEEP=1; USE_SUDO=0; LOAD_CMD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --freq) FREQ="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --call-graph) CALLGRAPH="$2"; shift 2 ;;
    --attach-sleep) ATTACH_SLEEP="$2"; shift 2 ;;
    --sudo) USE_SUDO=1; shift ;;
    --) shift; LOAD_CMD=("$@"); break ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" && ${#LOAD_CMD[@]} -gt 0 ]] || { usage; exit 2; }
FE_PID="$(cat "$RUN_DIR/frontend.pid")"
kill -0 "$FE_PID" 2>/dev/null || { echo "前端 pid=$FE_PID 不在跑" >&2; exit 2; }
mkdir -p "$OUT_DIR" "$RUN_DIR/perf"
PERF_DATA="$OUT_DIR/$TAG.kernel.perf.data"
REPORT="$OUT_DIR/$TAG.kernel-report.txt"

PREFIX=(); [[ "$USE_SUDO" == "1" ]] && PREFIX=(sudo -n)
"${PREFIX[@]}" true 2>/dev/null || { echo "sudo -n 不可用；本脚本只用于内核态采样" >&2; exit 3; }

# 先做一次 2 秒的能力探测：paranoid=2 下普通 `perf record` 会静默降级成 :u，
# `sudo` 则应该能拿到 `cpu-clock`（无 `:u` 后缀）。探测失败就早退，别浪费负载窗口。
echo "[perf_kernel] 探测：$([[ $USE_SUDO == 1 ]] && echo sudo) perf record -e $EVENT ..."
set +e
"${PREFIX[@]}" perf record -p "$FE_PID" -e "$EVENT" -F 99 -o /tmp/.perf-probe.data -- sleep 2 \
  > /tmp/.perf-probe.log 2>&1
PROBE_RC=$?
set -e
if [[ $PROBE_RC -ne 0 ]]; then
  echo "[perf_kernel] 探测失败（rc=$PROBE_RC）：" >&2
  sed -n '1,10p' /tmp/.perf-probe.log >&2
  exit 4
fi
echo "[perf_kernel] 探测成功，开始正式采样"

CF=(); [[ "$CALLGRAPH" == "fp" ]] && CF=(--call-graph fp) || CF=(--call-graph "$CALLGRAPH")
# ⚠️ 背景 perf 必须能收尾：负载命令失败时（set -e）如果直接退出，perf 会变成孤儿进程
#    继续往同一个 -o 文件写（踩过：留下一个仍在跑的 sudo perf 与 rotated .old 文件）。
cleanup() {
  kill -0 "${PERF_PID:-0}" 2>/dev/null || return 0
  sudo -n kill -INT "$PERF_PID" 2>/dev/null || kill -INT "$PERF_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$PERF_PID" 2>/dev/null && { sudo -n kill -TERM "$PERF_PID" 2>/dev/null || true; }
}
trap cleanup EXIT INT TERM
"${PREFIX[@]}" perf record -p "$FE_PID" -e "$EVENT" -F "$FREQ" "${CF[@]}" \
  -o "$PERF_DATA" -- sleep 86400 > "$RUN_DIR/perf/$TAG.perf-kernel-record.log" 2>&1 &
PERF_PID=$!
sleep "$ATTACH_SLEEP"
"${LOAD_CMD[@]}"
sudo -n kill -INT "$PERF_PID" 2>/dev/null || kill -INT "$PERF_PID" 2>/dev/null || true
for _ in $(seq 1 60); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 0.5; done
kill -0 "$PERF_PID" 2>/dev/null && sudo -n kill -TERM "$PERF_PID" 2>/dev/null || true
wait "$PERF_PID" 2>/dev/null || true
trap - EXIT INT TERM

[[ -s "$PERF_DATA" ]] || { echo "perf.data 为空" >&2; tail -20 "$RUN_DIR/perf/$TAG.perf-kernel-record.log" >&2; exit 1; }
"${PREFIX[@]}" perf report -i "$PERF_DATA" --stdio --no-children -n > "$REPORT" 2>&1 || true
head -1 "$RUN_DIR/perf/$TAG.perf-kernel-record.log" >/dev/null
echo "[perf_kernel] 符号级 top-N → $REPORT"
echo "[perf_kernel] 事件名（判断是否真的采到内核态）："
"${PREFIX[@]}" perf script -i "$PERF_DATA" --show-mmap-events 2>/dev/null | head -3 | sed 's/^/    /'
sed -n '/^# Samples/,$p' "$REPORT" | head -30
