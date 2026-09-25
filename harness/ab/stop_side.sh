#!/usr/bin/env bash
# 停掉一侧的前端 + 引擎栈（含容器内的 EngineCore / Worker 子进程）。
#
# 用法:
#   stop_side.sh --run runs/ab/C1-rust [--port 8300] [--keep-container] [--quiet]
#   stop_side.sh --help
#
# 只杀本 run 记录的 pid 及其进程组，不动容器里其它东西（尤其不碰别人的容器）。
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --keep-container) AB_KEEP_CONTAINER=1; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; usage; exit 2; }

say() { [[ "$QUIET" == "1" ]] || printf '[ab] %s\n' "$*"; }

# 1) 容器内先按进程组 TERM（EngineCore/Worker/vllm-rs 都在主进程的进程组里）
#    ⚠️ 按 **comm** 白名单匹配（vllm / vllm-rs / VLLM::*），不能按 cmdline：
#    `docker exec ... bash -lc` 自身的命令行里就含 "vllm serve" 字样，按 cmdline
#    匹配会先杀掉自己、循环中断（踩过：清场报成功但进程一个没死，端口一直被占）。
if ab_container_up; then
  docker exec "$AB_CONTAINER" bash -lc '
    for p in $(ls /proc | grep -E "^[0-9]+$"); do
      c=$(cat /proc/$p/comm 2>/dev/null)
      case "$c" in
        vllm|vllm-rs|vllm-mock-engine|VLLM::*) kill -TERM "$p" 2>/dev/null || true;;
      esac
    done
  ' >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    n="$(docker exec "$AB_CONTAINER" bash -lc 'ls /proc | grep -E "^[0-9]+$" | while read p; do c=$(cat /proc/$p/comm 2>/dev/null); case "$c" in vllm|vllm-rs|vllm-mock-engine|VLLM::*) echo x;; esac; done | wc -l' 2>/dev/null || echo 0)"
    [[ "${n:-0}" == "0" ]] && break
    sleep 1
  done

  docker exec "$AB_CONTAINER" bash -lc '
    for p in $(ls /proc | grep -E "^[0-9]+$"); do
      c=$(cat /proc/$p/comm 2>/dev/null)
      case "$c" in
        vllm|vllm-rs|vllm-mock-engine|VLLM::*) kill -KILL "$p" 2>/dev/null || true;;
      esac
    done
  ' >/dev/null 2>&1 || true
fi

rm -f "$RUN_DIR"/frontend.pid "$RUN_DIR"/engine.pid "$RUN_DIR"/worker.pid "$RUN_DIR"/supervisor.pid 2>/dev/null || true

# mock 臂的引擎是宿主机上的 vllm-mock-engine（单独记 pid）
if [[ -f "$RUN_DIR/mock_engine.pid" ]]; then
  mp="$(cat "$RUN_DIR/mock_engine.pid")"
  if kill -0 "$mp" 2>/dev/null; then
    kill -TERM -"$mp" 2>/dev/null || kill -TERM "$mp" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$mp" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$mp" 2>/dev/null && kill -KILL -"$mp" 2>/dev/null || true
  fi
  rm -f "$RUN_DIR/mock_engine.pid"
fi
say "已停 $RUN_DIR"

if [[ "${AB_KEEP_CONTAINER:-0}" != "1" && "${AB_STOP_CONTAINER:-0}" == "1" ]]; then
  ab_container_stop
fi
