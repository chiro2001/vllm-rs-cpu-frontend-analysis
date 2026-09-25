# 01b · Python 前端侧的代码锚点（给 C 线 A/B 与 perf 归属用）

> **线 A 追加交付**（`docs/04-ab-comparison.md` 的前置材料；本文不改 C 线的任何文件）。
> 与 `docs/01-request-path.md` 配套：那篇讲 **Rust 侧** P1–P10，这篇讲 **Python 侧**的等价物、
> **进程/线程拓扑**与 **`--headless` 用法**。
>
> **行号口径（硬性）**：本文所有 `vllm/...py:行号` 都指 vLLM 0.26.0 仓库根
> `REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm`（commit
> `568afb3a13806beb53bb2e6bd518269357b237c0`）下的相对路径 + 行号，逐条 `rg`/`sed` 回读。
> 复核脚本：`harness/static/check_anchors.sh docs/01b-python-frontend-anchors.md`
> （本次给脚本加了 `--py-root` / `--no-py`，**默认行为不变**，见 §7）。
>
> **标注约定**：**【源码】**=已回读确认；**【引用】**=引用既有项目结论；
> **【推断】**=由源码推出但未实测；**【未核实】**=本机无法确认。
> 本文**不含任何新测的数字**，也不跑 CPU 密集任务。

---

## 0. 一分钟结论

1. **默认的 `vllm serve <model>` 没有"独立编排进程"**：当 `--api-server-count` 解析为 1 时，
   主进程**自己就是 API server**（`vllm/entrypoints/cli/serve.py:141-148` 走
   `uvloop.run(run_server(args))`），engine core 是**它的子进程**。
   ⇒ 常见部署里 3 个角色的 pid 关系是 **主进程 = 前端 = engine core 的父进程**，不是三段。
2. **只有四种进程拓扑**（§1.1）：默认单 API server（A）/ 多 API server（B，DP>1 默认）/
   Rust 前端（C）/ headless（D）。**只有 B 与 C 才有"只做编排"的主进程**。
3. **前端进程内的线程布局很薄**：1 个事件循环线程（tid = 主线程）+
   `renderer_num_workers` 个线程池 worker（默认 **1**）+ 2 个 ZMQ io 线程（§1.6）。
   **P3/P4（模板 + 分词）在池线程**；其余 P1/P5/P6/P7/P8/P9/P10 在事件循环线程
   （**P2 同，但标【推断】**——本机 fastapi/starlette 版本与 vLLM 0.26.0 的要求不符，见 §1.6）。
4. **tokenizer 项目的实测（pid=1 前端 / pid=131 engine core）与源码一致**，对应拓扑 A；
   但**他们自己的 `tokenizer/docs/01-code-logic.md:96-99` 拓扑图描述的是拓扑 B**
   （"主进程只做编排 + ApiServer_i 子进程"），与他们自己的 pid 证据**矛盾**（§1.5）。
5. **南北向边界两侧一一对应**：都是 ZMQ `ROUTER(入) + PULL(出)` + msgpack，
   出方向 3 帧 `(identity, request_type, payload)`。差异只在**编解码库**
   （Python `msgspec` vs Rust `rmp-serde`）与**附加帧/张量旁路**的处理（§3）。

---

## 1. 进程与线程拓扑（最重要）

### 1.1 四条分支：`vllm serve` 到底起了什么

`ServeSubcommand.cmd` 是唯一的分发点（`vllm/entrypoints/cli/serve.py:50-148`）：

| # | 触发条件（源码处） | 走哪个函数 | 主进程角色 | 子进程 |
|---|---|---|---|---|
| **A** | `api_server_count == 1`（DP=1 且无 LB 开关、无 Rust 前端时的**默认**）<br>`vllm/entrypoints/cli/serve.py:105-122` 定值 → `vllm/entrypoints/cli/serve.py:145-148` | `uvloop.run(run_server(args))`<br>`vllm/entrypoints/cli/serve.py:148` | **API server 本身**（同时是 engine 的父进程） | EngineCore ×`data_parallel_size_local`（由 `AsyncMPClient` 内部拉起，`vllm/v1/engine/core_client.py:573-577`） |
| **B** | `api_server_count > 1`，**或** `envs.VLLM_RUST_FRONTEND_PATH` 非空<br>`vllm/entrypoints/cli/serve.py:143-144` | `run_multi_api_server(args)`<br>`vllm/entrypoints/cli/serve.py:257-394` | **只做编排**（父进程只 bind 监听 socket，不 serve HTTP） | `ApiServer_i` ×N（spawn，`vllm/v1/utils.py:208-236`）+ EngineCore ×local（`vllm/entrypoints/cli/serve.py:323-325`）+ 可选 DPCoordinator（`vllm/v1/engine/utils.py:1114-1127`） |
| **C** | 同 B + `VLLM_RUST_FRONTEND_PATH`（Rust 前端接管 HTTP） | `run_multi_api_server` 的 rust 分支<br>`vllm/entrypoints/cli/serve.py:330-347` | 只做编排 | `vllm-rs` 子进程 1 个（`subprocess.Popen(..., pass_fds=(fd,))`，`vllm/v1/utils.py:390`）+ EngineCore ×local |
| **D** | `--headless`（`vllm/entrypoints/cli/serve.py:61-69` 把 `api_server_count` 置 0）→ `vllm/entrypoints/cli/serve.py:141-142` | `run_headless(args)`<br>`vllm/entrypoints/cli/serve.py:173-254` | **只做编排**（起完引擎就 `monitor_engine_liveness` 挂着） | EngineCore ×`data_parallel_size_local`（`vllm/entrypoints/cli/serve.py:235-244`），**不启任何 API server** |

> `--api-server-count` 的默认值是 `None`（`vllm/entrypoints/openai/cli_args.py:360-366`），
> 由 `vllm/entrypoints/cli/serve.py:105-122` 填：外部 LB / 多端口 LB / Rust 前端 → 1；hybrid LB → local DP size；
> 其余 → **`data_parallel_size`**。所以 **DP=1 时默认就是拓扑 A**。

### 1.2 拓扑 A（默认）：进程树与 fork/spawn 关系

```
$ vllm serve Qwen/Qwen3-0.6B          # DP=1，无 --api-server-count，无 VLLM_RUST_FRONTEND_PATH
│
└─ PID P  「主进程 == API server」      ← vllm/entrypoints/cli/serve.py:148 uvloop.run(run_server(args))
   │     vllm/entrypoints/openai/api_server.py:746 run_server
   │       → vllm/entrypoints/openai/api_server.py:758 setup_server（建监听 socket）
   │       → vllm/entrypoints/openai/api_server.py:762 run_server_worker
   │       └─ :773 build_async_engine_client（定义 :117；内层 :148）
   │            → :175 AsyncLLM.from_vllm_config（同进程内对象，不走 RPC）
   │            vllm/v1/engine/async_llm.py:132 renderer / :135 input_processor / :138 output_processor
   │            vllm/v1/engine/async_llm.py:146 EngineCoreClient.make_async_mp_client
   │              vllm/v1/engine/core_client.py:550-552 client_addresses 为空 ⇒ "managed by this client"
   │              vllm/v1/engine/core_client.py:573 launch_core_engines
   │                vllm/v1/engine/utils.py:1195 CoreEngineProcManager
   │                  vllm/v1/engine/utils.py:139 context = get_mp_context()   ← **默认 fork**
   │                  vllm/v1/engine/utils.py:164-171 Process(target=EngineCoreProc.run_engine_core,
   │                                            name="EngineCore" | "EngineCore_DP{i}")
   ├─ PID C1 「EngineCore」               ← 上面的子进程（name 见 vllm/v1/engine/utils.py:167）
   │     进程标题 "VLLM::EngineCore"      （vllm/v1/engine/core.py:1270 set_process_title）
   │     └─ （TP/PP>1 时再由 executor 起 Worker 进程：
   │           vllm/v1/executor/multiproc_executor.py:1018/1046 set_process_title("Worker")）
   └─ （`needs_dp_coordinator` 时：PID 另计「DPCoordinator」，vllm/v1/engine/coordinator.py:152）
```

**证据链（逐条）**

| 判断 | 源码依据 |
|---|---|
| 主进程就是 API server | `vllm/entrypoints/cli/serve.py:141-148`：`api_server_count<1` 走 headless；`>1 或 rust` 走多进程；**否则原地 `uvloop.run(run_server)`** |
| 主进程建监听 socket | `vllm/entrypoints/openai/api_server.py:758` `setup_server(args, reuse_port=False)`（`reuse_port` 只有多 server 才是 True，`vllm/entrypoints/cli/serve.py:284`） |
| AsyncLLM 在同进程（非 RPC 到别的 API server） | `vllm/entrypoints/openai/api_server.py:773` `build_async_engine_client(...)` → `:148` `build_async_engine_client_from_engine_args` → `:175` `AsyncLLM.from_vllm_config`（实现见 `vllm/v1/engine/async_llm.py:203-229`） |
| 该进程**自己**拉起 engine core | `vllm/v1/engine/core_client.py:550-552`（`client_addresses` 为空/假值分支）→ `:573-577` `launch_core_engines` 并把 `engine_manager` 挂到 `resources` |
| engine core 是**独立进程** | `vllm/v1/engine/utils.py:139` `get_mp_context()` + `:164-171` `context.Process(target=EngineCoreProc.run_engine_core, ...)` |
| **默认是 fork 不是 spawn** | `vllm/envs.py:67` `VLLM_WORKER_MULTIPROC_METHOD = "fork"`（`:913-914` 只允许 `spawn`/`fork`）；`vllm/utils/system_utils.py:168-181` `get_mp_context()` 据此返回 context。**例外**：`_maybe_force_spawn()`（`system_utils.py:126-152`）在 CUDA/XPU 已初始化或 Ray actor 内会强制 spawn |

> ⚠️ **给 C 线的两条提醒**（都标【推断】，因为本文没跑起来验证）：
> 1. 在拓扑 A 下，`fork` 发生在**渲染器/tokenizer 已经构造之后**
>    （顺序：`async_llm.py:132` renderer → `:138` output_processor → `:146` 起 engine client），
>    所以 engine core 子进程会**以 CoW 方式继承父进程的 tokenizer 内存**。
>    这解释了为什么"engine core 侧没有 tokenizer"（tokenizer 项目结论）与"engine core RSS 不小"可以同时成立；
>    **做内存对照时必须记录 RSS 而不是"有没有构造 tokenizer 对象"**。
> 2. 如果部署里 CUDA/XPU 在父进程已初始化（例如多模态 GPU ipc pool，
>    `vllm/renderers/base.py:114-123`），`_maybe_force_spawn` 会把 fork 改成 **spawn**，
>    继承关系随之消失。**A/B 前请先确认实际用的是哪种**（`ps -o pid,ppid,cmd` +
>    `/proc/<pid>/status` 的 `NSpid`）。

### 1.3 拓扑 B / C / D

```
B（api_server_count > 1，例如 --data-parallel-size 4 的内置 LB）
  PID P（只编排）
    ├─ ApiServer_0..N-1   spawn（vllm/v1/utils.py:208-236），标题 "VLLM::APIServer_<i>"（vllm/v1/utils.py:509）
    │     每个都自带一份 AsyncLLM + Renderer + tokenizer
    ├─ EngineCore × local（fork；vllm/entrypoints/cli/serve.py:323-325 → vllm/v1/engine/utils.py:1195）
    └─ DPCoordinator（按需；vllm/v1/engine/utils.py:1114-1127）

C（VLLM_RUST_FRONTEND_PATH=/path/to/vllm-rs）
  PID P（只编排）
    ├─ vllm-rs        subprocess.Popen(..., pass_fds=(listen_fd,))（vllm/v1/utils.py:350-390）
    ├─ EngineCore × local（fork）
    └─ DPCoordinator（按需）

D（--headless）
  PID P（只编排；run_headless）
    └─ EngineCore × data_parallel_size_local（fork；vllm/entrypoints/cli/serve.py:235-244）
       ※ P 自己**不**监听 ZMQ handshake：ROUTER 由远端前端 bind（见 §4）
```

### 1.4 进程标题（`ps` / perf 归属用）

`set_process_title` 的实现是 `setproctitle.setproctitle(f"{VLLM_PROCESS_NAME_PREFIX}::{name}")`
（`vllm/utils/system_utils.py:184-198`，前缀默认 `VLLM`，`vllm/envs.py:1725`）。

| 进程 | 标题 | 源码 |
|---|---|---|
| API server | `VLLM::APIServer_<i>`（**拓扑 A 下主进程不设标题**，仍是 python 命令行） | `vllm/v1/utils.py:509` |
| EngineCore | `VLLM::EngineCore`，DP 时 `VLLM::EngineCore_DP<global_rank>` | `vllm/v1/engine/core.py:1267-1270`、`vllm/v1/engine/utils.py:167` |
| TP/PP worker | `VLLM::Worker*` | `vllm/v1/executor/multiproc_executor.py:1018`、`:1046` |
| DP coordinator | `VLLM::DPCoordinator` | `vllm/v1/engine/coordinator.py:152` |

### 1.5 与 `tokenizer` 项目实测的对照（**部分不一致，必须纠正**）

`tokenizer/docs/02-cost-and-share.md:34-49` 的证据：

| scope | tid | pid |
|---|---|---|
| `tokenizer: encode` | 1169 | **1** |
| `http: create_completion` | **1** | **1** |
| `output: process_outputs` | **1** | **1** |
| `Step:Model` / `phase: *`（engine core） | 131 | **131** |

来源是**历史 LiteProfiler 日志** `liteprof_v1_torch_uni_a321_chip15_20260914T2142Z`
（REMOTE_HOST_HIST / Ascend NPU / `torch_uni` executor），不是本机 x86 容器。

| 对照项 | 结论 | 依据 |
|---|---|---|
| `http: create_completion` 在 **pid 1 的 tid 1（主线程）** | ✅ **与源码一致**：HTTP/ASGI 事件循环跑在主线程；且 pid 1 有 http scope ⇒ 该进程就是 API server ⇒ **拓扑 A** | `vllm/entrypoints/cli/serve.py:148`、`vllm/entrypoints/openai/api_server.py:746-759` |
| engine core 是**另一个 pid**（131） | ✅ 一致：EngineCore 是独立进程 | `vllm/v1/engine/utils.py:164-171` |
| `tokenizer: encode` 与 `http:` **同 pid 不同 tid** | ✅ 一致：tokenize 被 `make_async(..., executor=self._executor)` 丢进 ThreadPoolExecutor | `vllm/renderers/base.py:97-99`、`vllm/renderers/hf.py:915-917` |
| **他们自己的拓扑图** `tokenizer/docs/01-code-logic.md:96-99` 写"`vllm serve` 主进程：只做编排"+ "`ApiServer_i` 进程 × `--api-server-count`（spawn）" | ❌ **与上面的 pid 证据矛盾**（拓扑 B 下 pid 1 不会有 `http:` scope） | `vllm/entrypoints/cli/serve.py:105-122` + `:141-148`：`api_server_count == 1` 时**整个 `APIServerProcessManager` 分支被跳过**，API server 在主进程内 |

**结论（给 C 线）**：引用 tokenizer 项目的 pid 数据时，
请把它标成 **"拓扑 A（单 API server，DP=1）的实测"**；
他们的 §2.1 拓扑图描述的是**拓扑 B**，**不能**用来解释那份 pid=1/pid=131 的数据，
也**不能**用在 DP>1 的部署上（那时 pid 1 只有编排线程，`http:`/`tokenizer:` scope 会出现在子进程）。

### 1.6 在线服务时的线程布局（决定按 pid 还是按 tid 采 perf）

| 线程 | 数量 | 跑什么 | 源码 |
|---|---|---|---|
| **事件循环线程**（= 进程主线程，tid 1） | 1 | uvicorn/ASGI、路由、**请求体读取 + pydantic 校验**（【推断】，见下）、`OpenAIServingChat`、**输出后处理**（`output_handler` → `process_outputs` → detokenizer）、**权限/SSE 生成**（parser + JSON 序列化） | `vllm/entrypoints/openai/api_server.py:746-759`；`vllm/v1/engine/async_llm.py:637-700`；`vllm/v1/engine/core_client.py:984-1051` |
| **渲染线程池 worker** | `renderer_num_workers`（**默认 1**，`vllm/config/model.py:337`） | chat 模板渲染 + 编码（chat 路径）、文本 prompt 编码、MM 预处理、prompt 反解 | `vllm/renderers/base.py:86-87`（建池）、同文件 `:97-100`（offload 入口）、`vllm/renderers/hf.py:915-917`（模板 offload）、同文件 `:920-922`（`maybe_make_thread_pool`） |
| **ZMQ io 线程** | 2 | 仅 socket 收发（`zmq.Context(io_threads=2)`） | `vllm/v1/engine/core_client.py:491` |
| （离线 `LLM` 路径才有）`EngineCoreOutputQueueThread` | 1 | **同步** MPClient 的收包线程；**AsyncLLM 不用它**，改用 asyncio task | `vllm/v1/engine/core_client.py:840-844`（sync）vs 同文件 `:984-1051`（async） |

**给 C 线的采法建议（【推断】，需 C 线用实测确认）**：

> **P2（请求体 JSON + pydantic）的线程归属**：vLLM 0.26.0 依赖
> `fastapi >= 0.133.0, < 0.137.0`、`starlette >= 1.0.1`（`requirements/common.txt:14-15`），
> 但**本机装的是 fastapi 0.115.14 / starlette 0.46.2**（版本不符）。
> 在**本机**这两个版本里，body 读取与 JSON 解码都在事件循环线程上：
> `starlette/requests.py:246-249`（`await self.body()` → `json.loads`）、
> `fastapi/routing.py:250-262`（`await request.body()` / `await request.json()`），
> 校验走 `solve_dependencies`（`fastapi/routing.py:291`），端点是 `async def` ⇒ **不经
> `run_in_threadpool`**。⇒ **【推断】P2 在事件循环线程**；版本不同，请在真环境用
> `perf`/`py-spy` 的 tid 归属确认一次。

- **按 pid 统计是安全的**：前端进程内既有事件循环线程也有池线程，两者都属"前端成本"。
  这与 Rust 侧不同——Rust 前端进程内是三个 tokio runtime（见 `docs/01-request-path.md` §3.1）。
- **要拆 P3/P4 vs 其余，必须按 tid**：默认 `renderer_num_workers=1` 时，
  前端的"模板+编码"集中在**一个池线程**上（`tokenizer/docs/02-cost-and-share.md:39` 的 tid=1169 就是它）。
- **engine core 必须排除**：按 pid 采前端时，别把 `VLLM::EngineCore*` 算进去（`_api_process_count`
  之类的标签只在子进程里，见 `vllm/entrypoints/openai/api_server.py:136-137`）。

---

## 2. P1–P10 的 Python 侧锚点

### 2.1 为什么十段要合并成六组

Python 前端**没有**与 Rust 一一对应的十段结构，原因有三（都是【源码】）：

1. **没有独立的 lower 阶段**：请求校验/参数降级散在 pydantic 模型 + `SamplingParams.__post_init__`
   + `to_sampling_params`，且**在提交引擎之前**（`vllm/entrypoints/openai/chat_completion/serving.py:307-327`），没有单独的 "lower" 模块。
2. **模板与编码是一个原子调用**：chat 路径的 Jinja 渲染与 encode 在
   `apply_chat_template(tokenize=True)` 内部一次完成（`vllm/renderers/hf.py:778-784`），
   所以 tokenizer 项目才说 `render_messages` 的 scope 里"含编码"。
3. **没有显式序列化层**：msgpack 编解码被封装在 `mp` 客户端里
   （`core_client.py:1064-1074` 出、`:1008-1010` 入），不像 Rust 有独立的 P6/P7 函数。

⇒ 本文按 **六组** 给锚点：`HTTP 入口`(P1) / `JSON 与校验`(P2+P5) /
`模板+编码`(P3+P4) / `下发`(P6) / `回收+解码`(P7+P8) / `解析+回写`(P9+P10)。

### 2.2 对照表

| 组 | 覆盖 | Python 侧锚点（文件:行） | 说明 |
|---|---|---|---|
| **P1** HTTP 入口 | P1 | `vllm/entrypoints/openai/api_server.py:746`（`run_server`）→ `:758`（`setup_server` 建 socket）→ `:762`（`run_server_worker`）→ `:653`（`build_and_serve`）→ `vllm/entrypoints/launcher.py:26`（`serve_http`，uvicorn 启动）<br>路由：`vllm/entrypoints/openai/chat_completion/api_router.py:40-53`（`POST /v1/chat/completions`）<br>中间件：`vllm/entrypoints/openai/api_server.py:279-285`（CORS）/`:307-310`（`AuthenticationMiddleware`，`vllm/entrypoints/serve/utils/server_utils.py:45`）/`:312-315`（X-Request-Id）<br>指标：`vllm/entrypoints/serve/instrumentator/metrics.py:65-75` | 与 Rust 的 P1 对位；鉴权同样是 **每请求一次 SHA-256**（`server_utils.py:59`、`:70`） |
| **P2** JSON 反序列化 | P2 | `vllm/entrypoints/openai/chat_completion/protocol.py:196`（`ChatCompletionRequest`，pydantic）<br>内容类型门禁：`vllm/entrypoints/serve/utils/api_utils.py:348`（`validate_json_request`） | Python 侧是 **FastAPI + pydantic**：body → 模型在**事件循环线程**上做（同步解析）；Rust 侧在 `vllm-request` runtime 上做（`docs/01-request-path.md` §2.2） |
| **P5** 校验 / 降级 | P5 | `vllm/entrypoints/openai/chat_completion/protocol.py:614`（`to_sampling_params`）→ `vllm/sampling_params.py:199`/`:450`（`SamplingParams.__post_init__` 校验）<br>调用点：`vllm/entrypoints/openai/chat_completion/serving.py:307-327` | 与 P2 同组：都在**事件循环线程**、都是常数级字段检查（除 `bad_words` 需分词） |
| **P3+P4** 模板 + 编码 | P3、P4 | 入口：`vllm/renderers/online_renderer.py:95`（`render_chat`）→ `:164`（`preprocess_chat`）<br>编排：`vllm/renderers/base.py:1070-1095`（`render_chat_async`：`render_messages_async` → `tokenize_prompts_async`）<br>实现：`vllm/renderers/hf.py:1049`（`render_messages_async`）→ `:1111`（`await self._apply_chat_template_async`）→ `:699-794`（`safe_apply_chat_template`）→ **`:778`（`tokenizer.apply_chat_template(tokenize=True)`）**<br>线程池：`vllm/renderers/base.py:86-87`、`:97-99`；`vllm/renderers/hf.py:915-917`、`:920-922`；`vllm/tokenizers/hf.py:25`/`:44-46`/`:59-92` | **chat 请求的 Jinja + encode 是一次调用**；两者都在**池线程**上 |
| **P6** 序列化下发 | P6 | `vllm/entrypoints/openai/chat_completion/serving.py:363`（`engine_client.generate`）→ `vllm/v1/engine/async_llm.py:524`（`generate`）→ `:559`（`add_request`）→ `:400-412`（`_add_request`：先注册到 output_processor，再 `add_request_async`）<br>降级成 DTO：`vllm/v1/engine/input_processor.py:242`（`process_inputs`）→ `vllm/v1/engine/__init__.py:88`（`EngineCoreRequest`）<br>发送：`vllm/v1/engine/core_client.py:1121-1124`（`add_request_async`）→ `:1064-1074`（`_send_input`）→ `:1076-1099`（`_send_input_message`，`send_multipart(copy=False)`）<br>编码：`vllm/v1/serial_utils.py:136`/`:166`（`MsgpackEncoder.encode`） | 帧结构：`(engine_identity, EngineCoreRequestType.value, payload…)`，`vllm/v1/engine/core_client.py:1073` |
| **P7** 反序列化回收 | P7 | `core_client.py:984-1051`（`_ensure_output_queue_task` → `process_outputs_socket`：`:1008` `recv_multipart(copy=False)` → `:1010` `decoder.decode(frames)` → `:1042-1043` 入 asyncio 队列）<br>`core_client.py:1053-1062`（`get_output_async`）<br>`async_llm.py:656-691`（`output_handler`：`get_output_async` → `process_outputs`，按 `VLLM_V1_OUTPUT_PROC_CHUNK_SIZE` 分片并 `await asyncio.sleep(0)` 让出）<br>解码器：`vllm/v1/serial_utils.py:313`/`:340` | 与 Rust 的 P7 同为"**每 tick 一次**收包+解码"；但 **Python 侧在事件循环线程上**（Rust 侧在 `vllm-zmq` runtime） |
| **P8** 增量解码 | P8 | `vllm/v1/engine/output_processor.py:426`（`OutputProcessor`）→ `:586`（`process_outputs`）→ `:652-655`（`detokenizer.update`）→ `:397`（`get_next_output_text`）<br>实现：`vllm/v1/engine/detokenizer.py:95`（`update`）/`:148`（`get_next_output_text`）/`:167`（`FastIncrementalDetokenizer`）/`:250`（`SlowIncrementalDetokenizer`）<br>停止串：`detokenizer.py:309`（`check_stop_strings`）<br>建流：`output_processor.py:231`（`from_new_request`） | 仍在**事件循环线程**；⚠️ **与 Rust 不同**：Rust 的流式响应 P8–P10 在 HTTP runtime 上（`docs/01-request-path.md` §3.1 第 4 条） |
| **P9** parser | P9 | 构造：`vllm/entrypoints/openai/chat_completion/serving.py:265-271`（每请求一个 `Parser` 实例）<br>流式：`vllm/entrypoints/openai/chat_completion/serving.py:606-613`（`parser.parse_delta`）<br>非流式：`vllm/entrypoints/openai/chat_completion/serving.py:892`（`parser.parse`）<br>实现：`vllm/parser/abstract_parser.py:337`（`parse`）/`:357`（`parse_delta`）；选择：`vllm/parser/parser_manager.py:76` | 与 Rust 的 P9 同构（逐 delta 状态机）；**Python 侧在事件循环线程** |
| **P10** JSON + 回写 | P10 | SSE 生成器：`vllm/entrypoints/openai/chat_completion/serving.py:414`；分块序列化：`:533`（`chunk.model_dump_json(exclude_unset=True)`）→ `:466`/`:753`（`yield f"data: {data}\n\n"`）→ `:834`（`data: [DONE]`）<br>非流式：`:836`（`chat_completion_full_generator`）<br>返回：`vllm/entrypoints/openai/chat_completion/api_router.py:63-74`（`JSONResponse` / `StreamingResponse`） | Python 侧是 **`model_dump_json`（pydantic/rust 序列化）**，Rust 侧是 `serde_json::to_string`（`docs/01-request-path.md` §2.10） |

---

## 3. 两侧边界差异（P6/P7 对齐）

**相同的部分**（两侧都是【源码】）：

| 项 | Python | Rust |
|---|---|---|
| 传输 | ZMQ：入 `ROUTER`、出 `PULL` | 同（入 `ROUTER`、出 `PULL`） |
| 入方向帧 | `(identity, request_type, payload…)`，`vllm/v1/engine/core_client.py:1073` | `[engine_id] [request_type(1B)] [payload]`，`engine-core-client/src/transport.rs:517-529` |
| 请求类型字节 | `EngineCoreRequestType`（`vllm/v1/engine/__init__.py:252`） | `EngineCoreRequestType::Add = 0`（`rust/src/engine-core-client/src/protocol/request.rs:23-56`） |
| DTO | `EngineCoreRequest`（`vllm/v1/engine/__init__.py:88`） | `EngineCoreRequest`（`rust/src/engine-core-client/src/protocol/request.rs:74-127`） |
| 握手 | engine 侧 DEALER connect + HELLO → 收 INIT → READY（`vllm/v1/engine/core.py:1186-1212`、同文件 `:1215-1250`） | 前端侧 ROUTER bind（`engine-core-client/src/transport.rs:180-181`），收 HELLO → 发 INIT（`transport.rs:417-439`）→ 等 READY |
| 本地回环 | `client_local_only` 时用 **ipc://**（`vllm/v1/engine/utils.py:1051-1063`） | 拓扑 C 用 ipc（`rust/src/cmd/src/cli.rs:679-694`）；直连时用 `tcp://host:0`（`transport.rs:371-389`） |

**不同的部分**（C 线做 A/B 时的口径提醒）：

| 项 | Python | Rust | 影响 |
|---|---|---|---|
| 编解码库 | `msgspec.msgpack`（`vllm/v1/serial_utils.py:156`、`:332`） | `rmp-serde`（`engine-core-client/src/protocol/mod.rs:39-70`） | 微基准 D3 要分别对照，不能拿一个代表另一个 |
| 附加帧 / 零拷贝 | 张量与 >阈值 的数组走附加帧（`vllm/v1/serial_utils.py:142-147`），`send_multipart(copy=False)`（`core_client.py:1089`） | 单帧 msgpack + 显式 aux 帧解析（`protocol/output.rs:125-136`）；出方向 TODO 见 `client/imp.rs:223-224` | 有 MM/大 logprobs 时两侧行为不同；**纯文本 chat 请求下两侧都是单 payload 帧** |
| 收包线程模型 | **asyncio task**（`core_client.py:984-1051`）；同步客户端才用线程（`:840-844`） | 专用 `vllm-zmq` runtime（`rust/src/engine-core-client/src/runtime.rs:45-67`） | 火焰图归类：Python 全在事件循环线程，Rust 分成 3 组线程 |
| 输出后处理分片 | 按 `VLLM_V1_OUTPUT_PROC_CHUNK_SIZE` 分片并让出事件循环（`async_llm.py:667-683`） | 无等价分片（`client/imp.rs:346-407` 逐条投递） | 高并发下 Python 的"让出"行为本身有成本（【推断】） |

**结论（给 C 线）**：把两侧的 **P6/P7 逐段对齐是可行的**（同一套协议、同一组帧），
但**不要把"编解码耗时"当成同一个量**——库不同、零拷贝路径不同。
建议 D3 微基准里分别测 `msgspec.msgpack` 与 `rmp-serde`，而不是复用同一个数。

---

## 4. `--headless` 的准确用法（可直接复制）

### 4.1 参数与约束（全部【源码】）

| 项 | 值 | 依据 |
|---|---|---|
| 参数名 | `--headless`（`store_true`，默认 `False`） | `vllm/entrypoints/openai/cli_args.py:352-358` |
| 与 `--api-server-count` **互斥** | `--headless` + `--api-server-count>0` 直接报错；不写时会被**强制置 0**（不启 API server） | `vllm/entrypoints/cli/serve.py:61-69` |
| 与 `--data-parallel-hybrid-lb` **互斥** | 报 `data_parallel_hybrid_lb is not applicable in headless mode` | `vllm/entrypoints/cli/serve.py:184-185`、`vllm/engine/arg_utils.py:1964-1966` |
| `data_parallel_size_local` **必须 > 0** | `raise ValueError("data_parallel_size_local must be > 0 in headless mode")` | `vllm/entrypoints/cli/serve.py:190-191` |
| `data_parallel_size_local > data_parallel_size` 非法 | `ParallelConfig` 校验 | `vllm/config/parallel.py:456-458` |
| 不写 `--data-parallel-size-local` 时 | 默认等于 `--data-parallel-size`（⇒ 通常自动满足 >0） | `vllm/engine/arg_utils.py:2061-2074` |
| headless 下 `--data-parallel-start-rank` 不推 hybrid LB | `if ... and not headless` 才推 | `vllm/engine/arg_utils.py:2034-2036` |
| handshake 地址 | `tcp://<--data-parallel-address>:<--data-parallel-rpc-port>`，默认 `127.0.0.1:29550` | `vllm/entrypoints/cli/serve.py:223-225`；默认值 `vllm/config/parallel.py:139`、`:141` |
| **谁 bind 这个地址** | **远端前端**（Python headless 不 bind）：Rust 前端 `RouterSocket::bind` | `rust/src/engine-core-client/src/transport.rs:178-181`；engine 侧 `connect` 在 `vllm/v1/engine/core.py:1186-1193` |
| 多节点注意事项 | `node_rank_within_dp > 0` 时 headless 走的是 `MultiprocExecutor` 内联路径，**不是** `CoreEngineProcManager` | `vllm/entrypoints/cli/serve.py:206-221` |

### 4.2 可直接复制的启动命令

单机、1 个 engine、Rust 前端在本机（**与上游 `rust/README.md:52-57` 一致**）：

```bash
# 1) 先起 Python headless 引擎（本机 1 个 engine，等前端连过来）
python -m vllm.entrypoints.cli.main serve Qwen/Qwen3-0.6B \
  --headless \
  --data-parallel-address 127.0.0.1 \
  --data-parallel-rpc-port 62100 \
  --data-parallel-size 1 \
  --data-parallel-size-local 1

# 2) 再起 Rust 前端，指向同一个 handshake 端口
vllm-rs serve Qwen/Qwen3-0.6B \
  --data-parallel-address 127.0.0.1 \
  --data-parallel-rpc-port 62100 \
  --data-parallel-size 1 \
  --host 127.0.0.1 --port 8000
```

> ⚠️ **顺序**：engine 先起会阻塞等 INIT（`vllm/v1/engine/core.py:1232-1239`，超时
> `HANDSHAKE_TIMEOUT_MINS`），所以两种顺序都能工作（ZMQ connect 是异步的），
> 但**端口必须两边一致**且**只能由前端 bind**。**未核实**：本机没有真引擎，未端到端验证这两条命令。

**如果让 `vllm-rs` 自己托管 Python 引擎**（不需要手敲第 1 步，`vllm-rs serve` 会自动 spawn，
并把 `--headless/--data-parallel-address/--data-parallel-rpc-port/--data-parallel-size`
透传给 Python），命令是：

```bash
vllm-rs serve Qwen/Qwen3-0.6B --host 127.0.0.1 --port 8000 \
  -- python_args...          # `--` 之后的参数原样转发给 Python
```

（转发实现：`rust/src/managed-engine/src/process.rs:58-74`、`rust/src/managed-engine/src/cli.rs:78-133`。）

**C 线常用的另外两条**（对照臂）：

```bash
# Python 前端（拓扑 A）：默认即可，注意不要设 VLLM_RUST_FRONTEND_PATH
VLLM_USE_RUST_FRONTEND=0 vllm serve Qwen/Qwen3-0.6B --port 8000

# Rust 前端 + Python 引擎（拓扑 C，Python 当监管者）
VLLM_USE_RUST_FRONTEND=1 VLLM_RUST_FRONTEND_PATH=/path/to/vllm-rs \
  vllm serve Qwen/Qwen3-0.6B --port 8000
```

（`VLLM_USE_RUST_FRONTEND` 默认 0：`vllm/envs.py:155`、`:1339-1340`；
`VLLM_RUST_FRONTEND_PATH` 默认 `auto`：`vllm/envs.py:156`、`:553-580`。
⚠️ `--api-server-count > 1` 与 Rust 前端**互斥**：`vllm/entrypoints/cli/serve.py:123-128` 会警告并压回 1，
`vllm/entrypoints/cli/serve.py:263-266` 直接报错。）

---

## 5. 给 C 线的 perf 归属清单（可直接抄）

| 采什么 | 怎么选目标 | 依据 |
|---|---|---|
| Python 前端整进程 | 拓扑 A：**主进程 pid**；拓扑 B：`VLLM::APIServer_*` 每个子进程分别采 | §1.2/§1.3、`vllm/v1/utils.py:509` |
| 模板/编码专属成本 | 前端进程内按 **tid** 再分（默认只有 1 个池线程） | `vllm/renderers/base.py:86-87`、`tokenizer/docs/02-cost-and-share.md:39` |
| engine core（**要排除**） | `VLLM::EngineCore*`（`vllm/v1/engine/core.py:1267-1270`）；TP worker `VLLM::Worker*` | §1.4 |
| Rust 前端 | 进程内 3 组线程都要采（HTTP / `vllm-request` / `vllm-zmq`） | `docs/01-request-path.md` §3.1 |
| 内存对照 | 记录 **RSS/PSS**；注意拓扑 A 的 fork CoW 继承会使两个 pid 的数字不可简单相加 | §1.2 提醒 1【推断】 |

---

## 6. 未测 / 未核实

| 项 | 状态 | 原因 |
|---|---|---|
| 任何端到端启动/压测 | **未测** | A 线只做静态分析；本机不跑真引擎 |
| §4.2 两条命令的可运行性 | **未核实** | 无卡环境起不了真引擎（与 `tokenizer/docs/04-next-gen-rust-frontend.md:300` 同款限制） |
| 拓扑 A 下 engine core 是 fork 还是 spawn | **推断** | 默认 `fork`（`vllm/envs.py:67`）；但 `_maybe_force_spawn`（`system_utils.py:126-152`）在 CUDA/XPU 初始化后会改写。**需要 C 线用 `ps -o ppid` + `/proc/<pid>/smaps` 实测** |
| Python 侧 P2/P3/P4/P6/P7/P9/P10 的**耗时数字** | **未测** | 本文只给锚点；Rust 侧对应段同样是【假设】（见 `docs/01-request-path.md` §5） |
| uvicorn/anyio 自身的线程（如 sync endpoint 线程池） | **未核实** | 本机没有 uvicorn 源码快照；本文只列了 vLLM 自己创建的线程 |
| `renderer_num_workers > 1` 时的行为 | **未测** | 默认 1；>1 时池里会有多个 worker，tid 归属需要重新采（`tokenizer/docs/01-code-logic.md:117-122` 记录了池 = `renderer_num_workers + 1` 份 deepcopy） |
| 多 API server（拓扑 B）的 `_api_process_count` 影响 | **部分** | 只核到字段来源（`vllm/entrypoints/openai/api_server.py:136-137`、`vllm/config/parallel.py:377`），没测其对渲染池/共享内存的实际影响 |
| FastAPI/Starlette 的 body 解析线程归属 | **部分 / 版本不符** | vLLM 0.26.0 要求 fastapi≥0.133（`requirements/common.txt:14`），本机是 0.115.14 ⇒ 上面按本机源码给的结论只能算【推断】 |

---

## 7. 复核方式

```bash
cd REPO_HOME/projects/vllm/vllm-rs-wt/A-path
# 只会校验 Rust 树（行为不变）
harness/static/check_anchors.sh docs/01-request-path.md
# 同时校验 Rust 树 + Python 树（vLLM 仓库根）
harness/static/check_anchors.sh docs/01b-python-frontend-anchors.md
# 只看问题
harness/static/check_anchors.sh -q docs/01b-python-frontend-anchors.md
# 指定别的 Python 树 / 关掉 Python 校验
harness/static/check_anchors.sh --py-root /path/to/vllm docs/01b-python-frontend-anchors.md
harness/static/check_anchors.sh --no-py docs/01-request-path.md
# 指定第三方 site-packages（verify fastapi/starlette 那几条锚点；不传则用内置候选目录）
harness/static/check_anchors.sh --site-packages /path/to/site-packages docs/01b-python-frontend-anchors.md
```

本次新增的三个开关（**默认开启 Python 树**，默认路径
`REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm`）：
`--py-root DIR`、`--no-py`、`--site-packages DIR`。解析顺序 =
**Rust 源码树 → Python 源码树 → cargo registry（`[dep]`）→ site-packages**
（site-packages 候选：显式传入值 → `$HOME/miniforge3/lib/python*/site-packages` →
`$HOME/.venvs/*/lib/python*/site-packages` → `/usr/lib/python3/dist-packages` →
`/usr/local/lib/python*/site-packages`）。
**当前状态**：`anchors checked: 170, problems: 0`
（`docs/01-request-path.md` 回归：281 条、0 问题——脚本改动没有破坏原有行为）。

---

## 附录 A：文件索引（Python 侧的"哪几段在哪个文件"）

| 文件 | 段 | 备注 |
|---|---|---|
| `vllm/entrypoints/cli/serve.py` | 进程编排 | 拓扑判定的**唯一入口** |
| `vllm/v1/utils.py` | 进程编排 | `APIServerProcessManager` / `RustFrontendProcessManager` / 子进程入口 |
| `vllm/v1/engine/utils.py` | 进程编排 | `CoreEngineProcManager` / `launch_core_engines` / 握手等待 |
| `vllm/entrypoints/openai/api_server.py` | P1 | app 构建、middleware、`run_server*` |
| `vllm/entrypoints/launcher.py` | P1 | uvicorn 启动 |
| `vllm/entrypoints/openai/chat_completion/api_router.py` | P1、P10 | 路由与 `StreamingResponse` |
| `vllm/entrypoints/openai/chat_completion/protocol.py` | P2、P5 | pydantic 请求模型与 `to_sampling_params` |
| `vllm/sampling_params.py` | P5 | 采样参数校验 |
| `vllm/entrypoints/openai/chat_completion/serving.py` | P5、P6、P9、P10 | 预处理 → 提交 → 解析 → 回写 |
| `vllm/renderers/{online_renderer,base,hf}.py` | P3、P4 | 模板 + 编码（含线程池 offload） |
| `vllm/tokenizers/hf.py` | P4 | tokenizer 池（`deepcopy` × N+1） |
| `vllm/v1/engine/async_llm.py` | P6、P7 | `AsyncLLM`：`add_request` / `output_handler` |
| `vllm/v1/engine/core_client.py` | P6、P7 | 边界收发（`AsyncMPClient`） |
| `vllm/v1/serial_utils.py` | P6、P7 | msgpack 编解码（`msgspec`） |
| `vllm/v1/engine/input_processor.py` | P5、P6 | 降级成 `EngineCoreRequest` |
| `vllm/v1/engine/output_processor.py` | P7、P8 | tick 循环 → detokenize |
| `vllm/v1/engine/detokenizer.py` | P8 | `Fast`/`Slow` 增量解码 + 停止串 |
| `vllm/parser/{abstract_parser,parser_manager}.py` | P9 | reasoning/tool 解析 |
