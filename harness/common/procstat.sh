#!/usr/bin/env bash
# /proc/<pid>/stat 采样：拿前端进程的 CPU 时间增量（plan/EXPERIMENT **必采项 ④**）。
#
# 用法:
#   procstat.sh snapshot --out snap.json <pid> [pid...]
#   procstat.sh diff --before snap.json --after snap2.json [--out delta.json]
#   procstat.sh --help
#
# 口径说明：cpu_seconds = utime + stime（**不含**子进程 cutime/cstime；
# 若要连子进程一起算，用 --include-children）。ticks 按 sysconf(_SC_CLK_TCK) 换算。
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
esac

CMD="$1"; shift
OUT=""; BEFORE=""; AFTER=""
PIDS=(); INCLUDE_CHILDREN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --before) BEFORE="$2"; shift 2 ;;
    --after) AFTER="$2"; shift 2 ;;
    --include-children) INCLUDE_CHILDREN=1; shift ;;
    *) PIDS+=("$1"); shift ;;
  esac
done

case "$CMD" in
  snapshot)
    [[ ${#PIDS[@]} -gt 0 ]] || { echo "snapshot 需要至少一个 pid" >&2; exit 2; }
    python3 - "$OUT" "$INCLUDE_CHILDREN" "${PIDS[@]}" <<'PY'
import json, os, sys, time
out, inc, *pids = sys.argv[1:]
inc = inc == "1"
tck = os.sysconf("SC_CLK_TCK")

def read_stat(pid):
    try:
        raw = open(f"/proc/{pid}/stat").read()
    except OSError:
        return None
    # comm 字段可能含空格/括号，按最后一个 ')' 切
    head, rest = raw.rsplit(")", 1)
    comm = head.split("(", 1)[1]
    f = rest.split()
    # f[0] 是 state（原字段 3），utime 是字段 14 -> f[11]
    utime, stime, cutime, cstime = (int(f[11]), int(f[12]), int(f[13]), int(f[14]))
    rss_pages = int(f[21])
    threads = int(f[17])
    return {
        "comm": comm, "state": f[0],
        "utime_ticks": utime, "stime_ticks": stime,
        "cutime_ticks": cutime, "cstime_ticks": cstime,
        "self_cpu_ticks": utime + stime,
        "with_children_cpu_ticks": utime + stime + cutime + cstime,
        "rss_kb": rss_pages * (os.sysconf("SC_PAGE_SIZE") // 1024),
        "threads": threads,
        "ticks_per_sec": tck,
    }

doc = {"taken_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "epoch": time.time(),
       "wall": time.time(), "pids": {}}
for p in pids:
    s = read_stat(p)
    doc["pids"][p] = s if s else {"missing": True}
res = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
if out:
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    open(out, "w").write(res)
    print(f"[procstat] snapshot -> {out}", file=sys.stderr)
else:
    sys.stdout.write(res)
PY
    ;;
  diff)
    [[ -n "$BEFORE" && -n "$AFTER" ]] || { echo "diff 需要 --before 与 --after" >&2; exit 2; }
    python3 - "$BEFORE" "$AFTER" "$OUT" "$INCLUDE_CHILDREN" <<'PY'
import json, sys
b, a, out, inc = sys.argv[1:5]
inc = inc == "1"
B, A = json.load(open(b)), json.load(open(a))
wall = A["epoch"] - B["epoch"]
res = {"wall_seconds": round(wall, 3),
       "window": {"from": B["taken_at"], "to": A["taken_at"]}, "pids": {}}
key = "with_children_cpu_ticks" if inc else "self_cpu_ticks"
for pid, bs in B["pids"].items():
    as_ = A["pids"].get(pid, {})
    if bs.get("missing") or as_.get("missing"):
        res["pids"][pid] = {"missing": True}
        continue
    tck = bs["ticks_per_sec"]
    dticks = as_[key] - bs[key]
    secs = dticks / tck
    res["pids"][pid] = {
        "comm": bs["comm"],
        "cpu_seconds": round(secs, 4),
        "cpu_percent_of_one_core": round(secs / wall * 100, 2) if wall > 0 else None,
        "threads_max": max(bs["threads"], as_["threads"]),
        "threads_end": as_["threads"],
        "rss_kb_end": as_["rss_kb"],
        "utime_seconds": round((as_["utime_ticks"] - bs["utime_ticks"]) / tck, 4),
        "stime_seconds": round((as_["stime_ticks"] - bs["stime_ticks"]) / tck, 4),
    }
t = round(sum(v.get("cpu_seconds", 0) for v in res["pids"].values()), 4)
res["cpu_seconds_total"] = t
body = json.dumps(res, ensure_ascii=False, indent=1) + "\n"
if out:
    open(out, "w").write(body)
    print(f"[procstat] diff -> {out}", file=sys.stderr)
sys.stdout.write(body)
PY
    ;;
  *) echo "未知子命令：$CMD" >&2; usage; exit 2 ;;
esac
