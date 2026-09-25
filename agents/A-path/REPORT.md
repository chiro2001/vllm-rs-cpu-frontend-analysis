# A 线（A-path）交接报告 —— P1–P10 链路静态分解

> 分支：`agent/A-path`（worktree `REPO_HOME/projects/vllm/vllm-rs-wt/A-path`）
> 完成日期：2026-09-25（Asia/Shanghai）
> 源码口径：vLLM 0.26.0，commit `568afb3a13806beb53bb2e6bd518269357b237c0`，
> 只读源码树 `REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm/rust/src/`
> 本线**未跑任何 CPU 密集任务**（无编译、无压测、无 perf），只做 `rg`/`sed` 静态回读。

## 1. 交付物与状态

| 交付物 | 状态 | 说明 |
|---|---|---|
| `docs/01-request-path.md` | ✅ 完成（757 行） | P1–P10 逐段分解 + 调用图（A3）+ Python 对照（A2）+ 成本假设（A5）+ 未测清单 |
| `harness/static/check_anchors.sh` | ✅ 完成（含 `--help`） | 把文档里所有 `文件.rs:行号` 锚点在源码树上逐条回读，三类问题（NOT-FOUND / OUT-OF-RANGE / AMBIGUOUS） |
| `agents/A-path/REPORT.md` | ✅ 本文件 | |

**当前自检结果**：`anchors checked: 284, problems: 0`
（`harness/static/check_anchors.sh -q docs/01-request-path.md agents/A-path/REPORT.md`；
只扫 `docs/01-request-path.md` 是 268 个）。

## 2. 关键结论（3 条）

1. **南北向边界只有一处，且前端进程内有三个 tokio runtime。**
   P6（msgpack 编码 + ZMQ 发送）与 P7（ZMQ 收包 + msgpack 解码）夹住进程边界
   （`engine-core-client/src/transport.rs:510-531` / `:535-584`，协议
   `engine-core-client/src/protocol/mod.rs:39-75`）；前端进程内部则是
   **HTTP runtime → `vllm-request` runtime（5 条重路径被显式 offload）→ `vllm-zmq` runtime（默认 4 线程）**
   三层（`server/src/middleware/offload.rs:25-35`、`server/src/runtime.rs:17-25`、
   `engine-core-client/src/runtime.rs:45-67`）。**B 线按进程采 perf 时会同时采到这三组线程**，
   归类火焰图时不要把它们混成一个 "HTTP" 段。
   **更关键的是**：`stream=true` 时 P8–P10 由 SSE body poll 驱动、跑在 **HTTP runtime**；
   `stream=false` 时它们跑在 **request runtime**（依据 `server/src/middleware/offload.rs:75-79`
   的原文注释）。⇒ 同一个模型、同样的代码，**流式与非流式的热点归属线程不同**。

2. **「按 tick 摊销」与「按 token 摊销」的分界在 P8。**
   P7 的 msgpack 解码是**每个引擎 tick 一次**（一包里含多请求多 token，
   `engine-core-client/src/protocol/output.rs:144-166`），P9/P10 则是逐 delta / 逐 chunk；
   只有 **P8 是真正逐 token** 的（`text/src/output/decoded.rs:96-110`、
   `tokenizer/src/incremental.rs:127-165`，且用滑动窗口 `drain` 控制单步成本）。
   ⇒ 单请求低并发时，P7 的相对占比会被放大；高并发时被摊薄。这是 B 线 c=1 vs c=64 最值得看的对比。

3. **Python 侧基线数字必须先纠口径再引用。**（本线独立发现，建议写进 `docs/03`）
   `PREPARE_INPUT_PROJECT` 的 `frontend_bound 66.01% / IPC 0.7708` 采的是
   **Kunpeng 920B（aarch64）上 engine-core 主线程**在 `prepare input` scope 内的 topdown
   （`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:11-14`、`:247`、`:265-270`），
   **不是 Python API server 前端进程**；而 tokenizer/模板的 µs 数字采自 **x86_64 开发机**。
   两组数字之间、以及它们与 Rust 侧之间，都不能直接相减。
   唯一跨装置相对可比的量是 **IPC**（`plan/COORDINATION.md §5.4`）。

## 3. 失败路径与踩坑（给后续线省时间）

| # | 坑 | 现象 | 处理 / 建议 |
|---|---|---|---|
| 1 | **把 engine core 的 topdown 当成"Python 前端"** | 计划 `EXECUTION.md §1` 表述为 "Python 前端的热点是 CPython 逐条派发：frontend_bound 66.01%…"；但源文档的目标线程是 **engine-core 主线程** | 文档 §4.2/§4.3 已按源文档纠口径；**B/C 线引用时务必同样标注**，否则 `docs/03` 会出现"跨进程对比"的硬伤 |
| 2 | **依赖源码本机未解包** | `axum 0.8.8`、`minijinja 2.18.0` 在 `~/.cargo/registry/src/*` 下**不存在**；`hyper 1.10.1`、`serde_json 1.0.149`、`rmp-serde 1.3.1`、`zeromq 0.6.0` 有 | 有源码的标 `[dep]` 并给行号；没有的（axum/minijinja 内部行为）一律标【推断】，已写进未测表 |
| 3 | **行号简写会毁掉可复核性** | 文档里写 `listener.rs:56`、`chat_completions/convert.rs` 这类短名时，源码树里有 2–11 个同名文件，人工回读会指错 | `check_anchors.sh` 对短名做"唯一后缀匹配"，歧义即报 `AMBIGUOUS`；正式表格里全部改成完整相对路径 |
| 4 | **凭印象写"O(OSL²)"会错** | 初稿把 P8 的 `DecodeStream` 写成"每 token 重解码整段 ⇒ O(OSL²)" | 回读 `tokenizer/src/incremental.rs:143-145` 发现每步 `ids.drain(..prefix_index)` + 重算 prefix，**是滑动窗口**；已改正。**这正是"行号必须回读"的价值** |
| 5 | **`rmp_serde::to_vec_named` 不是预计算长度** | 初稿写"一次分配" | 回读 `[dep] rmp-serde-1.3.1/src/encode.rs:1243-1251`：`FallibleWriter(Vec::new())` 边写边增长，可能多次 realloc；已改正 |
| 6 | **`parser` crate 不是正则实现** | 直觉会以为 tool/reasoning parser 用正则 | 全 workspace `*.toml` 搜 `regex` **零命中**；`parser` 依赖是 `winnow` + 手写扫描器（`parser/src/utils.rs`）；已写进 §2.9 |
| 7 | **两条"隐藏成本"容易漏** | ① 请求体带 `chat_template` 时**每请求重新编译模板**（`chat/src/renderer/hf/mod.rs:145-153`）；② `bad_words` 逐词调用 tokenizer（`text/src/lower.rs:182`） | 已单独列在 §2.3 与 §2.5；若压测里出现这两类请求，热点形状会变 |
| 8 | **`structured_outputs` 的校验被 TODO 推迟** | `text/src/lower.rs:183-184` 明写 TODO | P5 的"常数级"结论对 **schema 复杂的请求不成立**（成本转移到 engine core）；已写进未测表 |
| 9 | **响应段（P8–P10）的 runtime 归属容易想当然** | 初稿把 P8–P10 都画在 request runtime；回读 `server/src/middleware/offload.rs:75-79` 发现**流式响应的 body 仍在 HTTP runtime 被 poll** | 已在 §3.1/§3.2/§2.8/§2.10 标注，并加假设 S5。**B 线绑核时要覆盖该进程全部 tokio worker 线程**，否则会把一半段排掉 |

## 4. 交给 B / C / D 线的具体钩子

**B 线（火焰图）**

- 文档 §2 每段都给了"主代码位置"，可作为**帧 → P1–P10 的归类映射**起点；
  特别注意 P7 的解码发生在 `vllm-zmq` 线程、P8–P10 在请求任务上，**线程名不同**。
- 建议点位：c=1 vs c=64 看 **P7/P1 的摊销**（假设 S3）；ISL=8k 看 **P2/P4 谁领先**（假设 S1）；
  OSL=512 看 **P8/P9/P10 的排序**（假设 S2）。
- 假设 S4（runtime 跨线程调度可忽略）最容易被推翻：直接看 `tokio`/`wake`/`spawn` 帧占比。

**C 线（A/B 对照）**

- Rust 侧**没有 LiteProfiler 等价物**（`plan/EXECUTION.md §3.3` 已记），逐段成本只能靠
  perf + 外部计时 ⇒ 若需要"每段一个数"，请与 D 线合做定点微基准，不要指望火焰图给出 µs。
- 对照组注意：Python 侧 chat 请求的 encode 被 `render_messages` 包住
  （`tokenizer/docs/00-INDEX.md:36-40`），**不能**把 `tokenizer: encode` 与
  `render_messages` 相加后再和 Rust 比。

**D 线（微基准）**

- 与本线假设一一对应：D1↔P2、D2↔P3、D3↔P6/P7、D4↔P10。
  **P9（parser）当前实验矩阵里没有基准**，若时间允许建议补一个"同一段带 tool 调用的文本过 `CombinedParser`"的点。
- 建议每个基准都报"每请求固定项 + 每 token 斜率"，这样能直接与本线 §5 的形状判据对齐。

## 5. 未做到 / 未覆盖（如实）

| 项 | 说明 |
|---|---|
| **没有任何实测数字** | A 线只做静态分析；§5 全部标【假设】，等待 B/D 证实或证伪 |
| Rust 侧 P4/P8 的 µs/token | 按计划直接引用 `tokenizer` 项目（Python 侧）的结论，Rust 侧标「未测」 |
| P2/P5/P9/P10 的 Python 侧对照数字 | Python 侧本就没有对应测量（tokenizer 项目的 8 环节不含这几段），全部标「无 / 未测」 |
| `/tokenize`、`/detokenize`、`/inference/v1/generate` 的逐段展开 | 只给了 handler 与代码位置（它们不经过 P3/P9），未逐段列表 |
| 多模态 / LoRA / gRPC / engine core 内部 | 按 `plan/EXECUTION.md §9` 明确不做，只在路由与 DTO 层面记了存在性 |
| 启动期成本（模板编译、tokenizer 加载、ZMQ 握手） | 未覆盖（只在 P3 指出模板是启动期编译） |
| 真实并发下的锁竞争 | 未测，需 B4 点位 |

## 6. 复现方式

```bash
cd REPO_HOME/projects/vllm/vllm-rs-wt/A-path
harness/static/check_anchors.sh --help                 # 用法
harness/static/check_anchors.sh -q docs/01-request-path.md \
    docs/01b-python-frontend-anchors.md agents/A-path/REPORT.md
# 期望输出：anchors checked: 481, problems: 0
```

脚本只做 grep/sed，**不需要编译、不占 CPU**，可在任意时间重跑；
上游换 commit 后行号漂移时，先跑它再改文档。
（第二轮已把脚本扩展到 Python 树与 site-packages，见 §8。） 

## 7. 提交记录

| commit | 内容 |
|---|---|
| `033b8c6` | P1–P6 行号核实与静态锚点校验脚本 |
| `6d4e64f` | P7–P10 分解、调用图（A3）、Python 对照（A2）与成本假设（A5） |
| `eead11b` | 修正 P8 滑动窗口语义与 P6 分配描述，补文件索引附录 |
| `af8bc25` | 本报告（`agents/A-path/REPORT.md`） |
| `6021b1f` | 修正响应段 runtime 归属（流式 P8–P10 在 HTTP runtime），加假设 S5 |

---

## 8. 追加交付（第二轮）：Python 前端侧锚点

> 触发：根代理要求为 `docs/04-ab-comparison.md` 提供「Python 前端侧的代码锚点」，
> 重点是**进程/线程拓扑**（C 线要把 perf 归到正确的进程上）。
> **本轮同样禁止派生子代理，全部自己完成**；未跑任何 CPU 密集任务。

### 8.1 交付物

| 交付物 | 状态 | 说明 |
|---|---|---|
| `docs/01b-python-frontend-anchors.md` | ✅ 新增（403 行） | 进程/线程拓扑、P1–P10 锚点、两侧边界差异、`--headless` 用法、perf 归属清单 |
| `harness/static/check_anchors.sh` | ✅ 扩展（**默认行为不变**） | 新增 `--py-root` / `--no-py` / `--site-packages`，现在能校验 `.py` 锚点 |
| `agents/A-path/REPORT.md` | ✅ 本节 | |

自检：`docs/01b` = **170 锚点 / 0 问题**；`docs/01-request-path.md` 回归 = 281 锚点 / 0 问题。

### 8.2 关键结论（5 条）

1. **默认 `vllm serve` 没有独立编排进程**：`api_server_count == 1` 时走
   `uvloop.run(run_server(args))`（`vllm/entrypoints/cli/serve.py:141-148`），
   **主进程 = API server = engine core 的父进程**；engine core 是它的子进程
   （`vllm/v1/engine/core_client.py:550-577` → `vllm/v1/engine/utils.py:139`、`:164-171`）。
   **只有 `api_server_count > 1` 或 Rust 前端（拓扑 B/C）才有"只做编排"的主进程。**
2. **默认 multiprocessing 方法是 `fork`，不是 `spawn`**（`vllm/envs.py:67`、
   `vllm/utils/system_utils.py:168-181`）；fork 发生在 renderer/tokenizer 构造之后
   （`vllm/v1/engine/async_llm.py:132` → `:146`）⇒ engine core 会以 CoW 继承前端内存。
   **例外**：CUDA/XPU 已初始化时强制 spawn（`vllm/utils/system_utils.py:126-152`）。
   ⚠️ API server 子进程（拓扑 B）相反，是**显式 spawn**（`vllm/v1/utils.py:208`）。
3. **纠正 tokenizer 项目的一处自相矛盾**：他们 §1.1 的 pid=1/pid=131 实测
   （`tokenizer/docs/02-cost-and-share.md:34-49`）对应**拓扑 A**，与他们自己 §2.1 的拓扑图
   （`tokenizer/docs/01-code-logic.md:96-99`："主进程只做编排 + ApiServer_i 子进程"）
   **不一致**；本文给出源码依据（`vllm/entrypoints/cli/serve.py:105-122` + `:141-148`）
   说明默认路径为何跳过 `APIServerProcessManager`。**C 线引用时请按拓扑 A 标注。**
4. **线程布局**：1 个事件循环线程 + `renderer_num_workers`（默认 1）+ 2 个 ZMQ io 线程；
   **P3/P4（模板+编码）在池线程，其余都在事件循环线程**（P2 标【推断】：本机
   fastapi 0.115.14 与 vLLM 0.26.0 要求的 ≥0.133 不符，见 `requirements/common.txt:14`）。
   ⇒ Python 前端**按 pid 采 perf 是安全的**；要拆模板/编码得按 tid。
5. **P6/P7 两侧可逐段对齐**（同协议：ROUTER 入 + PULL 出 + msgpack，出方向 3 帧），
   但**编解码库不同**（`msgspec` vs `rmp-serde`）、零拷贝与附加帧路径不同 ⇒
   D3 微基准必须分别测，不能互相代表。

### 8.3 `--headless` 的硬约束（给 C 线）

`--headless` 与 `--api-server-count>0` 互斥（`vllm/entrypoints/cli/serve.py:61-69`）；
与 `--data-parallel-hybrid-lb` 互斥（同文件 `:184-185`）；
`data_parallel_size_local` 必须 > 0（同文件 `:190-191`；不写该参数时默认等于
`--data-parallel-size`，`vllm/engine/arg_utils.py:2061-2074`）；
handshake 地址默认 `127.0.0.1:29550`（`vllm/config/parallel.py:139`、`:141`），
且**必须由前端 bind**（Rust：`engine-core-client/src/transport.rs:180-181`），
Python headless 只 connect（`vllm/v1/engine/core.py:1186-1193`）。

```bash
python -m vllm.entrypoints.cli.main serve Qwen/Qwen3-0.6B \
  --headless --data-parallel-address 127.0.0.1 --data-parallel-rpc-port 62100 \
  --data-parallel-size 1 --data-parallel-size-local 1
```

（与上游 `rust/README.md:52-57` 一致；**未端到端验证**——无卡环境起不了真引擎。）

### 8.4 未做到

| 项 | 说明 |
|---|---|
| 真引擎/端到端验证 | 与前一轮一致，A 线只做静态分析 |
| §4.2 启动命令未实测 | 无卡环境限制（同 tokenizer 项目遗留） |
| fork vs spawn 的真机确认 | 标【推断】，给出实测方法（`ps -o ppid` + `/proc/<pid>/smaps`）但没做 |
| Python 侧逐段耗时 | 全部标【未测】；本文只给锚点 |
| fastapi/starlette 版本口径 | 本机 0.115.14 ≠ vLLM 0.26.0 要求的 ≥0.133 ⇒ P2 线程归属只能算【推断】 |
| 多 API server（拓扑 B）实测 | `_api_process_count` 只核到字段来源，未测其实际影响 |
