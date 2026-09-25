#!/usr/bin/env bash
# **在 REMOTE_HOST 上运行**：一个 profiling 负载点 —— `perf record` 火焰图（前端进程）+ 端到端负载。
#
# 与 `harness/a3/point.sh` 的分工：
#   * `point.sh`  —— A/B 用：`perf stat` + procstat 分桶 + 吞吐/延迟（回答"快多少"）
#   * `prof_point.sh`（本脚本）—— profiling 用：`perf record --call-graph` 采样栈（回答"花在哪"）
#   两者都跑同一个负载、同一套绑核，可交叉引用。
#
# 为什么前端进程要用**宿主 pid**：服务跑在容器里，`perf` 在宿主上跑
#   （容器内没有 perf，且 `perf_event_paranoid=2` 下普通用户只能采 `:u`，
#    实测 `sudo -n perf` 可采到容器内进程的**完整栈含内核符号**）。
#   宿主 pid 用 `docker top` 取（见 `harness/a3/ab_serve.sh pids`）。
#
# 用法（单点，必须包在 chip_lock 里）:
#   harness/a3/chip_lock.sh -- harness/profile/a3/prof_point.sh \
#       --run b-a1 --side rust --tag A1 --port 18300 \
#       --input-len 1024 --output-len 128 --num-prompts 64 --max-concurrency 1 \
#       [--call-graph fp|dwarf,16384] [--freq 999] [--no-perf] [--perf-stat]
#   prof_point.sh --help
#
# 前置：服务容器已起好（`harness/a3/ab_serve.sh start --run <name> --frontend <side>`）、/health 200。
set -euo pipefail

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

RUN=""; SIDE=""; TAG="prof"; PORT=""; CHIP="${CHIP:-4}"
INPUT_LEN=1024; OUTPUT_LEN=128; NUM_PROMPTS=64; MAX_CONC=1; WARMUP=4
FREQ=999; CALLGRAPH="fp"; DO_PERF=1; DO_STAT=0; EVENT="cpu-clock"
DO_SYSCALL=0; SYMFS_FIX=1
MODEL="/models/Qwen3.5-0.8B"
CLIENT_CORES="${CLIENT_CORES:-200-201}"
PERF_MAX_SECS="${PERF_MAX_SECS:-3600}"
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
    --freq) FREQ="$2"; shift 2 ;;
    --call-graph) CALLGRAPH="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --no-perf) DO_PERF=0; shift ;;
    --perf) DO_PERF=1; shift ;;   # 显式开启（默认已是开）——让调用方语义直白，且幂等
    --perf-stat) DO_STAT=1; shift ;;
    --syscall-stat) DO_SYSCALL=1; shift ;;   # 额外记 tracepoint：syscall 次数（内核态归因的替代证据）
    --no-symfs) SYMFS_FIX=0; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$SIDE" && -n "$PORT" ]] || { echo "需要 --run --side --port" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROCSTAT="$REPO_ROOT/harness/common/procstat.sh"
OUT_DIR="$REPO_ROOT/runs/$RUN/$TAG-$SIDE"
mkdir -p "$OUT_DIR/bench"
say() { printf '[prof] %s\n' "$*"; }

# ---- 1. 解析进程（宿主 pid）----
CONTAINER="vrs-ab-$RUN"
TOP="$(sudo -n docker top "$CONTAINER" -eo pid,ppid,comm 2>/dev/null)"
pick() { echo "$TOP" | awk -v pat="$1" '$3 ~ pat {print $1; exit}'; }
if [[ "$SIDE" == "rust" ]]; then FE_PID="$(pick '^vllm-rs$')"; else FE_PID="$(pick '^vllm$')"; fi
ENG_PID="$(pick '^VLLM::EngineCor')"
[[ -n "$FE_PID" ]] || { echo "找不到前端进程（side=$SIDE）：" >&2; echo "$TOP" >&2; exit 1; }
ALL_PIDS="$(echo "$TOP" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ')"
say "前端 pid=$FE_PID 引擎 pid=${ENG_PID:-无}；容器内 pid：$ALL_PIDS"
{ echo "# docker top（宿主 pid）"; echo "$TOP"; } > "$OUT_DIR/topology.txt"

# ---- 2. 客户端封装 ----
run_client() {  # $1=phase $2=num_prompts $3...=extra
  local phase="$1" n="$2"; shift 2
  sudo -n docker run --rm --network host --cpuset-cpus="$CLIENT_CORES" \
    -v "$MODEL_HOST_DIR:/models:ro" -v "$OUT_DIR/bench:/out:rw" \
    -e ASCEND_RT_VISIBLE_DEVICES= -e VLLM_USE_MODELSCOPE=False \
    -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
    "$IMAGE" \
    vllm bench serve --backend openai-chat --endpoint /v1/chat/completions \
      --base-url "http://127.0.0.1:$PORT" --model "$MODEL" --tokenizer "$MODEL" \
      --dataset-name random --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN" \
      --num-prompts "$n" --max-concurrency "$MAX_CONC" "$@"
}

# ---- 3. 预热 ----
if [[ "$WARMUP" -gt 0 ]]; then
  say "预热 $WARMUP 个请求（不计入窗口）"
  run_client warmup "$WARMUP" > "$OUT_DIR/warmup.stdout.txt" 2>&1 || {
    tail -20 "$OUT_DIR/warmup.stdout.txt" >&2; echo "预热失败" >&2; exit 1; }
fi

# ---- 4. 窗口内：perf record / perf stat + procstat + 正式负载 ----
"$PROCSTAT" snapshot --out "$OUT_DIR/all.before.json" $ALL_PIDS 2>/dev/null

# 后台任务的三个坑（都在 point.sh 里踩过，这里照搬同样的对策）：
#   a) `sudo perf` 会 fork 出真正的 perf 子进程 ⇒ 要打它，不是打 sudo；
#   b) 后台任务必须 setsid + 完全重定向，否则 ssh 会话等管道 EOF 永不返回；
#   c) perf 必须能收尾（trap），否则负载失败时它会变成孤儿继续写同一个 -o。
PERF_PID=""; PERF_REAL=""; STAT_PID=""
CG_ARGS=()
if [[ "$CALLGRAPH" == "fp" ]]; then CG_ARGS=(--call-graph fp); else CG_ARGS=(--call-graph "$CALLGRAPH"); fi

if [[ "$DO_PERF" == "1" ]]; then
  say "perf record：pid=$FE_PID event=$EVENT freq=$FREQ call-graph=$CALLGRAPH"
  setsid sudo -n perf record -p "$FE_PID" -e "$EVENT" -F "$FREQ" "${CG_ARGS[@]}" \
    -o "$OUT_DIR/perf.data" -- sleep "$PERF_MAX_SECS" \
    </dev/null >>"$OUT_DIR/perf.stdout.txt" 2>>"$OUT_DIR/perf.stderr.txt" &
  PERF_PID=$!
  sleep 2
  PERF_REAL="$(for p in $(pgrep -P "$PERF_PID" 2>/dev/null); do pgrep -P "$p" 2>/dev/null; done | head -1 || true)"
  [[ -n "$PERF_REAL" ]] || PERF_REAL="$(pgrep -f "^perf record -p $FE_PID " 2>/dev/null | head -1 || true)"
  say "perf 包装 pid=$PERF_PID 真实 pid=${PERF_REAL:-未知}"
fi

if [[ "$DO_STAT" == "1" ]]; then
  say "perf stat：pid=$FE_PID"
  STAT_EVENTS="instructions:u,cycles:u,branches:u,branch-misses:u,cache-misses:u,cache-references:u"
  if [[ "$DO_SYSCALL" == "1" ]]; then
    # tracepoint 计数：不依赖 kallsyms，能直接量化「每 tick 一次收包」这类内核活动。
    # ⚠️ 选事件时踩过的坑：只记 `recvmsg` 会得到 **0**——zeromq 收包走的是 `recvfrom`/`read`。
    #    实测（A5-rust，96 请求 / OSL=128）：`write` = 19 988 次（**208 次/请求**，即每 token
    #    一次 SSE 回写），而 `recvmsg` = 0；所以这里把收发两侧的常见入口都记上。
    STAT_EVENTS+=",syscalls:sys_enter_recvmsg,syscalls:sys_enter_recvfrom"
    STAT_EVENTS+=",syscalls:sys_enter_read,syscalls:sys_enter_readv"
    STAT_EVENTS+=",syscalls:sys_enter_sendto,syscalls:sys_enter_write,syscalls:sys_enter_writev"
    STAT_EVENTS+=",syscalls:sys_enter_epoll_pwait,syscalls:sys_enter_futex"
  fi
  setsid sudo -n perf stat -p "$FE_PID" -e "$STAT_EVENTS" \
    -o "$OUT_DIR/perf-stat.txt" -- sleep "$PERF_MAX_SECS" \
    </dev/null >>"$OUT_DIR/perf.stat.stdout.txt" 2>>"$OUT_DIR/perf.stat.stderr.txt" &
  STAT_PID=$!
  sleep 2
  # ⚠️ 与 perf record 同样的坑：`sudo perf` 会 fork 真 perf 子进程，
  #    给 sudo 的 pid 发 SIGINT 不转发 ⇒ perf 不落盘（实测 perf-stat.txt 0 字节）。
  #    这里解析出**真正的** perf pid，停的时候打它。
  STAT_REAL="$(for p in $(pgrep -P "$STAT_PID" 2>/dev/null); do pgrep -P "$p" 2>/dev/null; done | head -1 || true)"
  [[ -n "$STAT_REAL" ]] || STAT_REAL="$(pgrep -f "^perf stat -p $FE_PID " 2>/dev/null | head -1 || true)"
  say "perf stat 包装 pid=$STAT_PID 真实 pid=${STAT_REAL:-未知}"
fi

stop_perf() {  # 收尾：打真正的 perf pid，且有界等待
  [[ -n "$PERF_REAL" ]] && sudo -n kill -INT "$PERF_REAL" 2>/dev/null || true
  sudo -n pkill -INT -f "^perf record -p $FE_PID " 2>/dev/null || true
  for _ in $(seq 1 60); do [[ -z "$PERF_PID" ]] || kill -0 "$PERF_PID" 2>/dev/null || break; sleep 1; done
  if [[ -n "$PERF_PID" ]] && kill -0 "$PERF_PID" 2>/dev/null; then
    say "⚠️ perf record 未在 60s 内退出，强杀"
    sudo -n kill -KILL "$PERF_REAL" 2>/dev/null || true
    sudo -n kill -KILL "$PERF_PID" 2>/dev/null || true
  fi
  [[ -n "$PERF_PID" ]] && wait "$PERF_PID" 2>/dev/null || true
}
stop_stat() {  # 与 stop_perf 同构：打真 pid + 有界等待 + 校验落盘
  [[ -n "${STAT_REAL:-}" ]] && sudo -n kill -INT "$STAT_REAL" 2>/dev/null || true
  sudo -n pkill -INT -f "^perf stat -p $FE_PID " 2>/dev/null || true
  for _ in $(seq 1 60); do [[ -z "$STAT_PID" ]] || kill -0 "$STAT_PID" 2>/dev/null || break; sleep 1; done
  if [[ -n "$STAT_PID" ]] && kill -0 "$STAT_PID" 2>/dev/null; then
    say "⚠️ perf stat 未在 60s 内退出，强杀"
    sudo -n kill -KILL "${STAT_REAL:-}" 2>/dev/null || true
    sudo -n kill -KILL "$STAT_PID" 2>/dev/null || true
  fi
  [[ -n "$STAT_PID" ]] && wait "$STAT_PID" 2>/dev/null || true
}
cleanup() { stop_perf; stop_stat; }
trap cleanup EXIT INT TERM

WINDOW_START=$(date +%s.%N)
say "正式负载：num-prompts=$NUM_PROMPTS c=$MAX_CONC ISL=$INPUT_LEN OSL=$OUTPUT_LEN"
run_client main "$NUM_PROMPTS" --save-result --result-dir /out \
  > "$OUT_DIR/main.stdout.txt" 2>&1 || {
    tail -30 "$OUT_DIR/main.stdout.txt" >&2; echo "正式负载失败" >&2; exit 1; }
WINDOW_END=$(date +%s.%N)

if [[ -n "$PERF_PID" ]]; then stop_perf; fi
if [[ -n "$STAT_PID" ]]; then stop_stat; fi
trap - EXIT INT TERM

# 采样落盘校验（0 字节 = 没落盘，必须显式报出来，别让它静默变成"无数据"）
if [[ "$DO_PERF" == "1" && ! -s "$OUT_DIR/perf.data" ]]; then
  say "⚠️ perf.data 为空或不存在 ⇒ 火焰图点无效"
fi
if [[ "$DO_STAT" == "1" && ! -s "$OUT_DIR/perf-stat.txt" ]]; then
  say "⚠️ perf-stat.txt 为空或不存在 ⇒ 该点的 IPC 无数据"
fi

"$PROCSTAT" snapshot --out "$OUT_DIR/all.after.json" $ALL_PIDS 2>/dev/null
"$PROCSTAT" diff --before "$OUT_DIR/all.before.json" --after "$OUT_DIR/all.after.json" \
  --out "$OUT_DIR/all_cpu.json" >/dev/null

# ---- 5. perf script（供离线折叠；原始 perf.data 不回传、不入 git）----
if [[ -s "$OUT_DIR/perf.data" ]]; then
  sudo -n chown "$(id -u):$(id -g)" "$OUT_DIR/perf.data" 2>/dev/null || true
  # ⚠️ **符号解析的关键一步（REMOTE_HOST 专属）**：被采进程在容器里，perf 记录的 mmap 路径是
  #    **容器内路径**（`/opt/vllm-rs-bin/vllm-rs`、`/usr/lib64/libc.so.6`），宿主上不存在
  #    ⇒ 直接 `perf script` 会得到一堆 `[unknown] (…/vllm-rs)`，符号全丢。
  #    解法：构造一个 `--symfs` 目录树，把容器内路径映射到真实文件（vllm-rs 用宿主副本、
  #    动态库从容器 `docker cp` 出来）。
  #    另：`/proc/kallsyms` 在本机把地址全写成 0（`head /proc/kallsyms` = `0 T _text`），
  #    所以**内核符号无法解析**，`[k]` 帧只能拿到裸地址 ⇒ 内核态去向改用 tracepoint 计数（--syscall-stat）。
  SYMFS="$OUT_DIR/symfs"
  SCRIPT_ARGS=()
  if [[ "$SYMFS_FIX" == "1" ]]; then
    say "构造 symfs（容器内路径 → 真实文件），用于解析符号"
    mkdir -p "$SYMFS/opt/vllm-rs-bin" "$SYMFS/usr/lib64" "$SYMFS/usr/lib"
    cp -f "${VLLM_BIN_HOST:-$HOME/projects/vllm/vllm-rs/bin/vllm-rs}" "$SYMFS/opt/vllm-rs-bin/vllm-rs" 2>/dev/null || true
    # 容器内的动态库：一次性把用到的几个拷出来（不同镜像版本可能不同 ⇒ 以容器内为准）
    for so in /usr/lib64/libc.so.6 /usr/lib64/libm.so.6 /usr/lib64/libstdc++.so.6 \
              /usr/lib64/libgcc_s.so.1 /usr/lib64/libpthread.so.0 /usr/lib64/libdl.so.2 \
              /usr/lib64/ld-linux-aarch64.so.1 /usr/lib64/libnuma.so.1; do
      sudo -n docker cp "$CONTAINER:$so" "$SYMFS$so" >/dev/null 2>&1 || true
    done
    SCRIPT_ARGS=(--symfs "$SYMFS")
    say "symfs 内容：$(find "$SYMFS" -type f | wc -l) 个文件"
  fi
  say "perf script → $OUT_DIR/perf-script.txt（gzip）"
  perf script -i "$OUT_DIR/perf.data" "${SCRIPT_ARGS[@]}" \
    > "$OUT_DIR/perf-script.txt" 2> "$OUT_DIR/perf-script.err" || true
  perf report -i "$OUT_DIR/perf.data" "${SCRIPT_ARGS[@]}" --stdio --no-children -n \
    > "$OUT_DIR/perf-report.txt" 2>&1 || true
  # 符号解析率自检：解析成功时帧名里不该全是 [unknown]
  UNK=$(grep -c "\[unknown\]" "$OUT_DIR/perf-script.txt" 2>/dev/null || echo 0)
  TOT=$(grep -c "^\s*[0-9a-f]" "$OUT_DIR/perf-script.txt" 2>/dev/null || echo 1)
  say "符号自检：未解析帧 $UNK / 总帧 $TOT（比例 $(python3 -c "print(f'{$UNK/max($TOT,1)*100:.1f}%')" 2>/dev/null || echo '?')）"
  # 事件名（判断是否采到内核态）：`cpu-clock` vs `cpu-clock:u`
  grep -m1 "^# Samples:" "$OUT_DIR/perf-report.txt" | sed 's/^/    /' || true
  gzip -f "$OUT_DIR/perf-script.txt"
  SCRIPT_SIZE=$(stat -c%s "$OUT_DIR/perf-script.txt.gz" 2>/dev/null || echo 0)
  say "perf-script.txt.gz = $SCRIPT_SIZE B"
  rm -rf "$SYMFS"
  # 原始 perf.data 体积大且不入 git；默认删掉。
  # 但**符号解析失败时保留**：那说明 symfs 没配对，需要重跑解析而不是重采一遍
  # （重采要再占一次 chip4 锁 + 模型加载 90 s，代价高得多）。
  UNRESOLVED_RATIO=$(python3 -c "print(1 if $UNK/max($TOT,1) > 0.5 else 0)" 2>/dev/null || echo 0)
  if [[ "${KEEP_PERF_DATA:-0}" == "1" || "$UNRESOLVED_RATIO" == "1" ]]; then
    say "保留 perf.data（KEEP_PERF_DATA=$KEEP_PERF_DATA，未解析比例高=$UNRESOLVED_RATIO）"
  else
    rm -f "$OUT_DIR/perf.data"
    say "已删除远端 perf.data（用 KEEP_PERF_DATA=1 可保留）"
  fi
fi

# ---- 6. 汇总 ----
python3 - "$OUT_DIR" "$RUN" "$SIDE" "$TAG" "$PORT" "$CHIP" "$INPUT_LEN" "$OUTPUT_LEN" \
        "$NUM_PROMPTS" "$MAX_CONC" "$WARMUP" "$CLIENT_CORES" "$WINDOW_START" "$WINDOW_END" \
        "$IMAGE" "$FE_PID" "${ENG_PID:-}" "$FREQ" "$CALLGRAPH" "$EVENT" \
        "$(sha256sum "${VLLM_BIN:-$HOME/projects/vllm/vllm-rs/bin/vllm-rs}" 2>/dev/null | cut -c1-16 || echo n/a)" <<'PY'
import glob, json, os, pathlib, sys, time

(out, run, side, tag, port, chip, isl, osl, n, c, warm, ccores, w0, w1,
 image, fe_pid, eng_pid, freq, cg, event, binsha) = sys.argv[1:]
out = pathlib.Path(out)

def jload(p):
    try:
        return json.load(open(p))
    except Exception:
        return None

allcpu = jload(out / "all_cpu.json") or {}
buckets = {"frontend": 0.0, "engine": 0.0, "other": 0.0}
detail = {}
for pid, v in (allcpu.get("pids") or {}).items():
    s = v.get("cpu_seconds") or 0
    comm = v.get("comm", "?")
    b = "frontend" if pid == fe_pid else ("engine" if comm.startswith(("VLLM::EngineCor", "VLLM::Worker")) else "other")
    buckets[b] += s
    detail[pid] = {"comm": comm, "cpu_seconds": s, "utime_seconds": v.get("utime_seconds"),
                   "stime_seconds": v.get("stime_seconds"), "bucket": b}

bench = None
for f in sorted(glob.glob(str(out / "bench" / "*.json"))):
    bench = jload(f)
    if bench:
        bench["_file"] = os.path.basename(f)
        break

doc = {
    "run": run, "side": side, "tag": tag,
    "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "image": image, "chip": chip, "port": port,
    "vllm_rs_bin_sha256_16": binsha,
    "load": {"input_len": int(isl), "output_len": int(osl), "num_prompts": int(n),
             "max_concurrency": int(c), "warmup": int(warm)},
    "window": {"start_epoch": float(w0), "end_epoch": float(w1),
               "seconds": round(float(w1) - float(w0), 3)},
    "cores": {"server_cpuset": "160-199", "client_cpuset": ccores},
    "pids": {"frontend": int(fe_pid), "engine": int(eng_pid) if eng_pid else None},
    "perf_record": ({"event": event, "freq_hz": int(freq), "call_graph": cg,
                     "target": "frontend 宿主 pid（容器内进程）",
                     "perf_data_kept": os.path.exists(out / "perf.data"),
                     "script_gz": (out / "perf-script.txt.gz").name
                     if (out / "perf-script.txt.gz").exists() else None}
                    if (out / "perf-script.txt.gz").exists() else None),
    "container_cpu_buckets": {k: round(v, 4) for k, v in buckets.items()},
    "container_cpu_detail": detail,
    "e2e": {k: bench.get(k) for k in (
        "completed", "failed", "duration", "request_throughput", "output_throughput",
        "total_input_tokens", "total_output_tokens", "mean_ttft_ms", "p99_ttft_ms",
        "mean_tpot_ms", "p99_tpot_ms", "mean_itl_ms", "mean_e2el_ms", "_file")} if bench else None,
    "loadavg": open("/proc/loadavg").read().split()[:3],
}
# 前端 CPU 单列（从 detail 里挑 bucket=frontend），与客户端/引擎分开
fe_s = sum(v["cpu_seconds"] for v in detail.values() if v["bucket"] == "frontend")
fe_ut = sum(v["utime_seconds"] or 0 for v in detail.values() if v["bucket"] == "frontend")
fe_st = sum(v["stime_seconds"] or 0 for v in detail.values() if v["bucket"] == "frontend")
doc["frontend_cpu"] = {"cpu_seconds": round(fe_s, 4), "utime_seconds": round(fe_ut, 4),
                       "stime_seconds": round(fe_st, 4)}
if bench and int(bench.get("completed") or 0) > 0:
    comp = bench["completed"]; itok = bench.get("total_input_tokens") or 0
    otok = bench.get("total_output_tokens") or 0
    doc["normalized"] = {
        "frontend_cpu_s_per_request": round(fe_s / comp, 6),
        "frontend_cpu_s_per_1k_input_tokens": round(fe_s / itok * 1000, 6) if itok else None,
        "frontend_cpu_s_per_1k_output_tokens": round(fe_s / otok * 1000, 6) if otok else None,
    }
    if bench.get("duration"):
        doc["normalized"]["frontend_cpu_over_window"] = round(fe_s / bench["duration"], 4)
        doc["normalized"]["engine_cpu_over_window"] = round(buckets["engine"] / bench["duration"], 4)

(out / "point.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
nz = doc.get("normalized") or {}
print(f"\n[prof] {side}/{tag}: 窗口 {doc['window']['seconds']}s "
      f"完成 {(bench or {}).get('completed')}")
print(f"[prof] 前端 CPU {doc['frontend_cpu']['cpu_seconds']}s "
      f"(utime {doc['frontend_cpu']['utime_seconds']}s / stime {doc['frontend_cpu']['stime_seconds']}s)；"
      f"引擎 CPU {buckets['engine']:.2f}s")
if nz:
    print(f"[prof] 前端 CPU/请求 {nz['frontend_cpu_s_per_request']}s；"
          f"前端/窗口 {nz.get('frontend_cpu_over_window')}")
if bench:
    print(f"[prof] 吞吐 {bench.get('request_throughput'):.3f} req/s, "
          f"TTFT {bench.get('mean_ttft_ms'):.1f} ms, TPOT {bench.get('mean_tpot_ms'):.2f} ms")
PY

say "结果 → $OUT_DIR/point.json"
