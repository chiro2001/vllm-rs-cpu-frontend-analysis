#!/usr/bin/env bash
# 起「mock 引擎臂」的一侧：引擎换成 `vllm-mock-engine`（≈免费），前端仍是真前端。
#
# 用法:
#   start_mock_side.sh --side rust|python --run runs/ab/C1-mock-rust --handshake-port 29550
#   start_mock_side.sh --help
#
# 为什么需要这一臂（root 决策）：真 CPU 引擎臂上前端占比 ≈0.08%，A/B 差异被引擎淹没；
#   mock 臂让引擎≈免费，**前端占比≈100%**，才能测出前端差距的「上界」，与真引擎臂
#   一起夹出 Q4 的拐点区间。
#
# 两侧前端进程：
#   rust  : 宿主 `/usr/local/...` 不行——用容器内同一份 `vllm-rs serve`（与真引擎臂同二进制）
#   python: 容器内 `vllm serve`，`--data-parallel-size-local 0` + `--data-parallel-external-lb`
#           ⇒ 自己不拉引擎，bind handshake 等外部引擎注册（DP=2 ⇒ mock engine_count=2）
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

SIDE=""; RUN_DIR=""; HANDSHAKE="${AB_HANDSHAKE_PORT:-29550}"; PORT="$AB_PORT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --side) SIDE="$2"; shift 2 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --handshake-port) HANDSHAKE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ "$SIDE" == "rust" || "$SIDE" == "python" ]] || { echo "缺少/非法 --side" >&2; usage; exit 2; }
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; usage; exit 2; }
mkdir -p "$RUN_DIR"
ab_container_start

# 先清场：上一次运行留下的前端会占着 $PORT，导致本次前端 bind 失败却仍能在
# 旧进程上拿到 /health 200（踩过：8 分钟的实验跑在残留进程上）。
"$AB_DIR/stop_side.sh" --run "$RUN_DIR" --quiet || true
AB_SIDE="$SIDE" "$AB_DIR/ab_clean.sh" || true
ab_require_free_port "$PORT"
ab_require_free_port "$HANDSHAKE"

[[ -x "$MOCK_ENGINE_BIN" ]] || ab_die "找不到 mock engine：$MOCK_ENGINE_BIN"
ENGINE_COUNT=1

if [[ "$SIDE" == "rust" ]]; then
  # 与真引擎臂同一个二进制（wheel 自带），只是不走 vllm serve 的编排
  ab_say "起 rust 前端（mock 臂）：vllm-rs serve --handshake-port $HANDSHAKE"
  docker exec -d "$AB_CONTAINER" bash -lc "
set -e
cd /work
exec taskset -c $AB_FE_CORES /usr/local/lib/python3.12/site-packages/vllm/vllm-rs serve \
  $AB_MODEL_IN_CONTAINER --data-parallel-size 1 --data-parallel-size-local 0 \
  --handshake-port $HANDSHAKE --host 127.0.0.1 --port $PORT \
  > /work/server.mock.rust.log 2>&1
" >/dev/null 2>&1 || ab_die "docker exec 启动失败"
  WAIT_MSG='waiting for engines to connect'
else
  ENGINE_COUNT=2
  # ⚠️ 不能用 --data-parallel-external-lb：`vllm/engine/arg_utils.py:2008-2013` 对
  # 非 MoE 模型直接 raise（"Non-MoE models do not support external data parallel mode"）。
  # 可行组合：`--api-server-count 1`（强制拓扑 A，主进程自己就是 API server）
  #   + `--data-parallel-size 2 --data-parallel-size-local 0`
  # ⇒ `launch_core_engines` 里 handshake_local_only=False（local_engine_count != dp_size），
  #   于是前端 bind tcp handshake 等 2 个「remote & headless」引擎注册；
  #   正好匹配 mock engine 的默认广告（local=false, headless=true）。
  ab_say "起 python 前端（mock 臂）：vllm serve --api-server-count 1 --data-parallel-size-local 0"
  docker exec -d "$AB_CONTAINER" bash -lc "
set -e
$(ab_pyenv)
cd /work
exec taskset -c $AB_FE_CORES vllm serve $AB_MODEL_IN_CONTAINER --port $PORT \
  --api-server-count 1 \
  --data-parallel-size 2 --data-parallel-size-local 0 \
  --data-parallel-address 127.0.0.1 --data-parallel-rpc-port $HANDSHAKE \
  --max-model-len $AB_MAX_MODEL_LEN $AB_ENGINE_EXTRA_ARGS \
  > /work/server.mock.python.log 2>&1
" >/dev/null 2>&1 || ab_die "docker exec 启动失败"
  WAIT_MSG='Waiting for the engine'
fi

# 等待条件用「handshake 端口已监听」而不是日志文本：Python 侧的
# "Waiting for N core engine proc(s) to connect" 是 debug 级，默认 INFO 日志里看不到
# （踩过：等满 240 s 超时，其实前端早就 bind 好了）。
ab_say "等前端在 handshake 端口 $HANDSHAKE 上等待…"
ok=0
for _ in $(seq 1 240); do
  if python3 "$AB_DIR/wait_port.py" --port "$HANDSHAKE" --timeout 1 >/dev/null 2>&1; then ok=1; break; fi
  ab_container_up || ab_die "容器已退出"
  sleep 1
done
if [[ "$ok" != "1" ]]; then
  docker exec "$AB_CONTAINER" bash -lc "tail -25 /work/server.mock.$SIDE.log" >&2 || true
  ab_die "$SIDE 前端未在 240s 内监听 handshake 端口 $HANDSHAKE"
fi
ab_say "前端已在 handshake 端口 $HANDSHAKE 上等待"

ab_say "起 mock engine（宿主，engine_count=$ENGINE_COUNT，绑核 $AB_ENG_MOCK_CORES）"
setsid taskset -c "$AB_ENG_MOCK_CORES" "$MOCK_ENGINE_BIN" \
  --handshake-address "tcp://127.0.0.1:$HANDSHAKE" \
  --engine-count "$ENGINE_COUNT" --vocab-size "${VOCAB_SIZE:-32000}" --seed 0 \
  > "$RUN_DIR/mock-engine.log" 2>&1 &
echo $! > "$RUN_DIR/mock_engine.pid"

ab_say "等 /health 200…"
ok=0
for i in $(seq 1 240); do
  code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || echo 000)"
  [[ "$code" == "200" ]] && { ok=1; ab_say "/health 200（${i}s）"; break; }
  kill -0 "$(cat "$RUN_DIR/mock_engine.pid")" 2>/dev/null || ab_die "mock engine 已退出（见 $RUN_DIR/mock-engine.log）"
  sleep 1
done
[[ "$ok" == "1" ]] || { docker exec "$AB_CONTAINER" bash -lc "tail -20 /work/server.mock.$SIDE.log" >&2 || true; ab_die "/health 未就绪"; }

python3 "$AB_DIR/ab_ctl.py" pids --side "$SIDE" --kind mock \
  --engine-pid "$(cat "$RUN_DIR/mock_engine.pid")" --container "$AB_CONTAINER" \
  --out "$RUN_DIR/pids.$SIDE.json" --pid-dir "$RUN_DIR" || ab_die "进程识别失败"

{
  echo "# harness/ab/start_mock_side.sh 采集（$SIDE 侧 mock 臂）"
  echo "# taken_at: $(date -Is)"
  echo "--- 容器内（前端） ---"
  docker exec "$AB_CONTAINER" bash -lc 'ps -eo pid,ppid,psr,nlwp,comm,args --sort=pid | grep -E "VLLM::|vllm-rs|vllm serve" | grep -v grep' || true
  echo "--- 宿主（mock engine） ---"
  ps -o pid,ppid,psr,nlwp,comm,args -p "$(cat "$RUN_DIR/mock_engine.pid")" || true
  echo "--- NSpid 对应 ---"
  for role in frontend engine; do
    f="$RUN_DIR/$role.pid"; [[ -f "$f" ]] || continue
    hp="$(cat "$f")"
    echo "--- $role host_pid=$hp ---"
    grep -E "^(Name|Pid|PPid|NSpid|Threads|Cpus_allowed_list):" "/proc/$hp/status" 2>/dev/null || echo "(gone)"
  done
} > "$RUN_DIR/topology.$SIDE.txt" 2>&1

ab_write_manifest "$RUN_DIR/server.env.$SIDE.json" \
  "side=$SIDE" "kind=mock" "vllm_commit=$VLLM_COMMIT" "vllm_version=0.26.0+cpu" \
  "container_image=$AB_IMAGE" "model=$AB_MODEL_IN_CONTAINER" "port=$PORT" \
  "handshake_port=$HANDSHAKE" "mock_engine_count=$ENGINE_COUNT" \
  "fe_cores=$AB_FE_CORES" "eng_cores=$AB_ENG_MOCK_CORES" "client_cores=$AB_CLIENT_CORES" \
  "frontend_kind=$SIDE" "rust_frontend_sha256=$(ab_rust_bin_sha 2>/dev/null || echo unknown)" \
  "mock_engine_path=$MOCK_ENGINE_BIN" "loadavg=$(ab_loadavg)" "mem_available_gib=$(ab_mem_avail)"

ab_say "mock 臂栈就绪（$SIDE）→ $RUN_DIR"
