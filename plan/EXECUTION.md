# vllm-rs CPU 负载分析 —— 执行计划（v1，待评审）

> 起草：2026-09-25。分析对象 **vLLM 0.26.0 自带的 Rust 前端 `vllm-rs`**
> （commit `568afb3a13806beb53bb2e6bd518269357b237c0`）。
> 视角：**CPU 负载**——不看重构本身，看"这段代码在 CPU 上干了什么、花了多少、
> 热点相对 Python 前端怎么变了"。
> 本文是**待讨论的计划**，评审通过后再拆成 `plan/{COORDINATION,experiment-matrix}.md`
> 并开 worktree 铺开。

---

## 1. 为什么单独做这个

前两个项目已经把这条线铺到了门口：

| 项目 | 结论（与本计划相关） |
|---|---|
| `PREPARE_INPUT_PROJECT` | **engine core** 的 `prepare_input` 阶段热点是 **CPython 逐条派发**：`frontend_bound 66.01%`、`IPC 0.771`、top-10 火焰图极平，同步调用仅 0.27%。⚠️ **这是 engine core 进程的数字，不是 API server 前端**，见 §2.3 |
| `tokenizer` | tokenizer 只占 TTFT **<2%**（8k 以下）；chat 模板（Jinja）是**常数级** 50–70 µs；真正的热点在哈希/查找与内存分配，不在 BPE merge |

两条合起来指向同一个结论：**Python 前端的成本主要不在 tokenizer，而在"整层解释器执行"**。
而 `vllm-rs` 恰好**把整层换成了 Rust**。所以"换个前端省多少"这个问题，
前面两个项目都答不了——它正是本计划的题目。

---

## 2. 目标与核心问题

**一句话**：说清 `vllm-rs` 在 CPU 上**干了什么活、活花在哪、相对 Python 前端热点怎么迁移**。

### 2.1 要回答的四个问题

| # | 问题 | 为什么重要 |
|---|---|---|
| **Q1** | **热点迁移**：Rust 前端的热点是什么（实测）？相对 Python **API server 前端**（不是 engine core）形状怎么变？ | 决定"下一刀砍哪里"。预期是 memcpy/serde/alloc/上下文切换，但**必须实测** |
| **Q2** | **逐段成本**：HTTP 入口 → JSON → 模板 → 分词 → 下发 → 回收 → 解析 → 回写，每一段多少 µs？ | 相当于 `prepare_input` 的 26 子步分解；没有这个就只能看总数 |
| **Q3** | **A/B 对照**：同模型、同负载、同核数下，两个前端的 CPU 时间/吞吐/延迟差多少？ | 这是"值不值"的唯一硬答案 |
| **Q4** | **规模拐点**：在什么 ISL / 并发下 Rust 前端开始明显划算？ | 小负载下两边都便宜，拐点位置决定适用场景 |

### 2.2 一个必须写清的边界

**只分析前端进程，不下沉到 engine core。** 南北向边界（ZMQ + msgpack）**两侧都算**：
前端侧的序列化/反序列化是它的 CPU 成本；engine core 侧的调度/forward/sample
是另一个课题（`PREPARE_INPUT_PROJECT` 已覆盖一部分）。

```
┌─ vllm-rs 进程（本计划的分析对象）───────────────┐
│ HTTP(axum) → JSON → minijinja → tokenize       │
│   → lower/validate → ZMQ+msgpack 序列化 ────────┼──→ [engine core: Python]
│ HTTP 回写 ← JSON ← parser ← detokenize ← 反序列化 │
└─────────────────────────────────────────────────┘
```

### 2.3 ⚠️ 口径修正（2026-09-25，A 线核实后由根代理修订）

计划初稿把 `PREPARE_INPUT_PROJECT` 的 `frontend_bound 66.01%` / `IPC 0.771`
当作「Python **前端**热点」——**这是错的**。该采集的目标是 **engine-core 宿主线程**：
`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:243` 写明
「目标 = engine-core 宿主 TID 704908」，其分析对象是 engine core 内部的
`prepare_input` / attention metadata builder（`vllm_ascend/ops/gdn_attn_builder.py`）。

对照 `tokenizer` 项目的进程归属实测（`tokenizer/docs/02-cost-and-share.md:34-49`）：
`tokenizer:` 三 scope 在 **pid=1（API server 前端）**，`Step:Model` / `phase:*`
在 **pid=131（engine core）**——两者是**不同进程**。

**后果与对策**：

1. **换 Rust 前端根本不改变 engine core**，所以 66% 这个数字与本计划的
   前端收益**无关**；引用它时必须写明「engine core 侧，本计划不覆盖」。
2. **Python API server 前端侧没有现成的 topdown/IPC 数据**，必须由 C 线在
   **同一台机器上**实测两条前端的 `perf stat` 对照——这使 C 线从「A/B 的补充」
   升级为 **Q1 与 Q3 的共同主证据**。
3. `docs/03` 必须按**三层**组织：层 1 = 同装置同口径（x86 上 Rust vs Python
   前端 IPC，C 线提供）；层 2 = 跨装置只比趋势/占比（tokenizer 项目 µs 级
   scope 数字，逐条标装置）；层 3 = 明确划出界外（engine core 的 66%，
   写明与前端收益无关）。

---

## 3. 分析对象（已侦察确认）

### 3.1 十三个 crate 与代码量

| crate | 行数 | 在请求路径上的角色 | 本计划覆盖 |
|---|---:|---|---|
| `server` | 21 565 | axum HTTP、路由、middleware、状态机 | 🎯 入口与回写段 |
| `parser` | 17 323 | reasoning / tool 解析 | 🎯 响应段 |
| `chat` | 17 087 | minijinja 模板渲染、多模态、结构化输出 | 🎯 模板段 |
| `bench` | 15 314 | **独立**的压测客户端（含自己的 tokenizer 三级回退） | 🔧 工具（用它产生负载） |
| `engine-core-client` | 11 647 | ZMQ + msgpack、握手、调度 | 🎯 边界段 |
| `text` | 4 335 | 编排：render → encode → 下发 | 🎯 主干 |
| `cmd` | 3 529 | CLI；50 个未实现 + 7 个 Noop 参数 | 🟡 只取参数清单（已有） |
| `tokenizer` | 3 065 | 六后端 + `DecodeStream` | ⏭️ **已完成**（tokenizer 项目） |
| `llm` | 2 999 | token-in/token-out 门面 | 🟡 薄层 |
| `mock-engine` | 930 | 引擎协议模拟器 | 🔧 **工具**（E2E 用） |
| `metrics` | 887 | Prometheus 指标 | 🟡 观测点 |
| `managed-engine` | 660 | 拉起/监管 Python engine | 🟡 启动路径 |
| `metrics`/其他 | — | — | — |

**覆盖率目标**：🎯 五个 crate（约 72 k 行）做**逐段拆解**；
🟡 四个只看与请求路径相关的部分；⏭️ `tokenizer` 直接引用已有结论，不重做。

### 3.2 已确认的可行性（P0 级别的好消息）

| 项 | 状态 |
|---|---|
| **火焰图可行性** | ✅ `vllm-rs` 二进制 **not stripped，161 911 个符号** ⇒ 函数级火焰图可直接做 |
| **二进制获取** | ✅ 官方 PyPI wheel 自带（HTTP Range 只下 ~6%）；`harness/rust-frontend/` 的脚本可复用 |
| **无引擎也能测** | ✅ 上游自带 `vllm-mock-engine`（编译约 60 s），E2E 已验证 9 条断言 |
| **压测客户端** | ✅ `bench` crate 是 Rust 写的 `vllm bench serve` 替代品（启动 ~7 ms），**自己就是"用 Rust 换 Python"的样本** |
| **对照基线** | ✅ Python 前端的数据在 `tokenizer`/`PREPARE_INPUT_PROJECT` 里已有，可直接 A/B |

### 3.3 已知的观测点

- **Prometheus 指标**：`/metrics` 端点 + `metrics` crate（`api_server.rs`/`request.rs`/`scheduler.rs`）。
- **日志**：`tracing` 全链路，可用 `RUST_LOG` 调级。
- **无内建逐段计时**：与 Python 侧不同，Rust 侧**没有 LiteProfiler 等价物** ⇒
  逐段分解要靠 **perf 火焰图 + 外部计时**（见 §5）。

---

## 4. 计划的"阶段词汇表"（对应 prepare_input 的 26 子步）

先把请求路径切成可比对的分段，这是全计划的骨架：

| # | 段 | 代码位置（待逐条核实行号） | CPU 工作内容 |
|---|---|---|---|
| P1 | HTTP 接入 | `server/src/routes.rs`、axum/hyper | 建连、解析 header、middleware（鉴权）、body 缓冲 |
| P2 | JSON 反序列化 | `serde_json`（HTTP 层） | 请求体 → 结构体；**大 prompt 时是 memcpy 大户** |
| P3 | chat 模板渲染 | `chat/src/renderer/hf/template.rs`（minijinja） | 拼串、`json` 序列化 tools |
| P4 | 分词 | `vllm-tokenizer` | ⏭️ 已有结论（1.47 µs/token @x86） |
| P5 | lower / 校验 | `text/src/lower.rs` | 参数校验、prompt 组装、token id 校验 |
| P6 | 序列化下发 | `engine-core-client`（`rmp-serde`） | 结构体 → msgpack、ZMQ 发送 |
| — | ═══ 南北向边界 ═══ | — | 跨进程 |
| P7 | 响应反序列化 | `engine-core-client` | msgpack → 结构体 |
| P8 | 增量解码 | `tokenizer::DecodeStream` | ⏭️ 部分已有（1.39–1.59 µs/token） |
| P9 | parser | `parser/`（reasoning / tool） | 文本扫描、正则、状态机 |
| P10 | JSON 序列化 + 回写 | `serde_json`、axum | SSE 分块 / 整包、写 socket |

**产出要求**：每段给出 µs 量级 + 在总 CPU 时间里的占比 + 随 ISL/OSL/并发的变化趋势。

---

## 5. 方法：怎么测一段 Rust 进程的 CPU 负载

### 5.1 三层证据（沿用前两个项目的规格）

| 层 | 工具 | 得到什么 |
|---|---|---|
| **时间归属** | 外部计时（客户端侧）+ `/metrics` 端点 | 端到端、请求级延迟 |
| **函数热点** | `perf record -g` + `inferno`（火焰图）；`cargo flamegraph` | P1–P10 各段的自耗、调用链 |
| **硬件计数** | `perf stat`（instructions / cycles / cache / IPC） | **与 Python 前端的 topdown/IPC 正面对比**（Q1 的关键证据） |

**为什么不直接给 Rust 侧做插桩**：重新编译带 `tracing` span 的版本成本高、
且会改变热路径。先用不侵入的方式（perf + 外部计时）拿到 80% 的答案；
**只有当某一段在火焰图上分不开时**，才对那一段做定点插桩（`tokenizer` 项目的
`--features` 方式可复用）。

### 5.2 火焰图的两个已知坑（`tokenizer` 项目踩过，直接继承）

1. **容器里没有 perf**——采样在**宿主机**做，被采进程在同容器里跑同一代码路径。
2. **Rust 帧不需要 dwarf 解析**（二进制 not stripped），但**混入 Python 时要**
   ——A/B 对照时两边用同一套采样参数才可比。

### 5.3 负载怎么产生

| 用途 | 工具 | 备注 |
|---|---|---|
| 标准压测 | **`vllm-bench`（Rust）** 或 Python `vllm bench serve` | 用它两边都行——但**必须固定一侧**，否则测的是压测客户端不是被测服务 |
| 协议级 E2E | `vllm-mock-engine` | 无卡、无模型也能跑完整路径 |
| 真实模型 | REMOTE_HOST 上的容器（纯 CPU，tokenizer 路径不需要 NPU） | 需要真引擎时用 |

> ⚠️ **压测客户端自身是变量**。`bench` crate 是 Rust 写的，若被测量时单机跑，
> 会和被测服务抢 CPU。**对策**：压测端绑不同核 + 记录其 CPU 占用；
> 或压测端放另一台机（REMOTE_HOST_HIST ↔ REMOTE_HOST）。

---

## 6. 工作分解（四条线）

沿用前两个项目的协作方式：每线一个 worktree、独立提交、根代理合并。

| 线 | 名称 | 内容 | 依赖 |
|---|---|---|---|
| **A** | 链路与静态分解 | P1–P10 的调用图、每段代码位置与工作量语义；与 Python 前端逐段对照表 | 无 |
| **B** | 火焰图与硬件计数 | `vllm-rs` 进程的 perf 火焰图（多负载点）+ `perf stat`；**Q1 的主证据** | A 的分段 |
| **C** | A/B 对照 | 同负载下 Rust vs Python 前端的吞吐/延迟/CPU 时间；**Q3/Q4 的主证据** | 需要真引擎 |
| **D** | 逐段微基准与工具 | 对 P2/P3/P6/P10 做定点微基准（serde_json vs Python json、minijinja vs Jinja、msgpack 编解码）；整理压测与 mock-engine 工具链 | 无 |

**P0 门禁**（决定后面怎么走）：

| 门禁 | 判据 | 不通过时的退路 |
|---|---|---|
| G1 | 能在本机起 `vllm-rs` + `mock-engine`，用 `vllm-bench` 打通压测 | 退化为只做火焰图 + 微基准，A/B 标注"未做" |
| G2 | `perf` 能在宿主机采到 `vllm-rs` 的 Rust 帧（符号解析） | 退化为 `perf report` 的符号级 top-N（无火焰图） |
| G3 | REMOTE_HOST 上能起真引擎（或确认纯 CPU 容器可行） | A/B 只能用 mock engine（测不了真实推理负载） |

---

## 7. 交付物

规模目标：**6–8 篇文档 / 2000–3000 行 / 10–15 张图**（与 tokenizer 项目同量级）。

```
vllm-rs/
├── docs/00-INDEX.md                    一分钟结论 + 导览
├── docs/01-request-path.md             P1–P10 逐段逻辑 + 与 Python 前端的对照
├── docs/02-cpu-profile.md              ★ 火焰图 + 硬件计数：热点在哪、是什么
├── docs/03-hotspot-migration.md        ★ Python(CPython 派发) → Rust(?) 的迁移分析
├── docs/04-ab-comparison.md            ★ 同负载 A/B：吞吐/延迟/CPU
├── docs/05-segment-costs.md            逐段微基准（serde/minijinja/msgpack）
├── docs/06-scale-and-tradeoffs.md      规模拐点 + 选型建议
├── data/{profiles,ab,micro,static}/
├── figures/                            火焰图 + 曲线
├── harness/                            压测编排 + perf 采集（复用 tokenizer 项目的脚本）
├── scripts/                            limit.sh / heavy_lock.sh / docker_run.sh（沿用）
└── agents/<line>/REPORT.md
```

三篇带 ★ 的是核心：**02（热点是什么）、03（相对 Python 怎么变了）、04（值多少）**。

---

## 8. 实验矩阵

> ⚠️ **2026-09-25 授权变更**：主 profiling 与 A/B **改在 REMOTE_HOST 的 chip4（`/dev/davinci4`）上用
> vLLM 0.26 镜像做**（用户指示，见 `COORDINATION.md §2.1`）。下表的「前端」轴、
> ISL/OSL/并发轴不变；「装置」一栏的含义从「本机 x86 + mock engine」变为
> 「REMOTE_HOST chip4 + 真实引擎」。本机 x86 的早期结果降级为**辅助证据**
> （reconnaissance、微基准、静态分析）。

| 轴 | 取值 | 想回答 |
|---|---|---|
| **前端** | Rust（`vllm-rs`） / Python（现行） | Q3/Q4 的主轴 |
| **负载形态** | chat(带 tools) / completion / 长文 / 大并发 | 热点是否随负载形态改变 |
| **ISL** | 128 / 1k / 8k | 与 tokenizer 项目的曲线对齐；看 P2/P4 的斜率 |
| **OSL** | 16 / 128 / 512 | 看 P8/P9/P10（响应段）的摊销 |
| **并发** | 1 / 8 / 64 / 256 | Q4 的拐点；也看前端是否成为瓶颈 |
| **核数** | 2 / 4 / 8（受资源纪律约束） | 并行扩展性；Rust 是否比 Python 更好地用多核 |

**每个负载点必采**：① 端到端吞吐/延迟 ② 前端进程的 `perf stat`（instructions/cycles/IPC）
③ 火焰图（选取代表点） ④ 前端进程 CPU 时间（`/proc/<pid>/stat` 增量）

---

## 9. 明确不做（控制深度）

| 不做 | 原因 |
|---|---|
| 不上游 PR、不改 `vllm-rs` 代码 | 本计划是**观测与分析**，不是优化实现 |
| 不覆盖 `server` 的全部端点 | 只做请求路径上的那几条（completions/chat/tokenize） |
| 不做 LoRA / 多模态 / 分布式（DP/EP）/ gRPC 深挖 | 与"CPU 负载"主题无关；文档里记一句"存在但未评估" |
| 不重做 tokenizer 六后端 | 已完成，直接引用 `tokenizer` 项目的结论 |
| 不做 engine core 内部（调度/forward/sample） | 那是另一个课题 |
| 不做完整功能对等评估（50+7 参数） | 已做过，引用 `tokenizer/docs/04` |
| 不做长期稳定性 / 压测到崩溃 | 只做稳态采样 |

---

## 10. 资源纪律（沿用，硬性）

本机 `LOCAL_HOST` 是**共享开发机**（12 核 / 29 GiB），用户明确要求：
**不要长时间占用过多 CPU（>75%）与内存**。

| 项 | 上限 |
|---|---|
| CPU | ≤ 9 核；基准统一绑 **2–4 核** |
| 内存 | 单任务 ≤ 8 GiB；容器 `--cpus=6 --memory=8g` |
| 并行编译 | cargo `-j ≤ 4`（Rust + LTO 是内存大户） |
| 串行化 | **全局唯一重活锁**：同一时刻只跑一个 CPU 密集任务 |

**直接复用 `tokenizer` 项目的三个脚本**（已跑通、有踩坑注释）：

```bash
REPO_HOME/projects/vllm/tokenizer/scripts/limit.sh        # 绑核 + 内存上限
REPO_HOME/projects/vllm/tokenizer/scripts/heavy_lock.sh   # 全局重活锁
REPO_HOME/projects/vllm/tokenizer/scripts/docker_run.sh   # 无卡容器执行器
```

> ⚠️ `limit.sh` 的 `CORES` 是**"绑到哪些核"而不是"几个核"**：
> `CORES=2` → 1 核；`CORES=4-5` → 2 核。运行时会把实际核数打出来。

---

## 11. 验收判据

| 维度 | 判据 |
|---|---|
| 覆盖 | P1–P10 **十段都有数**；缺的必须写清原因，不许留空 |
| 热点 | 给出函数级 top-N + 与 Python 前端的**同口径**对照（x86 上两侧都能采的 IPC / instructions / cycles；`frontend_bound` 分解只在 Kunpeng 上有，须标注不可比） |
| A/B | 至少三个负载点（短/中/长 ISL 或低/高并发）的对照；**分子分母写清** |
| 拐点 | 给出"什么规模下 Rust 前端开始划算"的定量判据，或明确说"未找到拐点" |
| 诚实 | 未测的写"未测"；推断标"推断"；跨装置/跨口径的比较必须标注 |
| 可复现 | 每条实验能从 `harness/` 或 `scripts/` 一键复跑，带 manifest（commit/镜像/绑核/loadavg） |

---

## 12. 与既有工作的衔接

| 已有产物 | 本计划怎么用 |
|---|---|
| `tokenizer/docs/04` | 形态、50+7 参数、E2E、抽取脚本 **直接引用**，不重做 |
| `tokenizer/data/nextgen/` | `vllm-rs` 二进制、help 文本、E2E 证据 |
| `tokenizer/harness/rust-frontend/` | `fetch_vllm_rs.py` / `verify_vllm_rs.sh` / `e2e_mock_engine.sh` |
| `tokenizer/docs/02` | Python 前端的 tokenizer/模板成本，作为 P3/P4 的对照基线 |
| `PREPARE_INPUT_PROJECT` | Python 前端的 topdown/IPC 与热点指纹，作为 Q1 的对照基线 |
| `bench` crate | **它自己就是"Rust 换 Python"的样本**（启动 7 ms vs 数秒），可另记一条 |

---

## 13. 待评审的取舍

| # | 取舍 | 我的倾向 |
|---|---|---|
| 1 | **A/B 要不要上真引擎**（REMOTE_HOST，需要起容器） | **要**。mock engine 测不到真实推理负载下的前端行为，A/B 的说服力依赖它 |
| 2 | **逐段分解靠 perf 还是靠插桩** | **先 perf**；某段分不开时再定点插桩那一段 |
| 3 | **压测客户端用 Rust 的 `vllm-bench` 还是 Python 的** | **两边都用同一个**（推荐 Rust 的，启动快、占用低）；但压测端要绑不同核 |
| 4 | **要不要把 `bench` crate 当独立对象分析** | **作为副产物**：它的"7 ms 启动 vs 数秒"本身就是一条 Rust 换 Python 的证据 |
| 5 | 文档规模 | 6–8 篇；若时间紧，保 ★ 三篇 + 01 |

---

## 14. 时间盒与优先级

```
P0 门禁（G1/G2/G3）        ── 决定后面怎么走
   ↓
A 链路分解 ──┐
B 火焰图    ──┼─→ ★02 / ★03（热点是什么、怎么变的）
C A/B 对照  ──┘   ★04（值多少）
D 微基准         05 / 06（补充与建议）
   ↓
收口：00-INDEX / 净化 / 发布（复用 tokenizer 项目的 export_publish.sh）
```

**优先级**：★04（A/B）> ★02/★03（热点）> 01（链路）> 05/06。
若时间紧，宁可把 A/B 做扎实（三个负载点），也不要为了覆盖十段而留下未校验的数。
