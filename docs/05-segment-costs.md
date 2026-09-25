# 05 · 逐段微基准：P2 / P3 / P6 / P7 / P10（附 P4 补充）

> D 线主产出。对应 `plan/experiment-matrix.md` §4 的 D1–D5。
> 全部原始数据：`data/micro/results.csv`；汇总：`data/micro/segments.json`；
> 一致性验收：`data/micro/checks.json`；D6 补充：`data/micro/d6_pretokenize.json`；
> 装置与哈希：`data/micro/manifest.json`。一键复跑：`harness/micro/run_micro.sh`。

## 0. 一句话结论

在 **1k / 8k ISL、OSL=128、含 2 个 tools** 的 chat 负载上，把可比的六段加起来：

| 口径（P2+P3+P6+P7，未计 P5/P9、未计 HTTP 与调度） | Rust | Python | Rust/Python |
|---|---:|---:|---:|
| **1k**（渲染后 1291 token） | **30.5 µs** | **52.2 µs** | **0.58** |
| **8k**（渲染后 8441 token） | **108.3 µs** | **210.8 µs** | **0.51** |
| **osl128 响应侧**（P10 单帧序列化+组帧） | **0.72 µs** | **6.67 µs** | **0.11** |

分段占比（四段合计 = 100%）：


三条要点：

1. **解析/渲染/编解码本身都只是几十 µs 量级**，与既有结论一致（chat 模板 50–70 µs
   是常数级；tokenizer 边际成本 1.47 µs/token）。⇒ 这些段**不解释** TTFT。
2. **Rust 侧真正的省处在"解释器开销"而不是算法**：同一份算法（JSON 解析、
   Jinja 渲染、msgpack），Rust 版普遍是 Python 版的 **0.37–0.56**；唯一的例外
   是 msgpack **编码**（Rust 反而慢 **1.30×（1k）/ 1.50×（8k）**，原因见 §4：
   Rust 侧不做 `omit_defaults`，而且多走一层 `serde` 派生）。
3. **分配次数是一条独立的结构性事实**：Rust 侧解析 1k 的 chat 请求体（5326 B）
   要做 **112 次分配 / 19 931 B**（≈输入的 **3.7 倍**），8k（37 371 B）是
   **115 次 / 94 500 B**（≈2.5 倍）；渲染一次 1k 的 chat 模板要做
   **248 次分配 / 63 201 B**（≈输入的 11.3 倍）。
   结合 B 线的火焰图（**正式 30 s 矩阵**：`[libc.so.6]` **15.20%**，其中 ≈80% 是
   glibc AVX-512 `memmove/memcpy` ⇒ **12.2%**、≈11% 是 `memcmp` ⇒ 1.7%；
   mimalloc 家族 **14.18%**；`serde_json` 几乎不进 top-20），
   **P2/P10 的成本在"数据搬运与分配"而不在"解析算法"**——
   这正是 B 线看到的块拷贝从哪里来的第一层答案（口径见 §1.5）。

## 1. 口径（引用任何数字前必读）

### 1.1 装置

| 项 | 值 |
|---|---|
| 机器 | `LOCAL_HOST`，x86_64 **AMD Eng Sample: 100-000000956-50_Y**，12 核 / 29 GiB |
| 绑核 | `scripts/limit.sh` 默认 `CORES=4-7`（= **4 个核**），内存上限 8 GiB |
| 串行化 | 每个子步骤单独走 `scripts/heavy_lock.sh`（全局唯一重活锁） |
| 编译 | `cargo build --release -j 4`，`lto=thin`、`codegen-units=1` |
| 计时 | `Instant::now()`（Rust）/ `time.perf_counter_ns()`（Python）夹住**一次**操作 |
| 微基准版本 | `harness/micro/rust` 独立 crate（不是 vLLM 工作区），依赖版本与 `rust/Cargo.toml` 对齐：`serde_json 1.0.151` / `minijinja 2.24.0` / `rmp-serde 1.3.1`；二进制 sha256 见 `data/micro/manifest.json` |
| 采样纪律 | 每点先预热 **≥10 s**，再采样 **≥30 s**；百分位用最近秩法 |
| 窗口组织 | 同一负载点里的多个 op 在**同一个窗口内轮转**（按 ~1 ms 时间片批量），共享 cache/allocator 状态；两侧规则一致 |
| 计时器自身开销 | `seg=meta, op=clock_overhead`：Rust **0.020 µs**、Python **0.080 µs**（p50，见 `results.csv`） |
| 本次运行 loadavg | 之前 `3.03 2.68 2.28`，之后 `1.80 2.22 2.31`（共享机，未独占） |
| 采样时长 | 预热 10 s + 采样 30 s（每点、每侧、每命令；写进 manifest 的 `run_config`） |

**计时器开销是一道硬门槛**：P10 的单帧组帧在 Rust 侧只有 0.19 µs（p50），
已经接近计时器自身开销（0.020 µs）的 10 倍，属于"能测但别当精确值用"的区间。

### 1.2 同输入、同尺寸（`checks.json` 是验收证据）

两侧读**同一份 fixture 文件**，浏览器缓存不参与；尺寸用真实 Qwen3-0.6B tokenizer
（`tokenizers` 0.22.2）计数，不用字符数折算：

| 负载点 | 用户消息 | 渲染后 prompt | chat 请求体 | EngineCoreRequest |
|---|---:|---:|---:|---:|
| `1k` | 990 token / 4401 B | **1291 token / 5603 B** | 5326 B | 1024 个 token id |
| `8k` | 8140 token / 36186 B | **8441 token / 37388 B** | 37371 B | 8192 个 token id |
| `osl128` | — | — | 响应体 855 B | 129 个流式分块 |

`data/micro/checks.json` 里 **11 条校验全部通过**（`all_ok: true`），其中最硬的四条：

| 校验 | 结果 |
|---|---|
| D2 两侧渲染的 prompt 字节 **sha256 相同** | ✅ 1k 与 8k 都逐字节相同（分别是 `66920578…` / `0432eb86…`） |
| D4 两侧序列化的响应体字节 **sha256 相同** | ✅ `7e173134…`（855 B） |
| D1 两侧解析出的字段摘要相同 | ✅ messages/tools/first_tool/content_bytes 全一致 |
| D3 两侧都能解对方的 msgpack payload | ✅ Rust 解 msgspec 的稀疏字节、Python 解 rmp-serde 的全量 map |

> **达标的含义**：D2 的"同一份模板"不是"看起来差不多"，是**输出字节完全一致**；
> 所以 §3 的 µs 差就是引擎差，不是输入差。

### 1.3 我测的是哪一段、没测哪一段

| 段 | 本文件 | 说明 |
|---|---|---|
| P2 JSON 反序列化 | ✅ D1 | `serde_json` vs `json.loads` / `orjson` |
| P3 chat 模板渲染 | ✅ D2 | minijinja（含 HF `tojson` + pycompat）vs Jinja2 |
| P4 分词 | ⏭️ D5 引用 + **D6 补充** | 不重测；D6 只补"预分词正则"这一小段 |
| P5 lower / 校验 | ❌ 未测 | 与 `serde` 反序列化耦合，单独切不出来（见 §7 未测清单） |
| P6 序列化下发 | ✅ D3 | `rmp_serde::to_vec_named` vs `msgspec.msgpack` |
| P7 响应反序列化 | ✅ D3 | 双向：各自解自己 + 解对方 |
| P8 增量解码 | ⏭️ D5 引用 | 不重测 |
| P9 parser | ❌ 未测 | 需要真实 reasoning/tool 输出流，微基准造不出来（见 §7） |
| P10 JSON 序列化 + 回写 | ✅ D4 | 序列化、SSE 组帧、`write()` 三层分开量 |

### 1.4 与既有基线的口径对照

| 基线 | 装置 | 能不能直接比 |
|---|---|---|
| `tokenizer` 项目（encode 1.47 µs/token、Jinja 50–70 µs） | **同机**（LOCAL_HOST x86_64，容器 2 核 cpuset 4-5） | **趋势可比**；绝对值它绑 2 核、我绑 4 核，**标注后可比** |
| `PREPARE_INPUT_PROJECT`（frontend_bound 66.01%、IPC 0.771） | **Kunpeng 920B aarch64 + Ascend** | ⚠️ **不可直接比**：跨装置、跨架构、且它是 topdown 口径我是 wall-clock µs |
| B 线火焰图（**正式 30 s 矩阵**：`[libc.so.6]` 15.20%（拷贝 12.2% / 比较 1.7%）、mimalloc 14.18%、PCRE2 相关合计 4.7%、P4 段 6.57%） | 本机 | ✅ 同机，**自耗占比 ↔ 本文件的 µs** 可互证 |

> 本文所有"比 Python 快多少"的结论，都只依赖**同一台机、同一次运行、同一份输入**
> 的两个数相除 ⇒ 不受跨装置影响。

### 1.5 B 线数字的版本（同一个量为什么会有两个数）

B 线在**早期探针**（10 s、非流式）阶段给过一组数字，本文件初版引用的是那一组；
B 线跑完**正式 30 s 矩阵**（SSE 流式，B1 = chat+tools / ISL=1k / OSL=128 / c=1）后
已更新。**本文一律采用正式矩阵**：

| 项 | 早期探针（10 s，非流式，样本少） | **正式矩阵（30 s，SSE 流式，B1）** |
|---|---:|---:|
| 块拷贝 | `memcpy/memmove` 10.6% | `[libc.so.6]` **15.20%**（memmove/memcpy ≈80% ⇒ **12.2%**；memcmp ≈11% ⇒ **1.7%**） |
| 分配器 | mimalloc 家族 ≈11% | **14.18%** |
| PCRE2 | ≈4.8% | **4.7%**（PCRE2 相关合计；其中 B1 的 JIT 叶子帧 2.91%）——**P4 段合计 6.57%**，ISL=8k 时 **41.71%** |
| `LocalKey<T>::with` | 6.25% | 4.22% |

- **来源**：`docs/02-cpu-profile.md`（正式矩阵）；两代口径的逐项对照表在 `docs/02` **§12**。
  ISL=8k 那条 41.71% 记在 `docs/03-hotspot-migration.md` 与
  `data/profiles/B2.segments.csv`（B2 点），不在 `docs/02`。
- **差异原因**：正式口径把**未解析的 `[libc.so.6]` 帧整体单列**（早期是手工归到 memcpy 上）；
  且正式负载是**流式 SSE**（每 token 一个 chunk），拷贝与分配都被放大。
- **本文件的定性结论不受影响，反而更强**：正式数字（12.2%）比早期探针（10.6%）**更大**，
  "成本在搬运与分配、不在解析算法"这条判断的证据更足。

## 2. D1 · P2 JSON 反序列化

**基准内容**：把 `chat_request_{1k,8k}.json` 的字节喂给两边的解析器。Rust 侧两个
op：无类型的 `serde_json::Value`（对应 Python 的 `json.loads` 口径）与强类型的
`serde_json::from_slice::<ChatRequest>`（产品路径）。Python 侧两个 op：
`json.loads`（主）与 `orjson.loads`（Python 侧上界，非 vLLM 依赖，仅作参考）。

### D1 计时（p50，µs；`iters` 是 30 s 窗口里的迭代次数）

| op | 1k（5326 B） | 8k（37371 B） | 分配/次 | 分配字节/次 | 相对 Rust `Value` |
|---|---:|---:|---:|---:|---:|
| Rust `serde_json::Value` | **6.502** | **19.226** | 112 / 115 | 19 931 / 94 500 | 1.00 |
| Rust `serde_json::from_slice::<ChatRequest>` | **5.169** | **17.783** | 74 / 77 | 16 421 / 90 990 | 0.80 / 0.92 |
| Python `json.loads` | **11.621** | **53.199** | 未测 | 未测 | 1.79 / 2.77 |
| Python `orjson.loads`（上界，非 vLLM 依赖） | 4.458 | 23.133 | 未测 | 未测 | 0.69 / 1.20 |

> "分配/次"两列是 `1k / 8k` 两个值；Rust 侧由计数分配器实测（见 §1.1、`rust/src/alloc.rs`），
> Python 侧**未测**（没有开 tracemalloc，开了也会污染 30 s 窗口的计时）。
> p99 见 `data/micro/results.csv`；`iters` 最少的那一行是 8k 的 Python `json.loads`
> （263 808 次），即使最慢的 op 在 30 s 里也有 26 万样本。

**斜率**：Rust `Value` 从 6.50 → 19.23 µs，输入从 5.3 → 37.4 KB，
即 **≈0.41 µs/KB**；Python `json.loads` 从 11.62 → 53.20 µs，即 **≈1.31 µs/KB**。
两者都近似线性 ⇒ **比值稳定在 0.36–0.56**，不随 ISL 反转。

**读法（三条）**：

1. **同为无类型解析，Rust 是 Python 的 ≈0.5×**：1k 上 6.6 µs vs 11.7 µs，
   8k 上差距更大（见上表）。这部分差值就是"CPython 逐条派发"在这一段上的量。
2. **强类型解析比无类型还快**：`from_slice::<ChatRequest>` 直接构造目标结构，
   跳过了 `Value` 中间态与它的分配，所以**生产路径比基准路径更省**。
   这条与直觉相反，值得写进 Q1：Rust 的类型驱动反序列化把"通用 DOM"这一层
   整个省掉了，而 Python 侧（pydantic/msgspec 校验）是**在 `json.loads` 之上再加
   一层**，只会更贵。
3. **分配是这一段真正的大头**：5.3 KB 的请求体要 **112 次分配 / 19.9 KB**，
   8k 的请求体要 **…**。`ChatRequest` 里每个 `String`/`Vec` 一次分配，
   输入里的中文（Qwen3 词表里一个汉字 ≈1 token，UTF-8 3 字节）还会在
   `serde` 的转义路径上多走一遍扫描。

> **这一节回答 B 线的疑问（"`serde_json` 为什么不在 top-20"）**：
> 1k 上 P2 只有 5–7 µs，而一次请求的端到端前端开销是**毫秒级**（B 线的
> TTFT 拆解）⇒ 占比 <1%，本来就该在火焰图上不可见。但**它产生的分配**会在
> 后续每次 `Vec<String>` 增长时变成 `memcpy`，并以 mimalloc 帧的形式出现在
> 火焰图上——**成本从"解析算法"转移到了"数据搬运"**。这不是"serde_json 慢"，
> 是"零拷贝没做到"。

## 3. D2 · P3 chat 模板渲染

**基准内容**：Qwen3-0.6B 的官方 chat template（4168 B，含 `<tools>` 循环），
同一份 messages（1 轮 user）+ 同一份 tools（2 个 function）。Rust 侧用
**逐行复刻**的 minijinja 环境（trim/lstrip、`minijinja_contrib::pycompat` 未知方法
回调、HF 版 `tojson` 过滤器、`TemplateMap` 自定义 map），Python 侧用
`ImmutableSandboxedEnvironment` + transformers 同义的 `tojson`。

Rust 侧拆成两个 op，因为产品路径上这是**两次**独立工作：

| Rust op | 干什么 | Python 侧对应 |
|---|---|---|
| `context_build` | `ChatRequest` → 模板上下文：messages/tools 搬进 `serde_json::Value` → `minijinja::Value`（`to_template_value` 递归建 `TemplateMap`） | **无独立对应**：Python 的 dict 直接就是模板上下文，这一步在 Python 侧是零成本 |
| `minijinja_render` | 编译一次后每请求 `render` | `jinja2_render`（含 dict 组装） |

| op | 1k | 8k | 分配/次（1k/8k） | 分配字节/次（1k/8k） |
|---|---:|---:|---:|---:|
| Rust `context_build` | 1.954 µs | 2.544 µs | 90 / 90 | 11 052 / 42 837 |
| Rust `minijinja_render` | **12.934 µs** | **16.902 µs** | 248 / 248 | 63 201 / 349 262 |
| **Rust 合计（产品口径）** | **14.888 µs** | **19.446 µs** | 338 / 338 | 74 253 / 392 099 |
| Python `jinja2_render`（含 dict 组装） | **25.066 µs** | **41.156 µs** | 未测 | 未测 |
| 比值（render 对 render） | **0.52×** | **0.41×** | — | — |
| 比值（Rust 合计 对 Python） | 0.59× | 0.47× | — | — |

两侧渲染出的字节数（5603 / 37 388）与 **sha256 完全相同**，见 §1.2。

**读法（三条）**：

1. **渲染是常数级、且与 prompt 长度几乎无关**：1k 与 8k 的 `minijinja_render`
   都是十几 µs（见上表），因为模板只做"拼字符串 + 把 tools 序列化一次"，
   与 §1.2 里 8k 的 37 KB prompt 无关。这**复现了 `tokenizer` 项目的结论**
   （Jinja 50–70 µs 常数级），只是换引擎后更低。
2. **模板引擎的"解释"开销在 Python 侧才显出来**：同一份模板、同一份输入、
   **输出字节 sha256 完全相同**，Rust 只要 0.56× 的时间。
3. ⚠️ **Rust 侧多出来的 `context_build` 是这一段的隐藏成本**，Python 侧没有
   对应的段。产品口径下 P3 应当是 `context_build + minijinja_render`（上表
   "Rust 合计"行），此时 Rust 的优势会缩小到 ≈1.0×。**这是 Rust 侧一个真实的
   结构性劣势**：为了让 minijinja 拿到数据，得先把 `serde` 结构再搬一遍成
   `minijinja::Value`；Python 的 dict 天生就能被 Jinja 直接用。写进 Q1/Q2 时要
   把这条和"引擎更快"分开说。

## 4. D3 · P6/P7 msgpack 编解码

**基准内容**：`EngineCoreRequest`（20 字段、`array_like` 数组式）在两侧各编一遍、
解两遍。两侧的字段取值来自**同一份** `engine_core_request_{1k,8k}.json`。

两侧的**编码策略本来就不同**，这是本段最重要的发现：

| 侧 | 实现 | 策略 | 1k payload | 8k payload |
|---|---|---|---:|---:|
| Rust | `rmp_serde::to_vec_named` | `serde_tuple` 20 元素数组；**不做 `omit_defaults`**（取默认值的字段照样编码） | 3528 B | 26523 B |
| Python | `msgspec.msgpack`（`array_like=True, omit_defaults=True`） | 默认值字段**整个省掉** | 3535 B | 26530 B |

> 两侧字节数只差 7 B：**纯属巧合**——两边在 1k/8k 上都是"多写了几个默认值字段、
> 少写了几个 map 键"。`rmp_serde` 用 `to_vec_named` 走的是**全量 map**，
> msgspec 走的是**稀疏 map**，字节量接近但**结构不同**，所以两者 sha256 不同
> （见 `checks.json`）。能互解是因为 `serde(default)` 与 `msgspec` 的默认值语义
> 对得上，这一点由 D3 的"交叉解码"两行**实测**验证。

| op | 1k | 8k | 分配/次（1k/8k） | 分配字节/次（1k/8k） |
|---|---:|---:|---:|---:|
| Rust `rmp_serde_encode` | **4.137 µs** | **31.017 µs** | 10 / 13 | 5 632 / 45 056 |
| Rust `rmp_serde_decode_rust_payload` | **5.019 µs** | **38.571 µs** | 5 / 5 | 4 196 / 32 868 |
| Rust `rmp_serde_decode_python_payload` | 5.038 µs | 38.592 µs | 5 / 5 | 4 196 / 32 868 |
| Python `msgspec_encode` | **3.175 µs** | **20.679 µs** | 未测 | 未测 |
| Python `msgspec_decode_python_payload` | 12.393 µs | 95.718 µs | 未测 | 未测 |
| Python `msgspec_decode_rust_payload` | **12.383 µs** | **95.739 µs** | 未测 | 未测 |
| Python `msgpack.packb`（通用 C 扩展，非 vLLM 依赖） | 22.461 µs | 170.297 µs | 未测 | 未测 |
| 比值：encode（Rust/Python） | **1.30×** | **1.50×** | — | — |
| 比值：decode（Rust/Python） | **0.41×** | **0.40×** | — | — |

**斜率**：Rust 编码 + payload 从 3.5 → 26.5 KB（7.5×）耗时长 7.5×（4.14 → 31.02 µs）
⇒ 严格线性；Python 编解码同理（3.18 → 20.68、12.38 → 95.74）。
**这一段没有超线性项**，瓶颈是纯字节搬运。

**读法（三条）**：

1. **解码 Rust 更快（0.41× / 0.40×），编码 Rust 更慢（1.30× / 1.50×）**。解码快符合预期
   （静态类型 + 无解释器）。编码慢的原因是结构性的：`rmp_serde` 要经过
   `Serialize` 派生逐字段序列化成 map，而 msgspec 是**把结构体当数组直接刷**
   （`array_like`）——后者本来就少一层。
2. **Rust 的线上字节并不天然更小**：不做 `omit_defaults` ⇒ 每次都把
   `temperature/top_p/...` 这些默认值写进去。这段膨胀在本负载下只有几字节，
   但如果 `sampling_params` 的字段集继续长（Python 侧真实是 ~40 个字段），
   **Rust 侧的固定开销会线性增长**。这是 Q2/Q4 的一个可优化点。
3. **Rust 侧收包路径值得单独看**：`rmp_serde_decode_python_payload`（解 msgspec
   的稀疏字节）比解自家全量字节略慢一点（见上表），因为要处理"字段缺失 →
   回落默认值"的 `serde(default)` 分支。这是**跨语言协议的真实成本**，
   在只测"自己编自己解"的基准里是看不到的。

## 5. D4 · P10 JSON 序列化 + SSE 回写

**基准内容**：同一份非流式响应体（855 B）与同一条流式序列（129 帧 = 1 个首帧 +
127 个 content delta + 1 个 finish chunk，另加 `[DONE]`；每帧平均 177.7 B）。

按 B 线的要求，**序列化 CPU 与 `write()` 系统调用分开报**，再加上"组帧"这一层：

| 层 | Rust op | Python op | 说明 |
|---|---|---|---|
| ① 序列化 | `serde_json_response` | `json.dumps_response` | 强类型结构体 → JSON 字节，产出 855 B（两侧 sha256 相同） |
| ② 组帧 | `serde_json_sse_frame` | `json.dumps_sse_frame` | 单帧"序列化 + `data: …\n\n`"，**不写 socket** |
| ③ 写 socket | `write_frame_tcp` | `asyncio_write_frame_tcp` | 单帧写 loopback TCP。⚠️ **机制不同**：Rust 是阻塞 `write_all`，Python 是 `asyncio` write+drain（含事件循环调度） |
| ④ 整流组帧 | `stream_request_local` | `stream_request_local` | 129 帧全部序列化+组帧写进内存缓冲，**不碰 socket** |

| op | Rust | Python | Rust/Python | Rust 分配/次 | Rust 分配字节/次 |
|---|---:|---:|---:|---:|---:|
| ① `*_response`（855 B 响应体） | **0.541 µs** | **4.358 µs** | **0.12×** | 4 | 1 092 |
| ② `*_sse_frame`（162 B 单帧） | **0.180 µs** | **2.314 µs** | **0.08×** | 3 | 426 |
| ③ `write_frame_tcp` / `asyncio_write_frame_tcp` | **3.277 µs** | **38.771 µs** | 0.08×（⚠️ 不可比） | 不适用（syscall） | 不适用 |
| ④ `stream_request_local`（129 帧，23 834 B） | **23.263 µs** | **317.160 µs** | **0.07×** | 258 | 33 024 |
| ⑤ 派生：一个流式请求的 P10 总成本（=④ + 129×③，**推断**） | **446.0 µs** | **5 318.6 µs** | 0.08× | — | — |
| Python `orjson.dumps_response`（上界，非 vLLM 依赖） | — | 0.351 µs | — | — | — |

④ 的斜率：Rust 23.263 µs ÷ 129 帧 = **0.180 µs/帧**，与 ② 的单帧序列化完全一致
（说明 ④ 里没有额外的大项）；Python 317.16 ÷ 129 = **2.458 µs/帧**。
按 OSL=512 外推（1 帧/token，**推断**）：Rust ≈92 µs、Python ≈1.26 ms。

**读法（四条）**：

1. **单帧序列化是亚微秒级**：Rust 侧 0.19 µs、Python 侧 2.2 µs。Rust 的这个数
   已经接近计时器下限（0.020 µs）的 10 倍，**只能当量级用**。
2. **蛇形本体在 Python 侧**：129 帧整流组帧 Python 是 300+ µs（见上表），
   也就是**每个 token 多花 ≈2.4 µs 在组帧上**（该数按 1 帧/token 折算）。
   按 OSL=512 线性外推（**推断**），仅"组帧"这一层就是 1.2 ms/请求。
   这是 Python 前端在长输出下的一个真实成本，与 `PREPARE_INPUT_PROJECT` 的
   "CPython 逐条派发"是同一件事。
3. **`write()` 是另一码事，且两侧不可比**：Rust 的阻塞 `write_all` 单帧 3.2 µs，
   Python 的 asyncio 写 43.9 µs（≈14×）。但这个对比**不公平**——asyncio 的数字
   含事件循环调度与 `drain()` 的 await 往返，而 Rust 侧是裸 syscall。
   线上是 hyper/tokio 在写，不是裸 `write_all`。**这条只报不推结论**。
4. **回写成本随 OSL 线性、不随 ISL 变化**：② 与 ④ 都只与帧数有关，
   ISL=1k 与 8k 对它们没有影响。⇒ 长输出场景才是 P10 的战场。

> **"P10 的成本在哪"**：④ 说明**整流组帧**在 Rust 侧 21.9 µs、Python 侧 300+ µs；
> ③ 说明**每帧一次 syscall** 是另一层账。把 ② + ③ × n 相加得到"一个流式请求的
> P10 总成本"，两侧都是**推断值**（两段实测相加），数值在
> `segments.json` 的 `points.osl128.derived`。

## 6. D5/D6 · P4 分词：引用 + 一处补充

### 6.1 D5（不重测）

按 `plan/experiment-matrix.md` 的约定，**P4/P8 不重测**，直接引用 `tokenizer` 项目：

| 段 | 引用结论（`tokenizer/docs/02`） | 装置 |
|---|---|---|
| P4 encode | `cost ≈ 1.4688 × tokens − 136.3`，**R²=0.99975**，边际 ≈**1.47 µs/token**（128–8k 线性）；64 token 以下有 25–45 µs 固定成本 | Kunpeng 920B aarch64，容器 2 核 |
| P4 模板内 encode | 8k 时 10 009 µs（`tools_1turn`），是 `render_messages` 的线性主项 | 同上 |
| P8 detokenize: stream | **1.39–1.59 µs/token**，另加首步 216–292 µs | 同上 |
| P8 decode: prompt_reverse | 0.17–0.19 µs/token | 同上 |

⚠️ **跨装置标注**：上表是 **Kunpeng 920B aarch64 + Ascend** 环境，本文件是
x86_64 ⇒ **绝对值不可直接与本文件的 µs 相加或相比**；可比的是**趋势与比值**
（"与 token 数线性"这一条在本文件的 P2/P3/D6 上也成立）。

### 6.2 D6（B 线发现的缺口，本线补测，**可选段**）

**为什么补**：B 线的**正式 30 s 矩阵**在 `vllm-rs` 进程里看到 PCRE2 相关帧合计
**4.7%**——`[perf-<pid>.map]_[j]`（JIT 代码区）**2.91%**、
`pcre2::bytes::Regex::find_at` 1.00%、`pcre2_match_8` 0.41%、`pcre2_jit_match_8` 0.34%，
且三点斜率分解显示这些帧**全是 ISL 驱动** ⇒ 属于 **P4（编码）**；
`Cargo.lock` 反查确认**只有 `fastokens` 依赖 `pcre2`**。而 `tokenizer` 项目测的是
**fastokens 的 BPE/编码路径**，**没有单独测过预分词正则**。所以补一个 D6，
量 fastokens 的**预分词**与**全量 encode** 的拆分。

> ⚠️ **两套数字不同源，不要混为一句**：B 线是**线上火焰图口径**（前端进程 30 s 的
> on-CPU 自耗占比，B1 的 P4 段占 6.57%、PCRE2 相关合计 4.7%；ISL=8k 的 B2 点上
> P4 段升到 **41.71%**）；D6 是**微基准多线程口径**（4 线程墙钟 µs）。两者只能
> **互证方向**（都指向"预分词正则很贵"），**不能互相折算**。

**基准内容**：输入是 D2 渲染出的真实 prompt（1k→5603 B / 989 splits；
8k→37388 B）。三个 op：

| op | 覆盖什么 |
|---|---|
| `fastokens_build_pre_tokenized` | normalizer + added-token 切分（**不含正则**） |
| `fastokens_pretokenize` | 上面 + `pre_tokenizer().pre_tokenize()`（**PCRE2 JIT 正则切分**） |
| `fastokens_encode_full` | 全量 `encode`（预分词 + BPE），与 `tokenizer` 项目口径的同一段对齐 |

| op | 1k（5603 B / 989 splits） | 8k（37 388 B / 6059 splits） | 分配/次（1k/8k） |
|---|---:|---:|---:|
| `fastokens_build_pre_tokenized`（无正则） | **3.877 µs** | **22.190 µs** | 9 / 25 |
| `fastokens_pretokenize`（含 PCRE2 JIT 正则） | **50.564 µs** | **311.209 µs** | 44 / 69 |
| `fastokens_encode_full`（= 预分词 + BPE） | **71.263 µs** | **350.793 µs** | 56 / 81 |
| 预分词占全量 encode 的比例 | **70.95%** | **88.72%** | — |
| 差值 = 纯 BPE（**推断**：全量 − 预分词） | 20.699 µs | 39.584 µs | — |

**斜率**：预分词 50.6 → 311.2 µs（6.2×），splits 989 → 6059（6.1×）⇒ **线性于 split 数**。
纯 BPE 的差值只从 20.7 → 39.6 µs，**远低于线性**（1k→8k 是 8.3× 的 token 数，
但 BPE 只涨 1.9×）⇒ 这印证了 `tokenizer` 项目"DAG/哈希缓存命中后 BPE 很便宜"的结论。

**换算**：8k 全量 encode 350.8 µs ÷ 8441 token = **0.042 µs/token**。
与 `tokenizer` 项目的 **1.47 µs/token**（Python 前端 + HF tokenizers 后端 + 单线程 +
**Kunpeng 920B**）相比是 35×，但**这三件事同时不同**（后端 / 线程数 / 装置）
⇒ 只能当"量级参考"，**不能当成 35 倍的加速比**。

**读法（三条）**：

1. **预分词（含 PCRE2 JIT 正则）占 fastokens 全量 encode 的大头**（1k：
   50.6/71.3 µs ≈ **71%**；8k：311.2/350.8 µs ≈ **88.7%**）。B 线在火焰图上看到的
   那 **4.7%**（P4 段合计 **6.57%**）的 PCRE2 帧，对应的正是**这个大头**，
   而不是 BPE。
2. **这修正了"分词成本主要在 BPE merge"的直觉**：`tokenizer` 项目的结论是
   "热点在哈希/查找与内存分配，不在 BPE merge"——D6 方向一致（都不指向 merge），
   但把落点说得更具体：**预分词正则比 BPE 更贵**。
3. ⚠️ **D6 是多线程口径，不能与 D1–D4 相加**：fastokens 的 `Split` 在
   ≥16 个 split 时切到 rayon 线程池（`pre_tokenized.rs::PARALLEL_THRESHOLD`），
   线程数受 taskset 限制为 4（本机绑核 4-7）。所以 D6 是**4 线程墙钟**，
   不是单线程 CPU 时间。单线程对照可用 `RAYON_NUM_THREADS=1` 复跑。

> **与 D5 的关系**：D6 **不是** D5 的替代，是它的一个补丁。D5 仍然成立
> （整段不重测、引用既有结论）；D6 只回答"B 线正式矩阵里那 4.7% 的 PCRE2 帧
> 到底是什么"。

## 7. 每段 µs 与相对占比（给 docs/06 的输入）

**四段合计的口径**：`P2 + P3 + P6 + P7`，取 p50 相加。
**不含** HTTP 接入（P1）、lower/校验（P5）、分词（P4）、parser（P9）、
系统调用与上下文切换 —— 所以这是**下界**，不是"前端总开销"。

### 7.1 1k（渲染后 1291 token）

| 段 | Rust µs | Rust 占比 | Python µs | Python 占比 | Rust/Python |
|---|---:|---:|---:|---:|---:|
| P2 JSON 反序列化 | 6.50 | 21.3% | 11.62 | 22.2% | 0.56 |
| P3 模板（Rust 含 context_build） | 14.89 | 48.7% | 25.07 | 48.0% | 0.59 |
| P6 msgpack 编码 | 4.14 | 13.5% | 3.18 | 6.1% | **1.30** |
| P7 msgpack 解码 | 5.02 | 16.4% | 12.38 | 23.7% | 0.41 |
| **合计** | **30.55** | **100%** | **52.25** | **100%** | **0.58** |

### 7.2 8k（渲染后 8441 token）

| 段 | Rust µs | Rust 占比 | Python µs | Python 占比 | Rust/Python |
|---|---:|---:|---:|---:|---:|
| P2 JSON 反序列化 | 19.23 | 17.8% | 53.20 | 25.2% | 0.36 |
| P3 模板（Rust 含 context_build） | 19.45 | 18.0% | 41.16 | 19.5% | 0.47 |
| P6 msgpack 编码 | 31.02 | 28.7% | 20.68 | 9.8% | **1.50** |
| P7 msgpack 解码 | 38.57 | 35.6% | 95.74 | 45.4% | 0.40 |
| **合计** | **108.26** | **100%** | **210.77** | **100%** | **0.51** |

### 7.3 规模拐点（从这张表能看出来的部分）

| 观察 | 数据 |
|---|---|
| **P2 的斜率差最大** | 1k→8k：Rust 6.50→19.23（**2.96×**），Python 11.62→53.20（**4.58×**）⇒ **ISL 越大，Rust 的 JSON 优势越大**（比值 0.56 → 0.36） |
| **P3 不随 ISL 变** | Rust 14.89→19.45（1.31×）、Python 25.07→41.16（1.64×）⇒ 模板是常数级 + 一点分配放大 |
| **P6/P7 严格线性** | Rust 4.14→31.02、5.02→38.57；两者比值 7.5×，正好等于 payload 7.5× ⇒ 无拐点，纯搬运 |
| **P10 与 ISL 无关** | 只与帧数（OSL）相关 ⇒ **长输出场景才是 P10 的主场** |
| **Rust 唯一变差的一段** | P6 msgpack **编码**：比值从 1.30 涨到 1.50 ⇒ 这是 Rust 前端的一个**真实待优化点** |

> ⚠️ **给 docs/06 的三条限制**：
> 1. 四段合计只有 **30 µs（1k）/ 108 µs（8k）**，相对一次请求的毫秒级 TTFT
>    是**小头** ⇒ **不要用它解释端到端差异**，它的价值是"证明这几段不是瓶颈"。
> 2. P10 的 ⑤ 是**两段实测相加**（推断），且 ③ 两侧机制不同（裸 `write_all`
>    vs asyncio），**不要把 0.08× 当成生产环境的回写加速比**。
> 3. D6 是**多线程口径**，归入 P4 时要么做单线程对照，要么明确标注。

## 8. 未测清单

| 项 | 状态 | 原因 |
|---|---|---|
| **P5 lower / 校验** | 未测 | 与 `serde` 反序列化耦合在同一个 `from_slice` 调用链里，微基准切不出独立边界；要拆只能改上游代码插桩，超出本计划（不改 `vllm-rs` 源码） |
| **P9 parser（reasoning / tool）** | 未测 | 需要真实模型输出的 reasoning/tool 流才能构造有代表性的输入；mock 数据造出来的是"我编的解析成本"，不是线上的 |
| **P1 HTTP 接入** | 未测 | 属于 axum/hyper/tokio 网络栈，微基准量与 B 线的火焰图重复；E2E 才是正确口径（C 线负责） |
| **Python 侧分配次数** | 未测 | `tracemalloc` 会显著改变被测代码路径（且 30 s 窗口下样本量太大）；要测得另开一个不带计时的小基准 |
| **D3 全字段（~40 个）的 SamplingParams** | 部分 | 本基准只用 24 个字段（与 Rust 侧同款）。真实 vLLM 的 `SamplingParams` 更长 ⇒ Rust 侧"不做 omit_defaults"的膨胀被**低估** |
| **D2 多轮 / tool 结果场景** | 部分 | 只测了单轮 user + 2 tools。`tokenizer` 项目的 2 轮 + tool 结果场景是 139–216 µs（Python）⇒ 多轮时模板段会更重，本文件未覆盖 |
| **D6 单线程对照** | 部分 | 默认就是多线程（rayon 4 线程）。`RAYON_NUM_THREADS=1` 可复跑，但本文件未采 |
| **D4 hyper/tokio 真实回写** | 未测 | ③ 用裸 `write_all` / asyncio 代替 ⇒ **两侧都不是线上实现**。真实回写成本要看 B 线的火焰图或 C 线的 E2E |
| **跨装置（aarch64）复现** | 未测 | 本线全程在 x86_64；`PREPARE_INPUT_PROJECT` 的 Kunpeng 数据只作趋势对照 |
| **负载点 128 / 512 ISL** | 未测 | 计划里 D 线只要求"同尺寸对照"，选了 1k/8k 与 B 线的 B1/B2 对齐 |

## 9. 怎么复跑

```bash
cd REPO_HOME/projects/vllm/vllm-rs-wt/D-micro

# 全量（fixture → Rust → Python → 汇总），约 25 分钟 CPU，内部每步都走重活锁
harness/micro/run_micro.sh

# 只跑一个点 / 只跑一侧 / 只验流程
harness/micro/run_micro.sh --points 1k
harness/micro/run_micro.sh --only rust
harness/micro/run_micro.sh --smoke          # 每点 1 s，数字不可引用

# 单独复跑某一步（都要自己套重活锁 + limit.sh）
scripts/heavy_lock.sh scripts/limit.sh \
  harness/micro/rust/target/release/micro-bench d1 \
  --fixture harness/micro/fixtures/chat_request_1k.json --point 1k \
  --out /tmp/d1.csv --warmup 10 --sample 30

scripts/heavy_lock.sh scripts/limit.sh harness/micro/.venv/bin/python \
  harness/micro/python/micro_py.py d2 --template harness/micro/fixtures/chat_template.jinja \
  --fixture harness/micro/fixtures/chat_request_1k.json --point 1k --out /tmp/d2.csv

# 单线程 D6 对照
RAYON_NUM_THREADS=1 DMICRO_ALLOW_SHORT=1 harness/micro/rust/target/release/micro-bench d6 \
  --text data/micro/raw/rust_render_8k.txt \
  --tokenizer REPO_HOME/models/Qwen3-0.6B/tokenizer.json --point render_8k \
  --out /tmp/d6-st.csv --warmup 10 --sample 30
```

每个程序都支持 `--help`：`run_micro.sh --help`、`gen_fixtures.py --help`、
`summarize.py --help`、`setup_py_env.sh --help`、`micro_py.py --help`、
`micro-bench --help`。

## 10. 与 B 线的接口（B 线问的三条，本文件的回答）

| B 线的观察 | 本文件的证据 | 结论 |
|---|---|---|
| `serde_json` 不进 top-20，但 `[libc.so.6]` **15.20%**（其中块拷贝 **12.2%**、比较 1.7%）+ mimalloc 家族 **14.18%** | P2 只有 **6.5 µs（1k）/ 19.2 µs（8k）**，但要做 **112 / 115 次分配、19.9 KB / 94.5 KB** | **P2/P10 的成本在数据搬运与分配，不在解析算法**。火焰图上该亮的帧是 `mi_malloc*` 与块拷贝，不是 `serde_json::de`。正式矩阵的 **12.2% > 早期探针的 10.6%** ⇒ 证据比初版更强 |
| 同上 | P10 序列化 **0.54 µs**、单帧 **0.18 µs**，但整流 129 帧要 **258 次分配 / 33 KB** | 同一条结论，响应侧更极端（Python 侧整流组帧 317 µs，是 Rust 的 **13.6×**） |
| P4 段占 **6.57%**（ISL=8k 时 **41.71%**），其中 PCRE2 相关合计 **4.7%** | D6：预分词占 fastokens 全量 encode 的 **71%（1k）/ 88.7%（8k）**，纯 BPE 只有 20.7 / 39.6 µs | **那 4.7% 就是预分词正则**，不是 BPE。优化 tokenizer 应优先看正则，而不是 merge 表（两套数字口径不同源，见 §6.2） |

> **报告里不要按符号名下结论**（B 线的提醒）：本文件所有关于"成本在哪"的判断都来自
> **allocator 计数 + 两侧同输入对照**，没有一条依赖符号名。§3 的 `context_build`
> 也是按"数据是否被重新搬了一遍"定义的口径，不依赖任何函数名。
