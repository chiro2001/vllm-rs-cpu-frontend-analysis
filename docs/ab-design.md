# A/B 实验设计：同引擎、同镜像、同卡，只换前端

> C 线（★04）的方法论文档 —— `docs/04-ab-comparison.md` 的**可信度来源**。
> 主结论在 `docs/04`；本文只回答「这个对照凭什么公平」。
>
> **装置**：REMOTE_HOST（Kunpeng 920B + Ascend 910）× chip4（`/dev/davinci4`）。
> **镜像**：`quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler`。
> **快速复跑**：`harness/a3/push_private.sh` → `harness/a3/chip_lock.sh -- bash -lc 'cd ~/projects/vllm/cab && bash harness/a3/matrix.sh --configs C1'`。

---

## 0. 一句话

两侧跑的是**同一个容器镜像、同一份 vLLM 引擎实现、同一张 NPU、同一个模型、
同一个压测客户端容器、同一组绑核**，唯一变量是 **`VLLM_USE_RUST_FRONTEND`**。
因此两侧「前端进程 CPU」的差，可以被归因到前端语言，而不是引擎或装置。

---

## 1. 装置：为什么从 x86 换到 REMOTE_HOST chip4

最早一版 A/B 在本机 x86 上做（纯 CPU 真引擎，vLLM 0.26.0+cpu wheel）。
实测发现该装置**测不出前端差异**：

| 装置 | 引擎速度 | 前端占服务端 CPU | 能否回答 Q3/Q4 |
|---|---:|---:|---|
| x86 纯 CPU（本机，`harness/ab/`） | **245 ms/token** | **0.08%** | ❌ 差异被引擎淹没 |
| REMOTE_HOST chip4（本文主线，`harness/a3/`） | **≈4.8 ms/token** | **1.1% – 17.0%** | ✅ 前端可分辨（c=64 时 Python 占 17%） |

x86 那套**降级为附录**（见 `docs/04` 附录 A/B），它与本文主结论**不可混用**：
跨装置（x86 x86_64 vs aarch64 + NPU）比较既跨架构又跨加速器。

---

## 2. 公平性的核心：同一个 `vllm serve`，只差一个环境变量

### 2.1 启动命令只差一个开关

两侧**同一条命令**，容器由 `harness/a3/ab_serve.sh` 统一构造：

```bash
vllm serve /models/Qwen3.5-0.8B --port 18300 \
  --max-model-len $MAX_MODEL_LEN --max-num-seqs $MAX_NUM_SEQS \
  --gpu-memory-utilization 0.5 --no-enable-prefix-caching
```

| 臂 | 额外环境变量 | 谁来处理 HTTP |
|---|---|---|
| **Rust** | `VLLM_USE_RUST_FRONTEND=1` + `VLLM_RUST_FRONTEND_PATH=/opt/vllm-rs-bin/vllm-rs` | `vllm-rs` 子进程 |
| **Python** | `VLLM_USE_RUST_FRONTEND=0` | `vllm serve` 主进程自己（拓扑 A） |

> ⚠️ **必须同时设两个变量**：只设 `VLLM_RUST_FRONTEND_PATH` 而不设
> `VLLM_USE_RUST_FRONTEND=1` 时，vLLM 只打一条 WARNING 然后**静默退回 Python 前端**
> （`vllm/envs.py:557-566`）。我们在 x86 上踩过这个坑：整轮实验跑在 Python 前端上，
> 数据看起来"正常"但结论完全错。

### 2.2 镜像与 commit 的一致性

| 项 | 值 | 来源 |
|---|---|---|
| 镜像 | `quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler` | `VLLM_IMAGE` |
| 镜像内 vLLM | **0.26.0**，源码 `/vllm-workspace/vllm` @ `568afb3a` | 与 `plan/COORDINATION.md` §3 锁定的 commit 一致 |
| 两侧引擎实现 | **同一份二进制/同一份代码** | 同一镜像、同一容器 |
| `vllm-rs` | 官方 aarch64 wheel 抽取的预编译二进制，挂载到 `/opt/vllm-rs-bin/vllm-rs` | `scripts/fetch_vllm_rs.py --arch aarch64` |
| 模型 | `/models/Qwen3.5-0.8B`（宿主只读挂载） | `MODEL_NAME` |

**注意**：镜像里**不含** `vllm-rs`（镜像无 cargo 工具链），所以 Rust 前端是**外挂**进去的
预编译产物。这带来一个口径上的细微差别：Python 前端是「镜像自带的 venv」，
Rust 前端是「另一份 wheel 抽出的二进制」。两者都由**同一版本的 vLLM 发布**，
但**不是同一次构建**——【未测】我们没有验证两者的 `vllm-rs` 版本号是否逐字节一致，
影响应在「前端语言」这个变量之外，故在 `docs/04` 的局限一节显式标注。

### 2.3 两侧的**南北向边界完全相同**

两侧前端与引擎之间都是 vLLM v1 引擎协议的 **ZMQ(ROUTER 入 / PULL 出) + msgpack**：

- Rust 侧：`vllm-rs frontend --input-address ipc://… --output-address ipc://…`
- Python 侧：`EngineCoreClient` 在同一进程内做同样的 socket 角色

⇒ 「前端」这个词在两侧指的是**同一条边界**上的同一件事：HTTP/OpenAI 协议 → 引擎协议。
引擎侧（`VLLM::EngineCore` / `VLLM::Worker`）**不计入前端成本**，两侧一致。

---

## 3. 进程拓扑：实证，不是假设

采集方式：`sudo docker top <container> -eo pid,ppid,comm`（宿主 pid）
+ 容器内 `ps` + `/proc/<pid>/status` 的 `NSpid` 做内外 pid 对照。
原始输出留在每个 run 的 `topology.txt`。

### 3.1 Rust 臂（`runs/ab-C1r1-rust/topology.txt`）

```
--roles--
supervisor_or_python_frontend 1
engine 127
frontend_rust 128
--ps--
  1   0 vllm            /usr/local/python3.12.13/bin/python3 …/vllm serve /models/Qwen3.5-0.8B --port 18300 …
127   1 VLLM::EngineCor VLLM::EngineCore
128   1 vllm-rs         /opt/vllm-rs-bin/vllm-rs frontend --listen-fd 7 --input-address ipc:///tmp/… --engine-count 1
```

### 3.2 Python 臂（`runs/ab-C1r1-python/topology.txt`）

```
--roles--
supervisor_or_python_frontend 1
engine 131
--ps--
  1   0 vllm            /usr/local/python3.12.13/bin/python3 …/vllm serve /models/Qwen3.5-0.8B --port 18300 …
131   1 VLLM::EngineCor VLLM::EngineCore
```

### 3.3 差异与它对口径的影响（**主动承认**）

| | Rust 臂 | Python 臂 |
|---|---|---|
| 主进程（`vllm serve`） | **只做编排**，不做 HTTP | **既是编排，也是 API server** |
| 处理 HTTP 的进程 | `vllm-rs`（独立子进程） | 主进程自己 |
| 我们采的「前端 CPU」 | `vllm-rs` 的 pid | 主进程的 pid |
| 是否含编排开销 | **不含** | **含** |

⇒ Python 臂的「前端 CPU」**比纯前端工作多算了一点编排开销**，对 Rust 不公平（高估 Python）。
**量化**：Rust 臂的编排进程在同一窗口内只花 **0.01–0.02 s / ≈38 s（≈0.04%）**
（同一镜像、同一段编排代码路径）。因此这个偏差是**上界估计**意义的可忽略量。
⚠️ 严格说两者代码路径不完全相同（`run_server` vs `run_multi_api_server`），
所以只能作为**量级参照**，不能当作精确扣减项。

> 与 A 线 `docs/01b-python-frontend-anchors.md` §1.1 的四种拓扑一致：
> Python 臂是**拓扑 A**（主进程即 API server），Rust 臂是**拓扑 C**（主进程只编排 + Rust 前端子进程）。

---

## 4. 采集口径：分子分母写清楚

### 4.1 时间窗口

```
窗口 = [预热结束, 正式负载结束]
```

- **预热不计入**：每点先跑 `--warmup N` 个请求（C1 用 4，C2 用 8…），
  用于摊掉 tokenizer 加载、PCRE2 正则 JIT、CUDA/NPU 图捕获等一次性开销。
- **正式负载**用 `vllm bench serve --num-prompts N`，`procstat` 快照在**负载前后**各一次。
- 客户端自己的容器**在窗口外启动**（镜像拉取/冷启动不计入）。

### 4.2 每个指标的分子 / 分母

| 指标 | 分子 | 分母 | 说明 |
|---|---|---|---|
| `request_throughput` (req/s) | 完成的请求数 | 窗口秒数 | **端到端**，含客户端与网络 |
| `output_throughput` (tok/s) | 完成请求的 output token 数 | 窗口秒数 | **端到端** |
| `mean_ttft_ms` | 请求发出 → 首 token | 请求数 | **端到端**；含 prefill 与排队 |
| `mean_tpot_ms` | 首 token → 末 token | output token 数 | **端到端**；含引擎 decode |
| **前端 CPU 秒** | 前端进程 `utime+stime` 增量 | — | **不含子进程**；不含引擎 |
| **前端 CPU s/请求** | 前端 CPU 秒 | **完成的请求数** | 归一化主指标 |
| **前端 CPU s/千输入 token** | 前端 CPU 秒 | 输入 token 数 ÷ 1000 | 归一化主指标 |
| **前端 CPU s/千输出 token** | 前端 CPU 秒 | 输出 token 数 ÷ 1000 | 归一化主指标 |
| **前端占服务端 CPU** | 前端 CPU 秒 | 容器内**全部进程** CPU 秒 | 分桶见 §4.4 |

> **延迟是端到端，不是前端处理时间。** 本项目没有单独测「前端处理延迟」——
> 那需要在前端进程内部埋点，两侧都要埋，本次**未做**（见 `docs/04` 未测清单）。

### 4.3 CPU 采样的精度限制（必须知道）

`/proc/<pid>/stat` 的 `utime/stime` 以 **10 ms tick** 为粒度（`sysconf(_SC_CLK_TCK)`）。
C1 里 Rust 前端的窗口 CPU 只有 **0.30–0.40 s**，即 **30–40 个 tick** ⇒
单次量化台阶就是 `0.01 s / 32 请求 = 0.31 ms/请求`。
这就是 3 次重复里 Rust 侧 `0.30 / 0.40 / 0.33` 的主要来源
（Python 侧 1.45–1.48 s，几十~上百 tick，离散度 <2%）。
⇒ **两侧比值的不确定度主要由 Rust 侧决定**，`docs/04` 的置信区间据此给。

> **这本身是一条结论**：在真引擎装置上 Rust 前端已经**便宜到接近 `/proc` 的分辨极限**。
> 想测它必须**放大信号**（增加请求数、或改用两点法），而不是靠更长的窗口
> —— 更长的窗口只会把空转也一起放大（见 §4.6）。

### 4.6 「含空转」与「边际」是两个口径（在真引擎装置上必须分开）

真引擎装置的一个结构性特征：**单个请求要跑几十秒**（C1 的窗口 38 s 只有 32 个请求，
1.4 req/s）。前端在整个窗口里都活着，它等待引擎时被唤醒的开销同样计入 `/proc`。

```
CPU_total  =   r × W   +   m × N
               ~~~~~       ~~~~~
               空转(与请求数无关)   边际处理(随请求线性增长)
```

| 口径 | 定义 | 用途 |
|---|---|---|
| **含空转** | `CPU_total ÷ N` | 描述「这段窗口里前端占了多少 CPU」（`docs/04` §1、§3–§6） |
| **边际** | `r`、`m` 由**两点法**解出（同负载形态只变请求数） | **容量/拐点分析**（`docs/06`）；μs/token 类模型 |

**为什么必须要边际**：用含空转的每请求数去算「单核能支撑多少 req/s」，
会**严重低估**前端能力（把空转按请求数摊进去了）；反过来，在两个不同请求率的
装置之间直接比较每请求 CPU 也会得出错误结论。
两点法**不需要预设空转是多少**，这是它比「先测空载再扣减」更强的理由。

**实测参考**（`docs/04` §2）：REMOTE_HOST 上 Rust 空转 0.57% 单核、边际 5.86 ms/请求；
Python 空转 0.90%、边际 37.8 ms/请求。

### 4.4 容器内进程分桶（不只统计前端那一个 pid）

`harness/a3/point.sh` 对容器内**所有**进程采 CPU，再按 `comm` 分三类：

| 桶 | 归类规则 | 用途 |
|---|---|---|
| `frontend` | pid == 该臂的前端 pid | **A/B 的被分析对象** |
| `engine` | `comm` 前缀 `VLLM::EngineCor` / `VLLM::Worker` | 证明「两侧引擎工作量相当」 |
| `other` | 其余（辅助 `python3` 子进程等） | 防漏算 |

为什么必须分桶：Python 臂实测会 fork 出辅助 `python3` 子进程，
只统计主 pid 会漏算；引擎侧在 TP>1 时还有 `VLLM::Worker`。

### 4.5 客户端隔离

| 角色 | 位置 | 绑核 |
|---|---|---|
| 前端 + 引擎 | 服务容器（chip4，`--cpuset-cpus=160-199`，NUMA 2） | 160-199（40 核） |
| **压测客户端** | **独立容器**（`--network host`，**不带任何 NPU 设备**） | **200-201（2 核）** |

客户端命令（两侧**逐字相同**）：

```bash
vllm bench serve --backend openai-chat --endpoint /v1/chat/completions \
  --base-url http://127.0.0.1:<PORT> --model /models/Qwen3.5-0.8B --tokenizer /models/Qwen3.5-0.8B \
  --dataset-name random --random-input-len <ISL> --random-output-len <OSL> \
  --num-prompts N --max-concurrency C --save-result --result-dir /out
```

⇒ 客户端 CPU**不并入服务端**（它在另一个容器、另一组核，且我们只采服务容器内进程）。

---

## 5. 防护措施（都是踩出来的）

这一节记录**会静默污染数据**的陷阱，以及 harness 里对应的防护。它们不是洁癖：
每一条都真实发生过一次。

| 陷阱 | 现象 | 防护 |
|---|---|---|
| 开关只设了一半 | 数据"正常"但跑的是 Python 前端 | 必须同时设 `VLLM_USE_RUST_FRONTEND=1` 与 `VLLM_RUST_FRONTEND_PATH` |
| 残留容器占着端口 | 新容器 `vllm-rs` bind 失败退出，但 `/health` 由**旧容器**回答 200 | 起栈前清场 + 起栈后校验容器内真的出现该侧前端进程 |
| 共享脚本目录被别人的 `sync --delete` 覆盖 | 矩阵跑一半改用 ssh 回连自己（`Could not resolve hostname REMOTE_HOST`） | C 线改用**私有远端目录** `~/projects/vllm/cab/`（`push_private.sh`） |
| 清场按 label 过滤 | **会误删 B 线正在跑的容器**（同一 label） | 清场收窄为**按容器名前缀** `vrs-ab-ab-`（只匹配本线） |
| `sudo perf` 的进程树多一层 | 给 `sudo` 发 SIGINT 不落到 `perf`，采集窗口关不掉 | 记录真正的 `perf` 孙进程 pid，直接打它；并有 30 s 有界等待兜底 |
| 后台 perf 继承 stdout | ssh 会话永不返回（管道 EOF 等不到） | `setsid` + 完全重定向 |

---

## 6. perf stat 的口径

事件集（两侧**完全一致**，由 `point.sh --perf` 统一施加）：

```
instructions:u,cycles:u,branches:u,branch-misses:u,cache-misses:u
```

采集对象是**该臂的前端 pid**（`perf stat -p <pid>`，进程内所有线程合计），
与 `/proc/<pid>/stat` 的 utime+stime 是**互补的两套口径**（一个数指令/周期，一个数时间）。

**x86 上的对照结论**（`harness/ab/`，纯 CPU 装置）已实测可用：
`perf stat -p <pid>` 能采到容器内 root 进程（需 `sudo -n`，本机免密可用），
首轮 C1-mock 的 Rust 前端 IPC ≈ **1.014**、引擎 IPC ≈ 1.338。

⚠️ **REMOTE_HOST 上未采 topdown**：`frontend_bound` / `retiring` 这类分解依赖 Kunpeng
专用的 libkperfx，本轮的 A/B **只采了上面五个 PMU 事件**，不做 topdown 分解。

---

## 7. 层 3 边界：一个必须写清的纠错

计划早期版本曾把「Python 前端热点 = CPython 逐条派发（`frontend_bound 66.01%` /
`IPC 0.771`）」当作 Python 前端的基线。**这是错的**：

- 那个 66.01% 的采集目标是 **engine core 进程的主线程**
  （`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:243` 写明 `目标 = engine-core 宿主 TID 704908`），
  分析对象是 engine core 内部的 `prepare_input`/scheduler，**不是 API server 前端**。
- 对照 `tokenizer/docs/02-cost-and-share.md:34-49`：`tokenizer:` 三 scope 在 **pid=1（API server 前端）**，
  `Step:Model/phase:*` 在 **pid=131（engine core）** —— 两者是不同进程。

⇒ **`frontend_bound 66%` 属于 engine core，换 Rust 前端不改变 engine core，
该数字与本计划的前端收益无关。** 本文档与 `docs/04` 不再引用它作为 Python 前端基线。

---

## 8. 与 x86 装置的口径差异（不可混用清单）

| 维度 | x86（`harness/ab/`） | REMOTE_HOST chip4（`harness/a3/`） |
|---|---|---|
| 架构 | x86_64 | aarch64（Kunpeng 920B） |
| 引擎 | vLLM 0.26.0 **+cpu** wheel，纯 CPU forward | 同镜像 vLLM 0.26.0 + Ascend 910 |
| 引擎速度 | 245 ms/token | ≈4.8 ms/token |
| 前端进程 | `vllm-rs`（Rust 臂）/ 主进程（Python 臂） | 同上 |
| 客户端 | Rust `vllm-bench` | 镜像内 `vllm bench serve` |
| 前端占比 | 0.08%（不可分辨） | 1.2% / 5.1%（可分辨） |
| topdown 分解 | ❌ 采不到 | ⚠️ 本轮未采 |

⇒ **两组数字只能各自内部比较，绝不能跨装置相除。**

---

## 9. 本设计的已知局限

| 局限 | 影响 | 状态 |
|---|---|---|
| `vllm-rs` 是外挂二进制，非镜像自带 | 「同镜像」不完全严格 | 已在 §2.2 标注 |
| Python 臂的前端 CPU 含编排开销 | 高估 Python | 已量化上界 ≈0.04% |
| tick 量化（10 ms） | Rust 侧单次 ±3% | 用 3 次重复 + 中位数 |
| 共享生产机 loadavg ≈48 | 装置噪声 | 每点记 loadavg；两侧交错运行减少漂移 |
| 未测「前端处理延迟」 | TTFT 差不能全归前端 | 已在 §4.2 标注，`docs/04` 标「待分解」 |
| **未测**：前端侧的 topdown 分解 | 无法回答「前端为什么慢」 | 本轮不做；只采了 PMU 五事件到 `perf.txt` |
| C2–C5 只有单轮 | 逐点噪声未量化 | 仅 C1 做了 3 次重复（Python ±1%、Rust 受 tick 量化限制） |
| OSL 斜率假设「空转与 OSL 无关」 | 每输出 token 成本可能偏 | `docs/04` §5 已标【推断】 |

---

## 10. 用卡前的自检（编号陷阱，已踩）

`npu-smi info -t proc-mem -i <N>` 的 `-i` 是 **NPU ID，不是 davinci 编号**：

| NPU ID | 对应设备 |
|---|---|
| 0 | `/dev/davinci0, davinci1` |
| 1 | `/dev/davinci2, davinci3` |
| **2** | **`/dev/davinci4, davinci5`** ← 本项目的 chip4 |
| 3 | `/dev/davinci6, davinci7` |
| 4 | `/dev/davinci8, davinci9` |

本轮曾误用 `-i 4` 查看「chip4」，看到 5 个 `liftquant_moe` 进程（≈72 GB HBM）并
据此判断「卡被占用、可能需换卡」——**判断错了**：那些进程在 NPU 4（davinci8/9），
与 chip4 无关。正确的自检是：

```bash
npu-smi info -t proc-mem -i 2     # NPU 2 = davinci4/5，应显示 "No process in device."
```

⇒ **教训**：装置检查也要留原始输出（本项目把所有这类输出记进 manifest / 文档），
否则一次编号误读就会导致整轮实验跑到错误的资源判断上。
