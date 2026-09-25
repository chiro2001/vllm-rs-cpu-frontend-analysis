#!/usr/bin/env bash
# 构建 A/B 用的「纯 CPU vLLM 0.26.0」容器镜像（G3 打通记录，可一键复现）。
#
# 用法:
#   build_image.sh [--tag local/vllm-cpu:0.26.0-ab-20260925] [--force]
#   build_image.sh --help
#
# 为什么不是直接用现成的 ascend-stub 镜像：那个镜像的 `vllm` 是 ascend 插件版，
# 平台解析结果是 NPUPlatform（会去碰 NPU），本计划红线是不碰 NPU。
# 官方发布的 **vllm-0.26.0+cpu wheel** 的构建 commit 与本项目锁定的
# 568afb3a13806beb53bb2e6bd518269357b237c0 完全一致，且不含任何 NPU 插件。
#
# 打通过程中踩到的四个坑（都已固化进镜像）：
#   1. `vllm/_C*.so` 的 GNU_STACK 段带 X 位（RWX），内核拒绝给栈加执行权限，
#
#      ImportError: .../_C.abi3.so: cannot enable executable stack as shared object requires
#      解法：清掉 PT_GNU_STACK 的 PF_X（只改 ELF 程序头，不改代码）。
#   2. 缺 libnuma.so.1 → `apt-get install libnuma1`。
#   3. torch.compile/inductor 需要 C++ 编译器 → `apt-get install g++`。
#   4. 官方要求 LD_PRELOAD 里挂 TCMalloc 与 Intel OpenMP（容器内路径见下）。
set -euo pipefail

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ab_env.sh
source "$AB_DIR/ab_env.sh"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

TAG="$AB_IMAGE"; FORCE=0; BASE="python:3.12-slim"; TMP_NAME="cab-build"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tag) TAG="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

if docker image inspect "$TAG" >/dev/null 2>&1 && [[ "$FORCE" != "1" ]]; then
  echo "[ab][image] 已存在：$TAG（sha=$(docker image inspect -f '{{.Id}}' "$TAG" | cut -c8-19)）"
  exit 0
fi

WHEEL_URL="${AB_CPU_WHEEL_URL:-https://github.com/vllm-project/vllm/releases/download/v0.26.0/vllm-0.26.0%2Bcpu-cp38-abi3-manylinux_2_34_x86_64.whl}"

ab_say "构建 $TAG（base=$BASE）"
docker rm -f "$TMP_NAME" >/dev/null 2>&1 || true
docker run -d --name "$TMP_NAME" --entrypoint sleep "$BASE" infinity >/dev/null
trap 'docker rm -f "$TMP_NAME" >/dev/null 2>&1 || true' EXIT

ab_say "1/4 装系统依赖（libnuma1 / libtcmalloc / g++）"
docker exec "$TMP_NAME" bash -lc '
  set -e
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends libgomp1 libtcmalloc-minimal4t64 libnuma1 g++
'

ab_say "2/4 装 vLLM CPU wheel（commit 568afb3a…）"
docker exec "$TMP_NAME" bash -lc "
  set -e
  pip install --no-cache-dir '$WHEEL_URL' --extra-index-url https://download.pytorch.org/whl/cpu
  pip show vllm | head -3
"

ab_say "3/4 清 PT_GNU_STACK 的 X 位（否则 _C*.so 无法加载）"
docker exec "$TMP_NAME" bash -lc 'python3 - <<PY
import glob, struct
targets = (glob.glob("/usr/local/lib/python3.12/site-packages/vllm/_C*.so")
           + glob.glob("/usr/local/lib/libiomp5.so"))
for p in targets:
    f = open(p, "r+b"); hdr = f.read(64)
    if hdr[:4] != b"\x7fELF":
        f.close(); continue
    e_phoff = struct.unpack_from("<Q", hdr, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", hdr, 0x36)[0]
    e_phnum = struct.unpack_from("<H", hdr, 0x38)[0]
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        f.seek(off); ph = f.read(e_phentsize)
        p_type, p_flags = struct.unpack_from("<II", ph, 0)
        if p_type == 0x6474E551 and p_flags & 1:
            f.seek(off); f.write(struct.pack("<II", p_type, p_flags & ~1) + ph[8:])
            print("patched", p.split("/")[-1], p_flags)
    f.close()
PY'

ab_say "4/4 冒烟：平台必须是 CpuPlatform（不是 NPUPlatform）"
docker exec "$TMP_NAME" bash -lc '
  set -e
  export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4:/usr/local/lib/libiomp5.so
  python3 -c "
import torch, vllm
from vllm.platforms import current_platform
assert type(current_platform).__name__ == \"CpuPlatform\", type(current_platform).__name__
assert not hasattr(torch, \"npu\"), \"torch_npu 不应存在\"
print(\"vllm\", vllm.__version__, \"platform\", type(current_platform).__name__)
print(\"vllm-rs shipped:\", __import__(\"os\").path.exists(\"/usr/local/lib/python3.12/site-packages/vllm/vllm-rs\"))
"
'

docker commit "$TMP_NAME" "$TAG" >/dev/null
ab_say "已提交镜像：$TAG（sha=$(docker image inspect -f '{{.Id}}' "$TAG" | cut -c8-19)）"
