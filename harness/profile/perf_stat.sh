#!/usr/bin/env bash
# 采一轮 perf stat（挂在前端进程上），输出 instructions/cycles/cache/IPC 汇总。
#
# 用法:
#   perf_stat.sh --run runs/b5 --tag B5 --out-dir data/profiles \
#       [--events cycles:u,instructions:u,...] -- <压测命令...>
#   perf_stat.sh --help
#
# 口径：
#   * 采样对象 = 前端进程（runs/<name>/frontend.pid）；
#   * 只采**用户态**（`:u`），因为 `perf_event_paranoid=2` 不允许内核态；
#   * IPC = instructions / cycles —— 这是**比值**，与窗口长度无关，
#     所以负载前后的空闲时间不会污染 IPC（空闲进程不计周期）；
#   * 绝对计数（cycles/instructions）会被窗口内非负载时间稀释，
#     引用时必须与 load 窗口一起看（本脚本把两者都写进 JSON）。
#
# ⚠️ 重活：调用方自己套 `scripts/heavy_lock.sh scripts/limit.sh`。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)"
# shellcheck source=../common/env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; TAG="stat"; OUT_DIR="data/profiles"; STAT_DURATION="${STAT_DURATION:-30}"
EVENTS="cycles:u,instructions:u,branches:u,branch-misses:u,L1-dcache-loads:u,L1-dcache-load-misses:u,cache-references:u,cache-misses:u"
LOAD_CMD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --events) EVENTS="$2"; shift 2 ;;
    --duration) STAT_DURATION="$2"; shift 2 ;;
    --) shift; LOAD_CMD=("$@"); break ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" && ${#LOAD_CMD[@]} -gt 0 ]] || { usage; exit 2; }
FE_PID="$(cat "$RUN_DIR/frontend.pid")"
kill -0 "$FE_PID" 2>/dev/null || { echo "前端 pid=$FE_PID 不在跑" >&2; exit 2; }
mkdir -p "$OUT_DIR" "$RUN_DIR/perf"
RAW="$RUN_DIR/perf/$TAG.perf-stat.txt"

say "perf stat：pid=$FE_PID events=$EVENTS"
# 用 perf 自带的 --timeout 收口（SIGINT 到 `perf stat -- sleep` 不落报告，踩过）。
# 超时留 4 s 余量覆盖「prompt 合成 + 预热」——前端在这段时间是空闲的，
# 空闲进程不计周期/指令，所以 IPC 这个比值不受影响；绝对计数也不受影响。
TIMEOUT_MS=$(( (STAT_DURATION + 4) * 1000 ))
perf stat -p "$FE_PID" -e "$EVENTS" --timeout "$TIMEOUT_MS" > "$RAW" 2>&1 &
PERF_PID=$!
sleep 1
LOAD_T0=$(date +%s.%N)
"${LOAD_CMD[@]}"
LOAD_RC=$?
LOAD_T1=$(date +%s.%N)
for _ in $(seq 1 60); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 0.5; done
kill -0 "$PERF_PID" 2>/dev/null && { kill -INT "$PERF_PID" 2>/dev/null || true; sleep 1; }
wait "$PERF_PID" 2>/dev/null || true
say "perf stat 原始输出 → $RAW"

EVENTS="$EVENTS" python3 - "$RAW" "$OUT_DIR/$TAG.perf-stat.json" "$TAG" "${LOAD_CMD[*]}" "$LOAD_T0" "$LOAD_T1" "$LOAD_RC" <<'PY'
import json, re, sys, os, time, pathlib, socket
raw, out, tag, cmd, t0, t1, rc = sys.argv[1:8]
text = open(raw).read()
val = {}
not_counted = []
for line in text.splitlines():
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    if s.startswith("Performance counter stats"):
        continue
    toks = s.split()
    if len(toks) >= 3 and toks[1] == "seconds" and toks[2] == "time":
        try:
            val.setdefault("time", {})["elapsed"] = float(toks[0])
        except ValueError:
            pass
        continue
    if toks[0].startswith("<"):
        not_counted.append(toks[-1])
        continue
    if len(toks) < 2:
        continue
    ev = toks[1]
    try:
        val[ev] = {"count_int": int(toks[0].replace(",", ""))}
    except ValueError:
        try:
            val[ev] = {"value_float": float(toks[0])}
        except ValueError:
            continue
doc = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "host": socket.gethostname(), "machine": os.uname().machine,
    "tag": tag, "load_cmd": cmd,
    "load_window": {"start_epoch": float(t0), "stop_epoch": float(t1),
                    "duration_s": round(float(t1) - float(t0), 3)},
    "load_rc": int(rc),
    "events_requested": os.environ.get("EVENTS", ""),
    "raw_path": raw, "raw_text": text,
    "counters": val,
    "not_counted_events": not_counted,
}
cyc = val.get("cycles:u", val.get("cycles", {})).get("count_int")
ins = val.get("instructions:u", val.get("instructions", {})).get("count_int")
if cyc and ins:
    doc["ipc"] = round(ins / cyc, 4)
    doc["ipc_basis"] = "instructions/cycles（用户态，perf_event_paranoid=2）"
if cyc:
    doc["cycles_per_second_of_window"] = round(cyc / (float(t1) - float(t0)), 1)
for ev, label in (("branches:u", "branches"), ("branch-misses:u", "branch_misses"),
                  ("cache-references:u", "cache_references"), ("cache-misses:u", "cache_misses"),
                  ("L1-dcache-loads:u", "l1_dcache_loads"),
                  ("L1-dcache-load-misses:u", "l1_dcache_load_misses")):
    if ev in val:
        doc[label] = val[ev]["count_int"]
if doc.get("branches"):
    doc["branch_miss_rate_pct"] = round(doc.get("branch_misses", 0) / doc["branches"] * 100, 4)
if doc.get("l1_dcache_loads"):
    doc["l1d_load_miss_rate_pct"] = round(
        doc.get("l1_dcache_load_misses", 0) / doc["l1_dcache_loads"] * 100, 4)
if doc.get("cache_references"):
    doc["cache_miss_rate_pct"] = round(doc.get("cache_misses", 0) / doc["cache_references"] * 100, 4)
pathlib.Path(out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
print(f"[perf_stat] IPC={doc.get('ipc')} cycles={cyc} instructions={ins} "
      f"branch_miss={doc.get('branch_miss_rate_pct')}% cache_miss={doc.get('cache_miss_rate_pct')}% -> {out}")
PY
exit 0
