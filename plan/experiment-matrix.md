# 实验矩阵

> 配套 `EXECUTION.md`。每条实验必须写 manifest（commit / 二进制 sha256 /
> 模型 revision / 脚本 sha256 / 时间戳 / 绑核 / 线程数 / loadavg）。

## 0. P0 门禁（先做，决定后面怎么走）

| ID | 门禁 | 判据 | 不通过时的退路 |
|---|---|---|---|
| G1 | 起 `vllm-rs` + `vllm-mock-engine`，打通 HTTP | `/health`、`/v1/models`、`/v1/chat/completions` 均 200，且能持续压 | 只做火焰图 + 微基准；A/B 标"未做" |
| G2 | 宿主机 `perf` 能采到 Rust 帧 | `perf report` 能解析出 `vllm_*::*` 符号（二进制 not stripped，理论可行） | 退化为 `perf stat` 计数 + 符号级 top-N（无火焰图） |
| G3 | REMOTE_HOST 上能起**真引擎**（或确认纯 CPU 容器方案） | 能完成一次真实推理并采到前端 perf | A/B 只用 mock engine（测不到真实推理负载，须显式标注） |

## 1. A 线：链路与静态分解

| ID | 内容 | 产出 |
|---|---|---|
| A1 | P1–P10 每段的**代码位置**（精确到文件:行号）+ 工作量语义 | `docs/01-request-path.md` |
| A2 | 与 Python 前端**逐段对照表**（Python 侧引用 `tokenizer`/`PREPARE_INPUT_PROJECT` 的现成结论） | 同上 |
| A3 | 调用图（ASCII/Mermaid），标出进程边界与 ZMQ/msgpack 位置 | 同上 |
| A4 | 与 `tokenizer` 项目的分段对齐：P4（分词）与 P8（增量解码）的已有数字直接引用，不重测 | 同上 |
| A5 | 每段的**预期成本量级**（先给假设，后续由 B/D 证实或证伪） | 同上 |

**验收**：十段齐全、行号经 `rg`/`sed` 逐条回读；推断处显式标注。

## 2. B 线：火焰图与硬件计数（Q1 主证据）

### 2.1 采集矩阵

固定：`vllm-rs` + mock engine（或 G3 的真引擎）；压测端与前端**分核**。

| ID | 负载 | 采样 | 想回答 |
|---|---|---|---|
| B1 | chat + tools，ISL=1k，OSL=128，c=1 | `perf record -g -F 999`，60 s | 稳态下的热点 top-N |
| B2 | chat，ISL=8k，OSL=16，c=1 | 同上 | 长 prompt（P2/P3/P4 段）是否主导 |
| B3 | chat，ISL=1k，OSL=512，c=1 | 同上 | 长输出（P8/P9/P10 段）是否主导 |
| B4 | chat，ISL=1k，OSL=128，c=64 | 同上 | 高并发下热点是否变化（是否转向调度/锁/内核） |
| B5 | 与 B1 同负载，但采 `perf stat` | `instructions,cycles,cache-misses` | **IPC 与 Python 前端正面对比**（Q1） |

### 2.2 产出

| 产出 | 说明 |
|---|---|
| 火焰图 SVG ×4（B1–B4） | `figures/02-flame-*.svg` |
| 折叠栈 + 帧级 top-N 表 | `data/profiles/`（只存折叠后与汇总，不存原始 perf.data） |
| `perf stat` 汇总 | `data/profiles/stat.csv`（IPC / cycles / instructions） |
| **按 P1–P10 分类的 self-time 占比** | 火焰图帧 → 分段的映射表（**这是与 Python 侧对齐的关键**） |

**验收**：热点 top-20 表 + 分段占比表 + 至少一张可读火焰图；IPC 有数。

## 3. C 线：A/B 对照（Q3/Q4 主证据）

固定：同一模型、同一压测客户端、同一绑核、同一负载点；**只变前端**。

| ID | 负载点 | 指标 | 想回答 |
|---|---|---|---|
| C1 | chat，ISL=1k / OSL=128 / c=1 | 吞吐、p50/p99 延迟、前端 CPU 时间 | 单流下差多少 |
| C2 | 同 C1，c=64 | 同上 | 并发下差多少（Q4） |
| C3 | chat，ISL=8k / OSL=16 / c=1 | 同上 | 长 prompt 下差多少 |
| C4 | chat，ISL=1k / OSL=512 / c=1 | 同上 | 长输出下差多少 |
| C5 | 核数扫描（2 / 4 / 8 核）在固定负载点 | 吞吐、CPU 利用率 | Rust 是否更好地利用多核 |

**必采**：① 端到端吞吐/延迟 ② 前端进程 CPU 时间（`/proc/<pid>/stat` 增量）
③ 压测客户端自身 CPU ④ `perf stat`（可选）⑤ manifest。

**硬要求**：

- **分子分母写清**：延迟是"端到端"还是"前端处理"；吞吐是"请求/秒"还是"token/秒"。
- **对照必须同核同绑**；核数一变，两边一起变。
- **压测客户端必须固定一侧**（建议统一用 Rust `vllm-bench`），并单独记录它的 CPU。
- 若 G3 未过，只能 mock engine，**必须在文档标题与结论里写明**。

## 4. D 线：逐段微基准

对火焰图上"分不开"或"需要独立验证"的段做定点微基准：

| ID | 段 | 基准内容 | 对照 |
|---|---|---|---|
| D1 | P2 JSON 反序列化 | `serde_json` 解析同尺寸请求体 | Python `json.loads` |
| D2 | P3 模板渲染 | minijinja 渲染同一 chat 模板（含 tools） | Python Jinja2（已有 50–70 µs 基线） |
| D3 | P6/P7 msgpack | `rmp-serde` 编解码 EngineCoreRequest 尺寸的结构体 | Python msgpack |
| D4 | P10 JSON 序列化 + SSE | 序列化同尺寸响应、分块写出 | Python `json.dumps` + asyncio 写 |
| D5 | P4/P8 分词与增量解码 | **不重测**，引用 `tokenizer` 项目结论 | — |

**验收**：每个基准有 `--help`、可一键复跑、结果进 `data/micro/`；与 Python 侧的对照
同输入同尺寸。

## 5. 负载与工具

| 用途 | 工具 | 注意 |
|---|---|---|
| 标准压测 | **`vllm-bench`（Rust）** | 启动 ~7 ms、内存低；**两侧都用它**，并记录它的 CPU |
| 协议级 E2E | `vllm-mock-engine` | 无模型也能跑完整路径；G1 用 |
| 真引擎 | REMOTE_HOST 上的容器（纯 CPU） | G3 用；**不需要 NPU** |
| 采样 | 宿主机 `perf` + `inferno` | 容器内没有 perf（tokenizer 项目已验证） |

## 6. 采集参数（两边必须一致）

| 项 | 值 |
|---|---|
| `perf record` | `-e cpu-clock -F 999 -g --call-graph dwarf,16384`（Rust 侧可试 `fp` 对比） |
| 采样窗口 | 60 s（预热后），记录起止时间戳 |
| 绑核 | 压测端与前端分开绑；两侧 A/B 用同一组核 |
| 容器限制 | `--cpus=6 --memory=8g --memory-swp=8g --shm-size=2g` |
| 预热 | 每点 ≥10 s 或 ≥200 请求，预热不计入 |

## 7. 未测清单模板（每条实验必须填）

产出文档末尾统一附一张"未测项"表，格式：

| 项 | 状态 | 原因 |
|---|---|---|
| … | 未测 / 部分 | … |

## 8. 与既有实验的对齐

| 已有实验 | 对齐方式 |
|---|---|
| `tokenizer` E2（Python 前端三 scope） | 作为 P3/P4/P8 的 Python 侧基线 |
| `tokenizer` E3（Python 前端火焰图） | 与本计划 B 线**同口径对比**（注意 Python 侧是宿主采样、帧为 C/Rust） |
| `PREPARE_INPUT_PROJECT` topdown/IPC | ⚠️ **是 engine core 宿主线程的数字，不是 API server 前端**（见 `EXECUTION.md §2.3`）；只能用于「engine core 侧，本计划不覆盖」的边界说明 |
| `tokenizer` D 线 E2E | 复用其 mock-engine 脚本与 `vllm-rs` 二进制 |
