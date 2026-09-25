#!/usr/bin/env bash
# REMOTE_HOST 上的 A/B 服务编排 —— **同一个 vLLM 0.26 镜像、同一个引擎、同一个 chip，
# 只换前端语言**（Rust `vllm-rs` vs Python API server）。
#
# 为什么在 REMOTE_HOST 做而不是本机 x86：
#   本机 x86 只有「纯 CPU 真引擎」，实测 TPOT 245 ms/token，比真机慢约 50×，
#   前端占比被压到 0.003%（见 agents/root/REPORT.md），A/B 差异会被淹没。
#   REMOTE_HOST（Kunpeng 920B + Ascend 910）上引擎速度接近真实部署，
#   且**与 PREPARE_INPUT_PROJECT 项目同一台机器**，topdown/IPC 口径可比。
#
# 镜像：`quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler`
#   * vLLM 源码 `/vllm-workspace/vllm` @ commit 568afb3a（与计划锁定值一致）
#   * vllm-ascend @ f2f74a16c
#   * **不含** vllm-rs 二进制（镜像内无 cargo）⇒ 用官方 aarch64 wheel 抽取的
#     预编译 `vllm-rs`（scripts/fetch_vllm_rs.py --arch aarch64）挂进容器。
#
# chip 约定（沿用 PREPARE_INPUT_PROJECT）：chip N ⇒ CPU `40N..40N+39`、`/dev/davinciN`、
# `ASCEND_RT_VISIBLE_DEVICES=N`、NUMA `N/2`。**默认 chip 4**（用户指定，davinci4）。
#
# 用法:
#   ab_serve.sh start  --run rust-c1 --frontend rust   [--chip 4] [--port 18300]
#   ab_serve.sh start  --run py-c1   --frontend python [--chip 4] [--port 18301]
#   ab_serve.sh pids   --run rust-c1        # 打印前端/引擎 pid（含容器内 pid）
#   ab_serve.sh status --run rust-c1
#   ab_serve.sh logs   --run rust-c1 [--tail 40]
#   ab_serve.sh stop   --run rust-c1
#   ab_serve.sh --help
#
# 红线：只绑 `--chip` 指定的那一个 /dev/davinciN；不加 `--device davinci0..N-1`；
#       不动别人的容器；只在 --chip 上跑。
set -euo pipefail

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 远端配置（可用环境变量覆盖）----
A3_HOST="${A3_HOST:-REMOTE_HOST}"
A3_PROJECT="${A3_PROJECT:-projects/vllm/vllm-rs}"
# A3_LOCAL=1 ⇒ 本脚本**已经在 REMOTE_HOST 上**运行（例如被 chip_lock.sh 送进来）：
# 直接用本地 bash 执行，不再 ssh 回自己。
# 踩过的坑：远端解析不出 `REMOTE_HOST` 这个主机名 ⇒ `Could not resolve hostname REMOTE_HOST`。
A3_LOCAL="${A3_LOCAL:-0}"
export A3_LOCAL
IMAGE="${VLLM_IMAGE:-quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler}"
MODEL_ROOT="${MODEL_ROOT:-models}"
MODEL_NAME="${MODEL_NAME:-Qwen3.5-0.8B}"
CHIP="${CHIP:-4}"
PORT="${PORT:-18300}"
RUST_BIN_DIR="${RUST_BIN_DIR:-projects/vllm/vllm-rs/bin}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
GPU_MEM="${GPU_MEM:-0.5}"
# C5（核数扫描）要改服务容器的 cpuset 宽度；默认沿用 chip 的 40 核区间。
# 语义提醒：NPU 装置上「核数」指的是**前端可用的 CPU 拓扑宽度**，不是 NPU 算力。
SERVER_CPUSET_OVERRIDE="${SERVER_CPUSET:-}"

# ---- 多线隔离：容器名与 label 必须带 owner ----
# 为什么（C 线实测踩到）：chip4 是四条线共用的。若所有线共用同一容器名前缀与 label，
# 任何「起栈前清场」的自保动作都会删掉别线**正在跑**的容器——实测中 C 线按
# `vrs.project=vllm-rs-analysis` 清场，把 B 线正在跑的 `vrs-ab-b-t1` 干掉了。
# 因此：**每条线必须设 AB_OWNER**（如 `AB_OWNER=c-ab`），容器名与 label 都带上它。
AB_OWNER="${AB_OWNER:-}"

SUBCMD="${1:-}"; shift || true
case "$SUBCMD" in -h|--help|"") usage; exit 0 ;; esac

RUN=""
FRONTEND="rust"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --frontend) FRONTEND="$2"; shift 2 ;;
    --chip) CHIP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --model) MODEL_NAME="$2"; shift 2 ;;
    --tail) TAIL="${2:-40}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN" ]] || { echo "缺少 --run" >&2; exit 2; }

if [[ -n "$AB_OWNER" ]]; then
  CONTAINER="vrs-ab-${AB_OWNER}-${RUN}"
else
  CONTAINER="vrs-ab-${RUN}"        # 向后兼容：未设 owner 时沿用旧命名
fi
LEGACY_CONTAINER="vrs-ab-${RUN}"   # 旧命名，始终兜底（方便停掉早期起的容器）
OWNER_LABEL="${AB_OWNER:-shared}"
RUN_DIR="\$HOME/$A3_PROJECT/runs/$RUN"

# 远端辅助片段：解析出「实际存在的容器名」，优先新命名、回落旧命名。
# 这样即使别的线还在用旧命名，stop/status/pids/logs 也能正确命中。
resolve_remote() {
  cat <<EOF
C=""
for c in $CONTAINER $LEGACY_CONTAINER; do
  if sudo -n docker ps -aq --filter "name=^\${c}\\\$" | grep -q .; then C="\$c"; break; fi
done
[ -n "\$C" ] || C=$CONTAINER
EOF
}

# 执行一段远端脚本（A3_LOCAL=1 时就是本机）
if [[ "$A3_LOCAL" == "1" ]]; then
  a3() { bash -c "$*"; }
else
  a3() { ssh -o BatchMode=yes "$A3_HOST" "$@"; }
fi

case "$SUBCMD" in
  start)
    [[ "$FRONTEND" == "rust" || "$FRONTEND" == "python" ]] || { echo "--frontend 必须是 rust|python" >&2; exit 2; }
    FIRST=$((40 * CHIP))
    CPUSET="$FIRST-$((FIRST + 39))"
    [[ -n "$SERVER_CPUSET_OVERRIDE" ]] && CPUSET="$SERVER_CPUSET_OVERRIDE"
    MEMS=$((CHIP / 2))

    # 前端相关环境：Rust 臂打开开关并指向挂进来的二进制；Python 臂显式清空
    if [[ "$FRONTEND" == "rust" ]]; then
      FE_ENV="-e VLLM_USE_RUST_FRONTEND=1 -e VLLM_RUST_FRONTEND_PATH=/opt/vllm-rs-bin/vllm-rs"
    else
      FE_ENV="-e VLLM_USE_RUST_FRONTEND=0"
    fi

    say() { printf '[a3] %s\n' "$*"; }
    say "起容器 $CONTAINER：chip=$CHIP frontend=$FRONTEND port=$PORT cpuset=$CPUSET mems=$MEMS"

    a3 "set -euo pipefail
mkdir -p ~/$A3_PROJECT/runs/$RUN
sudo -n docker rm -f $CONTAINER $LEGACY_CONTAINER >/dev/null 2>&1 || true
sudo -n docker run -d --name $CONTAINER \
  --label vrs.project=vllm-rs-analysis --label vrs.owner=$OWNER_LABEL \
  --label vrs.run=$RUN --label vrs.chip=$CHIP \
  --privileged --network host --shm-size=64g --ulimit memlock=-1:-1 \
  --cpuset-cpus=$CPUSET --cpuset-mems=$MEMS \
  --device /dev/davinci$CHIP --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc \
  -v /etc/hccn.conf:/etc/hccn.conf:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v ~/$MODEL_ROOT:/models:ro \
  -v ~/$RUST_BIN_DIR:/opt/vllm-rs-bin:ro \
  -v ~/$A3_PROJECT/runs/$RUN:/runmeta:rw \
  -e ASCEND_RT_VISIBLE_DEVICES=$CHIP \
  $FE_ENV \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_USE_MODELSCOPE=False \
  -e PYTHONUNBUFFERED=1 -e OMP_NUM_THREADS=1 -e OMP_PROC_BIND=false \
  -e TASK_QUEUE_ENABLE=1 -e MSMONITOR_USE_DAEMON=0 \
  -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
  $IMAGE \
  vllm serve /models/$MODEL_NAME --port $PORT \
    --max-model-len $MAX_MODEL_LEN --max-num-seqs $MAX_NUM_SEQS \
    --gpu-memory-utilization $GPU_MEM --no-enable-prefix-caching \
  >/tmp/$CONTAINER.launch.txt 2>&1
echo '[a3] 容器已启动，等待 HTTP 就绪…'
ok=0
for i in \$(seq 1 900); do
  code=\$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/health 2>/dev/null || echo 000)
  if [ \"\$code\" = 200 ]; then ok=1; break; fi
  if ! sudo -n docker ps --format '{{.Names}}' | grep -qx $CONTAINER; then
    echo '[a3] 容器已退出，日志尾部：' >&2
    sudo -n docker logs --tail 30 $CONTAINER 2>&1 | tail -30 >&2
    exit 1
  fi
  sleep 1
done
if [ \"\$ok\" != 1 ]; then
  echo '[a3] 900s 内 /health 未就绪；日志尾部：' >&2
  sudo -n docker logs --tail 40 $CONTAINER 2>&1 | tail -40 >&2
  exit 1
fi
echo '[a3] /health 200'
"
    say "准备就绪，采集进程拓扑与 manifest"
    "$0" pids --run "$RUN" || true
    ;;

  pids)
    a3 "$(resolve_remote)
sudo -n docker exec \$C bash -lc '
SP=/usr/local/python3.12.13/lib/python3.12/site-packages
# 前端进程：Rust 臂是 vllm-rs，Python 臂是主进程（comm=vllm）
echo \"--roles--\"
for p in \$(ls /proc | grep -E \"^[0-9]+\\\$\"); do
  c=\$(cat /proc/\$p/comm 2>/dev/null || true)
  case \"\$c\" in
    vllm-rs) echo \"frontend_rust \$p\" ;;
    vllm) echo \"supervisor_or_python_frontend \$p\" ;;
    VLLM::EngineCor*) echo \"engine \$p\" ;;
    VLLM::Worker*) echo \"worker \$p\" ;;
  esac
done
echo \"--ps--\"
ps -eo pid,ppid,comm,args --sort=pid | grep -E \"vllm|EngineCor|Worker\" | grep -v grep | head -20
' 2>&1 | tee ~/$A3_PROJECT/runs/$RUN/topology.txt"
    ;;

  status)
    a3 "$(resolve_remote)
        sudo -n docker ps --filter name=^\$C\$ --format '{{.Names}} {{.Status}}'; \
        curl -s -m 3 -o /dev/null -w 'health HTTP %{http_code}\n' http://127.0.0.1:$PORT/health || true"
    ;;

  logs)
    a3 "$(resolve_remote)
        sudo -n docker logs --tail ${TAIL:-40} \$C 2>&1 | tail -${TAIL:-40}"
    ;;

  stop)
    a3 "for c in $CONTAINER $LEGACY_CONTAINER; do
          if sudo -n docker ps -aq --filter \"name=^\${c}\\\$\" | grep -q .; then
            sudo -n docker rm -f \"\$c\" >/dev/null 2>&1 && echo \"[a3] 已停止 \$c\"
          fi
        done"
    ;;

  cleanup)
    # 只清**自己 owner** 的残留容器。**绝不**按 vrs.project 全清——那会误伤别线正在跑的容器。
    a3 "n=\$(sudo -n docker ps -aq --filter label=vrs.owner=$OWNER_LABEL | wc -l)
        if [ \"\$n\" -gt 0 ]; then
          sudo -n docker ps -aq --filter label=vrs.owner=$OWNER_LABEL | xargs -r sudo -n docker rm -f >/dev/null 2>&1
          echo \"[a3] 已清理 \$n 个 owner=$OWNER_LABEL 的残留容器\"
        else
          echo \"[a3] 无 owner=$OWNER_LABEL 的残留容器\"
        fi"
    ;;

  *) echo "未知子命令：$SUBCMD" >&2; usage; exit 2 ;;
esac
