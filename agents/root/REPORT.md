# 根代理执行报告

> 更新：2026-09-25（Asia/Shanghai）。计划见 `plan/`，共享 harness 见 `harness/common/README.md`。

## 1. 已完成的准备工作

### 1.1 git 化管理（用户要求）

`REPO_HOME/projects/vllm/vllm-rs` 原先不是 git 仓库，已 `git init -b main`，
并在初始提交 `52bef26` 里纳入三份规划文档、目录骨架、`.gitignore`、
`scripts/{limit,heavy_lock,docker_run}.sh`。

四条线各一个 worktree，分支 `agent/<line>`：

```
REPO_HOME/projects/vllm/vllm-rs-wt/A-path      → agent/A-path
REPO_HOME/projects/vllm/vllm-rs-wt/B-profile   → agent/B-profile
REPO_HOME/projects/vllm/vllm-rs-wt/C-ab        → agent/C-ab
REPO_HOME/projects/vllm/vllm-rs-wt/D-micro     → agent/D-micro
```

`scripts/heavy_lock.sh` 相对 tokenizer 项目的改动：锁目录固定 `/tmp/vllm-rs-heavy`，
这样四个 worktree 共享同一把重活锁（不会各写各的 `.locks/`）。

## 2. P0 门禁

### G1 ✅ 通过 —— 起 `vllm-rs` + `mock-engine`，用 `vllm-bench` 持续压

- 栈：`vllm-rs serve REPO_HOME/models/Qwen3-0.6B --data-parallel-size-local 0`
  + 自编译 `vllm-mock-engine`，走真实 ZMQ + msgpack 握手。
- 冒烟：`/health`、`/v1/models`、`/v1/chat/completions`（整包 + SSE）全 200。
- 持续压：200/200 成功，`1238.7 req/s`、`158.5k output tok/s`，
  前端 CPU `0.28 s` / 窗口 `2.03 s`（c=8、ISL=1k、OSL=128）。
- 证据：`data/gates/g1-smoke-bench-result.json`、`data/gates/g1-frontend-cpu.json`。
- 复用脚本：`harness/common/stack.sh`（起停）、`harness/common/run_load.sh`（打负载 + 采 CPU）。

**踩坑**：前端要先绑好 ZMQ 握手插座、引擎连上后 HTTP 才开；先轮询 `/health` 必然超时。
另：从短命 shell 用 `nohup ... &` 起的后台编译会被会话回收，改用受控会话。

### G2 ✅ 通过 —— 宿主机 `perf` 能采到 Rust 帧

- `perf_event_paranoid=2`（只能采用户态，够用），`perf record -p <前端pid> -e cpu-clock -F 999 -g`。
- 20 s 窗口拿到 **12175 个样本**，符号可解析：
  `std::thread::local::LocalKey<T>::with`（14.1%）、`vllm_tokenizer::byte_level_decode::decode_byte_level`（2.1%）、
  `mi_free`（2.0%）、`<core::iter::adapters::map::Map ...>::try_fold`（2.2%）。
- 证据：`data/gates/g2-perf-symbol-check.txt`（原始 perf.data 留 `/tmp`，不入 git）。
- **初步信号（待 B 线证实）**：第一名是 TLS（`LocalKey::with`），出现在 `vllm-request` 线程，
  与 tokenizer 后端的 thread-local 使用形状一致；这正好是「Python 的 CPython 派发 → Rust 的 ?」
  这个 Q1 问题的候选答案，但**必须靠 B 线的调用链证据坐实**。

### G3（早期探索，后被下方「✅ 通过」取代）—— 真引擎

**新发现（可能改变 A/B 的做法）**：vLLM 0.26.0 自带 `vllm serve --headless`
（`vllm/entrypoints/cli/serve.py:142,173`）：它只起 **engine core**，不启 API server，
在 `handshake_address` 上等外部前端来握手——这正是 `vllm-rs` 的角色。

于是 A/B 可以做到**同引擎、只换前端**：

| 侧 | 前端进程（被分析对象） | 引擎 |
|---|---|---|
| Rust | `vllm-rs`（独立进程） | `vllm serve <model> --headless`（独立进程） |
| Python | `vllm serve <model>` 的 API server 进程 | 同一个 `vllm serve` 的 engine core 进程 |

两侧前端与引擎之间都是 **ZMQ + msgpack**（v1 引擎协议），所以前端进程的
`utime+stime` 是可比的；差别只在「谁实现前端」。这比 mock engine 版本强得多。

**未决风险**：本机 x86 镜像 `local/vllm-ascend-stub-x86:...-cpuonly-20260922`
与 REMOTE_HOST 的 `a322-cpuonly-*` 镜像能否在**纯 CPU** 上真的跑起 vLLM 引擎（含 forward），
需要实测。C 线负责打通；打不通就按计划退化为 mock engine A/B，并显式标注。

### G3 ✅ 通过（2026-09-25 下午，C 线完成，根代理复核关键证据）

**结论：纯 CPU 真引擎可行，且 A/B 达到本计划能做到的最强口径——「同一个引擎，只换前端」。**

证据链（每一步都可复核）：

1. **官方 CPU wheel 的构建 commit 与计划锁定值一致**：`wheels.vllm.ai/0.26.0/cpu/vllm/`
   的三个 wheel 下载路径均嵌 `568afb3a13806beb53bb2e6bd518269357b237c0`
   （`data/gates/g3-cpu-wheel-commit.txt`，根代理独立复核）。
2. **容器内实测**：`python:3.12-slim` + `vllm-0.26.0+cpu` wheel，`current_platform = CpuPlatform`，
   `torch_npu` / `vllm_ascend` **均未安装** ⇒ 真纯 CPU，**不碰 NPU**。
3. **真实 forward 跑通**：`VLLM_USE_RUST_FRONTEND=1 VLLM_RUST_FRONTEND_PATH=auto
   vllm serve /models/Qwen3-0.6B` 返回正常 chat completion
   （`prompt_tokens=14, completion_tokens=16`）。
4. **进程拓扑实证**（`/proc/<pid>/status` 的 `NSpid` 做容器内外 pid 对应）：
   `supervisor`（`python vllm serve`，只编排，不做 HTTP）+ `frontend`
   （`vllm-rs frontend --listen-fd 3`，7 线程）← **被分析对象** +
   `VLLM::EngineCore`（15 线程）+ `VLLM::Worker`（53 线程）。
   这与 A 线 `docs/01b` 推的「拓扑 C」一致。
5. **两侧唯一变量是前端**：

   | | 启动方式 | 谁做 HTTP |
   |---|---|---|
   | Rust 臂 | `VLLM_USE_RUST_FRONTEND=1 vllm serve <model>` | `vllm-rs` 子进程 |
   | Python 臂 | `vllm serve <model>` | 主进程自己（拓扑 A） |

   引擎侧完全同源（同一 wheel、同一 commit、同一模型、同一 `vllm serve` 命令行）。

**踩到的坑（已固化进 `harness/ab/build_image.sh`）**：
官方 CPU wheel 的 `_C*.so` 其 `PT_GNU_STACK` 带 X 位 ⇒ 内核拒绝 execstack ⇒
`ImportError: cannot enable executable stack`；解法是清掉该段的 `PF_X`。
另需 `libnuma1`（运行）与 `g++`（inductor 编译）。

**同时暴露的装置限制（必须随结论引用）**：本机 x86 纯 CPU 引擎**极慢**——
实测 **TPOT 245 ms/token**（Qwen3-0.6B，c=1），比 `PREPARE_INPUT_PROJECT` 项目在
Kunpeng 920B + Ascend 910 上测到的 engine core 单步 p50（4.9 ms/token）**慢约 50×**。
⇒ 这个装置能**证伪**「换前端能省端到端延迟」，但**答不了 Q3/Q4**；
`docs/06` 因此改用「前端绝对成本 × 引擎速度轴」的外推表（`harness/scale/extrapolate.py`）。

**根代理自查发现并已向 C 线指出的量级异常**：C1-rust 前端 CPU 0.23 s / 4 请求
= **57.5 ms/请求**，而 B 线 mock engine 模型给出 **0.90 ms/请求**（差 60×）。
已要求 C 线把「初始化 CPU」与「稳态每请求 CPU」分开报（最可能的原因：窗口混进了
启动/冒烟/预热，而 PCRE2 JIT 编译属一次性开销）；若排除后差距仍在，
则说明「前端成本随引擎形态变化」，B 线模型在 `docs/06` 里正是标为**未验证的假设**。

## 3. 分工与红线

- 四条线各一个 worktree、一个分支，提交后由根代理合并；**禁止 push / rebase / reset --hard / 动 main**。
- 子代理**不得再派孙代理**（用户明确要求），已写进每份任务书。
- 重活必须 `scripts/heavy_lock.sh scripts/limit.sh <cmd>`（全局唯一重活锁，避免互相污染测量）。
- 不碰 NPU、不占卡；不写其它项目目录。

## 4. 分线执行结果（原「下一步」清单，已完成）

| 线 | 计划做的事 | 实际结果 |
|---|---|---|
| A | P1–P10 行号核实 + Python 侧对照 | ✅ `docs/01`（786 行）+ `docs/01b`（404 行，Python 前端锚点，**超出原计划**） |
| B | B1–B5 采集矩阵（火焰图 + `perf stat`） | ✅ x86 的 B1–B5 + **装置变更后在 REMOTE_HOST 重做 A1/A4/A5**（含 Python 前端对照）→ `docs/02`（1448 行）、`docs/03` |
| C | 真引擎可行性（G3）→ 同引擎只换前端 A/B | ✅ G3 打通（**比原计划的 mock 退路强得多**）；C1–C5 + 受控点 → `docs/04`（465 行）、`docs/ab-design.md` |
| D | P2/P3/P6/P10 微基准 | ✅ `docs/05`（491 行）+ **D6 预分词补测**（超出原计划，命中 B 线发现的 PCRE2 缺口） |
| 根 | `docs/00`、`docs/06`、合并、净化发布 | ✅ `docs/00`（113 行）、`docs/06`（417 行）、四线合并、净化导出通过 |

**两处超出原计划的收获**（都改变了项目结论）：
1. **A 线发现计划本身的口径错误**——`frontend_bound 66.01%` 属 engine core 而非
   Python 前端，据此重写了 Q1 的提法与 `docs/03` 的三层骨架（见 §5）；
2. **D 线的 D6 与 C 线的边际成本模型**——前者把 P4 的成本归因从 BPE 转到
   **PCRE2 预分词正则**（占 encode 的 71–89%），后者把「每请求成本」拆成
   **空转 + 边际**（表观比值 0.225 → 边际 0.155）。

## 5. ⚠️ 重大口径纠错：`frontend_bound 66.01%` 是 engine core，不是 Python 前端

### 5.1 事实与证据

计划初稿（`README.md`、`plan/EXECUTION.md §1`）把
`PREPARE_INPUT_PROJECT` 的 `frontend_bound 66.01%` / `IPC 0.771`
当成「**Python 前端**热点」。**这是错的。**

| 证据 | 内容 |
|---|---|
| `PREPARE_INPUT_PROJECT/docs/05-hotspots.md:243` | 「目标 = **engine-core 宿主 TID 704908**」——topdown 的采集目标 |
| 同文 §3 | 分析对象是 `vllm_ascend/ops/gdn_attn_builder.py::AscendGDNAttentionMetadataBuilder.build` 等 **engine core** 内部代码 |
| `tokenizer/docs/02-cost-and-share.md:34-49` | 该项目的进程归属**实测**：`tokenizer:` 三 scope 在 **pid=1（API server 前端）**，`Step:Model`/`phase:*` 在 **pid=131（engine core）** |

⇒ `PREPARE_INPUT_PROJECT` 测的是 **engine core 的 `prepare_input`**；
`tokenizer` 测的才是 **API server 前端**。两者是不同进程，不能用同一个数字描述。

### 5.2 为什么这件事重要

1. **换 Rust 前端根本不改变 engine core**。66% 与本计划要回答的「前端收益」**无关**。
2. **Python API server 前端侧，现成的 topdown/IPC 数据是「没有」的**——只有
   `tokenizer` 项目的 µs 级 scope 时间（且部分是 aarch64 真机），跨装置不可直接比。
3. ⇒ **C 线升级为 Q1 与 Q3 的共同主证据**：只有在同一台机器上采「Rust 前端 vs
   Python 前端」的 `perf stat`，这个对照才第一次真正成立。
4. `docs/03` 改为**三层**组织（层 1 同装置同口径 / 层 2 跨装置只比趋势 /
   层 3 明确划出界外），已同步 B 线。

### 5.3 已做的处置

- 修订 `plan/EXECUTION.md`（新增 §2.3、改写 §1 表格与 Q1、修订 §11 判据）。
- 修订 `plan/COORDINATION.md`（§2 只读参考定位、§5.4 `perf stat` 口径）。
- 修订 `plan/experiment-matrix.md §8` 与 `README.md` 的对应表述。
- 同步 B 线（`docs/03` 按三层骨架写）与 C 线（新增必做项：同一台机器上两侧前端
  的 `perf stat` 对照；并验证 `vllm serve` 的 API server / engine core 进程拓扑）。

### 5.4 尚未解决的遗留问题

- **Python 前端侧到底有没有可比的 topdown 数据？** 目前结论是「没有同装置的」。
  若 C 线在 REMOTE_HOST（aarch64，有 libkperfx）上做 A/B，则两侧都可尝试 topdown；
  但那要把整个 A/B 搬到 REMOTE_HOST。**建议先保证 x86 上的 IPC 对照**，REMOTE_HOST 作为加强项。
- **计划 §1 的叙事要被重写**：原话「Python 前端的成本主要不在 tokenizer，而在整层
  解释器执行」对 **engine core** 成立，对 **API server 前端**是否成立，**未知**
  （只有 tokenizer 项目的 µs 级 scope 数字支持「不在 tokenizer」，但没有
  topdown 证据支持「在解释器执行」）。`docs/00` 收口时必须按实测写，不能沿用旧叙事。

### 5.5 ⚠️ 装置变更（2026-09-25 下午，用户指示）：主 profiling 迁到 REMOTE_HOST chip4

用户指示：**不在本机 x86 做主要 profiling**，改用 `ssh REMOTE_HOST` 的
**chip4（`/dev/davinci4`）** + **vLLM 0.26 镜像**。

#### 为什么这个变更是对的

| 装置 | 引擎速度（TPOT） | 前端占服务端 CPU | 能否回答 Q1/Q3/Q4 |
|---|---|---|---|
| 本机 x86 纯 CPU | **245 ms/token** | Rust 0.08%（实测） | ❌ 前端被压到噪声里 |
| **REMOTE_HOST chip4（真 NPU）** | **4.7–5.1 ms/token** | Rust **1.22%** / Python **4.97%**（实测） | ✅ |
| `PREPARE_INPUT_PROJECT` 基线（同机 aarch64+NPU） | 4.915 ms/token | — | 口径可对齐 |

⇒ REMOTE_HOST chip4 的引擎速度与既有 engine-core 基线**几乎一致**（4.72 vs 4.915 ms），
是唯一能同时「和真机基线对上口径」且「前端成本可见」的装置。

#### 镜像与二进制（可复现链）

| 项 | 值 |
|---|---|
| 镜像 | `quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler` |
| 镜像内 vLLM 源码 | `/vllm-workspace/vllm` @ **`568afb3a`**（与 `plan/COORDINATION.md §3` 锁定值一字不差） |
| 镜像内 vllm-ascend | `f2f74a16c` |
| `vllm-rs` 二进制 | 镜像**不自带**（无 cargo）⇒ 用官方 aarch64 wheel 抽取：<br>`scripts/fetch_vllm_rs.py --arch aarch64` → `REMOTE_HOST:~/projects/vllm/vllm-rs/bin/vllm-rs`<br>sha256 `cae05321227ed3c7c7c386ca5c2e96d58f8261d80e03d3923890ef06d540dc0b`（not stripped） |

#### 跨版本探测（回答「哪个 vLLM 版本能启用 vllm-rs」）

`scripts/probe_wheel_versions.py`（HTTP Range 只读 zip 中央目录，不下载整包）实测：

| 版本 | `vllm/vllm-rs` | `vllm/_rust_tool_parser.abi3.so` |
|---|---|---|
| 0.26.0 / 0.27.0 / 0.28.0 | ✅ | ✅ |
| 0.25.1 / 0.25.0 / 0.24.0 | ✅ | ✅ |
| 0.23.0 / 0.22.1 / **0.22.0** | ✅ | ❌ |
| 0.21.0 / 0.20.x / 0.19.1 / 0.18.1 | ❌ | ❌ |

⇒ **`vllm-rs` 自 v0.22.0 起随 wheel 发布**；`VLLM_USE_RUST_FRONTEND` 开关
在 `vllm/envs.py` 的出现次数也同为 0.21.0=0 / 0.22.0=8 / 0.26.0=8，两者一致。
**v0.26.0 可用**（本项目锁定版本）。

#### 首个 A/B 结果（REMOTE_HOST chip4，C1：ISL=1024 / OSL=128 / c=1 / n=32，只换前端）

| | Rust（`vllm-rs`） | Python（API server） | 比值 |
|---|---:|---:|---:|
| **前端 CPU** | **0.34 s（10.6 ms/请求）** | **1.49 s（46.6 ms/请求）** | **0.228** |
| 引擎 CPU | 27.45 s | 28.46 s | 0.96 |
| 前端占服务端 CPU | **1.22%** | **4.97%** | — |
| 吞吐 / TTFT / TPOT | 1.465 req/s / 83.1 ms / 4.72 ms | 1.347 req/s / 96.4 ms / 5.09 ms | — |

证据：`data/ab/a3-chiplock/SUMMARY.json`（含三条 caveat）。

**⚠️ 引用前必读**：① 各只跑一轮、n=32、无重复，**差异里含 run-to-run 波动**
（两侧 TPOT 差 0.37 ms ≈ 装置 ±4% 波动）；② TTFT 差 −13.3 ms **不能全归给前端**
（含 prefill 与排队）；③ 正式矩阵由 C 线补重复与并发/长度扫描。

#### 新增基础设施（已合并）

`harness/a3/{ab_serve,point,chip_lock,sync}.sh` —— 起停服务容器（chip4）、
单点测量（procstat 全进程分桶 + perf stat + 归一化指标）、**chip4 远端互斥锁**、
本地↔REMOTE_HOST 同步。四条线的实验一律走这些脚本，保证同口径。

#### 踩过的坑（都已修进脚本）

1. `sudo perf ... &` 会 fork 出真正的 perf 子进程，**给 sudo 的 pid 发 SIGINT 不会
   传到 perf** ⇒ `wait` 永久挂住（观测到 ssh 会话挂 10 分钟）。
   修法：`setsid` + 取**孙进程** pid（`pgrep -P` 两层）+ `pkill -INT -f` 兜底 +
   有界等待 30 s 后强杀。
2. 后台任务**绝不能继承脚本 stdout**：ssh 的 `... | tail` 会一直等管道 EOF，
   只要有一个后台后代持有写端，ssh 就永不返回。修法：`</dev/null >>log 2>>log`。
3. `vllm bench serve` 的 `--base-url` **不带 `/v1`**，且必须显式给
   `--endpoint /v1/chat/completions`，否则报 `URL must end with ...`。
4. 容器里直接 `--entrypoint bash` 会跳过 CANN 环境 ⇒ `import torch_npu` 失败；
   用镜像默认入口（它会 source CANN env 再 exec）即可。

> 发现者：A 线；核实与修订：根代理。已写入 `plan/EXECUTION.md §2.3`（plan 只有根代理能改）。

## 6. ✅ 收口终审（2026-09-25 收尾）

### 6.1 目标逐条核对

| # | 要求 | 状态 | 证据 |
|---|---|---|---|
| ① | REMOTE_HOST chip4 上 `vllm-rs` + 真实引擎打通 | ✅ | 镜像内 vLLM commit `568afb3a` 与计划锁定值一致；aarch64 wheel 抽取的 `vllm-rs`（sha256 `cae05321…`）跑通真实 chat；`data/gates/g3-cpu-wheel-commit.txt` |
| ② | B 线 profiling 迁到 REMOTE_HOST（火焰图 + `perf stat` + IPC，同机可比 Python 前端） | ✅ | `docs/02` §14（14 小节）、`docs/03` §1；A1 Rust / A4 Python 火焰图并列；层 1 IPC 表 |
| ③ | C 线 A/B 用同一镜像／同一引擎／只换前端 | ✅ | `docs/04`（C1–C5 + 受控点 I8k/S16 + 两点法边际成本）、`docs/ab-design.md` |
| ④ | 合并各线成果，更新 `docs/04`、`docs/03` 层 1、`docs/06` 比值 | ✅ | 四线全部 `merge --no-ff` 进 main（A `3754422`/`f0146b7`、B `a30fdb2`、C `8cb3e81`、D `7d5d2b6`/`a8bc5b3`） |
| ⑤ | 收口 `docs/00-INDEX`、全量锚点与数字一致性审计、净化导出 | ✅ | `docs/00` 113 行；锚点 **457 条 / 0 问题**；净化导出**通过全部门禁**（11 个原值残留 0） |

### 6.2 交付物总量

| 项 | 数量 |
|---|---|
| 文档 | **10 篇 / 4 771 行**（`docs/00`–`06`、`01b`、`ab-design`、`SANITIZATION`） |
| 图 | **9 张 SVG**（x86 的 B1–B4 + 分段着色；REMOTE_HOST 的 A1/A4 各自原图 + 分段着色） |
| 数据 | 564 个跟踪文件（`data/{gates,ab,micro,profiles,static}`），无原始 `perf.data` |
| harness / scripts | 78 个文件；用户可见脚本 **61 个带 `--help`** |
| 全仓库 | 684 个跟踪文件 / 9.7 MB（最大单文件 224 KB） |

**`--help` 的 5 个例外**（都合理，非缺口）：`harness/common/env.sh` 与
`harness/ab/ab_env.sh` 是**被 source 的库**（文件头写明用法）；
`harness/micro/python/ecr_types.py` 是**类型定义模块**无 CLI；
`harness/profile/mock_engine_chunk_wrapper.sh` 是**透传参数的包装器**；
`scripts/limit.sh` **无参数时即打印完整用法**。

### 6.3 跨文档一致性

关键数字在文档间一致（抽查 16 个量，分布在 2–6 份文档，无冲突）：
`10.31/45.94 ms`（前端 CPU/请求）、`0.225`（C1 比值）、`0.155`（边际比值）、
`5.86/37.83 ms`（边际成本）、`17.03%`（C2 时 Python 占服务端 CPU）、
`0.7243/1.1638`（IPC）、`0.0745`（每请求指令数比）、`18.31%`（`_PyEval`）、
`30.03%`（Rust 内核帧）、`13.4×`、`41.71%`（P4 @ISL=8k）、`208 次 write/请求`、`32.9%`（内核态）。

**收口过程中修正的两处自身错误**（都由交叉审阅发现，已写进文档）：
1. 我在 `docs/00` 引用层 1 时用了**总量比值 0.112**，B 线指出应按请求归一化
   （两次 A5 完成数 96 vs 64）⇒ 正确值 **0.0745（省 13.4×）**；
2. 我早期 `docs/06` 的表 A **漏算 prefill 的 TTFT**，把前端占比高估约 3 倍
   ⇒ 补齐后最高占比从 23–29% 修正为 **8.6%**。

### 6.4 净化导出（✅ 通过）

```bash
bash scripts/export_publish.sh --no-push --out ../vllm-rs-publish3
```

结果：**11 个原值残留文件数全为 0**；683 文件 / 9.7 MB；**单点历史**；
作者为 GitHub noreply；无 `refs/`、`runs/`、`target/`、`.locks/`、
`.sanitize-map.tsv`、`*perf.data*`。产物：`../vllm-rs-publish3`。

**首次导出被自己的 gate 拦下并修掉三处自身泄漏**（过程见 `PUBLISH.md §4.1`）：
净化模板用真实项目名当示例、`PUBLISH.md` 基线表写了原值、`SANITIZATION.md` 提到真实目录名。

### 6.5 资源清场

| 资源 | 状态 |
|---|---|
| 本机重活锁 | **FREE** |
| 本机残留进程（vllm-rs / mock-engine / vllm-bench / perf / cargo） | **无** |
| 本机 loadavg | 1.5 / 2.2 / 1.8（常态） |
| REMOTE_HOST chip4 容器与锁 | 各线收尾时均已停容器、放锁（B 线最后一次确认：chip4 已清、锁 FREE）；**收尾时 VPN 中断，未能再次复验** |

> ⚠️ **诚实记录**：最后一次远端复验时 VPN 中断，无法再连 REMOTE_HOST_HIST/REMOTE_HOST。
> 此前各线的收尾消息均声明「容器 0 残留、锁已交还」，且我本人在
> 17:43 亲验过 chip4 锁为 FREE、无 `vrs-ab-*` 容器。**恢复网络后建议复核一次**
> （一条命令：`harness/a3/chip_lock.sh --status`，以及
> `ssh REMOTE_HOST 'sudo -n docker ps -a --filter name=vrs-ab'`）。

### 6.6 未做到（汇总，各章末有详表）

| 项 | 原因 |
|---|---|
| B 线的 A2（c=64）/A3（ISL=8k）规模点 | 时间盒收口；**C 线的 `docs/04` 已用同装置覆盖这两个维度** |
| P4 分词的同口径 Rust vs Python | 微基准只引用了前项目结论，跨装置不可比 |
| 前端 CPU 中「关键路径 vs 并行」的精确拆分 | 用 TTFT+TPOT 差分估得 ≈53%，未做插桩分解 |
| 内核**函数级**去向 | `/proc/kallsyms` 地址为 0，取不到符号 |
| C2–C5 的多次重复 | 机时需与 B 线串行，仅 C1 重复 3 次 |
| 多模态 / 结构化输出 / LoRA / gRPC 路径 | 按计划不覆盖 |
