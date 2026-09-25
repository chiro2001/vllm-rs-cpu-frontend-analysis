#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# export_publish.sh —— 从内部工作树导出一份**可发布**的净化副本
#
#   scripts/export_publish.sh [--out DIR] [--no-push] [--repo NAME]
#
# 为什么不是"就地净化后 push"：
#   内部工作树的 **git 历史**里含有内部标识（早期提交的 plan/ 引用了内部项目目录名、
#   绝对路径、主机名）。sed 只能处理工作树文本，改不了历史。
#   因此发布走**导出一条全新的、单一起点的历史**（与前两个项目的做法一致）。
#
# 流程：
#   1. rsync 工作树 → 导出目录（排除 .git / runs / target / refs / 原始采样）
#   2. 在导出目录里执行 sanitize_for_publish.sh --apply
#   3. git init + 单一提交（作者用 GitHub noreply 邮箱，避免暴露真实邮箱）
#   4. 复查：残留命中数必须为 0，且不得含被排除的路径
#   5. （默认）gh repo create --private + push
#
# 前置：仓库根有 .sanitize-map.tsv（被 .gitignore 排除，不会随导出走）。
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=""
REPO="vllm-rs-cpu-frontend-analysis"
PUSH=1
GIT_NAME="Chiro"
GIT_EMAIL="41908064+chiro2001@users.noreply.github.com"   # GitHub noreply，与前两个项目一致

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$OUT" ]] || OUT="$ROOT/../vllm-rs-publish"

# ---- 0. 前置检查 -----------------------------------------------------------
[[ -f "$ROOT/.sanitize-map.tsv" ]] || {
  echo "[export] 缺少 $ROOT/.sanitize-map.tsv（净化映射表）。" >&2; exit 3; }

# ---- 1. 导出（不带 .git）---------------------------------------------------
echo "== 1/5 导出 =="
echo "   $ROOT  ->  $OUT"
mkdir -p "$OUT"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='target/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.venv/' \
  --exclude='.sanitize-map.tsv' \
  --exclude='.locks/' \
  --exclude='runs/' \
  --exclude='refs/' \
  --exclude='*.perf.data' \
  --exclude='perf.data*' \
  --exclude='data/profiles/*.perf.data' \
  --exclude='*.whl' \
  --exclude='*.log' \
  --exclude='system-snapshot.txt' \
  "$ROOT/" "$OUT/"

# refs/ 是 upstream vLLM 源码副本（Apache-2.0，非本项目产出）。
# 导出时整目录排除；需要时按 refs/README.md 记录的 commit 自行 clone。
#
# runs/ 是运行期目录（PID / 日志 / 临时采样），默认 gitignore，不发布。
# data/profiles/ 只发布折叠栈与汇总；原始 *.perf.data 已在上面的 exclude 里挡掉。

# ---- 2. 净化 --------------------------------------------------------------
echo "== 2/5 净化 =="
# 映射表**留在内部仓库**（rsync 已排除），通过 SANITIZE_MAP 指过去，
# 这样导出目录里既没有真实值，也不影响净化执行。
SANITIZE_MAP="$ROOT/.sanitize-map.tsv" \
  bash "$OUT/scripts/sanitize_for_publish.sh" --apply

# ---- 3. 复核 --------------------------------------------------------------
echo "== 3/5 复核 =="
fail=0
while IFS=$'\t' read -r from to; do
  [ -n "$from" ] || continue
  # 注意 `|| true`：set -o pipefail 下，grep 无匹配会返回 1，
  # 会让整个管道判为失败并触发 set -e —— 而"无匹配"正是我们要的结果。
  n=$({ grep -rIl --exclude-dir=.git --exclude-dir=target -F -- "$from" "$OUT" 2>/dev/null || true; } | wc -l)
  printf '  %-28s 残留文件数=%s\n' "$to ← $from" "$n"
  [[ "$n" == "0" ]] || fail=1
done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/.sanitize-map.tsv" | awk -F'\t' 'NF>=2{print $1"\t"$2}')

for p in refs target runs .sanitize-map.tsv .locks; do
  if [[ -e "$OUT/$p" ]]; then echo "  ⚠️  不该存在的路径：$p" >&2; fail=1; fi
done

# 原始采样不该随发布走（体积大且无必要）
leftover_perf=$(find "$OUT" -name '*perf.data*' 2>/dev/null | wc -l)
if [[ "$leftover_perf" != "0" ]]; then
  echo "  ⚠️  导出目录里仍有 $leftover_perf 个 perf.data* 文件" >&2; fail=1
fi

if [[ "$fail" != "0" ]]; then
  echo "[export] 复核未通过，**不提交、不推送**。" >&2
  exit 4
fi
echo "  复核通过"

# ---- 4. 建仓 --------------------------------------------------------------
echo "== 4/5 建仓 =="
cd "$OUT"
if [[ ! -d .git ]]; then git init -q -b main; fi
git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
    commit -q -m "vLLM 0.26.0 Rust 前端（vllm-rs）CPU 负载分析：热点、逐段成本与 A/B 对照" \
  || echo "  （无变更，跳过提交）"
git log --oneline | head -3
echo "  文件数: $(git ls-files | wc -l)，体积: $(du -sh --exclude=.git . | cut -f1)"

# ---- 5. 推送 --------------------------------------------------------------
if [[ "$PUSH" == "0" ]]; then
  echo "== 5/5 跳过推送（--no-push）=="
  echo "  导出就绪：$OUT"
  exit 0
fi
echo "== 5/5 推送 =="
if gh repo view "chiro2001/$REPO" >/dev/null 2>&1; then
  echo "  仓库已存在，直接 push"
  git remote get-url origin >/dev/null 2>&1 || \
    git remote add origin "https://github.com/chiro2001/$REPO.git"
  git push -u origin main
else
  gh repo create "chiro2001/$REPO" --private --source=. --remote=origin --push
fi
echo
echo "发布完成：https://github.com/chiro2001/$REPO"
