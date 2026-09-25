#!/usr/bin/env bash
# 采一轮 perf record（挂在前端进程上）+ 折叠成 inferno 折叠栈。
#
# 用法:
#   perf_record.sh --run runs/b1 --tag B1 --out-dir data/profiles \
#       [--call-graph fp|dwarf,16384] [--freq 999] [--event cpu-clock] \
#       -- <压测命令...>
#   perf_record.sh --help
#
# 口径（plan/experiment-matrix.md §2、§6）：
#   * 采样对象 = **前端进程**（runs/<name>/frontend.pid），不是引擎、不是客户端；
#   * 采样参数（event / 频率 / call-graph / 窗口长度）全部写进 manifest；
#   * 原始 perf.data **留在 out-dir 但不进 git**（.gitignore 已屏蔽 perf.data*）；
#   * 折叠栈（.folded）与汇总（.json/.csv）才提交。
#
# ⚠️ 本脚本会跑 perf record + 一个完整负载，属重活：调用方必须自己套
#    `scripts/heavy_lock.sh scripts/limit.sh <perf_record.sh ...>`。
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)"
# shellcheck source=../common/env.sh
source "$COMMON_DIR/env.sh"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; TAG="run"; OUT_DIR="data/profiles"; CALLGRAPH="fp"; FREQ=999
EVENT="cpu-clock"; ATTACH_SLEEP=1.0; KEEP_PERF_DATA=1
LOAD_CMD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --run) RUN_DIR="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --call-graph) CALLGRAPH="$2"; shift 2 ;;
    --freq) FREQ="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --attach-sleep) ATTACH_SLEEP="$2"; shift 2 ;;
    --prune-raw) KEEP_PERF_DATA=0; shift ;;
    --) shift; LOAD_CMD=("$@"); break ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$RUN_DIR" ]] || { echo "缺少 --run" >&2; exit 2; }
[[ ${#LOAD_CMD[@]} -gt 0 ]] || { echo "缺少负载命令（-- 之后）" >&2; exit 2; }
[[ -f "$RUN_DIR/frontend.pid" ]] || { echo "$RUN_DIR 下没有 frontend.pid，先 stack.sh start" >&2; exit 2; }

FE_PID="$(cat "$RUN_DIR/frontend.pid")"
kill -0 "$FE_PID" 2>/dev/null || { echo "前端 pid=$FE_PID 不在跑" >&2; exit 2; }
mkdir -p "$OUT_DIR" "$RUN_DIR/perf"
PERF_DATA="$OUT_DIR/$TAG.perf.data"
FOLDED="$OUT_DIR/$TAG.folded"
SCRIPT_TXT="$RUN_DIR/perf/$TAG.perf-script.txt"

CG_FLAG=()
if [[ "$CALLGRAPH" == "fp" ]]; then
  CG_FLAG=(--call-graph fp)
else
  CG_FLAG=(--call-graph "$CALLGRAPH")
fi

say "perf record：pid=$FE_PID event=$EVENT freq=$FREQ call-graph=$CALLGRAPH → $PERF_DATA"
T_START=$(date +%s.%N)
perf record -p "$FE_PID" -e "$EVENT" -F "$FREQ" "${CG_FLAG[@]}" -o "$PERF_DATA" -- \
  sleep 86400 > "$RUN_DIR/perf/$TAG.perf-record.log" 2>&1 &
PERF_PID=$!
sleep "$ATTACH_SLEEP"

# 负载（前台跑，前后各记一次时间戳）
say "开始负载：${LOAD_CMD[*]}"
LOAD_T0=$(date +%s.%N)
set +e
"${LOAD_CMD[@]}"
LOAD_RC=$?
set -e
LOAD_T1=$(date +%s.%N)
say "负载结束 rc=$LOAD_RC"

# 收 perf：SIGINT 让 perf 落盘
kill -INT "$PERF_PID" 2>/dev/null || true
for _ in $(seq 1 60); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 0.5; done
kill -0 "$PERF_PID" 2>/dev/null && { kill -TERM "$PERF_PID" 2>/dev/null || true; sleep 1; }
T_STOP=$(date +%s.%N)
wait "$PERF_PID" 2>/dev/null || true

[[ -s "$PERF_DATA" ]] || { echo "perf.data 为空，见 $RUN_DIR/perf/$TAG.perf-record.log" >&2; tail -20 "$RUN_DIR/perf/$TAG.perf-record.log" >&2; exit 1; }

say "perf script → 折叠栈"
perf script -i "$PERF_DATA" > "$SCRIPT_TXT" 2> "$RUN_DIR/perf/$TAG.perf-script.err" || true
"$HOME/.cargo/bin/inferno-collapse-perf" --all -q "$SCRIPT_TXT" > "$FOLDED"

# ⚠️ 折叠栈的最后一列是 **perf period（纳秒）**，不是样本数：`perf record -e cpu-clock -F 999`
#    的 period ≈ 1001001 ns（1.001 ms）。所以：
#      cpu_ns        = Σ 最后一列        —— 直接等于"前端进程的 on-CPU 纳秒数"
#      SAMPLES       = cpu_ns / period   —— 与 perf record 自己报的样本数对照
#    两者都写进 manifest，百分比两者等价（period 恒定）。
CPU_NS=$(awk '{s+=$NF} END{printf "%d", s+0}' "$FOLDED")
SAMPLES_FROM_PERF=$(sed -n 's/.*(\([0-9]*\) samples).*/\1/p' "$RUN_DIR/perf/$TAG.perf-record.log" | tail -1)
# ⚠️ 不要用「折叠栈第一行的最后一列」当 period——那是**该栈自身的时间总和**，不是 period。
#    正确的做法是反解：period = CPU_NS / perf record 自报的样本数。
if [[ -n "${SAMPLES_FROM_PERF:-}" && "${SAMPLES_FROM_PERF:-0}" -gt 0 ]]; then
  SAMPLES="$SAMPLES_FROM_PERF"
  PERIOD_NS=$(python3 -c "print(round($CPU_NS/$SAMPLES))")
else
  PERIOD_NS=1001001
  SAMPLES=$(( CPU_NS / PERIOD_NS ))
fi
STACKS=$(wc -l < "$FOLDED")
export TAG PERF_DATA FOLDED SCRIPT_TXT RUN_DIR OUT_DIR CALLGRAPH FREQ EVENT SAMPLES STACKS
export CPU_NS PERIOD_NS SAMPLES_FROM_PERF="${SAMPLES_FROM_PERF:-}"
export T_START T_STOP LOAD_T0 LOAD_T1 FE_PID LOAD_RC
export LOAD_CMD_STR="${LOAD_CMD[*]}"
export PERF_RAW_KEPT="$KEEP_PERF_DATA"

python3 - "$OUT_DIR/$TAG.perf-manifest.json" <<'PY'
import hashlib, json, os, pathlib, socket, time
def sha(p, limit=None):
    if not pathlib.Path(p).exists(): return None
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
env = os.environ
doc = {
  "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
  "host": socket.gethostname(), "machine": os.uname().machine,
  "loadavg_at_end": open("/proc/loadavg").read().split()[:3],
  "tag": env["TAG"],
  "target": {"kind": "vllm-rs frontend process", "pid": int(env["FE_PID"])},
  "perf": {
    "record_cmd_template": "perf record -p <FE_PID> -e {event} -F {freq} --call-graph {cg}",
    "event": env["EVENT"], "freq_hz": int(env["FREQ"]), "call_graph": env["CALLGRAPH"],
    "attach_sleep_s": 1.0,
    "perf_window": {"start_epoch": float(env["T_START"]), "stop_epoch": float(env["T_STOP"]),
                    "duration_s": round(float(env["T_STOP"]) - float(env["T_START"]), 3)},
    "load_window": {"start_epoch": float(env["LOAD_T0"]), "stop_epoch": float(env["LOAD_T1"]),
                    "duration_s": round(float(env["LOAD_T1"]) - float(env["LOAD_T0"]), 3)},
    "load_rc": int(env["LOAD_RC"]),
  },
  "load_cmd": env["LOAD_CMD_STR"],
  "collapsed": {"stacks": int(env["STACKS"]), "samples": int(float(env["SAMPLES"])),
                "period_ns": int(env["PERIOD_NS"]),
                "cpu_ns": int(env["CPU_NS"]),
                "cpu_seconds": round(int(env["CPU_NS"]) / 1e9, 4),
                "samples_reported_by_perf_record": int(env["SAMPLES_FROM_PERF"]) if env["SAMPLES_FROM_PERF"] else None,
                "path": env["FOLDED"], "sha256": sha(env["FOLDED"])},
  "artifacts": {
    "perf_data": {"path": env["PERF_DATA"], "size": pathlib.Path(env["PERF_DATA"]).stat().st_size,
                  "in_git": False},
    "perf_script_txt": {"path": env["SCRIPT_TXT"], "size": pathlib.Path(env["SCRIPT_TXT"]).stat().st_size},
  },
}
pathlib.Path(os.environ["OUT_DIR"]).mkdir(parents=True, exist_ok=True)
pathlib.Path(os.environ["OUT_DIR"] + "/" + env["TAG"] + ".perf-manifest.json").write_text(
    json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
print(f"[perf_record] manifest -> {os.environ['OUT_DIR']}/{env['TAG']}.perf-manifest.json")
PY

say "CPU ${CPU_NS}ns ≈ $SAMPLES 样本（perf record 自报 ${SAMPLES_FROM_PERF:-?}）/ 栈 $STACKS → $FOLDED"
if [[ "$KEEP_PERF_DATA" == "0" ]]; then rm -f "$PERF_DATA"; say "已删除原始 perf.data（--prune-raw）"; fi
exit 0
