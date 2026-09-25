# vllm-rs CPU 负载分析 —— 协作约定

> 建立：2026-09-25（Asia/Shanghai）。**所有 agent 动手前先读本文件与 `EXECUTION.md`。**
> 本文件与 `EXECUTION.md`、`experiment-matrix.md` 同为**待评审计划**的一部分。

## 1. 目标（一句话）

说清 `vllm-rs`（Rust 前端）在 CPU 上**干了什么活、活花在哪、相对 Python 前端热点怎么迁移**。

## 2. 唯一写入范围（硬约束）

| 位置 | 路径 |
|---|---|
| 本仓库（主工作区） | `REPO_HOME/projects/vllm/vllm-rs` |
| 各 agent 工作区 | `REPO_HOME/projects/vllm/vllm-rs-wt/<line>`（git worktree） |
| 本地只读参考 | `REPO_HOME/projects/vllm/UPSTREAM_PROJECT/vllm`（vLLM 0.26.0 源码，浅克隆） |
| 本地只读参考 | `REPO_HOME/projects/vllm/tokenizer`（上一个项目：脚本、结论、`vllm-rs` 二进制） |
| 本地只读参考 | `REPO_HOME/projects/vllm/PREPARE_INPUT_PROJECT`（**engine core** `prepare_input` 热点基线；⚠️ 不是 API server 前端，见 `EXECUTION.md §2.3`） |
| 远端（**主 profiling + A/B**） | `REMOTE_HOST:~/projects/vllm/vllm-rs` —— **chip 4（`/dev/davinci4`）**，见下方 §2.1 |

**禁止**：写其他项目目录；动宿主机系统配置；**碰指定之外的任何 NPU 设备**
（见 §2.1 的授权范围与红线）。

### 2.1 ⚠️ 授权变更（2026-09-25，用户指示）

用户指示：**不在本机 x86 做主要 profiling**；改用 `ssh REMOTE_HOST` 的
**chip4（`/dev/davinci4`）**，并**使用 vLLM 0.26 镜像**。

因此：

| 项 | 变更前 | **变更后** |
|---|---|---|
| 主 profiling（B 线） | 本机 x86 + mock engine | **REMOTE_HOST chip4 + 真实 NPU 引擎** |
| A/B（C 线） | 本机 x86 纯 CPU 引擎 | **REMOTE_HOST chip4，同一 vLLM 0.26 镜像，只换前端** |
| 本机 x86 的角色 | 主要 | **辅助**：早期 reconnaissance、微基准（D 线）、静态分析（A 线） |

**新的红线（比原计划更具体）**：

1. **只用 chip4 = `/dev/davinci4`**：`--device /dev/davinci4` +
   `ASCEND_RT_VISIBLE_DEVICES=4` + `--cpuset-cpus=160-199` + `--cpuset-mems=2`
   （沿用 `PREPARE_INPUT_PROJECT` 的 chip→资源映射：chipN ⇒ CPU `40N..40N+39`、NUMA `N/2`）。
2. **绝不能** `--device /dev/davinci0..N`、不能用 `ASCEND_RT_VISIBLE_DEVICES=0,1,...`、
   **不动别人的容器**（`yy_vf` / `xh-mk` / `cann910` / `dsv41-lab` / `hotpath-gap-*` 都不是我们的）。
   chip4 上的邻居：`davinci5`（NPU2/Chip1）有他人进程（实测 HBM 44%、AICpu 100%）——
   **不要碰**，我们的容器只映射 davinci4。
3. REMOTE_HOST 是**共享生产机**（640 核 / 2 TB，loadavg 常年在 46 上下）：
   **CPU 只用 cpuset 内的 40 核**，压测客户端绑到别的核（如 200-201），
   不要在宿主上跑与 chip4 无关的重活。

## 3. 统一身份

| 组件 | 值 |
|---|---|
| vLLM | 0.26.0，commit `568afb3a13806beb53bb2e6bd518269357b237c0` |
| Rust 工作区 | `UPSTREAM_PROJECT/vllm/rust`（13 个 crate，约 99 k 行；**浅克隆**，无法历史考古） |
| `vllm-rs` 二进制 | 从官方 PyPI wheel 抽取（x86_64 42.79 MB / aarch64 39.60 MB，**not stripped，161 911 符号**） |
| 抽取脚本 | `tokenizer/harness/rust-frontend/fetch_vllm_rs.py`（HTTP Range，只下 ~6%） |
| mock engine | 上游 `rust/src/mock-engine`（自编译，约 60 s） |
| 本机 | x86_64，12 核，29 GiB |
| 远端 | REMOTE_HOST（aarch64，Kunpeng 920B，640 核），**纯 CPU 用法，不需要 chip 锁** |

## 4. 目录约定

```
plan/         计划与协调（仅根代理可改）
docs/         最终交付文档（中文，00-INDEX.md 为入口）
figures/      图（SVG/PNG），文件名 = 文档编号 + 语义
data/         结构化数据（CSV/JSON）+ manifest；原始 perf.data 不进包
harness/      压测编排 / perf 采集 / mock-engine 启动
scripts/      采集与解析脚本，均需 --help
agents/<line>/REPORT.md   每个 agent 的交接报告（结论 + 失败路径 + 踩坑）
refs/         源码快照（只读）
```

## 5. 数据口径（引用任何数字前必读）

1. **进程归属**：本计划的分析对象是 **`vllm-rs` 进程**。压测客户端（`vllm-bench`
   或 Python `vllm bench`）**是另一个进程**，它自身的 CPU 占用必须单独记录，
   否则会把客户端成本算进服务端。
2. **南北向边界**：ZMQ + msgpack 的**前端侧**算本计划；**engine core 侧不算**。
3. **A/B 必须同口径**：Rust 前端与 Python 前端的对照，必须固定
   **模型 / 负载形态 / ISL / OSL / 并发 / 核数 / 压测客户端**，只变前端。
4. **`perf stat` 必须与 Python 侧同口径**：Python 侧**唯一**的 topdown 数据来自
   **engine core 宿主线程**（`frontend_bound` / `retiring` / IPC，Kunpeng 920B 上用
   libkperfx 采的；见 `EXECUTION.md §2.3`）——**它不能当作「Python 前端」的基线**。
   x86 上没有同样的 topdown 分解 ⇒ **可比的是两侧前端都能采的量**
   （IPC / instructions / cycles），且必须**在同一台机器上**采（C 线负责）；
   `frontend_bound` 分解只在 Kunpeng 上有，文档里必须标注不可比。
5. **火焰图采样参数两边一致**：`perf record` 的频率、call-graph 方式、
   采样窗口长度都要写进 manifest。
6. **每条实验写 manifest**：commit、二进制 sha256、模型 revision、脚本 sha256、
   时间戳、绑核、线程数、测量前后的 loadavg 与可用内存。

## 6. 分工（四条线）

| 线 | 内容 | 主产出 |
|---|---|---|
| `A-path` | P1–P10 链路分解、与 Python 前端逐段对照 | `docs/01-request-path.md` |
| `B-profile` | perf 火焰图 + 硬件计数（Q1 主证据） | `docs/02-cpu-profile.md`、`docs/03-hotspot-migration.md` |
| `C-ab` | Rust vs Python 同负载 A/B（Q3/Q4 主证据） | `docs/04-ab-comparison.md` |
| `D-micro` | 逐段微基准 + 工具链（serde/minijinja/msgpack） | `docs/05-segment-costs.md` |

根代理负责：`docs/00-INDEX.md`、`docs/06-scale-and-tradeoffs.md`、合并、审阅、收口、净化发布。

**冲突规则**：`docs/` 下每个文件只有一个 agent 写；`data/` 按子目录分
（`data/profiles/`、`data/ab/`、`data/micro/`、`data/static/`）；`harness/` 同理；
`plan/` 只有根代理能改。

## 7. Git 约定

- 每个 agent 在自己的 worktree 里提交，分支 `agent/<line>`。
- commit message 用中文，格式：`<line>: <做了什么>`。
- **禁止** `git push`、`git rebase`、`git reset --hard`、改 `main`。
- 完成后写 `agents/<line>/REPORT.md`，然后通知根代理合并。
- P0 门禁未过时**先报告再继续**，不要带着不确定的环境往下跑。

## 8. 红线

- 不碰 NPU / 不占卡；不做需要 GPU 的实验。
- 不删别人数据；不覆盖他人目录；不改 `vllm-rs` 上游代码（本计划是观测，不是改代码）。
- 大文件（>50 MB）不进 git；原始 `perf.data` 留在本地 `/tmp` 或远端，只提交
   折叠后的栈与汇总。
- 结论必须有据：**没测的写"未测"，推断的必须标"推断"**。
- **不许把"Rust 应该更快"当结论**——本计划的核心问题恰恰是"热点变成了什么"，
  而不是"变快了多少"。

## 9. 资源纪律（沿用 tokenizer 项目，硬性）

本机 `LOCAL_HOST` 是**共享开发机**（12 核 / 29 GiB），用户明确要求：
**不要长时间占用过多 CPU（>75%）与内存**。

| 项 | 上限 |
|---|---|
| CPU | ≤ 9 核；基准统一绑 **2–4 核**（A/B 对照时两边一致） |
| 内存 | 单任务 ≤ 8 GiB；容器 `--cpus=6 --memory=8g --memory-swap=8g` |
| 并行编译 | cargo `-j ≤ 4` |
| 串行化 | **全局唯一重活锁** |

**直接复用**（已跑通、带踩坑注释）：

```bash
REPO_HOME/projects/vllm/tokenizer/scripts/limit.sh        # 绑核 + 内存上限
REPO_HOME/projects/vllm/tokenizer/scripts/heavy_lock.sh   # 全局重活锁
REPO_HOME/projects/vllm/tokenizer/scripts/docker_run.sh   # 无卡容器执行器
```

> ⚠️ **`limit.sh` 的 `CORES` 是"绑到哪些核"而不是"几个核"**（tokenizer 项目踩过）：
> `CORES=2` → 1 核；`CORES=4-5` → 2 核；默认 `4-7` → 4 核。运行时会把实际核数打出来。
> **A/B 对照时两侧必须绑同一组核**，否则测的是绑核差异。
