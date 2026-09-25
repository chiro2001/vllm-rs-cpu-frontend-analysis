#!/usr/bin/env bash
# A/B（C 线）共享常量与工具函数。所有 harness/ab/*.sh 先 source 本文件。
#
# A/B 设计（见 docs/ab-design.md）：
#   同一台机器、同一个 vLLM 0.26.0+cpu 引擎实现、同一个模型、同一个压测客户端；
#   唯一变量 = 前端进程（Python API server ↔ Rust vllm-rs），两者都经 ZMQ+msgpack
#   与同一个 engine core 通信。
#
# 两侧的启动方式（vLLM 0.26.0 的"拓扑 C"，见 docs/01b-python-frontend-anchors.md §1.3）：
#   Rust 侧:  VLLM_RUST_FRONTEND_PATH=<wheel 自带 vllm-rs> vllm serve <model> ...
#   Python 侧: vllm serve <model> ...            （主进程自己就是 API server）
# 两者的 supervisor 都是同一份 Python 代码、同一份引擎；差别只在"谁做前端"。
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AB_DIR/../.." && pwd)"
# shellcheck source=../common/env.sh
source "$REPO_ROOT/harness/common/env.sh"

# ---- 容器（纯 CPU，无 NPU 设备，无 --device / 无 ASCEND_* 变量）----
AB_CONTAINER="${AB_CONTAINER:-cab-cpu}"
AB_IMAGE="${AB_IMAGE:-local/vllm-cpu:0.26.0-ab-20260925}"
AB_MODELS="${AB_MODELS:-REPO_HOME/models}"
AB_WORK="${AB_WORK:-$HOME/.cache/cab-cpu}"

# 容器 cpuset：核 4-11（8 核）。前端与引擎在这个集合内部再分。
AB_CPUSET="${AB_CPUSET:-4-11}"

# ---- 绑核（CORES 语义 = taskset 的核列表，不是核数）----
# 前端：被分析对象。默认 2 核。
AB_FE_CORES="${AB_FE_CORES:-4-5}"
# 引擎：VLLM_CPU_OMP_THREADS_BIND 用同一组（引擎 worker 的 OMP 线程绑到这里）。
AB_ENG_CORES="${AB_ENG_CORES:-8-11}"
# 压测客户端：宿主机上跑，必须与前端/引擎分开。
AB_CLIENT_CORES="${AB_CLIENT_CORES:-0-1}"
# mock 臂的引擎（宿主 vllm-mock-engine）：与前端、客户端分开。
AB_ENG_MOCK_CORES="${AB_ENG_MOCK_CORES:-8-9}"
# mock 臂的 handshake 端口（容器内 python 前端 bind 在 host 网络上）
AB_HANDSHAKE_PORT="${AB_HANDSHAKE_PORT:-29550}"

# ---- 端口 ----
AB_PORT="${AB_PORT:-8300}"

# ---- 模型与引擎参数（两侧必须完全一致）----
AB_MODEL_IN_CONTAINER="${AB_MODEL_IN_CONTAINER:-/models/Qwen3-0.6B}"
AB_MAX_MODEL_LEN="${AB_MAX_MODEL_LEN:-16384}"
AB_KVCACHE_SPACE="${AB_KVCACHE_SPACE:-4}"
AB_ENGINE_EXTRA_ARGS="${AB_ENGINE_EXTRA_ARGS:---no-enable-prefix-caching}"

# 容器内 cgroup 上限（docker_run.sh 同口径）
AB_DOCKER_CPUS="${AB_DOCKER_CPUS:-8}"
AB_DOCKER_MEM="${AB_DOCKER_MEM:-8g}"

# 轮询/超时
AB_START_TIMEOUT="${AB_START_TIMEOUT:-900}"
AB_STOP_TIMEOUT="${AB_STOP_TIMEOUT:-60}"

# ---- 运行目录 ----
AB_RUNS_ROOT="${AB_RUNS_ROOT:-$REPO_ROOT/runs}"

# ============================ 工具函数 ============================

ab_die() { echo "[ab][error] $*" >&2; exit 1; }
ab_say() { printf '[ab] %s\n' "$*"; }

# 容器是否在跑
ab_container_up() {
  docker inspect -f '{{.State.Running}}' "$AB_CONTAINER" 2>/dev/null | grep -q true
}

# 在容器内执行（只读/控制类小命令，不占重活锁）
ab_exec() { docker exec "$AB_CONTAINER" bash -lc "$*"; }

# 起容器：纯 CPU、无设备、host 网络（便于宿主 perf/procstat 直接看 pid）
ab_container_start() {
  if ab_container_up; then
    ab_say "容器已在跑：$AB_CONTAINER"
    return 0
  fi
  docker rm -f "$AB_CONTAINER" >/dev/null 2>&1 || true
  ab_say "启动容器 $AB_CONTAINER（image=$AB_IMAGE cpuset=$AB_CPUSET cpus=$AB_DOCKER_CPUS mem=$AB_DOCKER_MEM）"
  docker run -d --name "$AB_CONTAINER" \
    --init \
    --network=host \
    --cpuset-cpus="$AB_CPUSET" --cpus="$AB_DOCKER_CPUS" \
    --memory="$AB_DOCKER_MEM" --memory-swap="$AB_DOCKER_MEM" --shm-size=2g \
    -v "$AB_MODELS:/models:ro" -v "$AB_WORK:/work" \
    -e HF_HUB_OFFLINE=1 \
    --entrypoint sleep "$AB_IMAGE" infinity >/dev/null
  ab_say "容器已启动"
}

ab_container_stop() {
  if ab_container_up; then
    docker rm -f "$AB_CONTAINER" >/dev/null 2>&1 || true
    ab_say "容器已删除：$AB_CONTAINER"
  fi
}

# 容器内统一的 Python 环境（LD_PRELOAD / 线程数 / OMP 绑核 / inductor 缓存）
ab_pyenv() {
  cat <<EOF
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4:/usr/local/lib/libiomp5.so
export OMP_NUM_THREADS=$(ab_ncores "$AB_ENG_CORES")
export MKL_NUM_THREADS=$(ab_ncores "$AB_ENG_CORES")
export VLLM_CPU_OMP_THREADS_BIND=$AB_ENG_CORES
export VLLM_CPU_KVCACHE_SPACE=$AB_KVCACHE_SPACE
export VLLM_PROCESS_NAME_PREFIX=VLLM
export TORCHINDUCTOR_CACHE_DIR=/work/inductor-cache
export TRITON_CACHE_DIR=/work/triton-cache
export VLLM_CACHE_ROOT=/work/vllm-cache
export TOKENIZERS_PARALLELISM=false
export PYTHONUNBUFFERED=1
EOF
}

ab_ncores() {
  python3 - "$1" <<'PY'
import sys
total = 0
for part in sys.argv[1].split(','):
    if '-' in part:
        a, b = part.split('-'); total += int(b) - int(a) + 1
    else:
        total += 1
print(total)
PY
}

# 两侧共用的 vllm serve 参数（除 --port 与前端开关外完全一致）
ab_serve_args() {
  echo --max-model-len "$AB_MAX_MODEL_LEN" $AB_ENGINE_EXTRA_ARGS
}

# 断言端口空闲。为什么必须：残留前端仍占着 $PORT 时，新前端 bind 失败退出，
# 但 `/health` 会由**旧进程**回答 200 —— 实验会安静地跑在错误的进程上（踩过一次）。
ab_require_free_port() {
  local port="$1"
  local holder
  holder="$(sudo -n ss -ltnp 2>/dev/null | grep -E ":$port\b" || true)"
  if [[ -n "$holder" ]]; then
    ab_die "$port 端口已被占用，拒绝开始（先跑 harness/ab/ab_clean.sh）：
$holder"
  fi
}

# 取容器内 vllm-rs（CPU wheel 自带的那个）的 sha256，写进 manifest
ab_rust_bin_sha() {
  ab_exec 'sha256sum /usr/local/lib/python3.12/site-packages/vllm/vllm-rs | awk "{print \$1}"'
}

# 宿主机侧当前 loadavg / 可用内存
ab_loadavg() { awk '{print $1, $2, $3}' /proc/loadavg; }
ab_mem_avail() { awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo; }

# 写 manifest：字段与 plan/COORDINATION.md §5.6 对齐
ab_write_manifest() {
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import hashlib, json, os, pathlib, socket, subprocess, sys, time
out, *pairs = sys.argv[1:]
kv = dict(p.split("=", 1) for p in pairs if "=" in p)

def sha(p):
    try:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None

doc = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "host": socket.gethostname(),
    "machine": os.uname().machine,
    "nproc": os.cpu_count(),
    "loadavg_at_start": open("/proc/loadavg").read().split()[:3],
    "mem_available_gib": round(
        int(next(l for l in open("/proc/meminfo") if l.startswith("MemAvailable")).split()[1]) / 1048576, 1
    ),
    "artifacts": {},
    "fields": {},
}
for k, v in kv.items():
    if k.endswith("_path"):
        doc["artifacts"][k[:-5]] = {
            "path": v, "sha256": sha(v),
            "size": os.path.getsize(v) if os.path.exists(v) else None,
        }
    else:
        doc["fields"][k] = v
pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
print(f"[ab][manifest] {out}")
PY
}

# 容器内进程拓扑：写 `<out>` 并回显关键信息
ab_topology() {
  local out="${1:-}"
  local body
  body="$(ab_exec 'for p in $(ls /proc | grep -E "^[0-9]+$"); do
    [ -r /proc/$p/cmdline ] || continue
    args=$(tr "\0" " " < /proc/$p/cmdline 2>/dev/null)
    comm=$(cat /proc/$p/comm 2>/dev/null)
    ppid=$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)
    nthreads=$(awk "{print \$20}" /proc/$p/stat 2>/dev/null)
    case "$comm" in
      VLLM::*) echo "pid=$p ppid=$ppid threads=$nthreads comm=[$comm]";;
      *) case "$args" in
           *vllm-rs*frontend*|*"/usr/local/lib/python3.12/site-packages/vllm/vllm-rs"*) echo "pid=$p ppid=$ppid threads=$nthreads comm=[$comm] args=${args:0:120}";;
           *"vllm serve"*|*entrypoints.cli.main*serve*|*vllm/cli*serve*) echo "pid=$p ppid=$ppid threads=$nthreads comm=[$comm] args=${args:0:120}";;
         esac;;
    esac
  done')"
  printf '%s\n' "$body"
  [[ -n "$out" ]] && printf '%s\n' "$body" > "$out"
  return 0
}
