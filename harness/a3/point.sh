#!/usr/bin/env bash
# **在 REMOTE_HOST 上运行**：一个 A/B 负载点的完整测量。
#
# 测什么（口径与 plan/EXPERIMENT 的必采项对齐）：
#   ① 端到端吞吐/延迟      —— 客户端容器里的 `vllm bench serve`
#   ② 前端进程 CPU 时间    —— /proc/<host_pid>/stat 的 utime+stime 增量
#   ③ 引擎进程 CPU 时间    —— 同上（用来画「前端 vs 引擎」的边界）
#   ④ 前端 perf stat       —— instructions/cycles/cache-misses/branches（可选）
#   ⑤ manifest             —— 镜像、chrom、绑核、loadavg、制品 sha256
#
# 三进程隔离（互不抢核，沿用 plan/COORDINATION.md §2.1 的 chip4 约定）：
#   | 角色 | 位置 | 核 |
#   |---|---|---|
#   | 前端/引擎 | 服务容器（chip4，cpuset 160-199） | 160-199 |
#   | 压测客户端 | **独立容器**（不带 NPU 设备） | 200-201 |
#
# 用法（单点）:
#   harness/a3/point.sh --run ab-c1-rust --side rust --tag C1 \
#     --port 18300 --input-len 1024 --output-len 128 \
#     --num-prompts 32 --max-concurrency 1 --warmup 4 [--perf]
#   harness/a3/point.sh --help
#
# 前置：服务容器已由 harness/a3/ab_serve.sh start 起好、/health 200。
set -euo pipefail

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; SIDE=""; TAG="point"; PORT=""; CHIP="${CHIP:-4}"
INPUT_LEN=1024; OUTPUT_LEN=128; NUM_PROMPTS=32; MAX_CONC=1; WARMUP=4
DO_PERF=0; MODEL="/models/Qwen3.5-0.8B"
CLIENT_CORES="${CLIENT_CORES:-200-201}"
# 服务容器 cpuset（必须与 ab_serve.sh 起容器时用的 SERVER_CPUSET 一致；这里只用于记录口径）
SERVER_CPUSET="${SERVER_CPUSET:-$((40 * CHIP))-$((40 * CHIP + 39))}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
PERF_MAX_SECS="${PERF_MAX_SECS:-3600}"   # perf 采样的硬上限（秒），防止忘记停时无限跑
IMAGE="${VLLM_IMAGE:-quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler}"
MODEL_HOST_DIR="${MODEL_HOST_DIR:-$HOME/models}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN="$2"; shift 2 ;;
    --side) SIDE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --chip) CHIP="$2"; shift 2 ;;
    --input-len) INPUT_LEN="$2"; shift 2 ;;
    --output-len) OUTPUT_LEN="$2"; shift 2 ;;
    --num-prompts) NUM_PROMPTS="$2"; shift 2 ;;
    --max-concurrency) MAX_CONC="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --perf) DO_PERF=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$SIDE" && -n "$PORT" ]] || { echo "需要 --run --side --port" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROCSTAT="$REPO_ROOT/harness/common/procstat.sh"
OUT_DIR="$REPO_ROOT/runs/$RUN/$TAG-$SIDE"
mkdir -p "$OUT_DIR/bench"
say() { printf '[point] %s\n' "$*"; }

# ---- 1. 解析进程（宿主 pid）------------------------------------------------
# 容器名解析：新命名 `vrs-ab-<AB_OWNER>-<run>`（多线隔离用），回落旧命名 `vrs-ab-<run>`。
# ⚠️ 不能硬编码旧命名：设了 AB_OWNER 后容器叫 `vrs-ab-c-ab-C2-rust`，
#    硬编码会取到空 docker top、报「找不到前端进程」（踩过一整轮 C2–C5）。
AB_OWNER="${AB_OWNER:-}"
CONTAINER=""
for c in "vrs-ab-${AB_OWNER}-$RUN" "vrs-ab-$RUN"; do
  [[ "$c" == "vrs-ab--$RUN" ]] && continue
  if sudo -n docker ps -aq --filter "name=^${c}\$" 2>/dev/null | grep -q .; then CONTAINER="$c"; break; fi
done
[[ -n "$CONTAINER" ]] || { echo "找不到容器（run=$RUN owner=${AB_OWNER:-未设}）" >&2; exit 1; }
echo "[point] 容器=$CONTAINER"
TOP="$(sudo -n docker top "$CONTAINER" -eo pid,ppid,comm 2>/dev/null)"
pick() { echo "$TOP" | awk -v pat="$1" '$3 ~ pat {print $1; exit}'; }

if [[ "$SIDE" == "rust" ]]; then
  FE_PID="$(pick '^vllm-rs$')"
else
  # 拓扑 A：主进程自己就是 API server（A 线 docs/01b §1.1 有源码依据）
  FE_PID="$(pick '^vllm$')"
fi
ENG_PID="$(pick '^VLLM::EngineCor')"
[[ -n "$FE_PID" ]] || { echo "找不到前端进程（side=$SIDE）；docker top 输出：" >&2; echo "$TOP" >&2; exit 1; }
say "前端 pid=$FE_PID 引擎 pid=${ENG_PID:-无}"

# ⚠️ 同时盯住**容器内所有进程**：vLLM 的前端进程可能 fork 出辅助子进程
#    （实测 Python 臂有 `python3` 子进程）。只统计单一 pid 会漏算。
#    汇总时按 comm 归类：前端 / 引擎 / 其它。
ALL_PIDS="$(echo "$TOP" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ')"
say "容器内全部 pid：$ALL_PIDS"

{
  echo "# docker top（宿主 pid）"
  echo "$TOP"
  echo "# picked frontend=$FE_PID engine=${ENG_PID:-none}"
} > "$OUT_DIR/topology.txt"

# ---- 2. 客户端封装 ---------------------------------------------------------
run_client() {  # $1=phase(warmup|main) $2=num_prompts $3=extra args...
  local phase="$1" n="$2"; shift 2
  sudo -n docker run --rm --network host --cpuset-cpus="$CLIENT_CORES" \
    -v "$MODEL_HOST_DIR:/models:ro" \
    -v "$OUT_DIR/bench:/out:rw" \
    -e ASCEND_RT_VISIBLE_DEVICES= -e VLLM_USE_MODELSCOPE=False \
    -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
    "$IMAGE" \
    vllm bench serve --backend openai-chat --endpoint /v1/chat/completions \
      --base-url "http://127.0.0.1:$PORT" \
      --model "$MODEL" --tokenizer "$MODEL" \
      --dataset-name random --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN" \
      --num-prompts "$n" --max-concurrency "$MAX_CONC" \
      "$@"
}

# ---- 3. 预热（不计入窗口）--------------------------------------------------
if [[ "$WARMUP" -gt 0 ]]; then
  say "预热 $WARMUP 个请求（不计入窗口）"
  run_client warmup "$WARMUP" > "$OUT_DIR/warmup.stdout.txt" 2>&1 || {
    tail -20 "$OUT_DIR/warmup.stdout.txt" >&2; echo "预热失败" >&2; exit 1; }
fi

# ---- 4. 窗口内：procstat + perf stat + 正式负载 ----------------------------
# shellcheck disable=SC2086
"$PROCSTAT" snapshot --out "$OUT_DIR/all.before.json" $ALL_PIDS 2>/dev/null

PERF_PID=""
PERF_REAL=""
if [[ "$DO_PERF" == "1" ]]; then
  say "启动 perf stat（前台 pid=$FE_PID）"
  # ⚠️ 踩过的坑：`sudo perf ...` 会 fork 出真正的 perf 子进程，
  #    给 sudo 那个 pid 发 SIGINT **不会**传到 perf ⇒ `wait` 永久挂住。
  #    这里记下真正的 perf pid（sudo 的子进程），停的时候直接打它。
  # ⚠️ 第二个坑：后台任务**绝不能继承本脚本的 stdout/stderr**。
  #    ssh 的 `... | tail` 会一直等管道 EOF；只要有一个后台后代活着并持有写端，
  #    整个 ssh 会话就永远不返回（观测到的现象：脚本早已写完结果，ssh 还挂着）。
  #    所以这里 `setsid` + 完全重定向，让它彻底脱离本会话。
  setsid sudo -n perf stat -p "$FE_PID" \
    -e instructions:u,cycles:u,branches:u,branch-misses:u,cache-misses:u \
    -o "$OUT_DIR/perf.txt" -- sleep "$PERF_MAX_SECS" \
    </dev/null >>"$OUT_DIR/perf.stdout.txt" 2>>"$OUT_DIR/perf.stderr.txt" &
  PERF_PID=$!
  sleep 2
  # setsid → sudo → perf：真正的 perf 是**孙进程**。只取子进程会拿到 sudo，
  # 给 sudo 发 SIGINT 不保证转发 ⇒ perf 不落盘（实测踩过：perf.txt 0 字节）。
  PERF_REAL="$(for p in $(pgrep -P "$PERF_PID" 2>/dev/null); do
                 pgrep -P "$p" 2>/dev/null
               done | head -1 || true)"
  # 兜底：按命令行精确匹配（FE_PID 唯一，模式安全）
  if [[ -z "$PERF_REAL" ]]; then
    PERF_REAL="$(pgrep -f "^perf stat -p $FE_PID " 2>/dev/null | head -1 || true)"
  fi
  say "perf 包装 pid=$PERF_PID 真实 pid=${PERF_REAL:-未知}"
fi

WINDOW_START=$(date +%s.%N)
say "正式负载：num-prompts=$NUM_PROMPTS c=$MAX_CONC ISL=$INPUT_LEN OSL=$OUTPUT_LEN"
run_client main "$NUM_PROMPTS" --save-result --result-dir /out \
  > "$OUT_DIR/main.stdout.txt" 2>&1 || {
    tail -30 "$OUT_DIR/main.stdout.txt" >&2
    [[ -n "$PERF_REAL" ]] && sudo -n kill -INT "$PERF_REAL" 2>/dev/null || true
    [[ -n "$PERF_PID" ]] && sudo -n kill -KILL "$PERF_PID" 2>/dev/null || true
    echo "正式负载失败" >&2; exit 1; }
WINDOW_END=$(date +%s.%N)

if [[ -n "$PERF_PID" ]]; then
  [[ -n "$PERF_REAL" ]] && sudo -n kill -INT "$PERF_REAL" 2>/dev/null || true
  # 兜底：即使 pid 解析失败，也按命令行精确匹配再打一次（FE_PID 唯一）
  sudo -n pkill -INT -f "^perf stat -p $FE_PID " 2>/dev/null || true
  # 有界等待：最多 30 s，超时则强杀包装进程，绝不无限挂住
  for _ in $(seq 1 30); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$PERF_PID" 2>/dev/null; then
    say "⚠️ perf 未在 30s 内退出，强杀"
    sudo -n kill -KILL "$PERF_REAL" 2>/dev/null || true
    sudo -n kill -KILL "$PERF_PID" 2>/dev/null || true
  fi
  wait "$PERF_PID" 2>/dev/null || true
fi

# shellcheck disable=SC2086
"$PROCSTAT" snapshot --out "$OUT_DIR/all.after.json" $ALL_PIDS 2>/dev/null

"$PROCSTAT" diff --before "$OUT_DIR/all.before.json" --after "$OUT_DIR/all.after.json" \
  --out "$OUT_DIR/all_cpu.json" >/dev/null
# 兼容旧路径：把「前端单进程」的差量单独落一份，便于与早期结果对照
python3 - "$OUT_DIR" "$FE_PID" "$ENG_PID" <<'PYALL'
import json, pathlib, sys
out, fe, eng = pathlib.Path(sys.argv[1]), sys.argv[2], (sys.argv[3] or "")
d = json.load(open(out / "all_cpu.json"))
for name, pid in (("frontend_cpu.json", fe), ("engine_cpu.json", eng)):
    if not pid:
        continue
    sub = dict(d)
    sub["pids"] = {k: v for k, v in d["pids"].items() if k == pid}
    sub["cpu_seconds_total"] = round(sum(v.get("cpu_seconds", 0) for v in sub["pids"].values()), 4)
    (out / name).write_text(json.dumps(sub, ensure_ascii=False, indent=1) + "\n")
PYALL

# ---- 5. 汇总 ---------------------------------------------------------------
python3 - "$OUT_DIR" "$RUN" "$SIDE" "$TAG" "$PORT" "$CHIP" "$INPUT_LEN" "$OUTPUT_LEN" \
        "$NUM_PROMPTS" "$MAX_CONC" "$WARMUP" "$CLIENT_CORES" "$WINDOW_START" "$WINDOW_END" \
        "$IMAGE" "$FE_PID" "${ENG_PID:-}" "$SERVER_CPUSET" "$MAX_MODEL_LEN" "$MAX_NUM_SEQS" <<'PY'
import glob, json, os, pathlib, subprocess, sys, time

(out, run, side, tag, port, chip, isl, osl, n, c, warm, ccores, w0, w1,
 image, fe_pid, eng_pid, server_cpuset, max_model_len, max_num_seqs) = sys.argv[1:]
out = pathlib.Path(out)

def _ncores(spec):
    """'160-199' -> 40 ; '160-175' -> 16（CORES 语义是核列表，不是核数）"""
    total = 0
    for part in str(spec).split(","):
        if "-" in part:
            a, b = part.split("-"); total += int(b) - int(a) + 1
        else:
            total += 1
    return total

def jload(p):
    try:
        return json.load(open(p))
    except Exception:
        return None

allcpu = jload(out / "all_cpu.json") or {}
fe = jload(out / "frontend_cpu.json") or {}
eng = jload(out / "engine_cpu.json") or {}

def classify(cpu_doc, key):
    """按 comm 把容器内进程分桶：前端 / 引擎 / 其它。

    ⚠️ 为什么不只看单个 pid：实测 Python 臂会 fork 出辅助 `python3` 子进程，
       只统计主 pid 会漏算；引擎侧还有 VLLM::Worker（TP>1 时）。
    """
    buckets = {"frontend": 0.0, "engine": 0.0, "other": 0.0}
    detail = {}
    for pid, v in (cpu_doc.get("pids") or {}).items():
        s = v.get(key) or 0
        comm = v.get("comm", "?")
        if pid == fe_pid:
            b = "frontend"
        elif comm.startswith("VLLM::EngineCor") or comm.startswith("VLLM::Worker"):
            b = "engine"
        else:
            b = "other"
        buckets[b] += s
        detail[pid] = {"comm": comm, "cpu_seconds": s, "bucket": b}
    return buckets, detail

fe_win = (fe.get("wall_seconds") or 0)
buckets, detail = classify(allcpu, "cpu_seconds")
bench = None
for f in sorted(glob.glob(str(out / "bench" / "*.json"))):
    bench = jload(f)
    if bench:
        bench["_file"] = os.path.basename(f)
        break

def g(d, k):
    return d.get(k) if isinstance(d, dict) else None

doc = {
    "run": run, "side": side, "tag": tag,
    "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "image": image, "chip": chip, "port": port,
    "load": {"input_len": int(isl), "output_len": int(osl),
             "num_prompts": int(n), "max_concurrency": int(c), "warmup": int(warm)},
    "window": {"start_epoch": float(w0), "end_epoch": float(w1),
               "seconds": round(float(w1) - float(w0), 3)},
    "cores": {"server_cpuset": server_cpuset, "client_cpuset": ccores,
              "server_cores_effective": _ncores(server_cpuset),
              "client_cores_effective": _ncores(ccores)},
    "engine_limits": {"max_model_len": int(max_model_len), "max_num_seqs": int(max_num_seqs)},
    "pids": {"frontend": int(fe_pid), "engine": int(eng_pid) if eng_pid else None},
    "frontend_cpu": {
        "cpu_seconds": g(fe, "cpu_seconds_total"),
        "utime_seconds": sum(v.get("utime_seconds", 0) for v in fe.get("pids", {}).values()),
        "stime_seconds": sum(v.get("stime_seconds", 0) for v in fe.get("pids", {}).values()),
        "threads_end": sum(v.get("threads_end", 0) for v in fe.get("pids", {}).values()),
        "rss_kb_end": sum(v.get("rss_kb_end", 0) for v in fe.get("pids", {}).values()),
    },
    "engine_cpu": {"cpu_seconds": g(eng, "cpu_seconds_total"),
                   "utime_seconds": sum(v.get("utime_seconds", 0) for v in eng.get("pids", {}).values()),
                   "stime_seconds": sum(v.get("stime_seconds", 0) for v in eng.get("pids", {}).values())},
    # 容器内**全部**进程的分桶（前端 / 引擎 / 其它），单位 CPU 秒
    "container_cpu_buckets": {
        k: round(v, 4) for k, v in buckets.items()
    },
    "container_cpu_detail": detail,
    "e2e": {k: bench.get(k) for k in (
        "completed", "failed", "duration", "request_throughput", "output_throughput",
        "total_input_tokens", "total_output_tokens", "mean_ttft_ms", "p99_ttft_ms",
        "mean_tpot_ms", "p99_tpot_ms", "mean_itl_ms", "mean_e2el_ms", "p99_e2el_ms",
        "_file")} if bench else None,
    "perf_file": "perf.txt" if (out / "perf.txt").exists() else None,
    "loadavg": open("/proc/loadavg").read().split()[:3],
}

# 归一化指标（A/B 的主要结论）
if bench and int(bench.get("completed") or 0) > 0:
    comp = bench["completed"]
    fe_s = doc["frontend_cpu"]["cpu_seconds"] or 0
    itok = bench.get("total_input_tokens") or 0
    otok = bench.get("total_output_tokens") or 0
    doc["normalized"] = {
        "frontend_cpu_s_per_request": round(fe_s / comp, 6),
        "frontend_cpu_s_per_1k_input_tokens": round(fe_s / itok * 1000, 6) if itok else None,
        "frontend_cpu_s_per_1k_output_tokens": round(fe_s / otok * 1000, 6) if otok else None,
        "engine_cpu_s_per_request": round((doc["engine_cpu"]["cpu_seconds"] or 0) / comp, 6),
    }

(out / "point.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")

n = doc.get("normalized") or {}
print(f"\n[point] {side}/{tag}: 窗口 {doc['window']['seconds']}s, 完成 {g(bench or {}, 'completed')}")
print(f"[point] 前端 CPU {doc['frontend_cpu']['cpu_seconds']}s "
      f"(utime {doc['frontend_cpu']['utime_seconds']}s / stime {doc['frontend_cpu']['stime_seconds']}s)")
print(f"[point] 引擎 CPU {doc['engine_cpu']['cpu_seconds']}s")
if n:
    print(f"[point] 前端 CPU/请求 {n['frontend_cpu_s_per_request']}s, "
          f"/千输入 tok {n['frontend_cpu_s_per_1k_input_tokens']}s, "
          f"/千输出 tok {n['frontend_cpu_s_per_1k_output_tokens']}s")
if bench:
    print(f"[point] 吞吐 {bench.get('request_throughput'):.3f} req/s, "
          f"TTFT {bench.get('mean_ttft_ms'):.1f} ms, TPOT {bench.get('mean_tpot_ms'):.2f} ms")
PY

say "结果 → $OUT_DIR/point.json"
