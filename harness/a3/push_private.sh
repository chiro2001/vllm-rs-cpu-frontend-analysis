#!/usr/bin/env bash
# 把 C 线的 harness 推到 REMOTE_HOST 上一个**只属于本线**的目录。
#
# 为什么需要：`~/projects/vllm/vllm-rs/harness/` 是多条线共用的可写目录，
#   `sync.sh push` 带 `--delete`；任何一条线 push 一次就会覆盖/删除别人的脚本
#   （实测踩到：我的 `matrix.sh` 被删、`ab_serve.sh` 被换回不带 A3_LOCAL 的版本，
#   于是「在远端跑的矩阵」中途改用 ssh 回连自己 → `Could not resolve hostname REMOTE_HOST`）。
#   C 线因此改用私有目录，与其他线彻底解耦。
#
# 用法:
#   harness/a3/push_private.sh            # 推送
#   harness/a3/push_private.sh --pull     # 把远端结果取回本地
#   harness/a3/push_private.sh --help
set -euo pipefail

A3_HOST="${A3_HOST:-REMOTE_HOST}"
CAB_REMOTE="${CAB_REMOTE:-projects/vllm/cab}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

case "${1:-push}" in
  --pull)
    shift
    for r in "$@"; do
      mkdir -p "$REPO_ROOT/runs/$r"
      rsync -a --exclude='*.perf.data' "$A3_HOST:$CAB_REMOTE/runs/$r/" "$REPO_ROOT/runs/$r/"
      echo "[cab] 取回 runs/$r"
    done
    ;;
  push|*)
    ssh -o BatchMode=yes "$A3_HOST" "mkdir -p ~/$CAB_REMOTE"
    rsync -a --delete --exclude='__pycache__/' --exclude='*.pyc' \
      "$REPO_ROOT/harness/" "$A3_HOST:$CAB_REMOTE/harness/"
    echo "[cab] harness → $A3_HOST:$CAB_REMOTE/harness"
    # ⚠️ rsync 不带 --perms 时，新文件在远端可能是 644 ⇒ 直接执行会 Permission denied
    #    （踩过：空载对照四连失败，全部报 `idle.sh: Permission denied`）。
    ssh -o BatchMode=yes "$A3_HOST" "chmod +x $CAB_REMOTE/harness/a3/*.sh $CAB_REMOTE/harness/a3/*.py \
      $CAB_REMOTE/harness/common/*.sh 2>/dev/null || true"
    ssh -o BatchMode=yes "$A3_HOST" "cd ~/$CAB_REMOTE && ls harness/a3/ && sha256sum harness/a3/matrix.sh harness/a3/point.sh harness/a3/ab_serve.sh | cut -c1-20,66-"
    ;;
esac
