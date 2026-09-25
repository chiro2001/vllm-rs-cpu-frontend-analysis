#!/usr/bin/env bash
# 起停「前端 + 引擎」栈，并把 PID / 日志 / 绑核落到 run 目录，供 A/B 与 profiling 复用。
#
# 用法:
#   stack.sh start --run runs/demo --model REPO_HOME/models/Qwen3-0.6B [--engine mock|none]
#   stack.sh stop  --run runs/demo
#   stack.sh status --run runs/demo
#   stack.sh --help
#
# 约定（plan/COORDINATION.md §5）：
#   - 三段分开绑核：前端 FE_CORES / 引擎 ENG_CORES / 客户端 CLIENT_CORES，互不抢核。
#   - 前端是分析对象；压测客户端是另一个进程，必须单独记录 CPU。
#   - 起停都写 runs/<name>/stack.json，含 pid、绑核、端口、制品 sha256。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

[[ $# -ge 1 ]] || { usage; exit 2; }
SUBCMD="$1"; shift
case "$SUBCMD" in -h|--help) usage; exit 0 ;; esac

RUN_DIR=""; ENGINE="mock"; FRONTEND="${FRONTEND:-rust}"; WAIT_SECS="${WAIT_SECS:-90}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --frontend) FRONTEND="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; exit 2; }

FE_PID_FILE="$RUN_DIR/frontend.pid"
ENG_PID_FILE="$RUN_DIR/engine.pid"
FE_LOG="$RUN_DIR/frontend.log"
ENG_LOG="$RUN_DIR/engine.log"

fe_alive() { [[ -f "$FE_PID_FILE" ]] && kill -0 "$(cat "$FE_PID_FILE")" 2>/dev/null; }
eng_alive() { [[ -f "$ENG_PID_FILE" ]] && kill -0 "$(cat "$ENG_PID_FILE")" 2>/dev/null; }

http_code() { curl -s -m 3 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

case "$SUBCMD" in
  start)
    [[ -x "$FRONTEND_BIN" ]] || die "找不到 vllm-rs：$FRONTEND_BIN（先跑 fetch_artifacts.sh）"
    [[ -d "$MODEL" ]] || die "模型目录不存在：$MODEL"
    mkdir -p "$RUN_DIR"
    if fe_alive; then die "前端已在跑（pid $(cat "$FE_PID_FILE")），先 stop"; fi

    say "启动前端 [$FRONTEND]绑核=$FE_CORES 端口=$PORT 握手=$HANDSHAKE_PORT"
    case "$FRONTEND" in
      rust)
        setsid taskset -c "$FE_CORES" "$FRONTEND_BIN" serve "$MODEL" \
          --data-parallel-size 1 --data-parallel-size-local 0 \
          --handshake-port "$HANDSHAKE_PORT" --host 127.0.0.1 --port "$PORT" \
          --engine-ready-timeout-secs "$WAIT_SECS" > "$FE_LOG" 2>&1 &
        ;;
      *) die "暂不支持的前端类型：$FRONTEND（C 线如需 Python 前端，自行扩展本脚本或另写 harness/ab/）" ;;
    esac
    echo $! > "$FE_PID_FILE"

    # ⚠️ 顺序：前端先绑好 ZMQ 握手插座，引擎才能连上；HTTP 要等握手完成才开。
    ok=0
    for _ in $(seq 1 "$WAIT_SECS"); do
      grep -q 'waiting for engines to connect' "$FE_LOG" 2>/dev/null && { ok=1; break; }
      fe_alive || { tail -20 "$FE_LOG" >&2; die "前端进程已退出（见 $FE_LOG）"; }
      sleep 1
    done
    [[ "$ok" == "1" ]] || die "前端未在 ${WAIT_SECS}s 内进入握手等待（见 $FE_LOG）"
    say "前端已监听握手端口 $HANDSHAKE_PORT"

    if [[ "$ENGINE" == "mock" ]]; then
      [[ -x "$MOCK_ENGINE_BIN" ]] || die "找不到 mock engine：$MOCK_ENGINE_BIN"
      VOCAB_SIZE="${VOCAB_SIZE:-32000}"
      say "启动 mock engine 绑核=$ENG_CORES vocab=$VOCAB_SIZE"
      setsid taskset -c "$ENG_CORES" "$MOCK_ENGINE_BIN" \
        --handshake-address "tcp://127.0.0.1:$HANDSHAKE_PORT" \
        --engine-count 1 --vocab-size "$VOCAB_SIZE" --seed "${SEED:-0}" --log-requests \
        > "$ENG_LOG" 2>&1 &
      echo $! > "$ENG_PID_FILE"
      ok=0
      for _ in $(seq 1 "$WAIT_SECS"); do
        grep -q 'engines connected' "$FE_LOG" 2>/dev/null && { ok=1; break; }
        eng_alive || { tail -20 "$ENG_LOG" >&2; die "mock engine 已退出（见 $ENG_LOG）"; }
        sleep 1
      done
      [[ "$ok" == "1" ]] || die "ZMQ 握手在 ${WAIT_SECS}s 内未完成（见 $FE_LOG / $ENG_LOG）"
      say "ZMQ 握手完成（engines connected）"
    fi

    # 等 HTTP 起来
    ok=0
    for _ in $(seq 1 "$WAIT_SECS"); do
      if [[ "$(http_code "http://127.0.0.1:$PORT/health")" == "200" ]]; then ok=1; break; fi
      fe_alive || { tail -20 "$FE_LOG" >&2; die "前端进程已退出（见 $FE_LOG）"; }
      sleep 1
    done
    [[ "$ok" == "1" ]] || die "前端 /health 在 ${WAIT_SECS}s 内未就绪（见 $FE_LOG）"
    say "前端 /health 200"

    # /v1/models 与一次最小 chat 冒烟
    [[ "$(http_code "http://127.0.0.1:$PORT/v1/models")" == "200" ]] || die "/v1/models 不是 200"
    SMOKE="$(curl -s -m 30 -o "$RUN_DIR/smoke-chat.json" -w '%{http_code}' \
      -X POST "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4,\"temperature\":0}")"
    [[ "$SMOKE" == "200" ]] || { tail -20 "$RUN_DIR/smoke-chat.json" >&2; die "冒烟 chat 失败：HTTP $SMOKE"; }
    say "冒烟 chat 200"

    python3 - "$RUN_DIR/stack.json" <<PY
import json, time
json.dump({
  "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
  "frontend": {"kind": "$FRONTEND", "bin": "$FRONTEND_BIN", "pid": $(cat "$FE_PID_FILE"),
               "cores": "$FE_CORES", "port": $PORT, "host": "127.0.0.1", "log": "$FE_LOG"},
  "engine": {"kind": "$ENGINE", "bin": "$MOCK_ENGINE_BIN", "pid": $( [[ -f "$ENG_PID_FILE" ]] && cat "$ENG_PID_FILE" || echo null ),
             "cores": "$ENG_CORES", "handshake_port": $HANDSHAKE_PORT, "log": "$ENG_LOG"},
  "client_cores": "$CLIENT_CORES",
  "model": "$MODEL",
  "frontend_bin_sha256": "$(sha256sum "$FRONTEND_BIN" | awk '{print $1}')",
}, open("$RUN_DIR/stack.json", "w"), ensure_ascii=False, indent=1)
PY
    say "栈就绪 → $RUN_DIR/stack.json"
    ;;
  stop)
    for f in "$FE_PID_FILE" "$ENG_PID_FILE"; do
      [[ -f "$f" ]] || continue
      pid="$(cat "$f")"
      if kill -0 "$pid" 2>/dev/null; then
        # setsid 起的进程组：杀整组，避免 taskset/子进程残留
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$pid" 2>/dev/null && kill -KILL -"$pid" 2>/dev/null || true
        say "已停 pid=$pid（$f）"
      fi
      rm -f "$f"
    done
    ;;
  status)
    if fe_alive; then echo "frontend: UP pid=$(cat "$FE_PID_FILE")"; else echo "frontend: DOWN"; fi
    if eng_alive; then echo "engine:   UP pid=$(cat "$ENG_PID_FILE")"; else echo "engine:   DOWN"; fi
    echo "health:   HTTP $(http_code "http://127.0.0.1:$PORT/health")"
    ;;
  *) echo "未知子命令：$SUBCMD" >&2; usage; exit 2 ;;
esac
