#!/usr/bin/env bash
# 共享环境与口径常量 —— 四条线都用这一份，保证 A/B 与 profile 同口径。
#
# 用法：在脚本里 `source .../harness/common/env.sh`，再调用下面的函数。
# 所有变量都可用环境变量覆盖（例：FE_CORES=4-7 ./run.sh）。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/../.." && pwd)"

# ---- 制品（二进制不进 git，只记路径 + sha256，见 plan/COORDINATION.md §8）----
FRONTEND_BIN="${FRONTEND_BIN:-/tmp/d-nextgen-wheel/vllm-rs}"
MOCK_ENGINE_BIN="${MOCK_ENGINE_BIN:-$HOME/.cache/d-nextgen-mock/target/release/vllm-mock-engine}"
BENCH_BIN="${BENCH_BIN:-$HOME/.cache/vllm-rs-bench/target/release/vllm-bench}"
MODEL="${MODEL:-REPO_HOME/models/Qwen3-0.6B}"
VLLM_SRC="${VLLM_SRC:-REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm}"
VLLM_COMMIT="${VLLM_COMMIT:-568afb3a13806beb53bb2e6bd518269357b237c0}"

# ---- 绑核：CORES 语义是 taskset 的核列表，不是核数（tokenizer 项目踩过的坑）----
# 本机 12 核，资源纪律要求 ≤9 核。默认三段分开绑，互不抢核：
FE_CORES="${FE_CORES:-4-5}"          # 被分析对象（前端）：2 核。核数扫描时改 4-7 / 2-7
ENG_CORES="${ENG_CORES:-6-7}"        # mock/真引擎：2 核
CLIENT_CORES="${CLIENT_CORES:-8-9}"  # 压测客户端：2 核，必须与前端分开

# ---- 端口 ----
PORT="${PORT:-8199}"
HANDSHAKE_PORT="${HANDSHAKE_PORT:-29577}"

# ---- 运行目录（gitignored）----
RUNS_ROOT="${RUNS_ROOT:-$REPO_ROOT/runs}"

ncores() {  # "4-7" -> 4 ; "4-5,8" -> 3
  python3 - "$1" <<'PY'
import sys
total = 0
for part in sys.argv[1].split(','):
    if '-' in part:
        a, b = part.split('-'); total += int(b) - int(a) + 1
    else:
        total += 1
print(total)
PY
}

sha256_16() { [[ -f "$1" ]] && sha256sum "$1" | cut -c1-16 || echo "missing"; }

loadavg() { awk '{print $1,$2,$3}' /proc/loadavg; }

mem_available_gib() { awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo; }

# 写一份 manifest（plan/COORDINATION.md §5.6 要求的字段）
write_manifest() {
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import hashlib, json, os, pathlib, socket, subprocess, sys, time
out, *pairs = sys.argv[1:]
kv = dict(p.split("=", 1) for p in pairs)

def sha(p):
    try:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None

doc = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "host": socket.gethostname(),
    "machine": os.uname().machine,
    "hostname_nproc": os.cpu_count(),
    "loadavg_at_start": open("/proc/loadavg").read().split()[:3],
    "mem_available_gib": round(
        int(next(l for l in open("/proc/meminfo") if l.startswith("MemAvailable")).split()[1]) / 1048576, 1
    ),
    "artifacts": {},
    "fields": {},
}
for k, v in kv.items():
    if k.endswith("_path"):
        doc["artifacts"][k[:-5]] = {"path": v, "sha256": sha(v), "size": os.path.getsize(v) if os.path.exists(v) else None}
    elif k.endswith("_sha256") or "cores" in k or "version" in k:
        doc["fields"][k] = v
    else:
        doc["fields"][k] = v
pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
print(f"[manifest] {out}")
PY
}

die() { echo "[error] $*" >&2; exit 1; }
say() { printf '[harness] %s\n' "$*"; }
