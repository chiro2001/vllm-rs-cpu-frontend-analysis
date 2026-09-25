#!/usr/bin/env bash
# 把本仓库的 harness/scripts 同步到 REMOTE_HOST，并把远端结果取回。
#
# 为什么要同步而不是直接在远端写代码：REMOTE_HOST 是共享生产机，
# 本项目所有产物统一在本仓库里版本化；远端只作为**执行场所**。
#
# 用法:
#   harness/a3/sync.sh push                      # 把 harness+scripts 推到 REMOTE_HOST（**不删远端文件**）
#   harness/a3/sync.sh push --into <子目录>      # 推到自己的私有子目录（多线并行时推荐）
#   harness/a3/sync.sh push --delete             # 慎用：会删掉远端同名目录里别人放的文件
#   harness/a3/sync.sh fetch <run> [<run>...]    # 把远端 runs/<run> 取回本地 runs/
#   harness/a3/sync.sh --help
#
# 远端路径：`REMOTE_HOST:~/projects/vllm/vllm-rs/`（`A3_PROJECT` 可覆盖）
#
# ⚠️ **多线并行时不要用默认的共享目录**：四条线都会 push，而此前的实现用了
#    `rsync --delete`，结果是「谁 push 谁就把别人放进远端的脚本删掉」
#    （实测：C 线的 matrix.sh 被删、ab_serve.sh 被换回旧版本，矩阵中途崩掉）。
#    现在默认**不删**；要彻底隔离请用 `--into <子目录>` 或设 `A3_PROJECT`。
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

A3_HOST="${A3_HOST:-REMOTE_HOST}"
A3_PROJECT="${A3_PROJECT:-projects/vllm/vllm-rs}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE="\$HOME/$A3_PROJECT"

# 默认不删远端文件；--delete 显式开启（危险，见文件头）
RSYNC_DELETE=()
INTO=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) RSYNC_DELETE=(--delete); shift ;;
    --into) INTO="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"
[[ -n "$INTO" ]] && A3_PROJECT="$A3_PROJECT/$INTO"

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
esac

SUBCMD="$1"; shift || true

case "$SUBCMD" in
  push)
    echo "[sync] 推送 harness/ scripts/ → $A3_HOST:$A3_PROJECT （删除远端多余文件：$([[ ${#RSYNC_DELETE[@]} -gt 0 ]] && echo 是 || echo 否)）"
    ssh -o BatchMode=yes "$A3_HOST" "mkdir -p ~/$A3_PROJECT"
    rsync -a "${RSYNC_DELETE[@]}" \
      --exclude='__pycache__/' --exclude='*.pyc' --exclude='.venv/' \
      --exclude='target/' --exclude='*.perf.data' \
      "$REPO_ROOT/harness/" "$A3_HOST:$A3_PROJECT/harness/"
    rsync -a --exclude='__pycache__/' "$REPO_ROOT/scripts/" "$A3_HOST:$A3_PROJECT/scripts/"
    rsync -a "$REPO_ROOT/plan/" "$A3_HOST:$A3_PROJECT/plan/" 2>/dev/null || true
    echo "[sync] 完成"
    ;;
  fetch)
    [[ $# -ge 1 ]] || { echo "fetch 需要至少一个 run 名" >&2; exit 2; }
    for r in "$@"; do
      mkdir -p "$REPO_ROOT/runs"
      echo "[sync] 取回 runs/$r"
      rsync -a --exclude='*.perf.data' --exclude='*.log' \
        "$A3_HOST:$A3_PROJECT/runs/$r/" "$REPO_ROOT/runs/$r/"
    done
    echo "[sync] 完成 → $REPO_ROOT/runs/"
    ;;
  *) echo "未知子命令：$SUBCMD" >&2; usage; exit 2 ;;
esac
