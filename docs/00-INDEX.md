# vllm-rs 前端 CPU 负载分析 —— 总览

> 分析对象：**vLLM 0.26.0 自带的 Rust 前端 `vllm-rs`**
> （commit `568afb3a13806beb53bb2e6bd518269357b237c0`）。
> 视角与前两个项目一致：**这段代码在 CPU 上干了什么、花了多少**，而不是看重构本身。
>
> 状态：**执行中**（2026-09-25）。本页是入口，各章为独立交付物。

---

## 0. 一分钟结论

1. **`Rust 前端把什么换掉了`：CPython 求值循环 → tokio 分发 + 内核态 + 搬运。**
   同装置同负载下（REMOTE_HOST chip4）：
   Python 前端 top-1 是 **`_PyEval_EvalFrameDefault` 18.31%**（后随 `_PyType_Lookup`、
   `_PyObject_Malloc`、`unicodekeys_lookup_unicode` 一整套**解释器逐条派发 + 对象内务**指纹）；
   Rust 前端 top-1 是 **内核帧 30.03%**，后随 tokio 调度器一族、`mi_free`、`rmp_serde::decode`
   ——**全是调度/唤醒/搬运，没有任何解释器痕迹**。
   ⇒ **`_PyEval` 那 18.31% 被换成了 tokio 分发（21.92%）+ 内核态（32.86%）+ 拷贝/分配（7.9%）**。
   而且**后者的形状取决于引擎 tick 粒度**：密集 tick（mock）下拷贝/分配主导、可批量摊销；
   稀疏 tick（真引擎，4.8 ms/tick）下唤醒/收包主导。⇒ `docs/02`、`docs/03`
2. **短 prompt 上换 Rust 前端省的是 CPU，不是延迟；长 prompt 上延迟收益才真实。**
   C1（ISL=1k）前端只占端到端 **1.5%**、两侧 TTFT 只差 **6.8 ms**，且前端 CPU 的差额里
   **只有约 53% 落在关键路径上**；但受控点 I8k（ISL=8k）实测 **TTFT 差 −82.8 ms**
   ——**唯一测到的、幅度足够让用户感知的延迟收益**。⇒ `docs/06` §2、§6.2/§6.3
3. **省 CPU 这件事是实打实的，且高并发下变成规划项：** 前端 CPU
   **Rust/Python = 0.225（c=1）～ 0.316（c=64）**，扣掉空转后的**边际比值 0.155
   （省 6.5×）**；c=64 时 Python 前端占到**服务端总 CPU 的 17.03%**，Rust 只占 6.02%。
   机制层面（`docs/03` §1.1，**按请求归一化**）：**每请求指令数 9.775 M vs 131.247 M
   ⇒ Rust 只有 Python 的 0.0745（省 13.4×）**；
   但 **IPC 反而是 Rust 更低（0.7243 vs 1.1638）**，因为 Python 指令多而每条轻、
   Rust 指令少而每条重（内存搬运 + 系统调用 + 内核态占 32.9%）。
   ⇒ **IPC 不能跨实现直接比大小**。⇒ `docs/04`（★）、`docs/03`
4. **单核前端只能撑上百 req/s 量级**：按两点法解出的**边际成本**，
   Rust **≈171 req/s**、Python ≈26 req/s（**Python 要 6.5 倍的核**）；
   Rust 前端连空转都更低（0.57% vs 0.90% 单核）。
   不是早期估算的上千——真引擎的稀疏 tick 让前端无法批量摊销。⇒ `docs/06` §3
5. **最值得动的下一刀在 Rust 前端自己身上，不在换语言：**
   ISL=8k 时 **P4 分词占前端 on-CPU 的 41.71%**，其中 **71–89% 是 PCRE2 预分词正则**；
   稀疏 tick 场景下 **208 次 `write`/请求**（OSL=128）与 **32.9% 内核态**才是大头。
   ⇒ `docs/02` §7、`docs/05` §6

---

## 1. 导览

| 文档 | 内容 | 线 |
|---|---|---|
| [`01-request-path.md`](01-request-path.md) | **P1–P10 逐段分解**：行号级代码位置、CPU 上干什么、调用图、与 Python 前端逐段对照、成本假设 | A |
| [`01b-python-frontend-anchors.md`](01b-python-frontend-anchors.md) | **Python 前端侧锚点**：`vllm serve` 的四种进程拓扑、线程布局、`--headless` 约束（供 A/B 用） | A |
| [`02-cpu-profile.md`](02-cpu-profile.md) | ★ **火焰图 + 硬件计数**：热点在哪、是什么（x86 与 REMOTE_HOST 两套装置） | B |
| [`03-hotspot-migration.md`](03-hotspot-migration.md) | ★ **热点迁移**：Python 派发 → Rust 的什么（按三层口径组织） | B |
| [`04-ab-comparison.md`](04-ab-comparison.md) | ★ **同机 A/B**：同一镜像、同一引擎、只换前端（REMOTE_HOST chip4）；含两点法边际成本模型 | C |
| [`ab-design.md`](ab-design.md) | A/B 的**实验设计与公平性论证**（进程拓扑实证、客户端隔离、用卡纪律、踩坑） | C |
| [`05-segment-costs.md`](05-segment-costs.md) | **逐段微基准**：P2/P3/P6/P7/P10 的 µs 与相对占比（含 D6 预分词补测） | D |
| [`06-scale-and-tradeoffs.md`](06-scale-and-tradeoffs.md) | **规模拐点与选型建议**：延迟轴 vs 容量轴、什么时候值得换 | 根代理 |

---

## 2. 装置与口径（**引用任何数字前必读**）

### 2.1 两套装置，不可混用

| | **REMOTE_HOST chip4（主）** | 本机 x86（辅助） |
|---|---|---|
| 引擎 | Ascend 910 真 NPU，TPOT **4.7 ms**/token | 纯 CPU 引擎，TPOT **245 ms**/token；或 mock engine |
| 用途 | A/B、火焰图、`perf stat`/IPC | 微基准、静态分析、方法学预研 |
| 前端占服务端 CPU | Rust **1.22%** / Python **5.10%**（c=1） | Rust 0.08%（被引擎压成噪声） |
| 结论适用范围 | **主结论** | 仅作趋势与乐观上界 |

### 2.2 三条必须随数字一起搬运的口径警告

1. **`frontend_bound 66.01%` / `IPC 0.771`（`PREPARE_INPUT_PROJECT`）是
   engine core 进程的数字，不是 Python 前端。** 换 Rust 前端**不改变 engine core**，
   该数字与本计划的前端收益无关。详见 `plan/EXECUTION.md §2.3`。
2. **Python 前端侧没有现成的 topdown/IPC 数据**——那必须在本计划的装置上实测，
   这正是 `docs/04` 与 `docs/03` 层 1 的内容。
3. **前端每请求成本取决于引擎 tick 粒度**：x86 + mock engine 1.83 ms ↔
   REMOTE_HOST + 真引擎 9.53 ms（**5.2×**）。容量规划只能用真引擎那一列。见 `docs/06 §3.1`。

### 2.3 两条实测出来的坑（会改变你怎么读数据）

* **`npu-smi` 的 `-i` 是 NPU ID，不是 davinci 编号**：我们的卡 = `npu-smi -i 2`
  = `/dev/davinci4`（见 `harness/a3/README.md`）。
* **只用用户态采样会系统性低估前端成本**：Rust 前端有 **32.9% 的样本在内核态**
  （全栈采样）/ **stime 占 49%**（procstat，x86），且低估幅度与引擎 tick 粒度强相关。

---

## 3. 复现入口

| 目的 | 入口 |
|---|---|
| 拿 `vllm-rs` 二进制（x86 / aarch64） | `scripts/fetch_vllm_rs.py --arch <arch>`（HTTP Range，只下 ~6% 的 wheel） |
| 查某版本 wheel 是否有 Rust 前端 | `scripts/probe_wheel_versions.py <版本...>`（实测：**v0.22.0 起有**） |
| REMOTE_HOST chip4 上的 A/B | `harness/a3/README.md`（含用卡纪律、锁、踩坑） |
| 本机 x86 微基准 | `harness/micro/run_micro.sh`（D 线，一键复跑） |
| 火焰图（x86） | `harness/profile/`（B 线，9 个脚本） |
| 行号锚点复核 | `harness/static/check_anchors.sh docs/*.md`（当前 455 条 / 0 问题） |
| 发布前净化 | `scripts/sanitize_for_publish.sh --check` + `scripts/export_publish.sh` |

---

## 4. 未测与边界（摘要，详见各章末）

| 项 | 状态 |
|---|---|
| engine core 内部（调度/forward/sample） | **不做**（另一个课题，`PREPARE_INPUT_PROJECT` 覆盖了一部分） |
| P4 分词的同口径 Rust vs Python | **未测**（`docs/05` D5 引用 tokenizer 项目，跨装置不可比） |
| ISL 与 OSL 对「Rust/Python 比值」的分离 | **未测**（C1→C3 两轴同变，且观察到与分段结论相悖的方向） |
| 前端 CPU 中「关键路径 vs 并行」的精确拆分 | **部分**（用 TTFT+TPOT 差分估计 ≈53%，未做分解实验） |
| 多模态 / 结构化输出 / LoRA / gRPC 路径 | **未测**（按计划不覆盖） |
| 长期稳定性 / 压到崩溃 | **不做**（只做稳态采样） |
