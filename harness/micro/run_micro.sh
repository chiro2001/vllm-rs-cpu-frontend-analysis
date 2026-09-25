#!/usr/bin/env bash
# D 线微基准一键复跑：fixture → Python payload → Rust 各段 → Python 各段 → 汇总。
#
# 纪律（plan/COORDINATION.md §9、plan/experiment-matrix.md §6）：
# * 每个子步骤都单独走 `scripts/heavy_lock.sh`（全局唯一重活锁）+ `scripts/limit.sh`
#   （默认绑核 4-7 = 4 核、8 GiB、cargo -j4）；
# * **不要把本脚本再套一层 heavy_lock**：那把锁不可重入，会自己等自己；
# * 预热默认 10 s、每点采样默认 30 s；`--smoke` 才允许更短（只用于验证流程）。
#
# 用法:
#   harness/micro/run_micro.sh                # 全量复跑（基准本身约 12–14 分钟 CPU）
#   harness/micro/run_micro.sh --points 1k    # 只跑 1k 档
#   harness/micro/run_micro.sh --smoke        # 冒烟（每点 1 s，数字不可引用）
#   harness/micro/run_micro.sh --only rust    # 只跑 Rust 侧
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

OUT_DIR="data/micro"
RAW_DIR="$OUT_DIR/raw"
POINTS="1k,8k"
WARMUP=10
SAMPLE=30
ONLY="both"
REGEN=0
SMOKE=0
export PATH="$HOME/.cargo/bin:$PATH"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --points) POINTS="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; RAW_DIR="$OUT_DIR/raw"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --sample) SAMPLE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --regen) REGEN=1; shift ;;
    --smoke) SMOKE=1; WARMUP=1; SAMPLE=1; shift ;;
    *) echo "未知参数: $1（试 --help）" >&2; exit 2 ;;
  esac
done

if [[ "$SMOKE" == "1" ]]; then
  export DMICRO_ALLOW_SHORT=1
fi

if [[ "$WARMUP" -lt 10 || "$SAMPLE" -lt 30 ]] && [[ "$SMOKE" != "1" ]]; then
  echo "[run_micro] 拒绝运行：--warmup $WARMUP / --sample $SAMPLE 低于纪律下限 10/30" >&2
  exit 2
fi

RUST_BIN="harness/micro/rust/target/release/micro-bench"
PY_BIN="harness/micro/.venv/bin/python"
FIX="harness/micro/fixtures"

lock_run() {
  WAIT="${WAIT:-1800}" scripts/heavy_lock.sh scripts/limit.sh "$@"
}

mkdir -p "$RAW_DIR"

# 环境快照（manifest 用）：loadavg 取运行前后各一次，另有 uname / CPU / 内存
cat /proc/loadavg > "$RAW_DIR/loadavg.before"
uname -a > "$RAW_DIR/uname.txt"
grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //' > "$RAW_DIR/cpu_model.txt" || true
awk '/MemTotal/ {print $2}' /proc/meminfo > "$RAW_DIR/mem_total_kib.txt"

# ---------------------------------------------------------------- 0. 前置检查
if [[ "$REGEN" == "1" || ! -f "$FIX/fixtures_manifest.json" ]]; then
  echo "[run_micro] 生成 fixture"
  lock_run python3 harness/micro/gen_fixtures.py
fi

if [[ "$ONLY" != "python" ]]; then
  # 源码比二进制新时自动重建（否则会拿旧二进制跑出旧结果）
  if [[ ! -x "$RUST_BIN" ]] || [[ -n "$(find harness/micro/rust/src harness/micro/rust/Cargo.toml -newer "$RUST_BIN" -print -quit)" ]]; then
    echo "[run_micro] 构建 Rust 微基准（cargo build --release -j 4，走 limit.sh）"
    lock_run cargo build --release -j 4 --manifest-path harness/micro/rust/Cargo.toml
  fi
fi

if [[ "$ONLY" != "rust" ]]; then
  bash harness/micro/setup_py_env.sh --check >/dev/null 2>&1 || {
    echo "[run_micro] 初始化 Python venv（msgspec/msgpack）"
    lock_run bash harness/micro/setup_py_env.sh
  }
fi

IFS=',' read -r -a POINT_LIST <<< "$POINTS"

# --------------------------------------------------- 1. Python 侧 payload 先行
# Rust 的真实收包路径要解 Python（omit_defaults）的稀疏字节，所以 Python 的
# payload 必须先落盘，Rust 的 d3 才能 --decode-file 它。
if [[ "$ONLY" != "rust" ]]; then
  for point in "${POINT_LIST[@]}"; do
    payload="$RAW_DIR/payload_python_${point}.msgpack"
    lock_run "$PY_BIN" harness/micro/python/micro_py.py emit-payload \
      --fixture "$FIX/engine_core_request_${point}.json" --out "$payload"
  done
fi

# ------------------------------------------------------------------- 2. Rust
if [[ "$ONLY" != "python" ]]; then
  for point in "${POINT_LIST[@]}"; do
    echo "[run_micro] rust d1 @$point"
    lock_run "$RUST_BIN" d1 --fixture "$FIX/chat_request_${point}.json" --point "$point" \
      --out "$RAW_DIR/rust_d1_${point}.csv" --warmup "$WARMUP" --sample "$SAMPLE" \
      --check "$RAW_DIR/rust_d1_check_${point}.json"

    echo "[run_micro] rust d2 @$point"
    lock_run "$RUST_BIN" d2 --template "$FIX/chat_template.jinja" \
      --fixture "$FIX/chat_request_${point}.json" --point "$point" \
      --out "$RAW_DIR/rust_d2_${point}.csv" --warmup "$WARMUP" --sample "$SAMPLE" \
      --dump "$RAW_DIR/rust_render_${point}.txt"

    echo "[run_micro] rust d3 @$point"
    lock_run "$RUST_BIN" d3 --fixture "$FIX/engine_core_request_${point}.json" --point "$point" \
      --out "$RAW_DIR/rust_d3_${point}.csv" --warmup "$WARMUP" --sample "$SAMPLE" \
      --payload-out "$RAW_DIR/payload_rust_${point}.msgpack" \
      --decode-file "$RAW_DIR/payload_python_${point}.msgpack"

    # D6：拿 d2 刚 dump 出来的渲染结果当输入（也就是 P4 真实要编码的那段文本）
    echo "[run_micro] rust d6 @$point（fastokens 预分词，多线程口径）"
    lock_run "$RUST_BIN" d6 --text "$RAW_DIR/rust_render_${point}.txt" \
      --tokenizer "${DMICRO_TOKENIZER:-REPO_HOME/models/Qwen3-0.6B/tokenizer.json}" \
      --point "render_$point" --out "$RAW_DIR/rust_d6_render_${point}.csv" \
      --warmup "$WARMUP" --sample "$SAMPLE"
  done

  echo "[run_micro] rust d4 @osl128"
  lock_run "$RUST_BIN" d4 --response "$FIX/response_osl128.json" \
    --chunks "$FIX/stream_chunks_osl128.json" --point osl128 \
    --out "$RAW_DIR/rust_d4_osl128.csv" --warmup "$WARMUP" --sample "$SAMPLE" \
    --dump "$RAW_DIR/rust_response_osl128.json"
fi

# ----------------------------------------------------------------- 3. Python
if [[ "$ONLY" != "rust" ]]; then
  for point in "${POINT_LIST[@]}"; do
    echo "[run_micro] python d1 @$point"
    lock_run "$PY_BIN" harness/micro/python/micro_py.py d1 \
      --fixture "$FIX/chat_request_${point}.json" --point "$point" \
      --out "$RAW_DIR/python_d1_${point}.csv" --warmup "$WARMUP" --sample "$SAMPLE" \
      --check "$RAW_DIR/python_d1_check_${point}.json"

    echo "[run_micro] python d2 @$point"
    lock_run "$PY_BIN" harness/micro/python/micro_py.py d2 \
      --template "$FIX/chat_template.jinja" --fixture "$FIX/chat_request_${point}.json" \
      --point "$point" --out "$RAW_DIR/python_d2_${point}.csv" \
      --warmup "$WARMUP" --sample "$SAMPLE" --dump "$RAW_DIR/python_render_${point}.txt"

    echo "[run_micro] python d3 @$point"
    lock_run "$PY_BIN" harness/micro/python/micro_py.py d3 \
      --fixture "$FIX/engine_core_request_${point}.json" --point "$point" \
      --out "$RAW_DIR/python_d3_${point}.csv" --warmup "$WARMUP" --sample "$SAMPLE" \
      --decode-file "$RAW_DIR/payload_rust_${point}.msgpack" \
      --payload-out "$RAW_DIR/payload_python_${point}.msgpack"
  done

  echo "[run_micro] python d4 @osl128"
  lock_run "$PY_BIN" harness/micro/python/micro_py.py d4 \
    --response "$FIX/response_osl128.json" --chunks "$FIX/stream_chunks_osl128.json" \
    --point osl128 --out "$RAW_DIR/python_d4_osl128.csv" \
    --warmup "$WARMUP" --sample "$SAMPLE" --dump "$RAW_DIR/python_response_osl128.json"
fi

# ------------------------------------------------------------------- 4. 汇总
cat /proc/loadavg > "$RAW_DIR/loadavg.after"
echo "[run_micro] 汇总 results.csv / manifest.json / segments.json / checks.json"
python3 harness/micro/summarize.py \
  --raw-dir "$RAW_DIR" --fixtures "$FIX" --out-dir "$OUT_DIR" \
  --points "$POINTS" --warmup "$WARMUP" --sample "$SAMPLE" \
  --rust-bin "$RUST_BIN"

echo "[run_micro] 完成 → $OUT_DIR"
