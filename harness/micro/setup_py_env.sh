#!/usr/bin/env bash
# 建 Python 侧微基准的 venv（只用 --system-site-packages 继承基座解释器，
# 额外装 msgspec / msgpack 两个对照臂；**不动宿主机 site-packages**）。
#
# 为什么要 venv：本机基座 conda 环境里没有 msgspec，而 msgspec.msgpack 是
# vLLM 前端与 engine core 之间 msgpack 的**真实实现**（D3 的主对照）。
# 版本对齐 requirements/common.txt：msgspec 0.21.1、jinja2 3.1.6（基座已装）。
#
# 用法:
#   harness/micro/setup_py_env.sh            # 建/更新 venv 并打印版本
#   harness/micro/setup_py_env.sh --check    # 只检查
#
# venv 落在 harness/micro/.venv（.gitignore 已忽略）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.venv"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --check) CHECK_ONLY=1 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "未知参数: $1（试 --help）" >&2; exit 2 ;;
esac

if [[ ! -x "$VENV/bin/python" ]]; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "[setup_py_env] venv 不存在：$VENV（去掉 --check 创建）" >&2
    exit 1
  fi
  python3 -m venv --system-site-packages "$VENV"
fi

if [[ "$CHECK_ONLY" == "0" ]]; then
  "$VENV/bin/pip" install --quiet --upgrade 'msgspec==0.21.1' 'msgpack>=1.0'
fi

"$VENV/bin/python" - <<'PY'
import sys

import jinja2
import msgspec
import msgpack

import orjson

print(f"[setup_py_env] python={sys.version.split()[0]} jinja2={jinja2.__version__} "
      f"msgspec={msgspec.__version__} msgpack={msgpack.version} orjson={orjson.__version__}")
PY
