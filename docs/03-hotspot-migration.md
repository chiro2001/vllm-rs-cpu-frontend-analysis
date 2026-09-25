# 03 · 热点迁移：从「Python 前端」到「Rust 前端」到底变了什么

> **线 B（B-profile）交付物**。本文回答 `plan/EXECUTION.md` 的 Q1：
> 「Python 前端是 CPython 逐条派发，Rust 前端是什么？」
>
> ⚠️ **口径纠错（本报告的处理方式）**：计划里写的
> 「Python 前端热点 = CPython 逐条派发（`frontend_bound 66.01%` / IPC 0.771）」
> **是错的**——那个 66.01% 的采集目标是 **engine core 进程的主线程**，
> 不是 API server 前端进程（证据：`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:243`
> 写明"目标 = engine-core 宿主 TID 704908"）。
> 换 Rust 前端**根本不改变 engine core**，所以那个数字与"换前端能省多少"无关。
> 本文据此**分三层**组织，每层只用该层允许的对比（§1–§3）。
>
> 本线测的是 Rust 侧（全部在 `docs/02-cpu-profile.md`，数字不在这里重复推导）；
> 需要 Python 侧同口径数据的地方**明确留给 C 线**，不代填。

---

## 0. 一分钟结论

1. **Q1 的正确答案（两侧都已在 REMOTE_HOST chip4 上实测）**：
   (a) **Rust 前端的热点 = 内核态 + tokio 分派 + 拷贝/分配**，不是 serde、也不是某个算法
   （REMOTE_HOST 实测：内核帧 30.03%、tokio 分发 21.92%、TLS/`Vec`增长 8.63%、分配 4.90%、
   拷贝 2.97%；x86 mock 下则是拷贝 15.20% + 分配 14.18%——见 §1.3 的 tick 粒度说明）；
   (b) **Python 前端的热点 = CPython 逐条派发 + 对象内务**：
   `_PyEval_EvalFrameDefault` **18.31%** 领跑，该类合计 **47.25%**（§1.3）。
2. **「热点迁移」的实质不是"换个更快的实现"，而是"把逐算子解释执行换成批量内存操作"**。
   Python 前端花在"每条语句要过一遍解释器"上的时间，在 Rust 前端变成了
   **一次 memcpy 搬一批、一次 malloc 拿一块**——总量小得多，但**形状也从
   "均匀摊在几千个 Python 帧上"变成"集中在少数几个内存原语上"**。
3. **分词链路是这次迁移里"结构性变了"的一段**：Python 侧 tokenizer 只占 TTFT 的
   0.3–1.2%（1k）/ 5.3–10.4%（8k）；Rust 侧仍然是最贵的一段之一（P4 = **6.57%**，
   且在 ISL=8k 时升到 **41.71%**），**但它的内部构成被换了**——
   Rust 侧 P4 的成本 **71–89% 花在预分词正则（PCRE2 JIT）上**，而不是 BPE merge。
   （D6 微基准 `data/micro/d6_pretokenize.json` 独立证实这一点。）
4. **响应侧（P8/P9/P10）在两种前端里都是"按 token 计费"，Rust 侧单价约
   133–103 ns/token 量级，而主导它的是拷贝与分配，不是解析状态机**
   （P9 parser 只占 2.79%，而 X-copy 15.20%）。
5. **一句可以直接引用的话**：
   > Rust 前端把 Python 的"解释器派发"换成了"`memcpy` + `malloc` + 任务调度"；
   > 换完之后，**前端 67.35% 的 on-CPU 时间是跨段的内存/调度开销**，
   > 只剩 32.65% 落在业务语义段（P1–P10）上。
   > 「Rust 应该更快」不是结论，**"Rust 快在去掉了派发，慢在多了搬运"才是**。

   ⇒ 直接的量化后果：**每多生成一个 token，前端多花 4.22 µs，
   其中 2.30 µs（55%）是拷贝+分配+调度，只有 0.89 µs（21%）是业务语义段。**

---

## 1. 层 1：同装置、同口径——唯一严格可比的对照

**这一层的实测已由 B 线在 REMOTE_HOST chip4 上完成**（装置变更后，原计划的 x86 版已被取代）。
条件：**同一台机器（REMOTE_HOST Kunpeng 920B + Ascend 910）、同一个镜像、同一个真引擎、
同一张卡（chip4 = `/dev/davinci4`）、同一个客户端容器、同一个负载**
（chat / ISL=1024 / OSL=128 / c=1），**唯一变量是前端语言**
（`VLLM_USE_RUST_FRONTEND=1` + `VLLM_RUST_FRONTEND_PATH` vs `=0`）。
采集：`sudo perf stat -p <前端容器内进程的宿主pid>`，事件
`instructions:u,cycles:u,branches:u,branch-misses:u,cache-misses:u,cache-references:u`
（**两侧完全相同**）。原始数据与口径：`docs/02` §14.3、§14.10。

### 1.1 层 1 表（REMOTE_HOST chip4 实测）

| 指标 | **Rust 前端**（`vllm-rs`） | **Python 前端**（API server） | Rust/Python |
|---|---:|---:|---:|
| 窗口 / 完成请求 | 82.0 s / 96 | 59.4 s / 64 | — |
| `instructions:u` **每请求** | **9.775 M** | **131.247 M** | **0.0745（省 13.4×）** |
| `cycles:u` 每请求 | 13.494 M | 112.742 M | 0.1197（省 8.4×） |
| `branches:u` 每请求 | 2.006 M | 27.163 M | 0.0738 |
| `branch-misses` 每请求 | 0.126 M | 1.508 M | 0.0835 |
| `cache-misses` 每请求 | 0.184 M | 1.854 M | 0.0992 |
| **IPC**（`instr/cycles`，比值口径） | **0.7243** | **1.1638** | 0.62 |
| 分支失败率 | 6.28% | 5.55% | 1.13 |
| cache miss 率（占 cache-refs） | 4.51% | 3.27% | 1.38 |
| **前端进程 CPU s/请求** | **0.00953** | **0.04333** | **0.220（省 4.6×）** |
| 其中 utime / stime | 1.04 / 0.79 s | 3.67 / 0.49 s | — |
| **前端占服务端 CPU** | **1.12%** | **4.93%** | 4.4× |
| 吞吐 / TTFT / TPOT（含引擎） | 1.436 req/s / 84.9 / 4.81 ms | 1.440 req/s / 89.4 / 4.76 ms | 引擎相同 |

**⚠️ 归一化口径（这一步很容易做错）**：两次 `perf stat` 完成的请求数不同（**96 vs 64**），
所以**必须按请求归一化**。若直接比总量，会得到 0.1117 / 0.1795 / 0.1489 这类
**偏大的比值**（方法上错误，只是结论方向碰巧相同）。本文只引用按请求归一化列。

**交叉验证**：本节的前端 CPU/请求与 **C 线独立测的同一装置**吻合——
Rust 9.53 ms vs C1 中位数 10.31 ms（差 7.6%）、Python 43.33 ms vs C1 的 45.94 ms（差 5.7%）；
前端占比 1.12% / 4.93% vs C 线的 1.22% / 5.10%。**两条线、两套 harness、两套口径互证。**

### 1.2 ★ Python 的 IPC 更高，但它慢 4.6×——IPC 不能跨实现比大小

这是本节最重要的一条，也是最容易被读反的一条：

> **Python 走的指令多（13.4×）但每条都"轻"**：解释器逐条派发、小对象操作，
> 数据依赖少、分支可预测 ⇒ **IPC 1.1638**。
> **Rust 走的指令少 13.4× 但每条都"重"**：内存搬运 + 系统调用 + 内核态
> （实测内核态占样本 **32.86%**、`sys_enter_write` **208 次/请求**）⇒ **IPC 0.7243**。
> ⇒ **Rust 的优势来自「指令数少了 13 倍」，不是「每条指令更快」。**

**推论**：**IPC 只在同一实现的不同负载点之间可比**；
跨实现（Rust vs Python）比 IPC 会把结论读反。
要跨实现比较，必须同时看 **指令数/周期数的绝对值（按请求归一化）** 与**内核态占比**。

**与 engine core 的 66% 形状相似、成因相反**：

| | `PREPARE_INPUT_PROJECT`（engine core 主线程，Kunpeng 920B） | **本节的 Rust 前端（REMOTE_HOST chip4）** |
|---|---|---|
| IPC | 0.771 | **0.724** |
| 低 IPC 的成因 | **取指/解码受阻**（topdown `frontend_bound 66.01%`） | **内存/系统调用受阻**（内核态 32.86%、`write` 208 次/请求） |

⇒ 两者 IPC 几乎相同而成因相反，这正是「**不能拿 engine core 的 66% 去推断前端**」的实证补充
（第一个理由见本文 §3：那个数字采的是 engine core 进程，换前端根本不改变它）。

### 1.3 Q1 的答案（同装置实测的两侧火焰图并列）

同装置同负载下（完整数据见 `docs/02` §14.9）：

| | **Rust 前端** | **Python 前端** |
|---|---|---|
| top-1 帧 | 内核帧 **30.03%** | **`_PyEval_EvalFrameDefault` 18.31%** |
| 前 12 名里的主导族 | tokio 调度器/唤醒类 7 个 | CPython 解释器/对象内务类 8 个 |
| **X-py-interp（CPython 解释器本体）** | — | **47.25%** |
| **X-runtime（tokio 分发）** | **21.92%** | —（Python 侧是 uvloop/asyncio 1.41%） |
| **X-kernel（内核态）** | **32.86%** | 10.23% |
| X-copy / X-alloc | 2.97% / 4.90% | 3.67% / 1.29% |

⇒ **Q1 一句话答案**：

> **Rust 前端把 Python 的「CPython 逐条派发（47.25%）」换成了
> 「tokio 任务分发（21.92%）+ 内核态系统调用（32.86%）+ 拷贝/分配（7.87%）」。**

（`docs/02` §14.8 进一步说明：这个形状还**随引擎 tick 粒度变化**——
密集 tick 下是拷贝/分配主导，稀疏 tick 下是唤醒/轮询/内核主导。）

---

## 2. 层 2：跨装置——只能比"形状与趋势"，不能相减

这一层把 **Rust 前端的采样占比** 与 **Python 前端的 µs 级 scope 计时** 并排，
两边**装置不同、量法不同**（采样 self-time vs scope 墙钟），所以：

* ✅ 可以比：**随 ISL/OSL 的增减趋势**、**段与段之间的相对顺序**、"哪一段是常数级"；
* ❌ 不可以比：绝对 µs、百分比、IPC。

### 2.1 形状对照（这是本文最硬的跨装置证据）

| 段 | Python 前端（`[引用]` tokenizer 项目，x86 容器 + aarch64 真机混测） | Rust 前端（`[实测]` 本线，x86，采样 self） | 形状是否一致 |
|---|---|---|---|
| P3 模板渲染 | Jinja 渲染 **50–69 µs，与 ISL 无关**（常数级） | **9.3–15.6 µs/请求**；斜率分解：**常数级**（B1n 14.5 → B2 13.0 → B3 14.3 µs，ISL 差 8× 而值几乎不动） | ✅ **都是常数级** |
| P4 分词 | `tokenizer: encode` **≈1.47 µs/token**（线性，R²=0.99975）；占 TTFT 0.3–1.2%（1k）/ 5.3–10.4%（8k） | 段斜率 **50.9 ns/输入 token**（整请求 77.6 ns/输入 token）；ISL=8k 时 P4 占比升到 **41.71%** | ✅ **都线性于 ISL，且都在长 prompt 时变成大头** |
| P8 增量解码 | `detokenize: stream` **1.39–1.59 µs/token**（Python + HF tokenizers） | 斜率分解 **133 ns/输出 token**（`byte_level_decode` self，段合计 158.5 ns/token） | ✅ 都线性于 OSL；量级差约 10×（与 tokenizer 项目自己测的"Rust 旁路 decode 8×"同向） |
| P2 JSON | 未单独测 | 13.2–25.7 µs/请求（下界口径，见下） | ⚠️ **不可比** |

⚠️ **P2 那一行必须特别小心**：B1（ISL=1221，含 tools）16.9 µs，而 B2（ISL=8211）
只有 13.2 µs——**8 倍的 prompt 反而更便宜**。原因不是测量错误，而是这两个请求体形状不同：
B2 的正文是**一个超长字符串**（扫描到闭合引号 + 一次分配），B1 的正文有 system 消息、
user 消息、tools 数组等**更多字段**。所以 "P2 随 ISL 线性" 这个说法**在 B 线不成立**，
本文不写。P2 的绝对值也只用下界口径（serde 泛型适配层无法定向，见 `docs/02` §7.1）。

⚠️ **三条口径提醒**（缺一条就会误读上表）：

1. Python 侧的 µs 是 **scope 墙钟**（含等待/调度），Rust 侧是 **采样 on-CPU self-time**
   （不含等待）⇒ Rust 侧系统性偏小；
2. Python 侧数字来自 **HF `tokenizers`**，Rust 侧是 **fastokens + 自写 `DecodeStream`**
   ⇒ 换的不只是语言，还有实现（tokenizer 项目已量过 fastokens 本身有 9.3–13.5× 的 encode 优势）；
3. 装置不同：Python 侧混了 x86 容器与 aarch64 Kunpeng 920B，Rust 侧只有 x86
   ⇒ **比例可以看，绝对值不要引用**。

### 2.2 结构对照：两种前端把活摊在哪些线程上

| | Python 前端（`[引用]` A 线 `docs/01b-python-frontend-anchors.md` §1.6） | Rust 前端（`[实测]` 本线 §7.4） |
|---|---|---|
| 线程布局 | 1 个事件循环线程（主线程）+ `renderer_num_workers`（默认 **1**）个池线程 + 2 个 ZMQ io 线程 | 3 个 tokio runtime：HTTP runtime（多线程，默认名 `tokio-rt-worker`）+ `vllm-request`（多线程）+ `vllm-zmq-N`（默认 4 线程） |
| 谁做 P3/P4 | **池线程**（默认只有 1 个 ⇒ 事实上的串行） | `vllm-request` runtime |
| 谁做 P1 | 事件循环线程 | HTTP runtime |
| 谁做 P8/P9/P10 | 事件循环线程 | **HTTP runtime**（流式响应体在 HTTP runtime 上被 poll，`offload.rs:76-79` 注释 + 本线线程占比双证） |
| 谁做 P7 | 事件循环线程 | `vllm-zmq-N` |

**这张表的含义（`[推断]`，需 C 线证伪）**：Python 前端在结构上**没有把重活搬出事件循环**——
只有模板+分词进了池，而池默认只有 1 个 worker；Rust 前端把
**入站预处理（P2–P6）与出站响应（P8–P10）物理分到了两个 runtime**。
本线的线程占比数据（B2 把 80.4% 压在 `vllm-request`、B3 把 62.2% 压在 HTTP runtime）
说明这个拆分**在实际负载下确实各管一段**；
至于"这能不能换成吞吐"，是 C 线（Q3/Q4）的问题，**本文不下结论**。

### 2.3 迁移了什么：一张对照表

| Python 前端在 CPU 上的样子（`[引用]`） | Rust 前端在 CPU 上的样子（`[实测]`） |
|---|---|
| CPython 逐条派发：成千上万个 Python 帧，每个自耗都很小 | 少数内存原语吃大头：`[libc.so.6]` 15.20%、mimalloc 14.18% |
| 对象创建/引用计数是主要"内务"成本 | **分配 + 拷贝 + 调度 = 43.3%** 是主要"内务"成本 |
| 分词/模板是"解释器里的一段代码" | 分词/模板是"几段 Rust 代码 + 一个正则 JIT 子系统"（PCRE2 4.7%） |
| 前端成本几乎全在一两个线程上 | 成本分布在 3 个 runtime / 6+ 个线程上 |

**一句话**：迁移**把"解释器派发"这条成本线整体删掉了**，
但**留下了（并且凸显出）内存搬运与任务调度**这条线——
它在 Python 里被解释器开销盖住，在 Rust 里成了第一、第二名。

---

## 3. 层 3：明确划出界外的那部分（防止后人继续误用）

> **`frontend_bound 66.01%` / `IPC 0.771` / `bad_spec 11.03%` / `retiring 12.85%`
> 这一整套 topdown 数字，采的是 `PREPARE_INPUT_PROJECT` 项目里
> engine core 宿主 TID 704908 的 `prepare input` 阶段，装置是
> aarch64 Kunpeng 920B（`data/profiles/real-b1/pmu/topdown.json`，9/9 组 PMU，
> 见 `PREPARE_INPUT_PROJECT/docs/05-hotspots.md:243`）。**

| 项 | 事实 |
|---|---|
| 采集对象 | **engine core 进程主线程**（不是 API server 前端进程） |
| 装置 | Kunpeng 920B（aarch64，640 逻辑核），libkperfx 采的 topdown |
| 换 Rust 前端会不会改变它 | **不会**。engine core 仍然是 Python，仍是同一个进程、同一段代码 |
| 它回答的问题 | "engine core 的 `prepare_input` 阶段卡在流水线的哪一档" |
| 它**不能**回答的问题 | "把 API server 从 Python 换成 Rust 能省多少" |

**与本计划相关的前端侧对照，只有层 1（§1）才算数**；层 2 只能看形状；
`PREPARE_INPUT_PROJECT` 的 topdown 数据在本项目里的正确用途是——
**作为"engine core 侧的既有结论"被引用**，而不是当作"Python 前端基线"。

（顺带修正一个容易连带出错的说法：`tokenizer` 项目的 scope 计时
**确实是** API server 前端进程的（`tokenizer/docs/02-cost-and-share.md:34-49`：
`tokenizer:` 三 scope 在 pid=1 前端、`Step:Model/phase:*` 在 pid=131 engine core）。
所以层 2 引用它是对的，引用那份 topdown 是错的。）

---

## 4. 未测项与交给别人的部分

| 项 | 状态 | 归属 |
|---|---|---|
| Rust vs Python 前端**同装置** IPC / 分支 / cache 对照 | **未测（待 C 线）** | C 线 `docs/04-ab-comparison.md` |
| Python 前端进程自身的火焰图（同装置同采样参数） | **未测** | C 线；本线只给出"建议先做 fp/dwarf 5 分钟对比"的方法结论（`docs/02` §2.1） |
| Python 前端的 per-request on-CPU 时间（`/proc/<pid>/stat`） | **未测** | C 线（B 线 `raw_load.py` 没接 `procstat.sh`，见 §1.2） |
| 前端 CPU 时间/吞吐的"值不值"（Q3/Q4） | **未测** | C 线；本文只给"热点是什么" |
| engine core 内部（调度/forward/sample） | **界外** | `PREPARE_INPUT_PROJECT` 已覆盖 |
| `tokenizer` 六后端与 50+7 参数的形态评估 | **界外** | `tokenizer` 项目已覆盖 |
