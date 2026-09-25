# B 线：perf 采集 / 折叠 / 出图工具链

> 归属：`agent/B-profile`（B 线）。共享常量与栈编排仍用 `harness/common/`（root 维护，只读复用）。
> 本文只讲「怎么采、怎么折、怎么判」，结论在 `docs/02-cpu-profile.md` 与 `docs/03-hotspot-migration.md`。

## 0. 一键复跑

```bash
# 0) 起栈（前端 + mock engine；前端绑 4-5、引擎绑 6-7）
harness/common/stack.sh start --run runs/b-matrix

# 1) 跑完整采集矩阵 B1/B1n/B2/B3/B4/B5（每点 30s 窗口）——整体走重活锁，不要再套一层
scripts/heavy_lock.sh scripts/limit.sh env CORES=1-3 \
  harness/profile/run_matrix.sh --run runs/b-matrix --out-dir data/profiles --duration 30

# 2) 出图
harness/profile/flamegraph.sh --folded data/profiles/B1.folded \
  --out figures/02-flame-B1.svg --title "B1 chat+tools ISL=1k OSL=128 c=1" \
  --subtitle "vllm-rs + mock engine | cpu-clock 999Hz fp | 30s" \
  --by-segment figures/02-flame-B1-by-segment.svg

# 3) 收工
harness/common/stack.sh stop --run runs/b-matrix
```

每个脚本都支持 `--help`。

## 1. 为什么不用 `vllm-bench` 打 B1 的负载

`vllm-bench`（Rust）是共享 harness 指定的压测客户端，但**它不支持在请求体里发 `tools`**
（`rust/src/bench/src/backends/openai_chat.rs:179` 构造的 payload 只有
`model/messages/max_tokens/...`；`--metadata` 只写进结果 JSON，不进请求体），
而 B1 的负载定义是「chat + tools」。

另外 `--dataset-name random` 每次都要现场生成 prompt（一次性前置开销），prompt 内容也随顺序变化。

所以 B 线自带一个最小 raw-payload 压测器 `raw_load.py`：

| 需求 | 做法 |
|---|---|
| 带 `tools` | 请求体里写真实 OpenAI function-calling 数组 |
| 逐字节固定 | 只构造一次 body，`--dump-body` 落盘 + sha256 写进结果 JSON |
| 采样窗口可控 | `--duration`（窗口）/`--warmup`（预热，不计入）/`--concurrency`/`--num-requests` |
| 绑核 | 调用方用 `taskset -c $CLIENT_CORES`（与前端分开） |
| 客户端 CPU 单独记 | `getrusage(RUSAGE_SELF)`，写进结果的 `client_cpu_seconds` |
| 口径写清 | 窗口起止 epoch、窗口内成功请求数、`completion_tokens` 来自响应 `usage` |

**口径差异必须写进文档**：B 线的吞吐/延迟是「raw_payload 客户端 + mock engine」的数字，
与 C 线用 `vllm-bench` 打的 A/B 数字**不同客户端**，不能直接互算。

## 2. 采样参数：为什么用 `fp` 而不是 `dwarf`

实测（2026-09-25，x86_64，同一负载、同一窗口长度）：

| 方式 | 样本 | 唯一折叠栈 | 栈深 | perf.data | `perf script` 后处理 |
|---|---:|---:|---|---:|---|
| `--call-graph fp` | 4140 | **731** | 2–128 | 310 KB | 秒级 |
| `--call-graph dwarf,16384` | 3991 | **15** | ≤2，且上层是垃圾地址（`1 [unknown]`） | **63 MB** | ≈2.5 min |

DWARF 展开在这份二进制上**完全失效**（`.debug_info` 不存在，`.eh_frame` 在但 perf 的 dwarf 走
不下第二帧），代价还高 200×。**B 线全部用 fp**，参数固定：

```
perf record -p <前端pid> -e cpu-clock -F 999 --call-graph fp
```

### 2.1 fp 栈浅：这是已知限制，不是可以忽略的细节

fp 展开出来的栈，**60% 只有「线程名 + 叶子帧」两帧**（详细直方图见 `docs/02` §2）。
含义与对策：

* 叶子帧 + **线程名**（`vllm-request` / `vllm-zmq-0` / `tokio-rt-worker`）是可靠的两级信息；
* 更上层只在 40% 的样本里有，且**不能**当作无偏样本解释；
* 因此分段归属不靠「一条完整调用链」，而靠
  ①叶子符号语义、②线程方向、③**B1/B1n/B2/B3 的差分斜率**（同一帧随 ISL / OSL 的变化）。

## 3. 折叠栈的计数单位是「纳秒」，不是「样本数」

`inferno-collapse-perf` 把每行的最后一列写成 **perf period**。
`-e cpu-clock -F 999` 下 period ≈ 1001001 ns（1.001 ms/sample），于是：

* Σ(最后一列) = **前端进程在该窗口内的 on-CPU 时间**（纳秒）；
* 样本数 = Σ / period（本工具链两个都报，`samples_reported_by_perf_record` 做交叉校验）。

这一点很容易误读成「样本数是 41 亿」——所以 `perf_record.sh` 把两者都写进 manifest。

## 4. 脚本清单

| 脚本 | 作用 | 关键参数 |
|---|---|---|
| `raw_load.py` | raw-payload 压测器（固定 body，支持 tools/stream） | `--input-len --output-len --concurrency --tools --stream --duration --dump-body` |
| `perf_record.sh` | 采一轮 `perf record` + `perf script` + 折叠栈 + manifest | `--tag --call-graph --freq --event -- <负载命令>` |
| `perf_stat.sh` | 采一轮 `perf stat`（IPC / cache / branch）+ JSON 汇总 | `--tag --events --duration -- <负载命令>` |
| `folded_stats.py` | 帧级 top-N、栈深直方图、线程归属、P1–P10 分段占比 | `--folded --outdir --top` |
| `segments.json` | **帧 → P1–P10 的映射规则**（可审计；每条带 basis 与 note） | — |
| `sym_offset.py` | 按 `(dso, 文件偏移)` 聚合叶子帧并解符号（把 `[libc.so.6]`、58 个同名 `LocalKey` 落到具体地址） | `--perf-data --dso-filter --symbol-filter --top` |
| `flamegraph.sh` | 折叠栈 → SVG；`--by-segment` 再出一张按分段着色的版本 | `--folded --out --title --by-segment` |
| `recolor_svg.py` | 按 `segments.json` 重着色 SVG 并插图例 | `--svg --in-place` |
| `run_matrix.sh` | 一键跑 B1/B1n/B2/B3/B4/B5 | `--run --out-dir --duration --only` |

## 5. 目录约定

```
data/profiles/
  B1.folded                 # 折叠栈（提交）
  B1.perf-manifest.json     # 采样参数 + 窗口 + sha256（提交）
  B1.topn.csv               # 帧级 top-N（提交）
  B1.segments.csv           # 分段占比（提交）
  B1.threads.csv            # 线程归属（提交）
  B1.depth.csv              # 栈深直方图（提交）
  B1.load.json              # 压测窗口原始结果（提交）
  B1.perf.data              # 原始采样，**不入 git**（.gitignore 屏蔽 perf.data*）
runs/<name>/perf/           # perf record 日志、perf script 文本（runs/ 不入 git）
```

## 6. 坑（都踩过）

1. **`perf stat -p PID -- sleep N` 收 SIGINT 不落报告** ⇒ 用 perf 自带 `--timeout <ms>`。
2. **重活锁不可重入**：`run_matrix.sh` 内部会调 `perf_record.sh`，所以**只在外层加一次**
   `heavy_lock.sh`；内层再加会自己等自己。
3. `taskset -c` 可以**收窄也可以改**掩码，所以外层 `limit.sh CORES=1-3` 不影响内层把压测端
   单独绑到 `CLIENT_CORES=8-9`。
4. `inferno-flamegraph` 的 `--title` **只能出现一次**（拼 `--by-segment` 时别重复传）。
5. `--nameattr` 改不动 `<rect>` 的颜色（`<rect>` 自带 `fill=` 优先于继承）⇒ 分段着色走
   `recolor_svg.py` 后处理 SVG。
6. `rg -rn 'pattern'` 里的 `-r` 是 `--replace`，会把匹配替换成 `n`；要递归+行号用 `rg -n`。
