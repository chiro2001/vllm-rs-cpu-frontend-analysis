#!/usr/bin/env bash
# 编译压测客户端 `vllm-bench`（上游 rust/src/bench，无需改上游代码）。
#
# 为什么要精简 workspace：完整 workspace 有 13 个 crate，而 `vllm-bench` 只依赖
# 外部 crate（无 workspace 内部依赖），单独建一个只含 `src/bench` 的 workspace
# 就能编译，省掉 axum/tonic/minijinja/pyo3 的整张依赖图。
#
# 用法:
#   scripts/build_bench.sh            # 缺二进制才编
#   scripts/build_bench.sh --force    # 强制重编
#   scripts/build_bench.sh --help
#
# 资源纪律：本机是共享开发机（12 核 / 29 GiB），编译走重活锁 + limit.sh（-j4）。
set -euo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

FORCE=0
case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  --force) FORCE=1 ;;
  *) echo "未知参数：$1" >&2; usage; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_SRC="${RUST_SRC:-REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm/rust}"
BUILD_DIR="${BUILD_DIR:-$HOME/.cache/vllm-rs-bench}"
BIN="$BUILD_DIR/target/release/vllm-bench"

if [[ -x "$BIN" && "$FORCE" == "0" ]]; then
  echo "[build_bench] 已存在：$BIN"; echo "[build_bench] sha256=$(sha256sum "$BIN" | awk '{print $1}')"; exit 0
fi

[[ -d "$RUST_SRC/src/bench" ]] || { echo "找不到上游 rust 源码：$RUST_SRC" >&2; exit 2; }
mkdir -p "$BUILD_DIR/src"
[[ -d "$BUILD_DIR/src/bench" ]] || cp -a "$RUST_SRC/src/bench" "$BUILD_DIR/src/"
[[ -f "$BUILD_DIR/Cargo.lock" ]] || cp "$RUST_SRC/Cargo.lock" "$BUILD_DIR/"
for f in rustfmt.toml rustfmt.unstable.toml deny.toml; do
  [[ -f "$BUILD_DIR/$f" || ! -f "$RUST_SRC/$f" ]] || cp "$RUST_SRC/$f" "$BUILD_DIR/"
done

# 只保留 bench 成员的精简 workspace
python3 - "$RUST_SRC/Cargo.toml" "$BUILD_DIR/Cargo.toml" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index("members = [")
end = src.index("]", start) + 1
src = src[:start] + 'members = [\n    "src/bench",\n]' + src[end:]
pathlib.Path(sys.argv[2]).write_text(src)
PY

source "$HOME/.cargo/env" 2>/dev/null || true
echo "[build_bench] 编译 → $BIN（heavy_lock + limit.sh，-j4）"
OWNER="build_bench:$$" "$REPO_ROOT/scripts/heavy_lock.sh" "$REPO_ROOT/scripts/limit.sh" \
  cargo build --release -p vllm-bench --manifest-path "$BUILD_DIR/Cargo.toml"
echo "[build_bench] sha256=$(sha256sum "$BIN" | awk '{print $1}')"
