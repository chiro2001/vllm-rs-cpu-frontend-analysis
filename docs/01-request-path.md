# 01 · 请求路径逐段分解（P1–P10）：vllm-rs 前端在 CPU 上干了什么

> **线 A（`A-path`）交付物**。分析对象：vLLM 0.26.0 自带的 Rust 前端 `vllm-rs`，
> commit `568afb3a13806beb53bb2e6bd518269357b237c0`。
>
> **行号口径（硬性）**：本文所有行号都指只读源码树
> `REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm/rust/src/`，写法为
> `server/src/routes.rs:130`（即该树下的相对路径 + 行号）。行号由 `rg`/`sed`
> 逐条回读，可用 `harness/static/check_anchors.sh` 一键复核（见 §7）。
>
> **依赖 crate**：`axum` / `hyper` / `serde_json` / `rmp-serde` / `zeromq` / `minijinja`
> 不在 `rust/src/` 树内，凡引用其源码一律加 `[dep]` 前缀并写清版本（版本取自
> `rust/Cargo.lock`），路径为本地 cargo registry 解包路径；**本地未解包的依赖**会显式写
> 「未逐行核实」。
>
> **标注约定**：
> - **【源码】** = 已在上述源码树回读确认；
> - **【引用】** = 直接引用既有项目文档（`tokenizer` / `PREPARE_INPUT_PROJECT`），未重测；
> - **【假设】** = 预期成本量级，供 B/D 线证实或证伪（本文不提供实测数字）；
> - **【推断】** = 由源码推出的结论，未做实测。
>
> **本文不含任何自测数据**：A 线按 `plan/COORDINATION.md §9` 只做静态阅读，
> 不跑 CPU 密集任务。本文出现的所有 µs 数字都来自 **【引用】**，并标注了采集装置。

---

## 0. 一分钟结论

1. **十段链路里只有一段真正跨进程**：P6（序列化下发）与 P7（反序列化回收）夹着
   ZMQ + MessagePack 的南北向边界，即前端进程 ↔ engine core 进程。**边界以北**
   （P1–P5）与**边界以南的前端侧**（P7–P10）都在同一个 `vllm-rs` 进程里。
   【源码】`engine-core-client/src/transport.rs:510-531`、`engine-core-client/src/transport.rs:535-584`
2. **前端进程内部被切成三个 tokio runtime**：HTTP/axum 运行时（轻活）、
   `vllm-request` 请求运行时（重活）与 `vllm-zmq` 传输运行时（默认 4 线程）。
   `/v1/chat/completions`、`/v1/completions`、`/tokenize`、`/detokenize`、
   `/inference/v1/generate` 五条路径被显式搬到 `vllm-request` 执行。
   【源码】`server/src/middleware/offload.rs:25-35`、`server/src/runtime.rs:17-25`、
   `engine-core-client/src/runtime.rs:45-67`
3. **P1–P5 的 CPU 工作是"解析 + 分配 + 拷贝"**：数据量随 ISL 增长的是 P2（请求体 JSON
   解析）、P3（整段正文的克隆与拼接，低常数）与 P4（分词）；P5（校验/降级）除
   `bad_words` 外是常数级字段检查。【源码】`text/src/lower.rs:33-70`、`text/src/lower.rs:182`
4. **P7–P10 的成本按"引擎 tick"而不是按 token 摊销**：P7 是**每个引擎 tick 一条
   msgpack 包**（内含多请求多 token），P8 才是逐 token 的增量解码，P9/P10 逐 delta。
   【源码】`engine-core-client/src/protocol/output.rs:144-166`、`text/src/output/decoded.rs:96-110`
5. **与 Python 前端的对照必须带三个口径标签**：Python 侧的 topdown/IPC 与
   tokenizer/模板数字是**在别的机器（Kunpeng 920B, aarch64）或别的进程（engine core 主线程）**
   上采的，跨装置、跨进程都不可直接相比（详见 §4.3 的三条警告）。

---

## 1. P1–P10 总览（一页表）

「成本量级」列是 **【假设】**，供 B/D 线证实或证伪；「Python 侧对照」列的口径见 §4.3。

| # | 段 | 主代码位置（精确行号） | CPU 上实际干的事 | 随什么变 | 成本量级【假设】 |
|---|---|---|---|---|---|
| **P1** | HTTP 接入 + middleware | `server/src/lib.rs:345-383`、`server/src/routes.rs:128-153` | `accept()` 系统调用、`TCP_NODELAY`、HTTP/1 头解析（httparse）、uuid、CORS/Vary 头改写、Prometheus 标签构造、SHA-256 鉴权 | 连接数 / 请求数（与 ISL/OSL 无关） | 单请求 **µs 级**；每连接一次 syscall + 一次任务 spawn |
| **P2** | JSON 反序列化 | `server/src/routes/openai/utils/validated_json.rs:32-43`、`server/src/routes/openai/chat_completions/types.rs:29` | 请求体 → `ChatCompletionRequest`：UTF-8 校验 + 扫描 + 逐字段 `String`/`Vec` 分配；随后 `normalize()` + `validate()` | **ISL**（正文长度）、消息条数 | **O(ISL)，非严格线性**（工具调用/多轮有额外分配） |
| **P3** | chat 模板渲染 | `chat/src/lib.rs:188`、`chat/src/renderer/hf/mod.rs:162-223`、`chat/src/renderer/hf/template.rs:124-127` | 内部消息 → 模板可序列化结构（**克隆整段正文**）、拼 minijinja 上下文、渲染进 `String`；tools 走 `tojson` 过滤器 | 消息条数 / tools 体积 + **prompt 正文字节数（低常数拷贝）** | **低常数、近似常数级**（【引用】Python Jinja 渲染 63/69/63 µs @220/1k/8k） |
| **P4** | 分词 | `text/src/lib.rs:143-148`、`tokenizer/src/hf.rs:144-158` | 渲染后的字符串 → BPE/unigram 合并 → `Vec<u32>` | **ISL** | 【引用】x86 **≈1.47 µs/token** |
| **P5** | lower / 校验 | `server/src/routes/openai/chat_completions/convert.rs:64-186`、`text/src/lower.rs:33-70`、`text/src/lower.rs:74-191` | 字段级校验（模型名、logprobs 上界、vocab 范围）、`ChatRequest`/`TextRequest` 组装、stop-id `BTreeSet`、`bad_words` 逐词分词 | 常数 + `bad_words` 词数 | **常数级**（<10 µs 量级，【假设】） |
| **P6** | 序列化下发 | `llm/src/lib.rs:82-118`、`engine-core-client/src/client.rs:473-522`、`engine-core-client/src/client/imp.rs:214-240`、`engine-core-client/src/transport.rs:510-531` | `EngineCoreRequest` → msgpack（`rmp_serde::to_vec_named`）→ 3 帧 ZMQ 消息 → loopback TCP 写 | 请求数 + **ISL**（prompt token 数组） | **O(ISL)** 序列化 + 1 次写 syscall + 1 次任务 spawn |
| **P7** | 响应反序列化 | `engine-core-client/src/transport.rs:535-584`、`engine-core-client/src/protocol/output.rs:350-359`、`engine-core-client/src/client/imp.rs:346-390` | 每个引擎 tick 收一条 ZMQ 包 → msgpack → `EngineCoreOutputs` → 按 `request_id` 分发到各请求的 mpsc | **引擎 tick 数 × 每 tick 输出数** | 每 tick 一次解码；高并发下 amortize 好 |
| **P8** | 增量解码 | `text/src/output/decoded.rs:96-110`、`text/src/output/decoded.rs:176-199`、`tokenizer/src/incremental.rs:127-165` | 每个新 token 追加进 id 缓冲 → 重新 `decode()` → 与旧前缀做差 → 产出新字符串片段 | **OSL** | 【引用】x86 **1.39–1.59 µs/token**（另有首步 216–292 µs） |
| **P9** | parser（reasoning / tool） | `chat/src/lib.rs:181-187`、`chat/src/output/default/mod.rs:46-99`、`chat/src/output/default/unified.rs:217-...`、`chat/src/output/structured.rs:255-...` | 解析器构造（按模型名匹配）+ 逐 delta 状态机扫描；工具调用要缓冲 JSON 片段 | **OSL** × 解析器族 | 【假设】每 delta **亚 µs～数 µs**，高度依赖解析器族 |
| **P10** | JSON 序列化 + 回写 | `server/src/routes/openai/chat_completions.rs:238-...`、`server/src/routes/openai/chat_completions.rs:630-669`、`server/src/routes/openai/completions.rs:568-584` | 每个 chunk `serde_json::to_string` → SSE `Event` → hyper 编码 → socket 写 | **OSL**（chunk 数） | 【假设】每 chunk **µs 级**：序列化 + 1 次写 syscall |

---

## 2. 逐段分解

### 2.1 P1 —— HTTP 接入与 middleware

**调用链（全部在 `vllm-rs` HTTP 运行时上）**

```
serve_with_router_extension (server/src/lib.rs:158)
  └─ Listener::bind            (server/src/lib.rs:182 → server/src/listener.rs:56-64)
  └─ build_router              (server/src/lib.rs:187 → server/src/routes.rs:49)
  └─ serve_connections         (server/src/lib.rs:345-383)
       ├─ listener.accept()          server/src/lib.rs:357-360
       ├─ TowerToHyperService::new   server/src/lib.rs:362-364（把 axum Router 接进 hyper）
       ├─ http1::Builder + header_read_timeout + keep_alive
       │                             server/src/lib.rs:365-369
       ├─ builder.serve_connection   server/src/lib.rs:370
       └─ tokio::spawn(connection)   server/src/lib.rs:373-377（每连接一个任务）
```

**CPU 上实际干的活（逐条）**

| 位置 | 工作 | 说明 |
|---|---|---|
| `server/src/listener.rs:135-149` | `accept()` + 每个 TCP 连接设 `TCP_NODELAY` | `enable_tcp_nodelay` 在 `server/src/listener.rs:123-128`；**每个新连接一次 `setsockopt` 系统调用** |
| `server/src/listener.rs:78-97` | 继承 fd 时 `listen()` + `set_nonblocking()` | 只在 `frontend` 模式（Python 监管）走这条；`serve` 模式走 `bind` |
| `[dep] hyper-1.10.1/src/proto/h1/role.rs:67` | HTTP/1 头解析 `parse_headers` | 底层落到 `httparse::parse_headers`（`[dep] hyper-1.10.1/src/proto/h1/decode.rs:649`）。**依赖源码**，非本仓库代码 |
| `server/src/routes.rs:128-153` | middleware 组装 | 顺序注释见 `server/src/routes.rs:147-149`：「后加的 layer 包在外面」 |
| `server/src/routes.rs:33`、`:130` | 请求体上限 32 MiB | `DefaultBodyLimit::max(32 * 1024 * 1024)` |
| `server/src/middleware/request_id.rs:18-26` | 缺 `X-Request-Id` 时生成 uuid4 hex | 请求里带 header 则只做一次 clone；否则 `Uuid::new_v4()` + 格式化 |
| `server/src/middleware/cors.rs:56-122`、`:130-144` | CORS 头构造；无 `Origin` 时删除 6 个头 | 纯 header 层工作，常数级 |
| `server/src/middleware/metrics.rs:34-71` | 计时 + Prometheus 计数/直方图 | `handler`/`method` 每次 `.to_string()`（`server/src/middleware/metrics.rs:35-39`），`get_or_create` 带 label 池查找（`server/src/middleware/metrics.rs:54-68`） |
| `server/src/middleware/load.rs:43-71` | 命中 18 条受跟踪路径时原子加/减 | 表在 `server/src/middleware/load.rs:21-40`；用 `Weak<AppState>` + body guard 保证流式响应结束才减 |
| `server/src/middleware/auth.rs:22-40`、`:46-66` | Bearer 鉴权：**每个请求一次 SHA-256** + 常数时间比较 | `hash_api_key` 在 `server/src/state.rs:26-28`；`GUARDED_PREFIXES` = `/v1`、`/v2`、`/inference`（`server/src/middleware/auth.rs:16`）。仅在配置了 api key 时挂载（`server/src/routes.rs:140-145`） |
| `server/src/middleware/offload.rs:71-93` | **把重活请求 spawn 到 request runtime** | 路径表 `server/src/middleware/offload.rs:25-35`；`AbortOnDropHandle` + `oneshot` 等待结果。⚠️ "P1 的 middleware 在 HTTP runtime、P2 起在 request runtime"这一分工依据的是 `server/src/routes.rs:147-149` 的排序注释，**axum 0.8.8 的 layer 语义源码本机未解包 ⇒ 标【推断】** |

**与 Python 前端的结构差异【源码 + 推断】**：Python 侧是 uvicorn/Starlette 单事件循环 +
`asyncio`，CPU 重的前处理与事件循环共享线程；Rust 侧用**两个 runtime 物理隔离**
（`vllm-request` / `vllm-zmq`）。这是"能不能把前端摊到多核"的结构性差异，
是否真的带来吞吐收益由 C 线判定，**本文不做结论**。

---

### 2.2 P2 —— JSON 反序列化

**调用链**

```
chat_completions handler  (server/src/routes/openai/chat_completions.rs:50-54)
  └─ ValidatedJson<ChatCompletionRequest> 提取器
       └─ ValidatedJson::from_request  (server/src/routes/openai/utils/validated_json.rs:32-43)
            ├─ Json::<T>::from_request    validated_json.rs:33   ← 依赖 axum 的 Json 抽取器
            ├─ data.normalize()           validated_json.rs:37
            └─ data.validate()            validated_json.rs:39   ← validator crate 的派生实现
```

**CPU 上实际干的活**

1. **body 缓冲**：`DefaultBodyLimit`（`server/src/routes.rs:33,130`）允许到 32 MiB，
   body 由 axum/hyper 读进内存（`Bytes`），这里有一次 **网络读 + 缓冲**。
   （这一步在 offload layer 内层 ⇒ **跑在 request runtime 上**；同 §2.1 的【推断】口径。）
2. **JSON 解析**：`Json::<T>::from_request`（`validated_json.rs:33`）内部调用
   `serde_json::from_slice`（`[dep] serde_json-1.0.149/src/de.rs:2657`）。
   ⚠️ **口径**：axum 0.8.8 的源码在本机未解包，
   「`Json` 抽取器 = 缓冲 body + `serde_json::from_slice`」这一条标
   **【推断】（依赖行为，未逐行核实）**；能被证伪的地方：若 axum 换成流式解析，
   P2 的"先缓冲再解析"描述就要改。
3. **结构体填充**：`ChatCompletionRequest`（`server/src/routes/openai/chat_completions/types.rs:29`）
   的 `messages: Vec<ChatMessage>`、每条的 `content` 都是 **owned `String`**，
   因此解析过程对 prompt 正文**至少做一次分配 + 一次拷贝**（JSON 转义字符还要解码）。
4. **归一化**：`Normalizable::normalize`（`server/src/routes/openai/chat_completions/types.rs:315-325`）把 `max_tokens`
   迁移到 `max_completion_tokens`、补 `tool_choice` 默认值——常数级。
5. **字段校验**：`validator` 派生（`server/src/routes/openai/chat_completions/types.rs:29` 上的 `#[derive(Validate)]`、行级
    `#[validate(...)]`）在 `validated_json.rs:39` 触发——常数级字段检查 + schema 函数。

**为什么它可能是 P1–P5 里最大的 memcpy 大户【推断】**：prompt 正文在
「socket 缓冲 → `Bytes` → `String`」这条路上被搬运≥2 次，且分配是逐消息、逐 content 的
（不是一次性 arena）。**量级待 D1（`serde_json` vs `json.loads`）与 B 线火焰图证实**。

**Python 侧对应物**：FastAPI/pydantic 走 `json.loads` + 模型构造，
同样是 owned-str 语义；两边的**算法同阶**，差别在解释器开销而非解析算法（见 §4.3）。

---

### 2.3 P3 —— chat 模板渲染（minijinja）

**调用链**

```
ChatLlm::chat                (chat/src/lib.rs:175-226)
  ├─ request.validate()                                    chat/src/lib.rs:176
  ├─ backend.new_chat_output_processor(...)                chat/src/lib.rs:181-187  ← P9 的解析器在这里构造
  ├─ backend.chat_renderer().render(&request)              chat/src/lib.rs:188
  │    └─ HfChatRenderer::apply_chat_template              chat/src/renderer/hf/mod.rs:144-160
  │         └─ apply_chat_template_inner                   chat/src/renderer/hf/mod.rs:162-223
  │              ├─ to_template_messages                   chat/src/renderer/hf/mod.rs:167-171
  │              ├─ to_template_tools                      chat/src/renderer/hf/mod.rs:184
  │              ├─ effective_template_kwargs               chat/src/renderer/mod.rs:50-71
  │              └─ CompiledChatTemplate::apply             chat/src/renderer/hf/template.rs:124-127
  └─ multimodal::finalize_rendered_prompt                   chat/src/lib.rs:198-204
```

**CPU 上实际干的活**

| 位置 | 工作 | 成本形状 |
|---|---|---|
| `chat/src/renderer/hf/mod.rs:167-171` → `:453-470` | 内部消息 → `TemplateMessage`：**逐 content 块克隆文本**（`to_template_string_content` 里 `text.clone()` / `out.push_str`） | O(prompt 正文)，**每个 chat 请求必然发生** |
| `chat/src/renderer/hf/mod.rs:374-400` | assistant 历史里的 tool_call 参数要 `serde_json::from_str` 再转模板值 | O(历史 tool 参数) |
| `chat/src/renderer/hf/mod.rs:184`、`:559-575` | tools 列表 → `TemplateTool`，`parameters` 经 `to_template_value` 深拷贝 JSON（`to_template_tools` 在 `:559`） | O(tools 体积) |
| `chat/src/renderer/hf/value.rs:18-34` | JSON → `minijinja::Value`：对象走 `TemplateMap(IndexMap)`，**深拷贝** | O(tools 体积) |
| `chat/src/renderer/mod.rs:50-71` | 默认 kwargs `clone()` + extend + reasoning_effort 注入 | O(kwargs) |
| `chat/src/renderer/hf/template.rs:124-127` | `Environment::get_template("chat")` + `render(ctx)` —— 模板**只编译一次**（`template.rs:109-120`，启动期在 `server/src/lib.rs:92-104` 的 `load_model_backends` 里完成） | 渲染本身 O(输出文本) |
| `chat/src/renderer/hf/template.rs:29-41` | `build_environment`：`set_trim_blocks`/`lstrip_blocks`、`add_filter("tojson", …)`、pycompat 回调 | **启动期一次性** |
| `chat/src/renderer/hf/tojson.rs:18-54` | `tojson` 过滤器：kwargs 解析 + `sort_json_keys` + `serde_json_fmt` 序列化 | 模板里每次 `tojson` 一处 |

**两个容易漏掉的成本点【源码】**

1. **请求级模板覆盖**：请求体里带 `chat_template` 时，**每个请求都要重新编译一次模板**
   （`chat/src/renderer/hf/mod.rs:145-153`，`CompiledChatTemplate::new` → `build_environment`）。
   默认路径不触发；一旦触发就是**每请求一次的 jinja 编译**。
2. **`continue_final_message`**：走"渲染完再截断"（`chat/src/renderer/hf/mod.rs:177-182`、`:207-212`），
   渲染量不变但多一次字符串扫描。

**Python 侧对照【引用】**：Python 的 `apply_chat_template(tokenize=False)`（Jinja2）
实测 **50–69 µs 且与 ISL 无关**（单轮；含 tool 结果的两轮 139–216 µs）——
见 `tokenizer/docs/02-cost-and-share.md:205`、`tokenizer/docs/00-INDEX.md:26`。
**注意口径**：该数字是 x86_64 开发机、Python 3.12 + Jinja2 的实测，
而 Rust 侧本文**没有任何实测**；两者不可直接相减，只能作为"常数级"这一形状的对照。

---

### 2.4 P4 —— 分词（**直接引用 `tokenizer` 项目结论，不重测**）

**调用链**

```
ChatLlm::chat                       chat/src/lib.rs:188   （渲染出 Prompt::Text）
  └─ TextLlm::generate              text/src/lib.rs:118-130
       └─ generate_inner            text/src/lib.rs:132-171
            ├─ request.validate()              text/src/lib.rs:136
            ├─ tokenizer.encode(&text, …)      text/src/lib.rs:143-148   ← P4 本体
            ├─ backend.sampling_hints()        text/src/lib.rs:150
            └─ lower_text_request(...)         text/src/lib.rs:158-167   ← P5
```

**实现落点（Rust 侧）**

| 位置 | 工作 |
|---|---|
| `text/src/backend/hf/mod.rs:24-30` | `load_tokenizer`：`vllm-text` 唯一的 tokenizer 构造分发点 |
| `tokenizer/src/lib.rs:24-26` | `Tokenizer::encode(&self, text, add_special_tokens) -> Vec<u32>` trait 定义 |
| `tokenizer/src/hf.rs:128-141` | **先试 fastokens，失败回落 HuggingFace tokenizers**（`new_fastokens` 在 `:111-116`） |
| `tokenizer/src/hf.rs:144-158` | `encode` 的 backend 分发（`Backend::Fastokens \| FastokensByteLevel \| Hf`） |
| `tokenizer/src/hf.rs:85-103` | fastokens 后端选择：decoder 是纯 byte-level 时走 `FastokensByteLevel` 旁路 |

**CPU 语义【源码】**：把渲染后的整段 prompt 送进 BPE/unigram 合并器，输出 `Vec<u32>`；
**分配** = 输出数组 + 合并过程中的临时结构；正常路径**不做磁盘/网络 IO**
（大块分配器可能走 `mmap`，这是分配器行为，不是本段的显式 IO）。成本随 ISL 线性。

**已有结论（直接引用，本文不重测）【引用】**

| 指标 | 数值 | 出处 |
|---|---|---|
| `tokenizer: encode`（completion 路径，x86 2 核） | @220 tok **286 µs** / @1k **1 100 µs** / @8k **10 537 µs**；边际 **≈1.47 µs/token**（R²=0.99975） | `tokenizer/docs/00-INDEX.md:24`、`tokenizer/docs/06-conclusions.md:54` |
| 同上，线性区间 | 128–8k 严格线性；**<64 token 有 25–45 µs 固定成本**（线性外推会给负数） | `tokenizer/docs/02-cost-and-share.md:12`、`:121` |

⚠️ **两条口径提醒**（来自 tokenizer 项目，引用时不要弄丢）：
1. **chat 请求永远不会触发 Python 侧的 `tokenizer: encode` scope**——chat 的编码发生在
   `apply_chat_template(tokenize=True)` 内部，被 `render_messages` 包住；两个 scope 是
   **互补负载**，不能相加（`tokenizer/docs/00-INDEX.md:36-40`）。
2. **Rust 侧默认 backend 是 fastokens 优先**，与 Python 默认的 HF `tokenizers` 不是同一实现；
   「1.47 µs/token」是 **Python + HF tokenizers** 的数字，**不能当作 Rust 侧的值**
   （`tokenizer/docs/00-INDEX.md:44-50`：fastokens 本身在 Python 侧也有 9.3–13.5× encode 加速）。
   ⇒ **Rust 前端的 P4 到底多少 µs/token，本文不给数，标「未测」**，交给 D5/B 线。

---

### 2.5 P5 —— lower / 校验（prompt 组装与参数降级）

**调用链（两处，分别属于 chat 语义层与 text 层）**

```
server 路由层（P5 前一半）
  server/src/routes/openai/chat_completions/convert.rs:64   prepare_chat_request
    ├─ 同文件:69        validate_request_compat
    ├─ 同文件:82        convert_message × N
    ├─ 同文件:83,187    normalize_generation_prompt_mode
    └─ 同文件:115-168   ChatRequest { … }

text 层（P5 后一半）
  text/src/lib.rs:132                 TextLlm::generate_inner
    ├─ text/src/request.rs:221-229    TextRequest::validate
    └─ text/src/lower.rs:33-70        lower_text_request
         └─ text/src/lower.rs:74-191  lower_sampling_params
```

**CPU 上实际干的活**

| 位置 | 工作 | 成本形状 |
|---|---|---|
| `server/src/routes/openai/chat_completions/validate.rs:9-12` | 入口兼容性校验（模型名、`stream_options`、`n`、`top_logprobs` 等） | 常数级字段比较 |
| `server/src/routes/openai/chat_completions/validate.rs:51-62` | tools / message-local tools 的函数名校验 | O(#tools) 小常数 |
| `server/src/routes/openai/chat_completions/validate.rs:74-79` | 显式拒绝"能反序列化但未实现"的参数（`length_penalty` 等） | 常数级 |
| `server/src/routes/openai/chat_completions/convert.rs:82`、`:234` | `ChatMessage` → `VllmChatMessage`：**content 文本克隆**、parts 逐块转换 | **O(prompt 正文)** |
| `server/src/routes/openai/chat_completions/convert.rs:110-113` | `convert_from_response_format`（结构化输出参数转换） | O(schema) |
| `server/src/routes/openai/chat_completions/convert.rs:135-144` | `logit_bias` 的字符串 key → `u32`；`kv/ec` 传输参数 `serde_json::to_value` | O(#bias) |
| `chat/src/request.rs:517` | `ChatRequest::validate`（消息非空、角色顺序、tool_choice 一致性） | 常数级 + O(#messages) |
| `text/src/request.rs:221-229` | `TextRequest::validate`（只有 token-id 形态的空 prompt 检查） | 常数级 |
| `text/src/lower.rs:41` | `validate_prompt_token_ids`（长度 vs `max_model_len`、vocab 范围） | **O(ISL)**（扫一遍 token ids；`lower/token_ids.rs`） |
| `text/src/lower.rs:116-122` | `validate_logprobs` / `validate_repetition_detection` | 常数级 |
| `text/src/lower.rs:151-160` | stop token id 组装成 `BTreeSet`（排序插入，O(n log n)） | O(#stop_ids) |
| `text/src/lower.rs:182` | **`bad_words` 逐词调用 tokenizer.encode** | **O(#bad_words × 词长)**，用户可控 |
| `text/src/lower.rs:189` | `validate_vocab_range`（`allowed_token_ids`/`logit_bias` 与 vocab 对齐） | O(#ids log #ids) |

**注意【源码】**：`structured_outputs` 的 schema/regex **在此处不做校验**——
源码里是 `// TODO: Validate structured-output schemas and regexes before submitting requests
to engine-core.`（`text/src/lower.rs:183-184`）。也就是说这部分 CPU 成本被推到了 engine core。

**Python 侧对照**：Python 的 `SamplingParams.__post_init__` 与
`to_sampling_params` 做同类校验；`PREPARE_INPUT_PROJECT` 项目量的是 engine core 内的
`prepare_input` 段，**不是前端这一段**，因此**没有可直接对位的数字**（标「未测」）。

---

### 2.6 P6 —— 序列化下发（msgpack + ZMQ，**南北向边界前端侧**）

**调用链**

```
TextLlm::generate_inner            text/src/lib.rs:169
  └─ Llm::generate                 llm/src/lib.rs:82-118
       ├─ GenerateRequest::prepare            llm/src/request.rs:63-116
       │    └─ EngineCoreRequest { …20 字段… } llm/src/request.rs:91-114
       └─ EngineCoreClient::call              engine-core-client/src/client.rs:473-522
            ├─ register_request(...)                    engine-core-client/src/client.rs:487-488
            └─ ClientInner::send_to_engine              client/imp.rs:214-240
                 ├─ encode_msgpack(payload)             client/imp.rs:225
                 │    └─ rmp_serde::to_vec_named        protocol/mod.rs:43
                 └─ (spawn 到 ZMQ runtime)              client/imp.rs:229-239
                      └─ transport::send_message        transport.rs:510-531
                           └─ RouterSendHalf::send      transport.rs:529
```

**CPU 上实际干的活（逐条）**

| 位置 | 工作 | 成本形状 |
|---|---|---|
| `llm/src/request.rs:84-89` | 生成内部 request id（`Uuid::new_v4()` + 截断，**每请求一次**） | 常数级 |
| `llm/src/request.rs:91-114` | 组装 `EngineCoreRequest`（含 `prompt_token_ids: Some(Vec<u32>)` **所有权转移，无拷贝**） | 常数级 |
| `engine-core-client/src/client.rs:473-488` | `client_index` 改写、`validate()`（仅拒绝 `prompt_embeds`）、注册请求路由表（`register_request` 在 `engine-core-client/src/client.rs:487-488`） | 常数级（注册表是锁 + map） |
| `engine-core-client/src/client/imp.rs:225` | **msgpack 序列化**：`rmp_serde::to_vec_named`（`[dep] rmp-serde-1.3.1/src/encode.rs:1243`；实现是 `Vec::new()` 后边写边增长，**不是**预计算长度，见 `:1243-1251`），`EngineCoreRequest` 是 **20 元素定长数组**（`protocol/request.rs:73` 的 `Serialize_tuple`；测试 `protocol/request.rs:150-177` 断言 `array.len() == 20`） | **O(ISL)**：per-token 4 字节 + 每字段头部；输出缓冲从 `Vec::new()` 增长，**可能发生若干次 realloc**（摊还线性） |
| `engine-core-client/src/client/imp.rs:229-239` | `handle.spawn(...)` + `oneshot` 等待：**跨 runtime 的任务调度**（ZMQ runtime 默认 4 线程，`engine-core-client/src/runtime.rs:45-67`） | 常数级但含**上下文切换** |
| `engine-core-client/src/transport.rs:517-529` | 组 3 帧 `ZmqMessage` `[engine_id, request_type(1 字节), payload]` → `RouterSendHalf::send`（`[dep] zeromq-0.6.0/src/router.rs:176`） | 帧头拷贝 + **写 syscall** |
| `engine-core-client/src/transport.rs:371-389` | 输入/输出 socket 绑在 **loopback TCP**（`tcp://host:0`） | 边界是**真实 socket**，两侧都有内核收发成本 |

**边界定义**：`EngineCoreRequestType::Add = 0`（`protocol/request.rs:23-28`），
`to_frame()` 就是单字节 `b"\x00"`（`protocol/request.rs:49-56`）。
**所以"南北向边界"的物理形态 = loopback TCP + ZMQ 多帧 + MessagePack**，
与 Python 前端和 engine core 之间的协议**完全一致**（Python 侧同样是 ZMQ + msgpack）。

**预期成本量级【假设】**：序列化本身应≤ P2 的反序列化（**同阶、更少分配**），
1k token 的 prompt 对应 payload ≈ 4 KB 量级；真正的固定项是
**每请求一次 spawn + 一次 syscall**。这两种成本在低并发下会被放大、在高并发下被摊薄——
由 C 线（A/B）与 B 线（火焰图）判定。

---

### 2.7 P7 —— 响应反序列化（msgpack → 结构体 → 分流到请求）

**调用链（全部在 `vllm-zmq` runtime 上，除最后一步）**

```
transport::run_output_loop            engine-core-client/src/transport.rs:535-584
  ├─ output_socket.recv()                          transport.rs:540         ← ZMQ 收包
  ├─ ENGINE_CORE_DEAD 哨兵检查                      transport.rs:557-561
  ├─ decode_engine_core_outputs(&frames)           transport.rs:562
  │    └─ decode_msgpack::<EngineCoreOutputs>      protocol/output.rs:356
  │         └─ rmp_serde::from_slice               protocol/mod.rs:66
  └─ tx.send(decoded)  （mpsc，容量 64）            transport.rs:576-582
       └─ run_output_dispatcher_loop               client/imp.rs:346-407
            ├─ take_senders_for_outputs(...)       client/imp.rs:363
            └─ 按 request_id 投递到每请求 channel     client/imp.rs:376-379
                 └─ EngineCoreOutputStream::poll_next  client/stream.rs:84-88
                      └─ GenerateOutputStream::poll_next llm/src/output.rs:250-291
```

**CPU 上实际干的活**

| 位置 | 工作 | 成本形状 |
|---|---|---|
| `engine-core-client/src/transport.rs:540` | 一次 `recv()`（ZMQ/loopback TCP） | 每 tick 一次 syscall + 帧拷贝 |
| `engine-core-client/src/protocol/output.rs:356` | **一次 msgpack 解码**：`WireEngineCoreOutputs`（`protocol/output.rs:144-166`）里含 `outputs: Vec<EngineCoreOutput>`，**一个 tick 内多请求多 token 全在一条包里** | **每 tick 一次**，与并发/批量相关，**不是每 token 一次** |
| `engine-core-client/src/protocol/output.rs:125-136` | aux 帧解析：logprobs 等大字段走附加帧（`resolve_in_place`） | 仅当请求要 logprobs |
| `engine-core-client/src/client.rs:287` | `mpsc::channel(64)` | 常数级 |
| `engine-core-client/src/client/imp.rs:346-407` | 按 `request_id` 查注册表、逐个投递、更新 scheduler stats / LoRA 状态 | O(本 tick 输出数) |
| `llm/src/output.rs:250-291` | `EngineCoreOutput` → `GenerateOutput`：**`raw.new_token_ids` 直接移动**、算 `cached_token_count`、映射 finish_reason | 常数级 + 移动 |

**【推断】P7 的摊销特性**：解码成本按"引擎 tick"计，而 tick 里可能包含几十个请求的输出，
所以在高并发下 P7 的**每请求**成本会被摊薄；反过来在**单请求低并发**下，
每 tick 只服务一个请求，P7 的相对占比会升高。这一点值得 B 线在 c=1 与 c=64 两个点位对比。

**Python 侧对照**：Python `vllm/v1/engine/core_client.py` 侧同样是 ZMQ + msgpack 反序列化，
且 **engine core 侧**还有一份对称的序列化成本；本计划只算前端侧（`plan/COORDINATION.md §5.2`）。

---

### 2.8 P8 —— 增量解码（**直接引用 `tokenizer` 项目结论，不重测**）

**调用链**

```
TextLlm::generate                     text/src/lib.rs:118-130
  └─ output::decoded_text_event_stream text/src/output/decoded.rs:96-110
       ├─ 首个输出：create_decode_stream(prompt_token_ids, …)
       │                              text/src/output/decoded.rs:121-139
       │    └─ Tokenizer::create_decode_stream   tokenizer/src/lib.rs:54-66
       ├─ 逐 token：decoder.push_token(token_id)  text/src/output/decoded.rs:177
       │    └─ DecodeStream::push_token           tokenizer/src/incremental.rs:128
       │         └─ tokenizer.decode(&ids)        tokenizer/src/incremental.rs:135
       ├─ 逐 token：decoder.next_chunk()          text/src/output/decoded.rs:194
       │    └─ DecodeStream::next_chunk           tokenizer/src/incremental.rs:149
       └─ 终局：decoder.flush(truncate)           text/src/output/decoded.rs:239
```

**CPU 上实际干的活**

1. **每个新 token 都要重新 `decode()` 一遍 id 缓冲**（`tokenizer/src/incremental.rs:135`），
   然后与上一次的前缀比对得出新增文本（`:136-146`）。**缓冲是滑动窗口**：每次成功吐出
   文本后 `self.ids.drain(..self.prefix_index)`（`:143`）只保留尚未解码的尾巴，
   再对新尾巴重算 `prefix`（`:144-145`）——所以稳态下**每 token 的 decode 输入是短尾巴**，
   不是整段输出（否则会退化成 O(OSL²)）。**风险点**：连续多个 token 都不产生可见文本时
   （多字节 UTF-8 / CJK 跨 token、或长 stop 串缓冲）尾巴会变长，单步成本随之上升。
2. **prompt 只做一次短上下文裁剪**：`seed_prefix`（`tokenizer/src/incremental.rs:102-124`）与
   `SAFE_SUFFIX_MIN/MAX = 4/6`（`:67-68`）决定只用 prompt 的 4–6 个 token 作左上下文，
   避免把整个 prompt 拖进每步解码。
3. **停止串判定**：每个 token 后可能要检查 `stop_strings`（`text/src/output/decoded.rs:174-192`、
   `:309`）。不设 stop 串时走 `min_bytes_to_buffer` 分支（`:127-137`），成本更低。
4. **字符串分配**：每段可见文本要么 `push_str` 到已有缓冲，要么新建 `String`
   （`text/src/output/decoded.rs:194-199`）——chunk 越碎，分配次数越多。

⚠️ **runtime 归属【源码】**：P8 的驱动者是"谁在 poll 输出流"。流式响应时是
**HTTP runtime 的连接任务**（SSE body poll，`server/src/middleware/offload.rs:75-79`），
非流式时是 **request runtime** 上的 `collect_*`。⇒ **同一个模型、同一段代码，
`stream=true/false` 会跑在不同线程上**，B 线归类时必须分开。

**已有结论（直接引用，本文不重测）【引用】**

| 指标 | 数值 | 出处 |
|---|---|---|
| `detokenize: stream`（生成期增量解码，x86） | **1.39–1.59 µs/token**，另加**首步 216–292 µs** | `tokenizer/docs/00-INDEX.md:29`、`tokenizer/docs/02-cost-and-share.md:245` |

⚠️ **口径**：该值同为 Python 侧 HF tokenizers 的数字；Rust 侧 `DecodeStream` 是
**自己写的旁路**（`tokenizer/docs/00-INDEX.md:44-50` 指出 decode 的 8× 提速来自 Rust 侧旁路而非
fastokens 引擎）。**Rust 前端 P8 的实际 µs/token 本文不给数，标「未测」**，交 D5/B 线。

---

### 2.9 P9 —— parser（reasoning / tool 解析）

**调用链**

```
ChatLlm::chat                                  chat/src/lib.rs:175-226
  ├─ backend.new_chat_output_processor(...)    chat/src/lib.rs:181-187   ← 每请求构造解析器
  │    └─ DefaultChatOutputProcessor::new      chat/src/output/default/mod.rs:46-87
  │         ├─ resolve_optional_unified_parser / resolve_tool_parser
  │         │                                  chat/src/output/default/mod.rs:101-140
  │         ├─ apply_structural_tag_constraint chat/src/output/default/mod.rs:77
  │         └─ preserve_special_tokens → decode_options 改写
  │                                            chat/src/output/default/mod.rs:79-81
  └─ output_processor.process(decoded_stream)  chat/src/lib.rs:223
       └─ structured_chat_event_stream         chat/src/output/structured.rs:255-…
            └─ unified_event_stream            chat/src/output/default/unified.rs:217-…
                 └─ UnifiedParserState::process_delta
                                            chat/src/output/default/unified.rs:66-100
                      └─ UnifiedParser::parse_into
                                            parser/src/unified/mod.rs:185
```

**CPU 上实际干的活**

| 位置 | 工作 | 成本形状 |
|---|---|---|
| `chat/src/output/default/mod.rs:101-140` | 按 **模型名子串匹配** 选解析器（`ParserFactory::resolve_name_for_model`，`chat/src/parser/mod.rs:86-92`），再 `Box` 分配一个解析器实例 | **每请求一次**，常数级 |
| `parser/src/unified/mod.rs:27-38`、`parser/src/tool/mod.rs:54-77` | 事件/输出的中间结构（`Vec<ToolParserEvent>` 等） | 每 delta 分配 |
| `parser/src/utils.rs:21`、`:53` | `partial_prefix_len` / `safe_text_len`：**在缓冲里找部分分隔符前缀**（避免把 `</thi` 这种半截标记吐出去） | O(缓冲长度) |
| `parser/src/utils.rs:115-135`、`:182-209`、`:298-307` | `MarkerScanState` / `JsonObjectScanState` / `JsonStringScanState`：扫描状态机（逐字节/逐字符） | O(delta) 线性扫描 |
| `chat/src/output/structured.rs:65-76` | 组装状态（开文本块/开工具调用/索引） | 常数级 |

**成本形状【源码 + 推断】**：解析器是**纯字符串扫描 + 状态机**，没有正则回溯的结构——
`parser` crate 的依赖里**没有 `regex`**（`parser/Cargo.toml:10-18`，只有
`winnow` / `xgrammar-structural-tag` 等；对整个 `rust/src` 的 `*.toml` 搜 `regex` 零命中），
匹配逻辑是 `parser/src/utils.rs` 里的手写扫描器 + `winnow` 的 `Partial`/`ModalResult`；
成本随 **OSL** 增长，且**解析器族之间差异可能很大**（例如 tool 解析器要缓冲并
逐字符找 JSON 边界）。这一段的绝对值**本文不给数**，标「未测」，建议 B 线按
「有 tools / 无 tools」两个点位对比火焰图。

---

### 2.10 P10 —— JSON 序列化与回写（SSE / 整包）

**调用链**

```
chat_completions                          server/src/routes/openai/chat_completions.rs:50-110
  ├─ stream=true：
  │    chat_completion_chunk_stream(...)            同文件:238-…
  │      └─ chat_completion_sse_stream(...)         同文件:630-669
  │           ├─ serde_json::to_string(chunk)       同文件:653
  │           ├─ Event::default().data(payload)     同文件:655
  │           └─ Event::default().data("[DONE]")    同文件:669
  │      ⇒ Sse::new(sse_stream).into_response()     同文件:91
  └─ stream=false：
       collect_chat_completion(...)                 同文件:112-235
         └─ Json(response).into_response()          同文件:108
```

同一形状在 `/v1/completions`：`server/src/routes/openai/completions.rs:90-119`、
`server/src/routes/openai/completions.rs:568-584`。

**CPU 上实际干的活**

| 位置 | 工作 | 成本形状 |
|---|---|---|
| `server/src/routes/openai/chat_completions.rs:653` | **每个 chunk 一次 `serde_json::to_string`**（`[dep] serde_json-1.0.149/src/ser.rs:2245`） | O(chunk 大小)，**每次分配一个 `String`** |
| `server/src/routes/openai/chat_completions/types.rs:394`、`:422`、`:434` | `ChatCompletionStreamResponse` → choice → delta 的嵌套结构（`#[serde(skip_serializing_none)]`） | 序列化只写非 `None` 字段 |
| `server/src/routes/openai/chat_completions.rs:655` | `Event::default().data(payload)`：SSE 帧封装（`data: …\n\n`） | 一次拼接 |
| `server/src/routes/openai/chat_completions.rs:669` | 终止帧 `[DONE]` | 常数 |
| `server/src/routes/openai/chat_completions.rs:108` | 非流式：`Json(response)`（一次性序列化整个响应） | O(响应大小)，**一次分配** |
| `server/src/error.rs:41-60` | 错误路径的 `to_error_response()` → OpenAI 风格错误体 | 仅错误时 |
| `[dep] hyper-1.10.1/src/proto/h1/encode.rs:128` | SSE 帧 → HTTP/1 chunked 编码（`encode`） | 每帧一次 |
| `server/src/listener.rs:140`（同 P1） | 连接建立时已设 `TCP_NODELAY` | 保证小 chunk 不被 Nagle 合并 |

**【推断】P10 的两种形态差别很大**：
- 流式：**每个 chunk 都是"序列化 + 一次写 syscall"**，chunk 越碎，syscall 越多；
- 非流式：一次大序列化 + 一次写。
所以 `OSL` 越大、`stream=true` 时 P10 的 syscall 次数越接近 `OSL`。
**这是预期，不是实测**；B 线火焰图与 D4 微基准负责证实/证伪。

⚠️ **runtime 归属（同 P8）**：`stream=true` 时 chunk 生成（含 `serde_json::to_string`）
发生在 **HTTP runtime** 的 SSE body poll 里；`stream=false` 时发生在 **request runtime**
的 `collect_chat_completion` 里。⇒ 压测时若只绑 HTTP 线程组或只绑 request 线程组，
会把 P8–P10 或 P2–P5 排掉——**绑核必须覆盖该进程的全部 tokio worker 线程**
（或明确记录"只绑了哪一组"）。

---

## 3. 调用图：进程边界、runtime 边界与南北向边界（A3）

### 3.1 进程与 runtime 拓扑

```
┌─ 压测/客户端进程（本计划口径外，但必须单独记录其 CPU：plan/COORDINATION.md §5.1）─┐
└───────────────────────────────┬─────────────────────────────────────────────────┘
                                │ HTTP/1.1 over TCP（或 UDS / inherited fd）
┌─ vllm-rs 进程（= 本计划的分析对象）────────────────────────────────────────────┐
│                                                                               │
│  ┌─ HTTP runtime（tokio multi-thread，hyper 连接任务）──────────────────────┐  │
│  │  P1  accept / header 解析 / middleware（auth·cors·metrics·load·uuid）    │  │
│  │  ↑ 响应侧：Sse/Json 的 body **在 HTTP runtime 上被 poll 出去**            │  │
│  │         （offload.rs:76-79 注释明写）                                    │  │
│  └───────────────┬─────────────────────────────────────────────────────────┘  │
│                  │ request_runtime_layer：命中 OFFLOADED_PATHS 时 spawn         │
│                  ▼                                                             │
│  ┌─ vllm-request runtime（默认 = min(可用核数, 32) 线程）───────────────────┐  │
│  │  P2 JSON 反序列化（body 缓冲 + serde_json）                             │  │
│  │  P3 chat 模板渲染（minijinja，模板启动期编译）                            │  │
│  │  P4 分词（fastokens 优先 / HF 回落）                                     │  │
│  │  P5 lower / 校验                                                        │  │
│  │  P6 ⓐ msgpack 编码 + ⓑ ZMQ 发送（spawn 到 ZMQ runtime）                  │  │
│  └───────────────┬─────────────────────────────────────────────────────────┘  │
│                  ▼                                                             │
│  ┌─ vllm-zmq runtime（默认 4 线程）────────────────────────────────────────┐  │
│  │  P6 ⓑ transport::send_message → RouterSocket.send()                     │  │
│  │  P7 ⓐ transport::run_output_loop ← PullSocket.recv()                    │  │
│  │  P7 ⓑ msgpack 解码 → run_output_dispatcher_loop → 每请求 mpsc            │  │
│  └───────────────┬─────────────────────────────────────────────────────────┘  │
│                  │                                                             │
│  ┌─ 响应后半段（**默认在 HTTP runtime 上跑**）──────────────────────────────┐  │
│  │  P8 增量解码（DecodeStream，逐 token）                                   │  │
│  │  P9 parser（reasoning / tool 状态机）                                    │  │
│  │  P10 chunk → JSON → SSE 帧                                              │  │
│  │  ⚠️ 流式响应：这些工作在 hyper 连接任务里被 SSE body poll 驱动，           │  │
│  │     而连接任务属于 HTTP runtime（offload.rs:75-79 原文）；                 │  │
│  │     非流式（stream=false）：`collect_*` 在 handler 内 await ⇒ request rt。 │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────┬───────────────────────────────────────────────┘
                                │
        ═══════════ 南北向边界（P6/P7 之间）═══════════
        ZMQ over loopback TCP：ROUTER(入) + PULL(出)
        body = MessagePack（rmp-serde）
        帧 = [engine_id] [request_type(1B)] [payload]  （出方向）
        ═══════════════════════════════════════════════
                                │
┌─ engine core 进程（Python；**本计划不分析其内部**）─────────────────────────────┐
│  调度 / forward / sample / grammar(engine 侧 structured output)               │
└───────────────────────────────────────────────────────────────────────────────┘
```

**边界要点（A3 要求的标注）**

1. **HTTP/前端进程边界**：在 P1 与 P2 之间——北向是 HTTP/1.1 + JSON，由 axum/hyper 处理
   （`server/src/lib.rs:362-370`）。
2. **南北向边界（ZMQ + msgpack）**：在 P6 与 P7 之间——出方向
   `engine-core-client/src/transport.rs:510-531`，入方向
   `engine-core-client/src/transport.rs:535-584`；协议本体在
   `engine-core-client/src/protocol/mod.rs:39-75`。
3. **`vllm-rs` 进程内部的 runtime 边界**：HTTP runtime / `vllm-request` runtime /
   `vllm-zmq` runtime 三层（`server/src/middleware/offload.rs:71-93`、
   `server/src/runtime.rs:17-25`、`engine-core-client/src/runtime.rs:45-67`）。
   **这三层之间的切换是纯进程内调度，不产生 syscall，但会产生任务唤醒与跨线程迁移。**
4. **⚠️ 响应段（P8–P10）的 runtime 归属取决于是否流式**——这一点源码里有明确注释
   （`server/src/middleware/offload.rs:75-79`：「For streaming HTTP responses, the response
   body is still polled on the HTTP runtime」）：
   - `stream=true`：SSE body 由 **HTTP runtime 的连接任务** poll ⇒ P8/P9/P10 在 **HTTP runtime** 上执行；
   - `stream=false`：`collect_chat_completion`（`server/src/routes/openai/chat_completions.rs:112-235`）
     在 handler 内被 await ⇒ 这三段在 **request runtime** 上执行。
   **B 线按线程归类火焰图时必须区分这两种形态**，否则会把响应段算到错误的一侧。

### 3.2 单请求时序（以 `POST /v1/chat/completions`, `stream=true` 为例）

```
client ──HTTP──▶ [HTTP rt] P1 middleware ──spawn──▶ [request rt] P2 解析 JSON
                                                    P3 render → P4 encode → P5 lower
                                                    P6 msgpack → ──spawn──▶ [zmq rt] send
════════════════════════════ 边界 ═══════════════════════════════════════════════
[zmq rt] recv ◀── P7 decode ──▶ dispatch ──mpsc──▶ 请求输出流（每请求 channel）
                                                          │
[HTTP rt] SSE body 被连接任务 poll ◀────────────────────────┘
    └─ P8 decode 增量 → P9 parse → P10 chunk→JSON→SSE 帧 ──▶ client
    （非流式时，这一串改在 [request rt] 的 collect_* 里跑完再一次性返回）
```

> **关于这张图的确定性**：
> - 「请求体解析/渲染/分词/下发在 `vllm-request`、ZMQ 收发在 `vllm-zmq`」是【源码】，
>   依据 `server/src/middleware/offload.rs:71-93`、`engine-core-client/src/client/imp.rs:229-239`；
> - 「流式响应的 P8–P10 在 HTTP runtime」也是【源码】，依据
>   `server/src/middleware/offload.rs:75-79` 的注释原文；
> - 但**每一次 `await` 具体落在哪个 worker 线程**（tokio 多线程 runtime 会在
>   worker 之间迁移任务）本文没有实测，标 **【推断】**——这正是 B 线火焰图/线程视图
>   能补上的信息（例如 `perf` 里看线程名 `vllm-request` / `vllm-zmq-*` / 主线程各自的自耗）。

---

## 4. 与 Python 前端逐段对照（A2）

**Python 侧代码位置与环节划分直接引用** `tokenizer/docs/01-code-logic.md:27-45`（当代 Python 前端
1–8 环节的边界表），**不重新测量**；数据引用 `tokenizer/docs/00-INDEX.md`、
`tokenizer/docs/02-cost-and-share.md`、`tokenizer/docs/06-conclusions.md` 与
`PREPARE_INPUT_PROJECT/docs/00-INDEX.md`、`05-hotspots.md`。

### 4.1 逐段对照表

| P | Rust 侧（本文核实） | Python 侧对应环节（引用） | Python 侧数字（引用） | 可比性标注 |
|---|---|---|---|---|
| P1 | `server/src/lib.rs:345-383`、`server/src/routes.rs:128-153` | HTTP 入口 `vllm/entrypoints/openai/chat_completion/api_router.py:40`；鉴权 `server_utils.py:45`（`tokenizer/docs/01-code-logic.md:31-33`） | 无独立数字 | **不可比**：装置不同（x86 dev vs Kunpeng 920B），且 Python 侧 topdown 采的是 **engine core 线程**（见 §4.3 警告） |
| P2 | `server/src/routes/openai/utils/validated_json.rs:32-43` | FastAPI/pydantic 解析请求体（不在 tokenizer 项目的 8 环节里） | **无** | **未测**：Python 侧没有对应数字 |
| P3 | `chat/src/lib.rs:188`、`chat/src/renderer/hf/mod.rs:162-223` | 环节 4「chat 模板渲染（Jinja）」`vllm/renderers/online_renderer.py:95` → `vllm/renderers/base.py:1070` → `vllm/renderers/hf.py:929` / `:986` / `:778` | **Jinja 渲染 63/69/63 µs（220/1k/8k，常数级）**；`render_messages` 整体（含模板内 encode）1 015/2 075/12 231 µs | **同装置内可比**：均为 x86_64 + Python 3.12；**跨语言不可直接相减**（Rust 侧未测） |
| P4 | `text/src/lib.rs:143-148`、`tokenizer/src/hf.rs:144-158` | 环节 5「编码 encode」`vllm/renderers/base.py:471` `_tokenize_prompt` → `:481`；chat 请求走模板内 encode | **≈1.47 µs/token**（286 µs@220 / 1 100@1k / 10 537@8k，R²=0.99975）；<64 token 有 25–45 µs 固定成本 | **同装置内可比**；但 Python 侧默认 HF `tokenizers`、Rust 侧默认 fastokens ⇒ **实现不同，不可直接当"Rust 更快"的证据** |
| P5 | `server/src/routes/openai/chat_completions/convert.rs:64-186`、`text/src/lower.rs:33-191` | Python `SamplingParams` 校验 / `to_sampling_params`（**不在 tokenizer 项目 8 环节内**） | **无** | **未测** |
| P6 | `llm/src/lib.rs:82-118`、`engine-core-client/src/client/imp.rs:214-240`、`transport.rs:510-531` | 环节 6「请求下发（IPC）」`vllm/v1/engine/async_llm.py:280` → `EngineCoreRequest`(`vllm/v1/engine/__init__.py:88`) → ZMQ(`vllm/v1/engine/core_client.py:518`) + msgpack(`vllm/v1/serial_utils.py:136`)（`tokenizer/docs/01-code-logic.md:36`） | 无独立数字 | **结构可比、数字未测**：两边都是 ZMQ+msgpack，DTO 字段一致 |
| P7 | `engine-core-client/src/transport.rs:535-584`、`protocol/output.rs:350-359` | 环节 8 的上游：engine core → 前端输出（`vllm/v1/engine/output_processor.py:653`，`tokenizer/docs/01-code-logic.md:38`） | 无独立数字 | **未测** |
| P8 | `text/src/output/decoded.rs:96-110`、`tokenizer/src/incremental.rs:127-165` | 环节 8「流式解码 + 停止串判定」`output_processor.py:653 → detokenizer.py:95 update()`；`:131` 调 `check_stop_strings`（`:309`） | **1.39–1.59 µs/token**，首步 216–292 µs | **同装置内可比**；Rust 侧是自写 `DecodeStream`（不同实现）⇒ 只能比"形状" |
| P9 | `chat/src/lib.rs:223`、`chat/src/output/default/unified.rs:217-…` | Python 侧对应 reasoning/tool parser（在 engine core 或 serving 层；tokenizer 项目**未覆盖**） | **无** | **未测**（`PREPARE_INPUT_PROJECT` 也未覆盖 parser） |
| P10 | `server/src/routes/openai/chat_completions.rs:630-669` | 无直接对应（Python 侧是 FastAPI StreamingResponse + `json.dumps`） | **无** | **未测** |

### 4.2 `PREPARE_INPUT_PROJECT` 项目的数字怎么用（只能用在对的地方）

| 数字 | 它的真实含义（引用原文） | 本计划里能怎么用 |
|---|---|---|
| `frontend_bound 66.01%`（其中 `frontend_latency 59.89%`） | **Kunpeng 920B / aarch64 / REMOTE_HOST** 上，**engine-core 主线程**在 `prepare input` scope 内的 topdown L1（`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:247`、`:265-270`） | 作为「**CPython 逐条派发**」这一形态的**间接**证据；**不能**当作"Python API server 前端"的数字 |
| `retiring 12.85%`、`bad_spec 11.03%`、`backend_bound 10.11%` | 同上，同一次采集 | 同上 |
| `IPC 0.7708` | 同上（`INST_RETIRED / CPU_CYCLES`，`05-hotspots.md:265-270`） | **IPC 是唯一跨装置相对可比的量**（`plan/COORDINATION.md §5.4`）；Rust 侧的 IPC 由 B 线采，前提是**同一台机器**才做正面对比 |
| top-10 火焰图极平（合 22.83%）、`_PyEval_EvalFrameDefault` 10.35%、`_PyType_Lookup` 1.67% 等 | 同上（`PREPARE_INPUT_PROJECT/docs/00-INDEX.md:22-33`） | 「热点极平 = 无单点可砍」这一**形状**的对照；Rust 侧的形状由 B 线给 |

### 4.3 ⚠️ 三条必须随数字一起搬运的口径警告

1. **装置不同**：Python 侧 topdown/IPC 采自 **Kunpeng 920B（aarch64，REMOTE_HOST，Ascend 环境）**；
   tokenizer/模板 µs 采自 **x86_64 开发机**——两组数字之间**不可比**，
   本文分列列出，不做任何跨组换算。
2. **进程不同**：`frontend_bound/IPC` 是 **engine-core 主线程**的指标
   （`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:11-14` 的"目标线程"一行），
   而 P1–P10 描述的是 **`vllm-rs` 前端进程**。把二者当成"同一个前端的前后对比"是错的。
3. **实现不同**：Python 侧 tokenizer 默认 HF `tokenizers`（fastokens 需显式开关），
   Rust 侧默认 fastokens 优先（`tokenizer/src/hf.rs:128-141`）。
   引用 1.47 µs/token 时**必须**带上"Python + HF tokenizers"这个限定。

---

## 5. 每段预期成本量级假设（A5，供 B/D 线证实或证伪）

> **本表全部是【假设】**。写法遵循"可证伪"：给出**预期形状 + 预期主导项 + 证伪判据**。
> 没有一条是实测数字；实测由 B 线（火焰图/硬件计数）与 D 线（微基准）填。

| # | 预期主导项 | 预期形状（随 ISL/OSL/并发） | 预期量级【假设】 | 证伪判据（B/D 线怎么推翻它） |
|---|---|---|---|---|
| **P1** | 每请求的固定 middleware + 每连接 syscall | 与 ISL/OSL 无关；随 **QPS** 线性 | 单请求 **µs 级**（<10 µs 量级） | 若火焰图里 P1 的自耗占比随 ISL 增长，或 auth 的 SHA-256 成为 top-20 ⇒ 假设错 |
| **P2** | `serde_json` 解析 + `String` 分配 | **随 ISL 增长**；多轮/带 tools 时额外增长 | 1k token prompt：**数十 µs 量级**（与 1.47 µs/token 的 encode 同阶或更低） | D1 微基准：同尺寸 body 上 `serde_json` vs Python `json.loads`；若 Rust 侧反而更慢 ⇒ 假设错 |
| **P3** | 消息克隆 + minijinja 渲染 + tools `tojson` | 拷贝量线性于 prompt 字节数但**常数很小**；随消息条数/tools 体积增长 | 单轮无 tools：**数十 µs 量级**；带 tools 深拷贝时上浮 | D2：minijinja vs Jinja2 同模板同 tools；若斜率接近 P4（≈1.47 µs/token）⇒ 假设错（说明每 token 都在做重活） |
| **P4** | tokenizer 编解码器本身 | **线性于 ISL** | 1.47 µs/token 是 **Python + HF tokenizers** 的数；Rust 侧**未测**，【假设】≤ 该值 | D5 不做（按计划不重测）；若 B 线火焰图显示 encode 的 self-time 占比超过 P2 ⇒ 需重新评估 |
| **P5** | 字段校验 + `bad_words` 分词 | 常数级；`bad_words` 多时线性 | **<10 µs**（无 `bad_words`） | 若火焰图里出现 `validate_*` 显著占比 ⇒ 假设错 |
| **P6** | msgpack 编码 + spawn + 写 syscall | 编码 **O(ISL)**；spawn/syscall 每请求固定 | 1k token：编码 **数 µs～十几 µs**；固定项 **数 µs** | D3：`rmp-serde` vs Python msgpack 同结构；若 P6 在火焰图上不可见 ⇒ 预期偏高 |
| **P7** | 每 tick 一次 msgpack 解码 | 随**引擎 tick 频率 × 每 tick 输出数**；高并发摊薄 | 单请求 c=1：**每 tick 数 µs～数十 µs**（要看模型解码速度） | B 线 c=1 vs c=64 对比：若 P7 占比**不随并发下降** ⇒ 假设错 |
| **P8** | `DecodeStream` 每 token 对"未解码尾巴"重解码 | **线性于 OSL**（滑动窗口：每步 `drain` 已消费 id，见 `tokenizer/src/incremental.rs:143-145`；连续无可见文本时才退化） | Python 侧 1.39–1.59 µs/token；Rust 侧**未测** | B 线 B3（OSL=512）里若 `incremental`/`decode` 帧不在 top-20 ⇒ 预期偏高 |
| **P9** | 逐 delta 状态机扫描 | 线性于 OSL；解析器族差异大 | 每 delta **亚 µs～数 µs** | 若 B3 火焰图里 parser 帧占比 > P8 ⇒ 假设偏低（`parser/src/utils.rs` 扫描器是热点） |
| **P10** | 每 chunk 序列化 + 写 syscall | 线性于 **chunk 数**（≈ OSL，流式） | 每 chunk **µs 级** | D4：`serde_json::to_string` 同尺寸 + 假 SSE；若 P10 在火焰图上不可见 ⇒ 预期偏高 |

**跨段假设（需要 B 线验证的"形状"命题）**

| # | 假设 | 证伪判据 |
|---|---|---|
| S1 | 「P1–P5 的合计成本**随 ISL 增长的部分主要来自 P2 与 P4**（P3 的正文拷贝是低常数项）」 | B2（ISL=8k）火焰图里若无 P2/P4 相关帧领先 ⇒ 假设错 |
| S2 | 「P8–P10 的合计成本随 **OSL** 增长，且是流式响应下的主要前端成本」 | B3（OSL=512）与 B1（OSL=128）对比，若无明显抬升 ⇒ 假设错 |
| S3 | 「高并发下热点从"每请求固定成本"转向'调度/锁/syscall'" | B4（c=64）与 B1（c=1）对比，若热点分布不变 ⇒ 假设错 |
| S4 | 「runtime 间的跨线程调度（P1→P2 offload、P6 spawn 到 ZMQ、P7→请求流、流式响应回 HTTP rt）本身**可忽略**」 | 火焰图里若 `tokio`/`spawn`/`wake`/`park` 帧显著，或线程视图显示大量迁移 ⇒ 假设错 |
| S5 | 「`stream=true` 与 `stream=false` 的热点形状不同（前者 P8–P10 在 HTTP rt，后者在 request rt），但**总量接近**」 | 同一负载点分别跑 stream/non-stream，若两者总量差异大 ⇒ 假设错（说明 runtime 归属本身有成本） |

---

## 6. 未测 / 未覆盖（诚实清单）

### 6.1 本文（A 线）明确没做的事

| 项 | 状态 | 原因 |
|---|---|---|
| 任何端到端/逐段**实测**数字 | **未测** | A 线是静态分析；按 `plan/COORDINATION.md §9` 不在共享开发机上跑 CPU 密集任务 |
| Rust 侧 P4 分词 µs/token | **未测** | 按计划直接引用 `tokenizer` 项目结论（Python 侧）；Rust 侧 fastokens 的数字只在 D5/B 线补齐 |
| Rust 侧 P8 增量解码 µs/token | **未测** | 同上；Rust `DecodeStream` 是自写实现，不能套用 Python 数字 |
| P2 的 `serde_json` 具体实现路径（axum 内部） | **部分/推断** | axum 0.8.8 源码在本机 cargo registry **未解包**，`Json::from_request` 的内部行为标【推断】 |
| P9 parser 的绝对成本 | **未测** | 需要火焰图（B 线）或定点微基准（D 线，当前矩阵未列 P9） |
| 多模态 / LoRA / gRPC 路径 | **未覆盖** | 计划明确不做（`plan/EXECUTION.md §9`）；本文只在路由表里记了一句存在性 |
| prompt logprobs、structured outputs 的 CPU 成本 | **未覆盖** | 与 ISL/OSL 的耦合不同；`text/src/lower.rs:183-184` 还有 TODO 说明校验被推迟到 engine core |
| 非 chat/completion 的其它端点（`/tokenize`、`/detokenize`、`/inference/v1/generate`） | **部分** | 已给出代码位置与 handler（`server/src/routes/tokenize.rs:53-82`、`server/src/routes/inference/generate.rs:43`），但未逐段展开（它们不经过 P3/P9） |
| `/metrics`、`/health`、`/load` 等运维端点 | **未覆盖** | 不在推理请求路径上（`server/src/routes.rs:76-89`） |
| engine core 内部（调度/forward/sample/grammar） | **不覆盖** | 计划边界之外（`plan/EXECUTION.md §2.2`） |
| 启动期成本（模板编译、tokenizer 加载、ZMQ 握手） | **未覆盖** | 属启动路径；本文只在 P3 里指出"模板只在启动期编译一次" |
| 真实并发下的锁竞争（LoRA manager、metrics） | **未测** | 需要 B4 高并发点位 |

### 6.2 明确不做的（与 `plan/EXECUTION.md §9` 对齐）

| 不做 | 原因 |
|---|---|
| 不碰 NPU、不做需要卡的实验 | 本计划纯 CPU；前端路径不需要设备 |
| 不做 LoRA / 多模态 / 分布式（DP/EP）/ gRPC 深挖 | 与"CPU 负载"主题弱相关；只记录存在性 |
| 不做 engine core 内部（调度/forward/sample） | 另一个课题（`PREPARE_INPUT_PROJECT` 已覆盖一部分） |
| 不重做 tokenizer 六后端 | `tokenizer` 项目已完成，直接引用 |
| 不改 `vllm-rs` 上游代码 | 本计划是观测与分析，不是优化实现 |

---

## 7. 如何复核本文（可复现性）

```bash
# 在 A 线 worktree 里执行（不需要编译、不占 CPU）
cd REPO_HOME/projects/vllm/vllm-rs-wt/A-path
harness/static/check_anchors.sh --help
harness/static/check_anchors.sh                       # 默认校验 docs/01-request-path.md
harness/static/check_anchors.sh -q docs/01-request-path.md   # 只看问题
```

脚本会：

1. 从文档里抽出所有 `路径.rs:行号` 锚点；
2. 在只读源码树里逐条回读该行内容并打印（`-q` 只打印问题）；
3. 报告三类问题：`NOT-FOUND`（路径不存在）、`OUT-OF-RANGE`（行号越界）、
   `AMBIGUOUS`（同名文件多个候选，需要写全路径）。

**当前状态**（2026-09-25 提交时，只扫本文档）：`anchors checked: 268, problems: 0`
（268 个锚点全部可回读；连同 `agents/A-path/REPORT.md` 一起扫是 284 个，同样 0 问题）。

**源码树版本**：`REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm` @
`568afb3a13806beb53bb2e6bd518269357b237c0`（vLLM 0.26.0）。
若上游换 commit，行号会漂移——脚本是唯一权威的复核手段。

**依赖锚点**（`[dep]`）解析规则：在 `~/.cargo/registry/src/*/<包名-版本>/...` 下查找，
版本取 `rust/Cargo.lock`（`axum 0.8.8`、`hyper 1.10.1`、`serde_json 1.0.149`、
`rmp-serde 1.3.1`、`zeromq 0.6.0`、`minijinja 2.18.0`）。
其中 **axum 与 minijinja 本机未解包**，涉及它们的描述一律标【推断】。

---

## 附录 A：文件索引（哪个文件承担哪几段）

| 文件 | 承担的段 | 备注 |
|---|---|---|
| `server/src/lib.rs` | P1 | 启动、listener、每连接任务（`serve_connections`） |
| `server/src/listener.rs` | P1 | TCP/UDS 统一 listener + `TCP_NODELAY` |
| `server/src/routes.rs` | P1 | 路由表 + middleware 栈组装 |
| `server/src/middleware/*.rs` | P1 | auth / cors / metrics / load / request_id / offload |
| `server/src/routes/openai/utils/validated_json.rs` | P2 | 校验型 JSON 抽取器 |
| `server/src/routes/openai/chat_completions/types.rs` | P2、P10 | 请求/响应 DTO（含 `normalize`） |
| `server/src/routes/openai/chat_completions/convert.rs` | P5 | 请求降级到 `ChatRequest` |
| `server/src/routes/openai/chat_completions/validate.rs` | P5 | 兼容性校验 |
| `server/src/routes/openai/chat_completions.rs` | P10 | chat handler / chunk 流 / SSE |
| `server/src/routes/openai/completions.rs` | P10 | completions 同形状 |
| `server/src/routes/tokenize.rs` | （旁路） | `/tokenize`、`/detokenize`，不经过 P3/P9 |
| `server/src/routes/inference/generate.rs` | （旁路） | `/inference/v1/generate` |
| `server/src/runtime.rs` | P1 | `vllm-request` runtime 构造 |
| `chat/src/lib.rs` | P3、P4、P9 | `ChatLlm::chat` 编排 |
| `chat/src/renderer/hf/{mod,template,tojson,value}.rs` | P3 | minijinja 模板渲染全链 |
| `chat/src/output/default/{mod,unified}.rs` | P9 | 解析器构造与驱动 |
| `chat/src/output/structured.rs` | P9 | 结构化事件组装成 `ChatEvent` |
| `chat/src/parser/{mod,reasoning,tool}.rs` | P9 | 解析器注册表与选择 |
| `parser/src/**` | P9 | 20+ 解析器实现（扫描器在 `parser/src/utils.rs`） |
| `text/src/lib.rs` | P4、P5 | `TextLlm` 编排（encode → lower → 下发） |
| `text/src/request.rs` | P5 | `TextRequest` 与最小校验 |
| `text/src/lower.rs`、`text/src/lower/*.rs` | P5 | 采样参数降级与校验 |
| `text/src/output/decoded.rs` | P8 | 增量解码事件流 + 停止串 |
| `tokenizer/src/{lib,hf,incremental}.rs` | P4、P8 | tokenizer trait / 后端 / `DecodeStream` |
| `llm/src/{lib,request,output}.rs` | P5、P6、P7 | token-in/token-out 门面与引擎 DTO |
| `engine-core-client/src/client.rs`、`client/{imp,stream,state}.rs` | P6、P7 | 客户端 API / 发送 / 分发 / 每请求流 |
| `engine-core-client/src/transport.rs` | P6、P7 | ZMQ 收发与握手 |
| `engine-core-client/src/protocol/{mod,request,output}.rs` | P6、P7 | msgpack 编解码与 DTO |
| `engine-core-client/src/runtime.rs` | P6、P7 | `vllm-zmq` runtime |

**依赖（不在 `rust/src/` 树内，标 `[dep]`）**：`axum 0.8.8`（HTTP 框架/抽取器/SSE）、
`hyper 1.10.1`（HTTP/1 编解码）、`serde_json 1.0.149`（JSON 编解码）、
`rmp-serde 1.3.1`（MessagePack）、`zeromq 0.6.0`（ZMQ 传输）、`minijinja 2.18.0`（模板引擎）。
