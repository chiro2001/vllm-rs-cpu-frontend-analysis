#!/usr/bin/env bash
# 折叠栈 → 可读 SVG 火焰图（inferno-flamegraph），并可选生成「按 P 分段着色」版本。
#
# 用法:
#   flamegraph.sh --folded data/profiles/B1.folded --out figures/02-flame-B1.svg \
#       --title "B1 chat+tools ISL=1k OSL=128 c=1" --subtitle "vllm-rs + mock engine, fp, 999Hz" \
#       [--by-segment figures/02-flame-B1-by-segment.svg]
#   flamegraph.sh --help
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

FOLDED=""; OUT=""; TITLE="vllm-rs flamegraph"; SUBTITLE=""; BYSEG=""
WIDTH=1600; HEIGHT=16; MINWIDTH=0.05; COLORS=rust
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --folded) FOLDED="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --subtitle) SUBTITLE="$2"; shift 2 ;;
    --by-segment) BYSEG="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --colors) COLORS="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$FOLDED" && -n "$OUT" ]] || { usage; exit 2; }
mkdir -p "$(dirname "$OUT")"

ARGS=(--colors "$COLORS" --width "$WIDTH" --height "$HEIGHT" --minwidth "$MINWIDTH"
      --title "$TITLE" --countname ns --fontsize 11)
[[ -n "$SUBTITLE" ]] && ARGS+=(--subtitle "$SUBTITLE")
"$HOME/.cargo/bin/inferno-flamegraph" "${ARGS[@]}" "$FOLDED" > "$OUT"
echo "[flamegraph] $OUT（$(du -h "$OUT" | cut -f1)）"

if [[ -n "$BYSEG" ]]; then
  mkdir -p "$(dirname "$BYSEG")"
  ARGS_SEG=()
  for a in "${ARGS[@]}"; do
    if [[ "$a" == "$TITLE" ]]; then ARGS_SEG+=("$TITLE（按 P 分段着色）"); else ARGS_SEG+=("$a"); fi
  done
  "$HOME/.cargo/bin/inferno-flamegraph" "${ARGS_SEG[@]}" "$FOLDED" > "$BYSEG"
  python3 "$SCRIPT_DIR/recolor_svg.py" --svg "$BYSEG" --segments "$SCRIPT_DIR/segments.json" --in-place
  echo "[flamegraph] $BYSEG（按分段着色 + 图例）"
fi
