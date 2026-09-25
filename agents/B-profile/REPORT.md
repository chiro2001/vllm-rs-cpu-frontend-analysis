# B-profile 交接报告

> **本轮更新（REMOTE_HOST chip4 主 profiling 轮）见文末 §8–§9**；
> §1–§7 是 x86（mock engine，辅助口径）那一轮的原始记录，保留不改。

> 线 B（火焰图 + 硬件计数），分支 `agent/B-profile`。交付物：
> `docs/02-cpu-profile.md`、`docs/03-hotspot-migration.md`、`harness/profile/`、
> `data/profiles/`、`figures/02-flame-*.svg`。
> 采集时间 2026-09-25，装置 `LOCAL_HOST`（x86_64，AMD，12 核）。

## 1. 结论（3–5 条）

1. **Rust 前端的头号热点是内存拷贝，不是序列化**：`[libc.so.6]` 未解析帧占前端
   on-CPU **15.20%**，按文件内偏移分解后 **≈80% 是 glibc 的 AVX-512 `memmove/memcpy`
   （12.2%）、≈11% 是 AVX-512 `memcmp`（1.7%）**。二者都是**局部符号**，
   `.symtab` 已剥离，本文用「动态符号表 + 反汇编 + fortify 分支」三重证据定名
   （`docs/02` §5.1）。第二名是 **mimalloc 家族 14.18%**。
2. **「分配 + 拷贝 + 调度」三项 = 43.28%，超过 P1–P10 里任何单段**；
   P1–P10 合起来只有 **32.65%**，跨段桶 **67.35%**。
   每多生成一个输出 token，前端多花 **4.22 µs**，其中 **2.30 µs（55%）是拷贝+分配+调度**，
   只有 0.89 µs（21%）落在业务语义段。
3. **最反直觉的一条：分词里的正则子系统占比远超预期。** `fastokens` 的预分词走
   **PCRE2 JIT**（JIT 代码区 2.91% + `pcre2` 帧 ≈1.75%），`Cargo.lock` 反查确认
   **`pcre2` 的唯一使用者是 `fastokens`**；斜率分解显示这些帧**全是 ISL 驱动**
   （JIT 22.1 ns/输入 token）⇒ 坐实 **P4**。P4 段 B1 占 **6.57%**、
   ISL=8k 时升到 **41.71%**。**D 线的 D6 微基准独立证实**（预分词占 fastokens encode 的 71–89%）。
   → 已在采集当天用 `send_message` 提前报给根代理。
4. **硬件指纹（B5，与 B1 同负载）：IPC = 1.120、分支失败率 2.109%、
   L1d load miss 4.595%、cache miss 19.90%。** `perf stat` 的 8 事件多路复用把吞吐从
   618.9 req/s 压到 **271.5 req/s（−56%）** ⇒ **IPC 可用、绝对计数不可当"正常表现"用**。
5. **成本可以对长度线性分解**（三点拟合 + B1 留一点验证，误差 −2.6%）：
   `每请求 on-CPU ns ≈ 285 000 + 77.6×ISL + 4 220×OSL`
   ⇒ **一个输出 token 的前端成本 ≈ 一个输入 token 的 54 倍**；
   c=64 相比 c=1 只摊掉 28% 的每请求成本，且摊掉的全是"每请求/每 tick 固定项"，
   按 token 计费的段几乎不动。

## 2. 方法学：两个会让别人重踩的坑（都已用实测数字坐实）

1. **`--call-graph dwarf` 在这份二进制上不能用。** 同负载同窗口对照：
   dwarf 3991 样本只折出 **15 个唯一栈、深度 ≤2、上层是垃圾地址**（把栈上数据当返回地址），
   代价是 **63 MB / 3991 样本**与 **≈2.5 min** 后处理（是负载时长的 15 倍）；
   fp 同样窗口给出 **731 个唯一栈、深度 2–128**、310 KB、秒级后处理。
   ⇒ **B1–B4 全部用 `--call-graph fp`**（任务书要求"两种都试、写明实际用的哪种"，这是答案）。
   另：本机 AMD 平台 **`--call-graph lbr` 不支持**（"PMU Hardware or event type doesn't
   support branch stack sampling"）。
2. **fp 栈浅是硬限制，不能装作没看见**：60%/48% 的样本只有「线程名 + 叶子帧」两帧
   （探针/B1 两个口径）。因此分段归属不靠完整调用链，而靠
   **叶子符号 + 线程方向 + 三点差分斜率**三角验证（`docs/02` §8）。
   **建议 C 线采 Python 前端时先做同样的 5 分钟 fp/dwarf 对比**——否则会拿到一张
   看起来完整、其实是噪声的火焰图。

## 3. 口径纠错（根代理 2026-09-25 通知，已按三层骨架写进 `docs/03`）

**计划里「Python 前端热点 = CPython 逐条派发（`frontend_bound 66.01%` / IPC 0.771）」
是错的**：那个 topdown 的采集目标是 **engine core 主线程**（`PREPARE_INPUT_PROJECT`
`docs/05-hotspots.md:243` 写明 TID 704908），不是 API server 前端进程。
换 Rust 前端**不改变 engine core**，所以该数字与"换前端能省多少"无关。

`docs/03` 据此分三层：

- **层 1（同装置同口径，唯一严格可比）**：Rust vs Python 前端的 `perf stat`/IPC
  —— **待 C 线**。本文已把 Rust 侧那一半（B5）与两个必须随数字搬走的警告写好，
  并留了表格位置。B 线的自身缺口也如实列出：`raw_load.py` 只记压测端 CPU，
  **没接 `procstat.sh` 记前端 `/proc/<pid>/stat`**。
- **层 2（跨装置，只比形状/趋势）**：Rust 采样占比 vs Python µs 级 scope 计时。
  已给出四条形状对照（P3 都是常数级、P4 都线性于 ISL 且长 prompt 时变大头、
  P8 都线性于 OSL、P2 不可比）与线程拓扑对照（Python 只有 1 个事件循环 + 默认 1 个
  渲染 worker；Rust 有 3 个 runtime）。
- **层 3（划出界外）**：明确写清 `frontend_bound 66.01%` 属 engine core，
  并指出 `tokenizer` 项目的 scope 数据**确实是前端进程**（pid=1），两者不要混。

## 4. 交付物清单

| 路径 | 内容 |
|---|---|
| `docs/02-cpu-profile.md` | ★ 火焰图 + 硬件计数（686 行）：采样方法对照、top-N、帧→P1–P10 映射与占比、差分斜率、IPC、采样开销、局限 |
| `docs/03-hotspot-migration.md` | ★ 热点迁移（190 行）：三层口径骨架 + 形状对照 + 迁移对照表 |
| `agents/B-profile/REPORT.md` | 本文件 |
| `harness/profile/` | 9 个脚本，全部 `--help`：`raw_load.py`（raw-payload 压测器）、`perf_record.sh`、`perf_stat.sh`、`folded_stats.py`、`slope_model.py`、`sym_offset.py`、`flamegraph.sh`、`recolor_svg.py`、`run_matrix.sh` + `segments.json` + `libc_symbols.json` + `README.md` |
| `data/profiles/` | B1/B1n/B2/B3/B4/B5 的折叠栈 + 帧级 top-N + 分段占比 + 线程 + 栈深 + perf stat JSON + 压测窗口 JSON + manifest；`cmp-{fp,dwarf}.*` 采样方式对照；`*.libc-leaves.csv` / `*.tls-sites.csv` 地址级分解；`slope-model.csv` / `slope-segments.csv`；`B1.deps.json` |
| `figures/` | `02-flame-B1.svg`、`02-flame-B1-by-segment.svg`（按 P 分段着色 + 图例）、`02-flame-B2/B3/B4.svg` |

**原始 `*.perf.data` 未入 git**（`.gitignore` 已屏蔽；本地保留在 `data/profiles/` 下便于复核）。

## 5. 失败路径与踩坑（供后人省时间）

| # | 坑 | 处理 |
|---|---|---|
| 1 | `vllm-bench` **发不出 `tools`**，B1 的负载定义落不了地 | 自带 `raw_load.py`（固定 body、支持 tools/stream、客户端 CPU 单独记）；**代价**：B 线吞吐与 C 线（用 vllm-bench）不是同一客户端口径，已在两处文档写明 |
| 2 | `perf stat -p PID -- sleep N` 收 SIGINT **不落报告** | 改用 perf 自带 `--timeout <ms>` |
| 3 | 折叠栈最后一列被当成"样本数"（4 128 889 250 这种数） | 它其实是 **perf period 之和（纳秒）**。正确做法：period = period_reported/样本数；已在 `perf_record.sh` 里反解并把两个数都写进 manifest |
| 4 | 用「折叠栈第一行的最后一列」当 period | 那是**该栈自身的时间总和**，样本数会算错 3 个数量级（B3 曾算出 53 vs 实际 16630）。已修 |
| 5 | serde 泛型帧被误归到 P2，导致 P2 看起来随 OSL 增长 | 单列 `X-serde` 桶；P2 改为**下界口径**并在文档标注 |
| 6 | `inferno-flamegraph --title` 只能出现一次 | 拼 `--by-segment` 时不要在 `ARGS` 里重复传 |
| 7 | `--nameattr` 改不动 `<rect fill>`（自带属性优先于继承） | 写 `recolor_svg.py` 后处理 SVG 并插图例 |
| 8 | 重活锁**不可重入** | `run_matrix.sh` 内部调 `perf_record.sh`，所以只在外层加一次 `heavy_lock.sh` |
| 9 | 锁竞争激烈（C/D 线同时在跑） | 首轮矩阵排队约 30 min 才拿到锁；一次拿到后连续跑完 6 个点（≈8 min） |
| 10 | `rg -rn 'x'` 的 `-r` 是 `--replace` | 用 `rg -n <path>` |

## 6. 未做到 / 留给别人的

| 项 | 状态 | 说明 |
|---|---|---|
| 层 1 的同装置 Rust vs Python IPC 对照 | **未做（属 C 线）** | `docs/03` §1.2 已留表；C 线出数后替换即可 |
| 前端 `/proc/<pid>/stat` 的每请求 CPU | **未做** | `raw_load.py` 没接 `procstat.sh`；B 线只有采样口径的 on-CPU |
| 采样开销的重复实验 | **未做** | 只做了单次对照（B1 555.5 vs B1x 618.9 req/s，−10.2%），含 run-to-run 漂移 |
| 真实引擎（非 mock）下的火焰图 | **未做（属 C 线）** | mock engine 无节流，P7 的"每 tick 摊薄"在真引擎下会变 |
| `perf stat` 在 c=64 的点位 | **未做** | 矩阵只要求 B5 与 B1 同负载 |
| 跨段桶（67.35%）到具体段的分解 | **未做** | 需要插桩/eBPF；本线按计划只做不侵入采样 |
| `[libc.so.6]` 剩余 ≈9% 未登记区间 | 部分 | 已定名 memmove/memcpy 与 memcmp，余下未定名 |

## 7. 复现

```bash
git checkout agent/B-profile
harness/common/stack.sh start --run runs/b-matrix
scripts/heavy_lock.sh scripts/limit.sh env CORES=1-3 \
  harness/profile/run_matrix.sh --run runs/b-matrix --out-dir data/profiles --duration 30
harness/profile/flamegraph.sh --folded data/profiles/B1.folded \
  --out figures/02-flame-B1.svg --title "B1 …" --by-segment figures/02-flame-B1-by-segment.svg
python3 harness/profile/slope_model.py
harness/common/stack.sh stop --run runs/b-matrix
```

每份 manifest 带 call-graph 方式、freq、窗口起止 epoch、样本数、折叠栈 sha256；
`data/profiles/README.md` 是数据字典。

---

# 8. 第二轮：REMOTE_HOST chip4 主 profiling（2026-09-25 傍晚）

> 用户指示把主 profiling 从本机 x86（纯 CPU + mock engine）搬到 **REMOTE_HOST chip4
> （真 NPU 引擎）**；x86 那批保留为辅助口径。新增脚本 `harness/profile/a3/`，
> 结果 `data/profiles/a3/`，图 `figures/02-flame-a3-*.svg`。文档见 `docs/02` §14、`docs/03` §1。

## 8.1 结论（层 1 与 Q1）

**层 1（同装置/同引擎/同卡/同负载，只换前端）——本项目的核心对照，首次成立**

| 指标 | Rust 前端 | Python 前端 | Rust/Python |
|---|---:|---:|---:|
| `instructions:u` **每请求** | **9.775 M** | **131.247 M** | **0.0745（省 13.4×）** |
| `cycles:u` 每请求 | 13.494 M | 112.742 M | 0.1197（省 8.4×） |
| **IPC** | **0.7243** | **1.1638** | 0.62 |
| 分支失败率 / cache miss 率 | 6.28% / 4.51% | 5.55% / 3.27% | — |
| **前端 CPU s/请求** | **0.00953** | **0.04333** | **0.220（省 4.6×）** |
| **前端占服务端 CPU** | **1.12%** | **4.93%** | 4.4× |
| 吞吐 / TPOT（含引擎） | 1.436 req/s / 4.81 ms | 1.440 req/s / 4.76 ms | 引擎相同 |

**Q1（迁移了什么）**：同负载两侧火焰图并列（`docs/02` §14.9）——

* **Python top-1 = `_PyEval_EvalFrameDefault` 18.31%**，CPython 解释器/对象内务合计 **47.25%**；
* **Rust top-1 = 内核帧 30.03%**，tokio 分派 **21.92%**、TLS(实为 Vec 增长) 8.63%、分配 4.90%、拷贝 2.97%；
* ⇒ **迁移的实质：把「CPython 逐条派发 47.25%」换成了「tokio 分发 21.92% + 内核态 32.86% + 拷贝/分配 7.87%」。**

**★ 反直觉但关键**：**Python 的 IPC（1.164）比 Rust（0.724）高**，却慢 4.6×。
Rust 的优势来自**指令数少 13.4 倍**，不是每条指令更快 ⇒ **IPC 不能跨实现比大小**。
（与 engine-core 的 0.771 形状相似但成因相反：那边是取指受阻，这边是内存/系统调用受阻。）

**★ 热点形状随引擎 tick 粒度变化**（`docs/02` §14.8）：
密集 tick（mock）⇒ 拷贝/分配主导且可摊销（chunk 1→32 时前端 CPU/请求 −72%）；
稀疏 tick（真引擎，4.81 ms/tick、每 tick 1 token）⇒ 唤醒/轮询/收包/内核主导，无法摊销。

## 8.2 四条方法学发现（都可复用）

1. **内核态占前端样本 32.9%**，而 x86 的 `:u` 采样**完全看不到**它
   ⇒ x86 那批占比系统性低估前端成本，且**低估幅度与引擎 tick 粒度相关**。
   与 x86 的 procstat `stime`（49%）方向一致、量级同阶 ⇒ 「**Rust 前端 1/3–1/2 的 CPU 在内核里**」是稳健结论。
2. **aarch64 的 fp 展开质量与 x86 完全相反**：REMOTE_HOST **99.15% 样本栈深 ≥10**（完整调用链），
   Python 侧 99.52%；而 x86 只有 **≤3 帧占 84.67%**。同一条命令。
   ⇒ REMOTE_HOST 的分段归属可**直接读调用链**；x86 被迫用的「差分斜率」只是补丁。
3. **zeromq 收包不走 `recvmsg`**：只记 `syscalls:sys_enter_recvmsg` 会得到 **0**，
   差点误判「前端不收包」。实测走 `recvfrom`/`read`（Python 侧 recvfrom 8 318 / read 8 536）。
4. **`sys_enter_write` = 208 次/请求**（Rust，OSL=128）⇒ 每 SSE chunk 一到两次 write，
   直接印证 A 线静态结论；`sendto` = 1 次/请求 ⇒ P6 每请求只发一次。

## 8.3 采集与工具（新增）

| 文件 | 作用 |
|---|---|
| `harness/profile/a3/prof_point.sh` | 一个 profiling 点：`perf record`/`perf stat`(/tracepoint) + procstat 分桶 + symfs 符号解析 + 汇总 |
| `harness/profile/a3/batch_remote.sh` | **在 REMOTE_HOST 上**：一次事务里起容器 → 跑 N 个点 → 停容器（摊掉 90 s 模型加载） |
| `harness/profile/a3/run_batch.sh` | **在本机**：同步到私有子树 → 在 chip_lock 里跑 batch → 取回结果 |
| `harness/profile/a3/resolve_syms.sh` | **从 perf 数据反推 DSO 列表 → 从容器 `--symfs` 拷 → 重新导出**（Python 臂未解析率 97.2% → 14.2%）；容器已停时用同镜像的临时容器取文件，**不需要锁** |
| `harness/profile/a3/collapse_a3.sh` | 本地折叠 + 出图（复用 x86 那套 `folded_stats.py`/`flamegraph.sh`） |
| `harness/profile/a3/summarize_a3.py` | 汇总 `points.csv` / `ipc.csv` |
| `harness/profile/a3/share_anchor.py` | 「前端占比 vs 引擎速度」实测锚点表 |

## 8.4 踩坑（第二轮新增，都已修）

| # | 坑 | 修法 |
|---|---|---|
| 1 | **容器内路径 ⇒ 符号全丢**（`[unknown] (…/vllm-rs)`） | `--symfs` 目录树 + `resolve_syms.sh` 自动反推 DSO 列表 |
| 2 | **`/proc/kallsyms` 地址全 0** ⇒ 内核符号不可解析 | 如实记录；改用 tracepoint 计数回答内核态去向 |
| 3 | **`--call-graph dwarf` 在 REMOTE_HOST 上直接报错**（`cpu-clock` 不支持 overflow） | 全部用 `fp` |
| 4 | `chip_lock.sh` 里再套 `bash -lc` ⇒ login shell 把 cwd 切回 `$HOME`，相对路径脚本找不到 | 直接把参数交给 chip_lock |
| 5 | `batch_remote.sh` 在**远端** ssh 回 `REMOTE_HOST` 失败（别名不可解析、也不允许 ssh 自己） | 改用共享 `ab_serve.sh` + `A3_LOCAL=1` |
| 6 | `sync.sh push --delete` 会删掉别人/自己的脚本（并发 push 竞争） | 迁移到私有子树 `--into b-profile`（默认已不删） |
| 7 | **一次 patch 误删 `for p in "${POINTS[@]}"; do ARGS+=(--point "$p"); done`** ⇒ 所有点位参数没传给远端，batch 打印 usage 退出码 2，**白占一个锁窗口** | 已修复并在脚本里写明「改动本文件后请冒烟一次」；`run_batch.sh` 现在**无条件取回结果**（`set +e` 吃掉 rc），避免已采到的点也丢 |
| 8 | `perf stat` 的 sudo 包装 pid 与真 perf 不是同一个 ⇒ SIGINT 不转发、`perf-stat.txt` 0 字节 | 解析孙进程 pid + `pkill -INT -f` 兜底 + 有界等待（与 `perf record` 同一套） |
| 9 | mock engine **空闲约 60 s 自行退出**（x86 那轮） | 把「起栈 + 采样」放进同一个锁窗口 |
| 10 | `segments.json` 里写 `\.` 导致 JSON 非法 | 用 `\\.`；Python 帧另加 `X-py-interp` / `X-py-venv` 两个桶 |

## 8.5 未做到（如实列出）

| 项 | 状态 | 原因 |
|---|---|---|
| **A2（c=64）** | **未测** | 时间盒收口；C 线 `docs/04` 已用同装置测了 c=64 的前端成本与占比 |
| **A3（ISL=8k）** | **未测** | 同上 |
| 内核**函数级**去向（内核火焰图） | 未测 | `/proc/kallsyms` 地址为 0，`[k]` 帧只有裸地址 |
| 内核模块符号（`nf_conntrack/nf_nat/nf_tables.ko.xz`） | 未测 | 容器内不存在这些 `.ko`，`docker cp` 取不到 |
| Python 侧 14.2% 残留未解析帧 | 部分 | 主要是内核帧 + 内核模块（同上） |
| 采样开销的重复实验（REMOTE_HOST） | 部分 | 只见 0.0086→0.0095 s/请求（+10.9%）的单次对照，未做交替重复 |
| x86 上 `sudo perf` 采内核态（补 x86 的 `:u` 缺口） | 未测 | 装置已降级为辅助；REMOTE_HOST 已提供内核态证据 |
