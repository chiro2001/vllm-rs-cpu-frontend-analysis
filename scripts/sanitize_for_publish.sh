#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sanitize_for_publish.sh —— 发布前净化：把内部标识替换为可读占位符
#
#   bash scripts/sanitize_for_publish.sh [--check|--apply|--revert]
#
# 目的：把本项目同步到 GitHub 之前，去掉**能定位到具体人或内部基础设施**的标识，
#       同时保留技术内容与可复现性。替换可逆。
#
# 设计要点：**真实值不写在本脚本里**，而是放在仓库根目录的 `.sanitize-map.tsv`
#           （该文件被 .gitignore 排除，不会随仓库分发）。
#           这样脚本本身可以公开，而映射仍然私密。
#
#   --check   只报告命中行数，不修改文件（默认，安全）
#   --apply   实际执行替换
#   --revert  把占位符换回原值
#
# 模板见 scripts/sanitize-map.example.tsv
# 本项目实际替换表与理由见 docs/SANITIZATION.md
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MAPFILE=${SANITIZE_MAP:-$ROOT/.sanitize-map.tsv}
SELF_REL="scripts/sanitize_for_publish.sh"

MODE=check
case "${1:-}" in
  --apply)  MODE=apply ;;
  --check|"") MODE=check ;;
  --revert) MODE=revert ;;
  -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $0 [--check|--apply|--revert]" >&2; exit 2 ;;
esac

if [ ! -f "$MAPFILE" ]; then
  cat >&2 <<EOF
[sanitize] 找不到映射表：$MAPFILE
[sanitize] 这是**有意**的——真实值不随仓库分发。
[sanitize] 请从模板起步并填入你自己的映射：
            cp scripts/sanitize-map.example.tsv $MAPFILE
          或用 SANITIZE_MAP=<路径> 指定别处。
EOF
  exit 3
fi

# 读取映射（跳过注释/空行），按原值长度降序，避免子串互相吃掉。
read_map() {
  grep -vE '^[[:space:]]*(#|$)' "$MAPFILE" \
    | awk -F'\t' 'NF>=2 {print length($1)"\t"$1"\t"$2}' \
    | sort -rn -k1,1 \
    | cut -f2,3
}

# 待处理的文本文件集合。
# 跳过清单（每一项都有理由）：
#   * 本脚本自身 —— 否则一次 --apply 会把脚本里的映射表改坏
#   * .sanitize-map.tsv —— 它就是映射表本身
#   * docs/SANITIZATION.md —— 它**本身就在列举占位符**，卷进替换会自指
#   * scripts/sanitize-map.example.tsv —— 同上，模板里全是占位符名
#   * PUBLISH.md —— 发布记录，正文就在列举占位符名与替换计数（同理）
#   * .git/ —— 版本库元数据（含提交者邮箱），不靠 sed 处理，靠重建仓库解决
#   * refs/ —— 上游 vLLM 源码快照副本，不属于本项目产出，发布时整目录排除
#   * runs/ —— 运行期目录（PID/日志/临时采样），本就 gitignore，不发布
#   * target/ __pycache__/ *.pyc —— 构建与缓存产物，可重建
#   * 二进制（.svg/.png/.gz/.bin 等）—— sed 会破坏，整类排除
find_text_files() {
  find . \
    -type f \
    -not -path "./.git/*" \
    -not -path "./refs/*" \
    -not -path "./runs/*" \
    -not -path "*/target/*" \
    -not -path "*/__pycache__/*" \
    -not -path "*/.venv/*" \
    -not -path "*/.locks/*" \
    -not -name "*.pyc" \
    -not -name ".sanitize-map.tsv" \
    -not -name "*.perf.data" \
    -not -path "./scripts/sanitize-map.example.tsv" \
    -not -path "./PUBLISH.md" \
    -not -path "./docs/SANITIZATION.md" \
    -not -path "./$SELF_REL" \
    -print0
}

# 统计某个字面量在多少行出现
count_hits() {
  local lit=$1 n=0 c
  while IFS= read -r -d '' f; do
    if grep -qI . "$f" 2>/dev/null; then
      c=$(grep -F -c -- "$lit" "$f" 2>/dev/null || true)
      [ -n "$c" ] && n=$((n + c))
    fi
  done < <(find_text_files)
  echo "$n"
}

# 在文本文件上就地执行 sed 表达式，返回被处理的文件数
apply_edit() {
  local expr=$1 n=0
  while IFS= read -r -d '' f; do
    if grep -qI . "$f" 2>/dev/null; then
      sed -i "$expr" "$f" 2>/dev/null && n=$((n + 1)) || true
    fi
  done < <(find_text_files)
  echo "$n"
}

echo "== 净化模式: $MODE =="
echo "   映射表: $MAPFILE"
echo

# ---- 撞名预检（踩过坑：占位符若与语料里既有标识符同名，revert 会改坏代码）----
# 反例（来自上一个项目的真实教训）：占位符 `LINKS_HOST` 与脚本里本来就叫
# LINKS_HOST 的 shell 变量撞名 ⇒ revert 把变量名也换成真实值，脚本直接语法错误。
collisions=0
if [ "$MODE" = apply ]; then
  while IFS=$'\t' read -r _ to; do
    [ -n "$to" ] || continue
    n=$(count_hits "$to")
    if [ "$n" != "0" ]; then
      printf '[预检] ⚠️  占位符 %s 在语料中已存在 %s 处（撞名风险）\n' "$to" "$n" >&2
      collisions=$((collisions + 1))
    fi
  done < <(read_map)
  if [ "$collisions" != "0" ]; then
    cat >&2 <<'EOF'
[预检] 上面这些占位符会与既有标识符混淆，导致 --revert 不可逆。
[预检] 改法：给占位符加一个不会撞名的前缀（例如 ZZ_REMOTE_USER）。
[预检] 确认无误可设 SANITIZE_FORCE=1 跳过本检查。
EOF
    [ "${SANITIZE_FORCE:-0}" = "1" ] || exit 4
  fi
fi

if [ "$MODE" = check ]; then
  printf '%-44s %s\n' "占位符 ← 原值" "命中行数"
  printf '%-44s %s\n' "--------------------------------------------" "--------"
  while IFS=$'\t' read -r from to; do
    [ -n "$from" ] || continue
    printf '%-44s %s\n' "$to ← $from" "$(count_hits "$from")"
  done < <(read_map)
  echo
  echo "（仅检查，未修改文件。执行：bash $0 --apply）"
  exit 0
fi

if [ "$MODE" = revert ]; then
  echo "== 还原（占位符 → 原值，长值优先）=="
  while IFS=$'\t' read -r from to; do
    [ -n "$from" ] || continue
    n=$(apply_edit "s|${to}|${from}|g")
    echo "  ${to} -> ${from}   (${n} 个文本文件)"
  done < <(read_map)   # 必须与 apply 同序（长值优先）；用 tac 会让短占位符吃掉长的
  echo
  echo "还原完成。建议复核：bash $0 --check"
  exit 0
fi

echo "== 执行替换 =="
while IFS=$'\t' read -r from to; do
  [ -n "$from" ] || continue
  n=$(apply_edit "s|${from}|${to}|g")
  echo "  ${from} -> ${to}   (${n} 个文本文件)"
done < <(read_map)

echo
echo "== 复核（应全为 0）=="
fail=0
while IFS=$'\t' read -r from to; do
  [ -n "$from" ] || continue
  c=$(count_hits "$from")
  printf '%-44s %s\n' "$from" "$c"
  [ "$c" != "0" ] && fail=1
done < <(read_map)

echo
if [ "$fail" = "0" ]; then
  echo "净化完成：全部原值命中数为 0。"
else
  echo "⚠️  仍有残留。常见原因：值出现在**二进制文件**里（sed 无法替换）。" >&2
  echo "    处理办法：把该文件加入 .gitignore（构建产物/压缩数据通常应整类排除）。" >&2
  exit 1
fi
echo "如需还原：bash $0 --revert"
