#!/usr/bin/env bash
# **在本机（x86）运行**：把 REMOTE_HOST 回传的 `perf-script.txt.gz` 折叠成折叠栈并出图。
#
# 为什么在本地折叠：REMOTE_HOST 上没有 inferno（只有 rustup 自带工具链），
# 而 `perf script` 的文本可以压得很小（本项目的点约 0.5–3 MB gzip）
# ⇒ 「远端只采、本地折叠出图」比在远端装工具链更省事、也不动生产机环境。
#
# 用法:
#   harness/profile/a3/collapse_a3.sh --in-dir runs/<run>/<tag>-<side> \
#       --out-dir data/profiles/a3 --tag A1-rust [--flame figures/02-flame-a3-A1-rust.svg]
#   collapse_a3.sh --help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "$HERE/.." && pwd)"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

IN_DIR=""; OUT_DIR="data/profiles/a3"; TAG=""; FLAME=""; SEG=0; TOPN=40
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --in-dir) IN_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --flame) FLAME="$2"; shift 2 ;;
    --by-segment) SEG=1; shift ;;
    --top) TOPN="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$IN_DIR" && -n "$TAG" ]] || { usage; exit 2; }
mkdir -p "$OUT_DIR"

SRC="$IN_DIR/perf-script.txt"
if [[ -f "$IN_DIR/perf-script.txt.gz" ]]; then
  echo "[collapse_a3] 解压 $IN_DIR/perf-script.txt.gz"
  gunzip -c "$IN_DIR/perf-script.txt.gz" > "$SRC"
fi
[[ -s "$SRC" ]] || { echo "找不到 $IN_DIR/perf-script.txt[.gz]" >&2; exit 2; }

FOLDED="$OUT_DIR/$TAG.folded"
echo "[collapse_a3] 折叠 → $FOLDED"
"$HOME/.cargo/bin/inferno-collapse-perf" --all -q "$SRC" > "$FOLDED"

SAMPLES=$(awk 'NR==1{print $NF}' "$FOLDED" 2>/dev/null || echo 0)
STACKS=$(wc -l < "$FOLDED")
echo "[collapse_a3] 栈 $STACKS 行"

# 复用 B 线的统计脚本（同一套 segments.json 规则 + 同一套 CSV 形状）
python3 "$PROFILE_DIR/folded_stats.py" --folded "$FOLDED" --tag "$TAG" --outdir "$OUT_DIR" \
  --top "$TOPN" --quiet --source "REMOTE_HOST chip4 profiling（prof_point.sh）+ collapse_a3.sh" || true

# 事件名（是否含内核态）从 perf-report 里带过来，供文档核对
if [[ -f "$IN_DIR/perf-report.txt" ]]; then
  grep -m1 "^# Samples:" "$IN_DIR/perf-report.txt" > "$OUT_DIR/$TAG.perf-event.txt" || true
  grep -m1 "^# Event count" "$IN_DIR/perf-report.txt" >> "$OUT_DIR/$TAG.perf-event.txt" || true
  cp "$IN_DIR/perf-report.txt" "$OUT_DIR/$TAG.perf-report.txt"
fi
for f in point.json perf-stat.txt; do
  [[ -f "$IN_DIR/$f" ]] && cp "$IN_DIR/$f" "$OUT_DIR/$TAG.$(basename "$f")"
done

if [[ -n "$FLAME" ]]; then
  ARGS=(--folded "$FOLDED" --out "$FLAME" --title "$TAG (REMOTE_HOST chip4)")
  if [[ "$SEG" == "1" ]]; then
    ARGS+=(--by-segment "${FLAME%.svg}-by-segment.svg")
  fi
  "$PROFILE_DIR/flamegraph.sh" "${ARGS[@]}"
fi
