# vllm-rs 前端 CPU 负载分析

> **状态：收口中（2026-09-25）。** 交付入口 → [`docs/00-INDEX.md`](docs/00-INDEX.md)
> （一分钟结论 + 导览 + 口径警告 + 复现入口 + 未测清单）。
> 计划入口：[`plan/EXECUTION.md`](plan/EXECUTION.md)｜执行协调：[`plan/COORDINATION.md`](plan/COORDINATION.md)
> ｜根代理进度：[`agents/root/REPORT.md`](agents/root/REPORT.md)

## 交付物

| 文件 | 内容 |
|---|---|
| [`docs/00-INDEX.md`](docs/00-INDEX.md) | 总览与一分钟结论 |
| [`docs/01-request-path.md`](docs/01-request-path.md) | P1–P10 逐段分解（行号级） |
| [`docs/01b-python-frontend-anchors.md`](docs/01b-python-frontend-anchors.md) | Python 前端侧锚点（进程拓扑、线程布局） |
| [`docs/02-cpu-profile.md`](docs/02-cpu-profile.md) | ★ 火焰图 + 硬件计数 |
| [`docs/03-hotspot-migration.md`](docs/03-hotspot-migration.md) | ★ 热点迁移（CPython 派发 → ?） |
| [`docs/04-ab-comparison.md`](docs/04-ab-comparison.md) | ★ 同机 A/B（只换前端） |
| [`docs/ab-design.md`](docs/ab-design.md) | A/B 的实验设计与公平性论证 |
| [`docs/05-segment-costs.md`](docs/05-segment-costs.md) | 逐段微基准 |
| [`docs/06-scale-and-tradeoffs.md`](docs/06-scale-and-tradeoffs.md) | 规模拐点与选型建议 |
| [`docs/SANITIZATION.md`](docs/SANITIZATION.md)、[`PUBLISH.md`](PUBLISH.md) | 发布前净化与发布记录 |

## 装置（2026-09-25 授权变更）

**主 profiling 与 A/B 在 REMOTE_HOST 的 chip4（`/dev/davinci4`）+ vLLM 0.26 镜像上做**
（用户指示，见 `plan/COORDINATION.md §2.1`）；本机 x86 降级为辅助
（早期侦察、微基准、静态分析）。

| | REMOTE_HOST chip4（主） | 本机 x86（辅助） |
|---|---|---|
| 引擎 | Ascend 910（真 NPU，TPOT **4.7–5.1 ms**/token） | 纯 CPU（TPOT **245 ms**/token） |
| 前端占服务端 CPU | Rust **1.22%** / Python **5.10%** | Rust 0.08%（被引擎压成噪声） |
| 用途 | 火焰图、`perf stat`/IPC、A/B 矩阵 | 微基准、静态分析、方法学预研 |

镜像 `quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler` 内含 vLLM 源码
commit `568afb3a`（与计划锁定值一致）；其 `vllm-rs` 由官方 aarch64 wheel 抽取。
实验入口见 [`harness/a3/README.md`](harness/a3/README.md)（含用卡纪律与踩坑）。

## P0 门禁

| 门禁 | 状态 | 证据 |
|---|---|---|
| G1 起栈 + 打通压测（x86 + mock engine） | ✅ | `data/gates/g1-smoke-bench-result.json` |
| G2 `perf` 能采到 Rust 帧 | ✅ | `data/gates/g2-perf-symbol-check.txt` |
| G3 真引擎可行 | ✅ | `data/gates/g3-cpu-wheel-commit.txt` + REMOTE_HOST chip4 实测 |

## 这是什么

对 **vLLM 0.26.0 自带的 Rust 前端 `vllm-rs`** 做 CPU 负载分析，视角与
`../PREPARE_INPUT_PROJECT`、`../tokenizer` 两个项目一致——看"这段代码在 CPU 上
干了什么、花了多少"，而不是看重构本身。

回答四个问题：

1. **热点迁移**：Rust 前端的热点是什么？相对 Python **API server 前端**
   形状怎么变？（预期是 memcpy/serde/alloc，但必须实测）
2. **逐段成本**：HTTP → JSON → 模板 → 分词 → 下发 → 回收 → 解析 → 回写，
   每段多少 µs、占多少？
3. **A/B 对照**：同模型同负载同核数下，两个前端的 CPU 时间/吞吐/延迟差多少？
4. **规模拐点**：什么 ISL / 并发下 Rust 前端开始明显划算？

## 为什么单独做

前两个项目把这条线铺到了门口，但合起来指向一个它们都答不了的问题：

| 项目 | 结论 |
|---|---|
| `PREPARE_INPUT_PROJECT` | **engine core** 的 `prepare_input` 热点 = **CPython 逐条派发**（`frontend_bound 66.01%`、`IPC 0.771`、同步调用仅 0.27%）⚠️ **这是 engine core 进程的数字，不是 Python 前端**，详见 `plan/EXECUTION.md §2.3` |
| `tokenizer` | tokenizer 只占 TTFT **<2%**（8k 以下）；chat 模板是**常数级** 50–70 µs；热点在哈希/查找与内存分配，**不在 BPE merge** |

⇒ engine core 侧的成本主要不在 tokenizer，而在整层解释器执行。
而 `vllm-rs` 恰好把**前端**整层换成了 Rust——"换个前端省多少"正是本计划的题目。

> ⚠️ **口径纠正**（详见 `plan/EXECUTION.md §2.3`）：`frontend_bound 66.01%` 采的是
> **engine core 进程**（`prepare_input` 阶段），**不是 API server 前端**；换 Rust 前端
> 不改变 engine core，该数字与本计划的前端收益无关。Python **前端**侧没有现成的
> topdown/IPC 数据，必须由本计划在**同一台机器上**实测（这就是 C 线的工作）。

## 计划文档

| 文件 | 内容 |
|---|---|
| [`plan/EXECUTION.md`](plan/EXECUTION.md) | 目标、核心问题、分析对象、方法、分线、交付物、时间盒 |
| [`plan/COORDINATION.md`](plan/COORDINATION.md) | 写入范围、统一身份、数据口径、git 约定、资源纪律 |
| [`plan/experiment-matrix.md`](plan/experiment-matrix.md) | P0 门禁 + 四条线的实验清单与验收判据 |

## 已侦察确认的可行性

| 项 | 状态 |
|---|---|
| 火焰图 | ✅ `vllm-rs` 二进制 **not stripped，161 911 符号** ⇒ 函数级火焰图可直接做 |
| 二进制获取 | ✅ 官方 PyPI wheel 自带（HTTP Range 只下 ~6%） |
| 无引擎也能测 | ✅ 上游自带 `vllm-mock-engine`（编译约 60 s），E2E 已验证 |
| 压测客户端 | ✅ `bench` crate（Rust 版 `vllm bench serve`，启动 ~7 ms） |
| 对照基线 | ⚠️ 只有 **engine core** 的 topdown/IPC（不可当前端基线，见上）；Python **前端**的 μs 级成本在 `tokenizer` 项目有，但跨装置 |
| 真引擎 | ✅ REMOTE_HOST chip4 + vLLM 0.26 镜像，**同一引擎只换前端**（`VLLM_USE_RUST_FRONTEND`） |

## 规模

| 项 | 数量 |
|---|---|
| Rust 工作区 | **13 个 crate / 约 99 000 行** |
| 逐段拆解覆盖 | **5 个 crate（约 72 k 行）**：`server` / `parser` / `chat` / `engine-core-client` / `text` |
| 引用已有结论 | `tokenizer` crate（3 065 行）**不重做** |
| 交付目标 | **6–8 篇文档 / 2 000–3 000 行 / 10–15 张图** |

## 资源纪律

两处共享资源，各有各的锁：

| 资源 | 锁 | 说明 |
|---|---|---|
| 本机 `LOCAL_HOST`（12 核 / 29 GiB） | `scripts/heavy_lock.sh` + `scripts/limit.sh` | 所有 CPU/内存密集操作（编译、微基准） |
| REMOTE_HOST **chip4**（NPU 卡） | `harness/a3/chip_lock.sh` | 远端互斥；B/C 两线串行用卡 |

> ⚠️ `limit.sh` 的 `CORES` 是**"绑到哪些核"而不是"几个核"**：
> `CORES=2` → 1 核；`CORES=4-5` → 2 核。

> ⚠️ REMOTE_HOST 上 **`npu-smi` 的 `-i` 是 NPU ID 不是 davinci 编号**：
> 我们的卡是 **`npu-smi -i 2`**（= `/dev/davinci4`）。详见 `harness/a3/README.md`。
