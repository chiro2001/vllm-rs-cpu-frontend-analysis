#!/usr/bin/env bash
# REMOTE_HOST chip4 的**远端互斥锁** —— 保证同一时刻只有一条线在 chip4 上跑实验。
#
# 为什么需要：REMOTE_HOST 上 chip4 只有一张卡、一份模型；
# B 线（profiling）与 C 线（A/B）若同时起引擎，会互相抢 HBM 和 CPU，
# 测出来的数谁都不算数。本锁把「用 chip4」这件事串行化。
#
# 锁放在 REMOTE_HOST 的 `~/projects/vllm/vllm-rs/.chip4-lock/`（宿主机侧，供所有 agent 共享）。
# 与本地 `scripts/heavy_lock.sh`（管本机 12 核）是**两把不同的锁**：
#   * 本机重活（cargo 编译、微基准）→ `scripts/heavy_lock.sh`
#   * REMOTE_HOST chip4 实验            → `harness/a3/chip_lock.sh`
# 两者互不冲突；只碰 REMOTE_HOST 的实验不必拿本机锁。
#
# 用法:
#   harness/a3/chip_lock.sh -- <命令...>      # 拿锁执行（默认最多等 3600 s）
#   WAIT=0 harness/a3/chip_lock.sh <命令...> # 拿不到立刻失败
#   harness/a3/chip_lock.sh --status
#   harness/a3/chip_lock.sh --release         # 仅在确认持有者已死时用
#   harness/a3/chip_lock.sh --help
set -euo pipefail

A3_HOST="${A3_HOST:-REMOTE_HOST}"
WAIT="${WAIT:-3600}"
LOCK_DIR="\$HOME/projects/vllm/vllm-rs/.chip4-lock"
OWNER="${OWNER:-${USER:-unknown}:$$}"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

status() {
  ssh -o BatchMode=yes "$A3_HOST" "
    if [ -d $LOCK_DIR ]; then echo HELD; cat $LOCK_DIR/lease.json 2>/dev/null; else echo FREE; fi"
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  --status) status; exit 0 ;;
  --release)
    ssh -o BatchMode=yes "$A3_HOST" "rm -rf $LOCK_DIR && echo released"
    exit 0
    ;;
esac

[[ "${1:-}" == "--" ]] && shift
[[ $# -gt 0 ]] || { usage; exit 2; }

# 在远端拿锁：mkdir 是原子的
ssh -o BatchMode=yes "$A3_HOST" "WAIT='$WAIT' OWNER='$OWNER' LOCK_DIR=$LOCK_DIR bash -s" <<'REMOTE'
set -euo pipefail
deadline=$(( $(date +%s) + WAIT ))
while true; do
  if mkdir -p "$(dirname "$LOCK_DIR")" && mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '{"owner": "%s", "host": "%s", "started_at": "%s", "purpose": "%s"}\n' \
      "$OWNER" "$(hostname)" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" > "$LOCK_DIR/lease.json"
    echo "[chip_lock] acquired by $OWNER" >&2
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "[chip_lock] 等待超时（${WAIT}s），当前持有者：" >&2
    cat "$LOCK_DIR/lease.json" 2>/dev/null >&2 || true
    exit 1
  fi
  echo "[chip_lock] 被占用，等待中…" >&2
  sleep 20
done
REMOTE

# 命令通过 stdin 送给远端执行（保留引号与管道）
CMD="$(printf '%q ' "$@")"
cleanup() {
  ssh -o BatchMode=yes "$A3_HOST" "rm -rf $LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC2029
ssh -o BatchMode=yes "$A3_HOST" "cd \$HOME/projects/vllm/vllm-rs && bash -c '$CMD'"
