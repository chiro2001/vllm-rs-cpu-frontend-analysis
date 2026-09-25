#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# check_anchors.sh —— 校验文档里引用的 `路径.rs:行号` 锚点是否仍然指向预期位置。
#
# 用途：A 线（A-path）交付物 docs/01-request-path.md 的所有行号都是手工回读的，
# 本脚本把文档里出现的锚点批量抽出来，在只读源码树上重新打印那一行，
# 让审阅者不用相信"我说行号对"，而是自己看一遍。
#
# 本脚本只做 grep/sed，属纯静态检查，不编译、不跑负载（plan/COORDINATION.md §9）。
#
# 锚点解析规则（按顺序尝试）：
#   1. 相对源码树根的完整路径，如 `server/src/routes.rs:130`（Rust 树）
#      或 `vllm/entrypoints/cli/serve.py:173`（Python 树，见 --py-root）；
#   2. 只写文件名的简写，如 `listener.rs:56` —— 在源码树内按路径后缀唯一匹配，
#      命中唯一才接受，多个同名文件报 AMBIGUOUS 并计为问题；
#   3. 依赖锚点，如 `hyper-1.10.1/src/proto/h1/role.rs:67` —— 在
#      `<dep-root>/<registry>/<包名-版本>/...` 下查找；
#   4. Python 第三方包锚点，如 `fastapi/routing.py:250` —— 在 site-packages 候选目录
#      （`--site-packages 指定值` → `$HOME/miniforge3/...` → `$HOME/.venvs/*/...` →
#      `/usr/lib/python3/dist-packages` → `/usr/local/lib/python*/site-packages`）下查找。

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

# 默认只读源码树（vLLM 0.26.0 / commit 568afb3a 的 rust/src）。
readonly DEFAULT_ROOT="REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm/rust/src"
readonly DEFAULT_DEP_ROOT="${HOME}/.cargo/registry/src"
# Python 侧的只读源码树（vLLM 0.26.0 仓库根，锚点写成 `vllm/.../*.py:行`）。
readonly DEFAULT_PY_ROOT="REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm"
readonly DEFAULT_DOC="docs/01-request-path.md"

usage() {
    cat <<'EOF'
用法:
  check_anchors.sh [选项] [DOC...]

把文档中形如 `server/src/routes.rs:130` 的锚点抽出来，在源码树里回读该行内容。
支持 .rs 与 .py 锚点。解析顺序：Rust 源码树 → Python 源码树 → cargo registry。
写法可以是完整相对路径、唯一后缀简写（如 listener.rs:56）或依赖锚点
（如 hyper-1.10.1/src/proto/h1/role.rs:67，在 cargo registry 下解析）。

选项:
  -r, --root DIR     只读源码树根目录
                     （默认 REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm/rust/src）
      --py-root DIR  Python 源码树根（默认 REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm）
      --no-py        禁用 Python 树（只校验 Rust 树与 cargo registry）
  -d, --dep-root DIR cargo registry 根（默认 $HOME/.cargo/registry/src）
      --site-packages DIR
                     额外的 Python site-packages 目录（用于 fastapi/starlette 一类
                     第三方锚点；不传则用内置候选目录）
  -w, --width N      每行输出截断宽度（默认 140）
  -q, --quiet        只报告问题（缺文件/越界/歧义），不打印正常锚点
  -h, --help         显示本帮助

参数:
  DOC...             要扫描的文档（默认 docs/01-request-path.md）

退出码:
  0  所有锚点都能回读
  1  存在缺失文件、行号越界或歧义匹配
  2  参数错误

示例:
  harness/static/check_anchors.sh
  harness/static/check_anchors.sh docs/01-request-path.md
  harness/static/check_anchors.sh docs/01b-python-frontend-anchors.md
  harness/static/check_anchors.sh --quiet docs/01-request-path.md
EOF
}

root="$DEFAULT_ROOT"
py_root="$DEFAULT_PY_ROOT"
use_py=1
site_packages=""
dep_root="$DEFAULT_DEP_ROOT"
width=140
quiet=0
docs=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--root)     root="${2:?missing value for $1}"; shift 2 ;;
        --py-root)     py_root="${2:?missing value for $1}"; shift 2 ;;
        --no-py)       use_py=0; shift ;;
        --site-packages) site_packages="${2:?missing value for $1}"; shift 2 ;;
        -d|--dep-root) dep_root="${2:?missing value for $1}"; shift 2 ;;
        -w|--width)    width="${2:?missing value for $1}"; shift 2 ;;
        -q|--quiet)    quiet=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "$SCRIPT_NAME: 未知选项 $1" >&2; usage >&2; exit 2 ;;
        *)             docs+=("$1"); shift ;;
    esac
done

if [[ ${#docs[@]} -eq 0 ]]; then
    docs=("$DEFAULT_DOC")
fi

if [[ ! -d "$root" ]]; then
    echo "$SCRIPT_NAME: 源码树不存在: $root" >&2
    exit 2
fi

# 源文件清单缓存（用于后缀唯一匹配）
file_list=$(mktemp)
py_file_list=$(mktemp)
trap 'rm -f "$file_list" "$py_file_list"' EXIT
(cd "$root" && find . -name '*.rs' | sed 's|^\./||') >"$file_list"
if (( use_py )) && [[ -d "$py_root" ]]; then
    (cd "$py_root" && find . -name '*.py' -not -path './.git/*' | sed 's|^\./||') >"$py_file_list"
fi

# 在某个树的文件清单里做后缀唯一匹配；命中唯一则打印绝对路径。
match_suffix() {
    local tree_root="$1" list="$2" rel="$3" matches count
    [[ -s "$list" ]] || return 1
    matches=$(grep -E "(^|/)$(printf '%s' "$rel" | sed 's/[.[\*^$]/\\&/g')$" "$list" || true)
    count=$(printf '%s\n' "$matches" | grep -c . || true)
    if [[ "$count" == "1" ]]; then
        printf '%s\n' "$tree_root/$matches"
        return 0
    elif [[ "$count" -gt 1 ]]; then
        printf 'AMBIGUOUS\t%s 个同名候选（请写全路径）\n' "$count"
        return 2
    fi
    return 1
}

# 解析一个锚点（不含行号）：成功时打印绝对路径；失败时打印 "REASON<TAB>说明"。
resolve_anchor() {
    local rel="$1"
    local exact="$root/$rel"
    if [[ -f "$exact" ]]; then
        printf '%s\n' "$exact"
        return 0
    fi

    # Python 源码树：先试完整相对路径，再试唯一后缀
    if (( use_py )) && [[ -d "$py_root" ]]; then
        if [[ -f "$py_root/$rel" ]]; then
            printf '%s\n' "$py_root/$rel"
            return 0
        fi
    fi

    # 后缀唯一匹配（Rust 树优先，再 Python 树）
    local out rc=0
    out=$(match_suffix "$root" "$file_list" "$rel") || rc=$?
    if (( rc == 0 )); then
        printf '%s\n' "$out"
        return 0
    elif (( rc == 2 )); then
        printf '%s\n' "$out"
        return 1
    fi

    if (( use_py )) && [[ -d "$py_root" ]]; then
        rc=0
        out=$(match_suffix "$py_root" "$py_file_list" "$rel") || rc=$?
        if (( rc == 0 )); then
            printf '%s\n' "$out"
            return 0
        elif (( rc == 2 )); then
            printf '%s\n' "$out"
            return 1
        fi
    fi

    # 依赖锚点：<crate-version>/... 在 cargo registry 下找
    if [[ -d "$dep_root" ]]; then
        local first="${rel%%/*}" rest="${rel#*/}"
        local dep_matches="" reg candidate
        for reg in "$dep_root"/*; do
            candidate="$reg/$first/$rest"
            if [[ -f "$candidate" ]]; then
                dep_matches+="$candidate"$'\n'
            fi
        done
        dep_matches=${dep_matches%$'\n'}
        if [[ -n "$dep_matches" ]]; then
            printf '%s\n' "$dep_matches"
            return 0
        fi
    fi

    # Python 第三方包锚点：在 site-packages 候选目录下找（fastapi/starlette 等）
    local sp candidate_sp
    local -a sp_roots=()
    [[ -n "$site_packages" ]] && sp_roots+=("$site_packages")
    for sp in "$HOME"/miniforge3/lib/python*/site-packages \
              "$HOME"/.venvs/*/lib/python*/site-packages \
              /usr/lib/python3/dist-packages \
              /usr/local/lib/python*/site-packages; do
        [[ -d "$sp" ]] && sp_roots+=("$sp")
    done
    for candidate_sp in "${sp_roots[@]}"; do
        if [[ -f "$candidate_sp/$rel" ]]; then
            printf '%s\n' "$candidate_sp/$rel"
            return 0
        fi
    done

    printf 'NOT-FOUND\tRust/Python 源码树与 cargo registry 内均未找到\n'
        return 1
}

# 抽锚点：认 <path>.rs:<line> 与 <path>.py:<line>，路径允许字母数字/下划线/点/斜杠/连字符。
anchor_re='[A-Za-z0-9_][A-Za-z0-9_./-]*\.(rs|py):[0-9]+'

total=0
bad=0
for doc in "${docs[@]}"; do
    if [[ ! -f "$doc" ]]; then
        echo "$SCRIPT_NAME: 文档不存在: $doc" >&2
        exit 2
    fi
    echo "== $doc"
    while IFS= read -r anchor; do
        [[ -z "$anchor" ]] && continue
        total=$((total + 1))
        rel="${anchor%:*}"
        line="${anchor##*:}"
        if ! resolved=$(resolve_anchor "$rel"); then
            label="${resolved%%$'\t'*}"
            detail="${resolved#*$'\t'}"
            printf '%-14s %-50s %s\n' "$label" "$anchor" "$detail"
            bad=$((bad + 1))
            continue
        fi
        file="$resolved"
        nlines=$(wc -l <"$file")
        if (( line < 1 || line > nlines )); then
            printf '%-14s %s (file has %s lines: %s)\n' "OUT-OF-RANGE" "$anchor" "$nlines" "${file#"$root"/}"
            bad=$((bad + 1))
            continue
        fi
        if (( quiet == 0 )); then
            content=$(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//' | cut -c1-"$width")
            printf '%-58s | %s\n' "$anchor" "$content"
        fi
    done < <(rg -o --no-filename "$anchor_re" "$doc" | uniq)
done

echo
echo "anchors checked: $total, problems: $bad"
exit $(( bad > 0 ? 1 : 0 ))
