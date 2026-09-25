#!/usr/bin/env bash
# 采一个进程的「每线程」CPU 时间增量（用来定位前端到底哪个线程在烧 CPU）。
#
# 用法:
#   threadcpu.sh snapshot --out /tmp/t.json <host_pid>
#   threadcpu.sh diff --before /tmp/t.json --after /tmp/t2.json [--out /tmp/d.json]
#   threadcpu.sh --help
#
# 为什么需要：`/proc/<pid>/stat` 只给进程合计。真引擎臂上前端 CPU 的
#   stime 占 2/3、且与窗口时长同向变化，需要分辨「哪个线程在等/轮询」。
# 口径：tid 级 utime+stime（ticks → 秒），threads 的 name 取自 /proc/<pid>/task/<tid>/comm。
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in -h|--help|"") usage; exit 0 ;; esac
CMD="$1"; shift
OUT=""; BEFORE=""; AFTER=""; PID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --before) BEFORE="$2"; shift 2 ;;
    --after) AFTER="$2"; shift 2 ;;
    *) PID="$1"; shift ;;
  esac
done

snapshot() {
  python3 - "$OUT" "$PID" <<'PY'
import json, os, pathlib, sys, time
out, pid = sys.argv[1], sys.argv[2]
tck = os.sysconf("SC_CLK_TCK")
taskdir = pathlib.Path(f"/proc/{pid}/task")
doc = {"taken_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "epoch": time.time(),
       "pid": pid, "ticks_per_sec": tck, "threads": {}}
for t in taskdir.iterdir():
    if not t.name.isdigit():
        continue
    try:
        raw = (t / "stat").read_text()
        rest = raw.rsplit(")", 1)[1].split()
        comm = raw.split("(", 1)[1].rsplit(")", 1)[0]
        doc["threads"][t.name] = {
            "comm": comm, "state": rest[0],
            "utime_ticks": int(rest[11]), "stime_ticks": int(rest[12]),
        }
    except (OSError, IndexError, ValueError):
        continue
if out:
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    pathlib.Path(out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    print(f"[threadcpu] snapshot -> {out}", file=sys.stderr)
else:
    print(json.dumps(doc, ensure_ascii=False, indent=1))
PY
}

diff() {
  python3 - "$BEFORE" "$AFTER" "$OUT" <<'PY'
import json, pathlib, sys
b, a, out = sys.argv[1], sys.argv[2], sys.argv[3]
B, A = json.load(open(b)), json.load(open(a))
tck = B["ticks_per_sec"]; wall = A["epoch"] - B["epoch"]
rows = []
for tid, bs in B["threads"].items():
    as_ = A["threads"].get(tid)
    if not as_:
        continue
    du = (as_["utime_ticks"] - bs["utime_ticks"]) / tck
    ds = (as_["stime_ticks"] - bs["stime_ticks"]) / tck
    rows.append({"tid": int(tid), "comm": bs["comm"], "state_end": as_["state"],
                 "utime_seconds": round(du, 4), "stime_seconds": round(ds, 4),
                 "cpu_seconds": round(du + ds, 4)})
rows.sort(key=lambda r: -r["cpu_seconds"])
doc = {"pid": B["pid"], "wall_seconds": round(wall, 3),
       "window": {"from": B["taken_at"], "to": A["taken_at"]},
       "cpu_seconds_total": round(sum(r["cpu_seconds"] for r in rows), 4),
       "threads": rows}
body = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
if out:
    pathlib.Path(out).write_text(body)
    print(f"[threadcpu] diff -> {out}", file=sys.stderr)
print(body)
PY
}

case "$CMD" in
  snapshot) [[ -n "$PID" ]] || { echo "snapshot 需要 pid" >&2; exit 2; }; snapshot ;;
  diff) [[ -n "$BEFORE" && -n "$AFTER" ]] || { echo "diff 需要 --before/--after" >&2; exit 2; }; diff ;;
  *) echo "未知子命令：$CMD" >&2; usage; exit 2 ;;
esac
