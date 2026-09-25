#!/usr/bin/env bash
# **在 REMOTE_HOST 上运行**：跑完整的 A/B 矩阵（C1–C5，两侧各一遍）。
#
# 用法（本地）:
#   harness/a3/chip_lock.sh -- bash harness/a3/matrix.sh --configs C1 [--reps 3]
#   harness/a3/chip_lock.sh -- bash harness/a3/matrix.sh --configs C2,C3,C4
#   harness/a3/chip_lock.sh -- bash harness/a3/matrix.sh --configs C5
#   harness/a3/chip_lock.sh -- bash harness/a3/matrix.sh --configs all --dry-run
#
# 设计要点（见 docs/ab-design.md）：
#   * 每个 config × side 都是「起容器 → 预热 → 正式负载 → 采 CPU/perf → 停容器」的独立单元，
#     任何一步失败都记录并**继续下一个**，不丢弃已完成的数据。
#   * 两侧**同一个镜像、同一张卡（chip4）、同一个客户端容器、同一组绑核**，
#     只差 `VLLM_USE_RUST_FRONTEND`。
#   * `--reps N` 时用 tag `C1r1/C1r2/C1r3` 分别落盘，便于事后取中位数。
#   * 每个 config-side 结束都 `stop` 容器，绝不留容器占着卡。
set -uo pipefail     # 注意：故意不用 -e，单个点失败要继续

# 本脚本设计为在 REMOTE_HOST 上运行（chip_lock 送进来）⇒ 让 ab_serve.sh 走本地模式
export A3_LOCAL=1
# 私有目录（不与他人共用的 harness/ 混用；见 push_private.sh 的说明）
export A3_PROJECT="${A3_PROJECT:-projects/vllm/cab}"
# **本线的 owner 标识**：容器名变成 `vrs-ab-c-ab-<run>`、label `vrs.owner=c-ab`，
# 于是 `ab_serve.sh cleanup` 只会清自己的容器（此前按共享 label 清场误删过 B 线的容器）。
export AB_OWNER="${AB_OWNER:-c-ab}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="${RUNS_ROOT:-$HOME/projects/vllm/cab/runs}"
CHIP="${CHIP:-4}"
CLIENT_CORES="${CLIENT_CORES:-200-201}"
PORT_BASE="${PORT_BASE:-18300}"
DO_PERF="${DO_PERF:-1}"
# IDLE=1 ⇒ 每个 config×side 起栈后先插一段**空载窗口**（不发任何请求），
# 得到「空转速率」，用于把每请求成本拆成「空转摊薄 + 边际处理」两部分。
IDLE="${IDLE:-0}"
IDLE_SECONDS="${IDLE_SECONDS:-30}"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

CONFIGS="all"; REPS=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --configs) CONFIGS="$2"; shift 2 ;;
    --reps) REPS="$2"; shift 2 ;;
    --no-perf) DO_PERF=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

say() { printf '[matrix] %s\n' "$*"; }

# 起栈前清场：只收**本线自己**的残留容器。
#
# ⚠️ 用 `ab_serve.sh cleanup`（按 `label=vrs.owner=$AB_OWNER` 过滤），不按
#    `vrs.project` 全清：后者是四条线共用的 label，会把别线**正在跑**的容器一起 rm 掉
#    （实测踩到：C 线按 project label 清场，删掉了 B 线正在跑的 `vrs-ab-b-t1`）。
#    兜底再加一层**容器名前缀**匹配，防止旧命名的残留漏网。
CAB_CONTAINER_PREFIX="${CAB_CONTAINER_PREFIX:-vrs-ab-${AB_OWNER}-}"
cleanup_our_containers() {
  local names n
  # 1) 官方 cleanup：按 owner label（新命名，带 owner 的容器）
  "$HERE/ab_serve.sh" cleanup >/dev/null 2>&1 || true
  # 2) 兜底：按容器名前缀（覆盖旧命名 vrs-ab-ab-* 之类的残留）
  names="$(sudo -n docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${CAB_CONTAINER_PREFIX}" || true)"
  if [[ -n "$names" ]]; then
    n="$(printf '%s\n' "$names" | wc -l)"
    say "清场：收掉本线残留容器 $n 个（$(printf '%s ' $names)）"
    # shellcheck disable=SC2086
    sudo -n docker rm -f $names >/dev/null 2>&1 || true
  fi
}

# 起栈后验证：容器里必须真出现该侧的前端进程，否则报错（防「跑在旧容器上」）
verify_frontend() {  # $1=run $2=side
  # ⚠️ 容器名要**动态解析**（设了 AB_OWNER 后是 `vrs-ab-c-ab-<run>`）；
  #    硬编码旧命名会「找不到容器」而误判起栈失败（踩过一整轮 C2–C5）。
  local c pat
  c="$(sudo -n docker ps --format '{{.Names}}' | grep -E "^vrs-ab-(${AB_OWNER}-)?$1\$" | head -1 || true)"
  [[ -n "$c" ]] || { say "⚠️ 找不到容器（run=$1 owner=$AB_OWNER）"; return 1; }
  [[ "$2" == "rust" ]] && pat='^vllm-rs$' || pat='^vllm$'
  for _ in $(seq 1 30); do
    if sudo -n docker top "$c" -eo pid,comm 2>/dev/null | awk -v p="$pat" '$2 ~ p {found=1} END {exit !found}'; then
      return 0
    fi
    sleep 1
  done
  say "⚠️ 容器 $c 内未找到前端进程（$pat）"
  sudo -n docker top "$c" -eo pid,ppid,comm 2>&1 | head -10 | sed 's/^/    /'
  return 1
}

# ---- 配置表 ---------------------------------------------------------------
# 名字|ISL|OSL|num_prompts|concurrency|warmup|MAX_MODEL_LEN|MAX_NUM_SEQS|SERVER_CPUSET|reps
# ⚠️ M32/M128 是两点法专用：同负载形态、同并发（c=1），只变 num_prompts。
#    C1 的 n=32 可直接当 M32 使用（tag 不同但负载相同），故只补 M128 也能算斜率。
CONFIG_TABLE=(
  "C1|1024|128|32|1|4|4096|8|160-199|3"
  "C2|1024|128|256|64|8|4096|64|160-199|1"
  "C3|8192|16|16|1|2|16384|8|160-199|1"
  "C4|1024|512|16|1|4|4096|8|160-199|1"
  "C5w|1024|128|64|8|8|4096|8|160-199|1"
  "C5n|1024|128|64|8|8|4096|8|160-175|1"
  # 两点法（边际成本）：同负载形态、同并发，只变请求数 ⇒ 两点连线的斜率
  # 就是「扣掉空转」的边际每请求 CPU（见 docs/04 §1.3）
  "M32|1024|128|32|1|4|4096|8|160-199|1"
  "M128|1024|128|128|1|4|4096|8|160-199|1"
  # OSL 斜率三点（ISL 固定 1k、c=1）：每输出 token 的边际成本 + 每 tick 固定项
  "S16|1024|16|64|1|4|4096|8|160-199|1"
  # 受控 ISL 点：固定 OSL=128（与 C1 同），只把 ISL 拉到 8k
  # —— 用来判定「为何 C1→C3 的比值反而变大」（C3 同时动了 ISL 和 OSL，不是受控对照）
  "I8k|8192|128|16|1|2|16384|8|160-199|1"
)

want() {  # $1=config id
  local sel
  IFS=',' read -ra sel <<< "$CONFIGS"
  for s in "${sel[@]}"; do
    [[ "$s" == "all" ]] && return 0
    [[ "$s" == "$1" ]] && return 0
    [[ "$s" == "C5" && "$1" == C5? ]] && return 0
  done
  return 1
}

if [[ "$DRY" == "1" ]]; then
  for row in "${CONFIG_TABLE[@]}"; do
    IFS='|' read -r id isl osl n c w mml mns cpuset r <<< "$row"
    want "$id" || continue
    echo "  [dry] $id ISL=$isl OSL=$osl n=$n c=$c warmup=$w max_model_len=$mml max_num_seqs=$mns cpuset=$cpuset reps=${REPS:-$r} (chip$CHIP, client $CLIENT_CORES)"
  done
  exit 0
fi

FAILED=()

for row in "${CONFIG_TABLE[@]}"; do
  IFS='|' read -r id isl osl n c w mml mns cpuset r <<< "$row"
  want "$id" || continue
  reps="${REPS:-$r}"

  for side in rust python; do
    for rep in $(seq 1 "$reps"); do
      tag="$id"
      [[ "$reps" -gt 1 ]] && tag="${id}r${rep}"
      run="ab-${tag}-${side}"
      port="$PORT_BASE"
      say "===== $tag / $side （ISL=$isl OSL=$osl n=$n c=$c warmup=$w mml=$mml mns=$mns cpuset=$cpuset）====="

      # 每个点开始前先清干净（容器重名/端口占用都会静默污染测量）
      cleanup_our_containers

      # 起服务容器（每个点独立起停，避免上一点的 KV/编译缓存影响下一侧）
      if ! MAX_MODEL_LEN="$mml" MAX_NUM_SEQS="$mns" SERVER_CPUSET="$cpuset" \
           "$HERE/ab_serve.sh" start --run "$run" --frontend "$side" --chip "$CHIP" --port "$port" \
           > "$RUNS_ROOT/$run.start.txt" 2>&1; then
        say "❌ $tag/$side 起栈失败（见 runs/$run.start.txt）"
        FAILED+=("$tag/$side:start")
        MAX_MODEL_LEN="$mml" SERVER_CPUSET="$cpuset" "$HERE/ab_serve.sh" stop --run "$run" >/dev/null 2>&1
        continue
      fi
      if ! verify_frontend "$run" "$side"; then
        say "❌ $tag/$side 起栈后前端进程校验失败"
        FAILED+=("$tag/$side:verify")
        MAX_MODEL_LEN="$mml" SERVER_CPUSET="$cpuset" "$HERE/ab_serve.sh" stop --run "$run" >/dev/null 2>&1
        continue
      fi
      say "✅ $tag/$side 栈就绪"

      if [[ "$IDLE" == "1" ]]; then
        say "空载窗口 ${IDLE_SECONDS}s（不发任何请求）"
        if AB_OWNER="$AB_OWNER" "$HERE/idle.sh" --run "$run" --side "$side" \
             --seconds "$IDLE_SECONDS" > "$RUNS_ROOT/$run.idle.txt" 2>&1; then
          grep -E "idle\]" "$RUNS_ROOT/$run.idle.txt" | sed 's/^/    /'
        else
          say "⚠️ 空载窗口失败（见 runs/$run.idle.txt）"
          FAILED+=("$tag/$side:idle")
        fi
      fi

      pf=""
      [[ "$DO_PERF" == "1" ]] && pf="--perf"
      if ! AB_OWNER="$AB_OWNER" SERVER_CPUSET="$cpuset" MAX_MODEL_LEN="$mml" MAX_NUM_SEQS="$mns" \
           CLIENT_CORES="$CLIENT_CORES" \
           "$HERE/point.sh" --run "$run" --side "$side" --tag "$tag" --port "$port" --chip "$CHIP" \
             --input-len "$isl" --output-len "$osl" --num-prompts "$n" --max-concurrency "$c" \
             --warmup "$w" $pf > "$RUNS_ROOT/$run.point.txt" 2>&1; then
        say "❌ $tag/$side 负载点失败（见 runs/$run.point.txt）"
        FAILED+=("$tag/$side:point")
      else
        say "✅ $tag/$side 完成"
        tail -6 "$RUNS_ROOT/$run.point.txt" | sed 's/^/    /'
      fi

      MAX_MODEL_LEN="$mml" SERVER_CPUSET="$cpuset" "$HERE/ab_serve.sh" stop --run "$run" >/dev/null 2>&1 \
        && say "容器已收" || say "⚠️ 容器可能未收干净"
      sleep 3
    done
  done
done

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
  say "全部完成，无失败项"
else
  say "完成，但有失败项："
  printf '    %s\n' "${FAILED[@]}"
fi
# 收尾：无论成败都把我们的容器收干净（把 chip4 让给别人）
cleanup_our_containers
say "收尾清场完成"
