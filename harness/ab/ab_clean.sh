#!/usr/bin/env bash
# 清场：杀掉容器内所有 vLLM 前端/引擎残留 + 宿主上本项目自己的 vllm-mock-engine。
#
# 用法:
#   ab_clean.sh [--container cab-cpu] [--dry-run]
#   ab_clean.sh --help
#
# 为什么必须存在：残留的前端进程仍占着 $PORT，于是新一轮 `start_side.sh` 里前端
#   bind 失败、进程退出，但 `/health` 却由**旧进程**回答 200 —— 实验会在错误的
#   进程上跑完（踩过一次）。所以每次起栈前先清场，并在起栈后校验前端 pid 是我们
#   这次起的那个。
#
# 安全性：只匹配 argv 含 `vllm serve` / `vllm-rs`，或 comm 形如 `VLLM::*` 的进程；
#   不动其它容器、不动别人的进程、不碰 NPU。
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --container) AB_CONTAINER="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

if ab_container_up; then
  # 两轮：先 TERM 再 KILL；每一轮都重新枚举（避免杀到刚 fork 的子进程）
  #
  # ⚠️ 必须按 **comm** 匹配，不能按 cmdline 匹配：`docker exec ... bash -lc`
  #    自己这条命令行里就含 "vllm serve" 字样，按 cmdline 匹配会先杀掉自己、
  #    循环直接中断（踩过：清场永远返回 0 但残留进程一个没死）。
  #    vLLM 会用 setproctitle 把 comm 设成 `vllm` / `vllm-rs` / `VLLM::*`，据此白名单。
  for sig in TERM KILL; do
    docker exec "$AB_CONTAINER" bash -lc "
      for p in \$(ls /proc | grep -E '^[0-9]+\$'); do
        c=\$(cat /proc/\$p/comm 2>/dev/null)
        case \"\$c\" in
          vllm|vllm-rs|vllm-mock-engine|VLLM::*) kill -$sig \$p 2>/dev/null || true;;
          *)
            # 引擎/前端的 python 子进程（resource_tracker 等）comm 是 python3.12
            a=\$(tr '\0' ' ' < /proc/\$p/cmdline 2>/dev/null)
            case \"\$a\" in *'/vllm '*) kill -$sig \$p 2>/dev/null || true;; esac
            ;;
        esac
      done
    " >/dev/null 2>&1 || true
    [[ "$sig" == "TERM" ]] && sleep 3
  done
  n="$(docker exec "$AB_CONTAINER" bash -lc "ls /proc | grep -E '^[0-9]+\$' | while read p; do c=\$(cat /proc/\$p/comm 2>/dev/null); case \"\$c\" in vllm|vllm-rs|vllm-mock-engine|VLLM::*) echo x;; esac; done | wc -l" 2>/dev/null || echo 0)"
  [[ "$DRY" == "1" ]] || ab_say "容器内残留 vLLM 进程数：${n:-?}"
fi

# 宿主上本项目的 mock engine（只匹配本项目二进制路径）
for p in $(pgrep -f "vllm-mock-engine --handshake-address" 2>/dev/null || true); do
  if [[ "$DRY" == "1" ]]; then echo "[ab][clean][dry] would kill $p"; else kill -TERM "$p" 2>/dev/null || true; fi
done
sleep 1
for p in $(pgrep -f "vllm-mock-engine --handshake-address" 2>/dev/null || true); do
  [[ "$DRY" == "1" ]] || kill -KILL "$p" 2>/dev/null || true
done
[[ "$DRY" == "1" ]] || ab_say "清场完成"
