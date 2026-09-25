#!/usr/bin/env bash
# **在 REMOTE_HOST 上运行**：把已保存的 `perf.data` 的符号解析补齐并重新导出 perf script / report。
#
# 为什么需要单独一个脚本：容器里跑的前端，perf 记录的 mmap 路径是**容器内路径**，
# 宿主上不存在 ⇒ 初始 `perf script` 里大量 `[unknown] (…/libpython3.12.so.1.0)`。
# `prof_point.sh` 只 `docker cp` 了固定的几个库（对 Rust 臂够用：vllm-rs + libc 等），
# 但 **Python 臂要解析的 DSO 有几十个**（libpython、uvloop、tokenizers、pydantic_core、
# libzmq、_asyncio…）—— 硬编码列表不现实。
#
# 本脚本的做法：**从 perf 数据自己反推需要哪些 DSO**（解析 `perf script` 里的
# `(路径)`），逐个 `docker cp` 进 `--symfs` 目录树，再重新导出。
# 这样对任何容器/语言都通用，不需要预先知道依赖。
#
# 用法（在 chip4 锁里或锁外都行，它不碰卡）:
#   harness/profile/a3/resolve_syms.sh --run b-t4 --tag A4-python --container vrs-ab-b-t4
#   resolve_syms.sh --help
set -euo pipefail

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; TAG=""; CONTAINER=""; OUT_ROOT=""
IMAGE="${VLLM_IMAGE:-quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --out-root) OUT_ROOT="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$TAG" && -n "$CONTAINER" ]] || { usage; exit 2; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/runs}"
DIR="$OUT_ROOT/$RUN/$TAG"
say() { printf '[resolve] %s\n' "$*"; }

[[ -s "$DIR/perf.data" ]] || { echo "[resolve] 找不到 $DIR/perf.data（可能已被 --prune 删除）" >&2; exit 2; }

# DSO 要从容器里拷。若服务容器已停，就**从同一个镜像起一个临时容器**来拷——
# 它**不带任何 NPU 设备、不绑核、不跑负载**，所以**不需要 chip4 锁**，
# 也不影响别人的实验。用完立刻删。
SRC_CONTAINER="$CONTAINER"
DUMMY=""
if ! sudo -n docker inspect "$CONTAINER" >/dev/null 2>&1; then
  say "容器 $CONTAINER 不存在 ⇒ 从镜像起一个临时容器（无设备、不跑负载）来取 DSO"
  DUMMY="vrs-symsrc-$$"
  sudo -n docker create --name "$DUMMY" --entrypoint /bin/true "$IMAGE" >/dev/null \
    || { echo "[resolve] 无法创建临时容器" >&2; exit 3; }
  SRC_CONTAINER="$DUMMY"
fi
cleanup_dummy() { [[ -n "$DUMMY" ]] && sudo -n docker rm -f "$DUMMY" >/dev/null 2>&1 || true; }
trap cleanup_dummy EXIT INT TERM

SYMFS="$DIR/symfs"
mkdir -p "$SYMFS"

say "1/3 从 perf 数据反推 DSO 列表"
perf script -i "$DIR/perf.data" --no-demangle 2>/dev/null \
  | grep -oE '\(/[^)]+\)$' | tr -d '()' | sort -u > "$DIR/dso-list.txt" || true
N=$(wc -l < "$DIR/dso-list.txt")
say "    需要 $N 个 DSO"

say "2/3 从容器逐个拷贝到 symfs"
copied=0; missing=0
while IFS= read -r dso; do
  [[ -z "$dso" ]] && continue
  dest="$SYMFS$dso"
  [[ -f "$dest" ]] && { copied=$((copied+1)); continue; }
  mkdir -p "$(dirname "$dest")"
  if sudo -n docker cp "$SRC_CONTAINER:$dso" "$dest" >/dev/null 2>&1; then
    copied=$((copied+1))
  else
    missing=$((missing+1))
    echo "    ⚠️ 拷不到：$dso"
  fi
done < "$DIR/dso-list.txt"
say "    拷贝成功 $copied / 失败 $missing"

say "3/3 用 symfs 重新导出 perf script / report"
perf script -i "$DIR/perf.data" --symfs "$SYMFS" \
  > "$DIR/perf-script.txt" 2> "$DIR/perf-script.err" || true
perf report -i "$DIR/perf.data" --symfs "$SYMFS" --stdio --no-children -n \
  > "$DIR/perf-report.txt" 2>&1 || true
UNK=$(grep -c "\[unknown\]" "$DIR/perf-script.txt" || echo 0)
TOT=$(grep -c "^	" "$DIR/perf-script.txt" || echo 1)
say "    未解析帧 $UNK / $TOT（$(python3 -c "print(f'{$UNK/max($TOT,1)*100:.1f}%')")）"
say "    注意：内核帧仍是 [unknown]（/proc/kallsyms 地址为 0，见 docs/02 §14.2）"

gzip -f "$DIR/perf-script.txt"
say "完成 → $DIR/perf-script.txt.gz 与 $DIR/perf-report.txt"
