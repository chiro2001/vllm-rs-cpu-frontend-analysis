#!/usr/bin/env bash
# 起「一侧」的前端 + 引擎栈（同一份 vLLM 0.26.0+cpu 引擎，只换前端进程）。
#
# 用法:
#   start_side.sh --side rust|python --run runs/ab/C1-rust [--port 8300] [--fe-cores 4-5]
#   start_side.sh --help
#
# 两侧启动命令（除前端开关外逐字相同）：
#   python: vllm serve <model> --port P <shared args>
#   rust  : VLLM_RUST_FRONTEND_PATH=<wheel 自带 vllm-rs> vllm serve <model> --port P <shared args>
#
# 落盘（run 目录）：frontend/engine/worker/supervisor.pid（宿主机 pid）、
#   pids.<side>.json（角色识别）、topology.<side>.txt（原始 ps/proc 视图）、
#   server.env.<side>.json（启动 manifest）、server.<side>.log（容器内日志）
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

SIDE=""; RUN_DIR=""; PORT="$AB_PORT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --side) SIDE="$2"; shift 2 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --fe-cores) AB_FE_CORES="$2"; export AB_FE_CORES; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ "$SIDE" == "rust" || "$SIDE" == "python" ]] || { echo "缺少/非法 --side" >&2; usage; exit 2; }
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; usage; exit 2; }
mkdir -p "$RUN_DIR"

ab_container_start
# 先清场：残留前端会占着 $PORT，让新一轮「bind 失败但 /health 仍 200」（踩过一次）
"$AB_DIR/stop_side.sh" --run "$RUN_DIR" --quiet || true
"$AB_DIR/ab_clean.sh" || true
ab_require_free_port "$PORT"

SERVE_ARGS="$(ab_serve_args)"
LOG_HOST="$AB_WORK/server.$SIDE.log"

if [[ "$SIDE" == "rust" ]]; then
  # 两把开关都要开：VLLM_USE_RUST_FRONTEND=1 才会真的走 Rust 前端，
  # VLLM_RUST_FRONTEND_PATH=auto 解析到 wheel 自带的 vllm-rs（同 wheel 同 commit）。
  FRONTEND_ENV="export VLLM_USE_RUST_FRONTEND=1; export VLLM_RUST_FRONTEND_PATH=auto"
else
  FRONTEND_ENV="unset VLLM_RUST_FRONTEND_PATH 2>/dev/null || true; unset VLLM_USE_RUST_FRONTEND 2>/dev/null || true"
fi

ab_say "起 $SIDE 侧：port=$PORT fe_cores=$AB_FE_CORES eng_cores=$AB_ENG_CORES cpuset=$AB_CPUSET"
ab_say "  serve args: $SERVE_ARGS"

# 主进程（= supervisor；Python 侧同时也是 API server）绑到前端核；
# VLLM_CPU_OMP_THREADS_BIND 把引擎 worker 的 OMP 线程绑到引擎核，两者不重叠。
docker exec -d "$AB_CONTAINER" bash -lc "
set -e
$(ab_pyenv)
$FRONTEND_ENV
cd /work
exec taskset -c $AB_FE_CORES vllm serve $AB_MODEL_IN_CONTAINER --port $PORT $SERVE_ARGS \
  > /work/server.$SIDE.log 2>&1
" >/dev/null 2>&1 || ab_die "docker exec 启动失败"

ab_say "等待 /health 200（上限 ${AB_START_TIMEOUT}s）…"
ok=0
for i in $(seq 1 "$AB_START_TIMEOUT"); do
  code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || echo 000)"
  if [[ "$code" == "200" ]]; then ok=1; ab_say "/health 200（${i}s）"; break; fi
  ab_container_up || ab_die "容器已退出"
  sleep 1
done
[[ "$ok" == "1" ]] || ab_die "$SIDE 侧 /health 未在 ${AB_START_TIMEOUT}s 内就绪（容器内日志 /work/server.$SIDE.log）"

python3 "$AB_DIR/ab_ctl.py" pids --side "$SIDE" --container "$AB_CONTAINER" \
  --out "$RUN_DIR/pids.$SIDE.json" --pid-dir "$RUN_DIR" || ab_die "进程拓扑识别失败：见 $RUN_DIR/pids.$SIDE.json"

{
  echo "# harness/ab/start_side.sh 采集（容器内视图）"
  echo "# taken_at: $(date -Is)"
  docker exec "$AB_CONTAINER" bash -lc 'ps -eo pid,ppid,psr,pcpu,nlwp,comm,args --sort=pid | grep -E "VLLM::|vllm-rs|vllm serve" | grep -v grep' || true
  echo
  echo "# /proc/<host_pid>/status 关键行（NSpid 证明容器内外 pid 的对应）"
  for role in frontend engine worker supervisor; do
    f="$RUN_DIR/$role.pid"
    [[ -f "$f" ]] || continue
    hp="$(cat "$f")"
    echo "--- $role host_pid=$hp ---"
    grep -E "^(Name|Pid|PPid|NSpid|Threads|Cpus_allowed_list):" "/proc/$hp/status" 2>/dev/null || echo "(gone)"
  done
} > "$RUN_DIR/topology.$SIDE.txt" 2>&1

BIN_SHA="$(ab_rust_bin_sha 2>/dev/null || echo unknown)"
ab_write_manifest "$RUN_DIR/server.env.$SIDE.json" \
  "side=$SIDE" "point=${AB_POINT:-}" "vllm_commit=$VLLM_COMMIT" "vllm_version=0.26.0+cpu" \
  "container_image=$AB_IMAGE" "container=$AB_CONTAINER" "model=$AB_MODEL_IN_CONTAINER" \
  "port=$PORT" "fe_cores=$AB_FE_CORES" "eng_cores=$AB_ENG_CORES" "client_cores=$AB_CLIENT_CORES" \
  "fe_cores_effective=$(ab_ncores "$AB_FE_CORES")" "eng_cores_effective=$(ab_ncores "$AB_ENG_CORES")" \
  "container_cpuset=$AB_CPUSET" "docker_cpus=$AB_DOCKER_CPUS" "docker_mem=$AB_DOCKER_MEM" \
  "serve_args=$SERVE_ARGS" "max_model_len=$AB_MAX_MODEL_LEN" "kv_cache_space_gb=$AB_KVCACHE_SPACE" \
  "rust_frontend_sha256=$BIN_SHA" "frontend_kind=$SIDE" \
  "loadavg=$(ab_loadavg)" "mem_available_gib=$(ab_mem_avail)" \
  "topology_path=$RUN_DIR/topology.$SIDE.txt" "pids_path=$RUN_DIR/pids.$SIDE.json"

ab_say "栈就绪（$SIDE）→ $RUN_DIR"
