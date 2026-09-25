# `data/profiles/` 数据字典（B 线）

由 `harness/profile/run_matrix.sh` 一键生成。**原始 `*.perf.data` 不入 git**
（`.gitignore` 已屏蔽 `perf.data*`），其余都在版本控制里。

## 每个采集点（`<tag>`）的文件

| 文件 | 内容 | 关键字段 |
|---|---|---|
| `<tag>.folded` | **inferno 折叠栈**（唯一必须的原始派生数据） | 最后一列 = perf period 之和（**纳秒**，不是次数） |
| `<tag>.perf-manifest.json` | 采样 manifest | `perf.event/freq_hz/call_graph`、`perf_window`、`load_window`、`collapsed.samples/cpu_seconds`、折叠栈 sha256 |
| `<tag>.topn.csv` | 帧级 top-N（self + inclusive） | `frame,self_ns,self_pct,segment,basis` |
| `<tag>.segments.csv` | **帧 → P1–P10 分段占比** | `segment,self_ns,self_pct_of_all,self_pct_of_P1_P10,top_frames_in_segment` |
| `<tag>.threads.csv` | 线程归属（`vllm-request` / `vllm-zmq-0` / `tokio-rt-worker`） | `thread,cpu_ns,pct,samples` |
| `<tag>.depth.csv` | 栈深直方图（fp 展开质量的自证） | `stack_depth,cpu_ns,pct,samples` |
| `<tag>.load.json` | **压测窗口原始结果** | 窗口 epoch、成功/失败请求数、`throughput_req_s`、延迟分位、`client_cpu_seconds`（压测端自己的，不算服务端） |
| `<tag>.perf-stat.json` | 仅 B5 | `ipc`、`cycles`、`instructions`、`branch_miss_rate_pct`、`l1d_load_miss_rate_pct`、`raw_text` |

## 专门的对照数据

| 文件 | 用途 |
|---|---|
| `cmp-fp.folded` / `cmp-dwarf.folded` / `cmp-{fp,dwarf}.perf-manifest.json` | **采样方式对照**：同负载同窗口下 fp 与 dwarf 的展开质量、体积、耗时（`docs/02` §2.1） |
| `B*.libc-leaves.csv`, `B*.tls-sites.csv` | `sym_offset.py` 的产出：把 `[libc.so.6]`、58 个同名 `LocalKey` 落到**文件内偏移**（`docs/02` §5） |
| `B*.deps.json` | 依赖反查（证明 `pcre2` 的唯一使用者是 `fastokens`） |
| `B1x.load.json` | **采样开销对照**：同 B1 负载但完全不开 perf（`docs/02` §10） |

## 口径三条（引用任何数字前必读）

1. **进程归属**：只有 `vllm-rs` 前端进程的 CPU。引擎（mock）与压测客户端是另外两个进程，
   客户端自己的 CPU 记在 `load.json` 的 `client_cpu_seconds`。
2. **单位**：折叠栈的计数是**纳秒**（perf period 之和）。占比 = 时间占比；
   样本数 = Σ/1001001（`cpu-clock -F 999`）。
3. **栈浅**：`--call-graph fp` 下 59.81% 的样本只有「线程名 + 叶子帧」两帧
   （`<tag>.depth.csv`）。分段归属靠叶子符号 + 线程 + 差分斜率，不靠完整调用链。

## 与其它线的口径差异

| 对比对象 | 差异 |
|---|---|
| C 线 A/B（`vllm-bench` + Python 前端） | **客户端不同**（raw_load vs vllm-bench）、**装置相同但负载形态不同**；不能直接相减 |
| `PREPARE_INPUT_PROJECT`（topdown / IPC） | 那是 **engine core 主线程**在 **aarch64 Kunpeng 920B** 上采的，与本线的「x86 前端进程」跨进程、跨装置 ⇒ 只能比形状，不能相减 |
| `tokenizer` 项目（µs 级 scope） | 那是 **Python 侧 HF tokenizers** 的 scope 计时；Rust 侧是 fastokens + 自写 `DecodeStream`，两者不是同一实现 |
