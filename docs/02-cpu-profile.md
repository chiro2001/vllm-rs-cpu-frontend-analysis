# 02 · vllm-rs 前端的 CPU 负载（火焰图 + 硬件计数）

> **线 B（B-profile）交付物**。分析对象：vLLM 0.26.0 自带的 Rust 前端 `vllm-rs`。
>
> **证据标签**：所有数字都标来源。「实测」= 本线采集；「引用」= 别的项目/别的装置；
> 「推断」= 由实测 + 源码推出但未直接测到。**没测的写「未测」。**

## ⚠️ 本文有两套装置，先看这一节再读任何数字

用户的指示（2026-09-25 傍晚）把**主 profiling 搬到了 REMOTE_HOST 的 chip4（真 NPU）**，
本机 x86 降级为**辅助**。两套装置的结论**不能混在一张表里**：

| | **§1–§13：本机 x86（辅助）** | **§14 起：REMOTE_HOST chip4（主）** |
|---|---|---|
| 机器 | LOCAL_HOST（x86_64，12 核，AMD） | REMOTE_HOST（aarch64，Kunpeng 920B + Ascend 910） |
| 引擎 | `vllm-mock-engine`（**无真实推理**）+ 一次纯 CPU 真引擎对照 | **真 NPU 引擎**（vLLM 0.26 + vllm-ascend） |
| 引擎速度 | 近似免费（mock）⇒ 前端占比 ≈100% | **TPOT 4.7–5.1 ms/token** ⇒ 前端占比 1–5% |
| 前端二进制 | x86_64 wheel 抽取（sha256 `0597bfc9…`） | aarch64 wheel 抽取（sha256 `cae05321…`） |
| 用途 | 前端**自身**的成本结构（谁在烧 CPU、随长度怎么变） | **真实部署下的前端画像** + Rust vs Python 同装置对照 |
| 为什么保留 | 它的引擎不构成瓶颈 ⇒ 能把前端成本测得更干净、样本量更大 | 它是唯一能与 `PREPARE_INPUT_PROJECT` 的 engine-core 基线对口径的装置 |

**一句话**：x86 那半回答「**前端自己花在哪**」，REMOTE_HOST 那半回答「**在真实引擎旁边，前端值多少**」。

两套装置共同的结论只有一条：**前端的成本是"拷贝 + 分配 + 系统调用"，不是"某个算法慢"**——
这条在两个不同架构、两套引擎上都成立（见 §14.6）。

> x86 侧的采集时间 2026-09-25 白天；REMOTE_HOST 侧 2026-09-25 傍晚。
> x86 侧二进制从官方 PyPI wheel 抽取（x86_64，42.79 MB，not stripped，sha256 前 16 `0597bfc909f22d94`）。

---

## 0. 一分钟结论

数字口径：**前端进程 `vllm-rs` 的 on-CPU 时间占比**，采样窗口 30 s，
负载与压测口径见 §3，完整 top-N 见 §6、分段占比见 §7。

1. **最大的单项热点是内存拷贝。** `[libc.so.6]` 这个未解析帧占 **15.20%**，
   它是 glibc 的向量化 `memmove/memcpy`（AVX-512 实现）与矢量 `memcmp` 的混合体；
   按文件内偏移分解后 **≈80% 是拷贝、≈11% 是比较**（§5.1、§7.3）。
   它是**局部符号**（`.symtab` 已剥离），perf 查不到名字；本文用
   「动态符号表 + 反汇编 + fortify 分支」三重证据把它钉死。
2. **第二名是分配器。** mimalloc 家族合计 **14.18%**：
   `_mi_page_malloc_zero` 3.69%、`mi_free` 2.51%、`mi_theap_malloc_aligned` 1.32%、
   `_mi_theap_malloc_zero` 0.86% 等（`Cargo.lock` 显示是 `vllm-cmd` 选的全局分配器）。
3. **「分配 + 拷贝 + 哈希」合计 31.93%**，比 P1–P10 里**任何一个单段都大**
   （最大的业务段 P7 也只有 6.81%）。⇒ 换语言的收益主要来自
   **把逐算子派发换成批量内存操作**，而不是某个算法本身变快。
4. **最反直觉的一条：正则子系统的占比远高于预期。** `fastokens` 的**预分词**
   走 **PCRE2 JIT**：JIT 代码区 `[perf-<pid>.map]_[j]` 2.91% +
   `pcre2::bytes::Regex::find_at` 1.00% + `pcre2_match_8` 0.41% +
   `pcre2_jit_match_8` 0.34% ≈ **4.7%**；三点斜率分解显示这些帧**全是 ISL 驱动**
   （JIT 22.1 ns/输入 token）⇒ 坐实是 **P4（编码）**（§8）。
   `Cargo.lock` 反查确认 `pcre2` 的**唯一使用者是 `fastokens`**（§5.2）。
   ⇒ P4 单段 = **6.57%**，是 B1 里最大的业务段之一。
5. **`std::thread::local::LocalKey<T>::with`（4.22%）这个名字是误导。**
   二进制里有 **58 个同名实例**；占其中 ≈78% 的热点实例（`0xaa3630`）的
   **函数体内没有任何 TLS 指令**，反汇编显示它内联了 `Vec` 增长
   （`mi_malloc_aligned` + `memcpy@GLIBC_2.14` + `alloc::raw_vec::handle_error`）。
   ⇒ **不能**把它说成「TLS 开销」（§5.3）。
6. **IPC = 1.12、分支失败率 2.11%、L1d load miss 4.59%、cache miss 19.9%**——
   「Rust 前端是什么形状」的硬件指纹（§9）。
7. **成本可以对长度做线性分解**（三点拟合，B1 留一点验证误差 −2.6%）：

   ```
   前端每请求 on-CPU ns ≈ 285 000 + 77.6 × ISL + 4 220 × OSL
                          (≈0.29 ms    ≈78 ns/输入 token   ≈4.2 µs/输出 token)
   ```

   ⇒ **一个输出 token 的前端成本 ≈ 一个输入 token 的 54 倍**。

   按分段拆开，**每多一个输出 token 的 4.22 µs 里**：
   拷贝 910 ns + 分配 644 ns + 运行时分发 748 ns = **2.30 µs（55%）**是跨段内务，
   只有 **0.89 µs（21%）**落在业务语义段（P1 169 + P7 388 + P8 159 + P9 75 + P10 202 ns）。
8. **一个归因陷阱（本文已避开）**：serde 的**泛型适配层**
   （`serde_core::de::…`、`<&mut A as SeqAccess>::next_element` 这类帧）
   **同时服务 JSON（P2）与 msgpack（P6/P7）**，符号名分不出方向。
   把它们一律算进 P2 会让 P2 看起来随 OSL 增长（那是 msgpack 的成本）。
   本文把这一批单独列成 **`X-serde`（2.08%）**，只在名字能定向时才归段
   （`serde_json::*` → P2/P10，`rmp*` → P6/P7，`serde_path_to_error` → P2）。
   **代价**：P2 的绝对值被低估（下界 1.79%），本文在 §7.1 明确标注。

---

## 1. 采集对象、边界与口径

| 项 | 值 | 说明 |
|---|---|---|
| 被采样进程 | `vllm-rs`（`runs/<name>/frontend.pid`） | **只看前端**；引擎是另一个进程、客户端是第三个进程 |
| 引擎 | `vllm-mock-engine`（上游自带，自编译） | 无节流，单请求 ≈ 瞬时；只用于产生稳态负载 |
| 客户端 | `harness/profile/raw_load.py`（B 线自带） | 与前端**分核**：前端 4-5、引擎 6-7、客户端 8-9 |
| 采样 | `perf record -p <前端pid>` | 只累计该进程（含其全部线程）的**用户态** |
| 时间口径 | on-CPU 时间（Σ period） | 不含引擎、不含客户端；客户端 CPU 单独记（§3.2） |

**为什么还要按线程看**：前端把工作切成三个 tokio runtime
——HTTP（`tokio-rt-worker`）、重活（`vllm-request`）、传输（`vllm-zmq-0`）。
线程名是这把数据里**唯一稳定的粗粒度调用方信息**（原因见 §2.2），逐点数据在
`data/profiles/<tag>.threads.csv`。

---

## 2. 采样方法：为什么是 fp 而不是 dwarf

计划（`plan/experiment-matrix.md` §6）建议 `--call-graph dwarf,16384`，
并要求「两种都试，写明实际用的哪种」。实测结论：**dwarf 在这份二进制上不能用**。

### 2.1 对照实验

同一负载（B1：chat+tools / ISL=1k / OSL=128 / c=1）、同一窗口长度（10 s）、
同一前端进程，只改 call-graph 方式：

| 项 | `--call-graph fp` | `--call-graph dwarf,16384` |
|---|---:|---:|
| 样本数 | **4140** | 3991 |
| 唯一折叠栈 | **731** | **15** |
| 栈深 | 2→128（见 §2.2） | **≤2，且上层是垃圾** |
| 上层帧长什么样 | 真实符号（`axum::…`→`tower…::call`） | `1 [unknown]`、`0x38 [unknown]`（把栈上的数据当返回地址） |
| `perf.data` | 310 KB | **63 MB**（≈166 KB/样本） |
| `perf script` 后处理 | 秒级 | **≈2.5 min**（≈15× 负载时长） |

证据：`data/profiles/cmp-fp.folded`、`cmp-dwarf.folded`、
`data/profiles/cmp-{fp,dwarf}.perf-manifest.json`。「实测」

**判据**：dwarf 只折出 15 个唯一栈且上层是**非法地址** ⇒ 它产出的不是「更准的栈」，
而是噪声；fp 在同样窗口里能读到完整调用链 ⇒ **fp 是这里唯一可用的方式**。

### 2.2 fp 栈浅，是必须随结论一起引用的限制

| 栈深（含线程名） | 样本占比 |
|---:|---:|
| 2（线程名 + 叶子） | **59.81%** |
| 3 | 27.01% |
| 4 | 5.48% |
| 5 | 5.50% |
| 6–8 | 1.67% |
| 9+ | 0.53% |

⇒ **六成样本没有调用方**。这不影响「热点函数是谁」，但直接决定了分段归属的做法：

1. **叶子符号语义**（`rmp_serde::decode` ⇒ P7）；
2. **线程方向**（`vllm-zmq-0` 上的收包 ⇒ P7）；
3. **差分斜率**：同一帧在 B1n（ISL 1k）/B2（ISL 8k）/B3（OSL 512）之间
   *每请求绝对成本*怎么变 ⇒ 判断它随 **prompt 长度** 还是 **输出长度** 增长（§8）。

**明确不采用**：拿「有父帧的那 40%」当无偏样本外推调用链——那 40% 是按
「函数体有没有用 `%rbp`」筛出来的有偏子集。

### 2.3 固定采样参数（B1–B4 完全一致）

```
perf record -p <前端pid> -e cpu-clock -F 999 --call-graph fp
```

写进每份 `data/profiles/<tag>.perf-manifest.json`（窗口起止 epoch、call-graph 方式、
freq、样本数、折叠栈 sha256）。

### 2.4 折叠栈的计数单位是纳秒，不是「样本数」

`inferno-collapse-perf` 的最后一列是 **perf period**；`cpu-clock -F 999` 下
period ≈ 1001001 ns。所以 **Σ(最后一列) 就是前端在该窗口的 on-CPU 纳秒数**。
本文所有「占比」都是时间占比，「样本数」= Σ/period（与 `perf record` 自报样本数交叉校验过）。
⚠️ 折叠栈里 `6006006` 这种数字**不是** 6006 次调用。

---

## 3. 采集矩阵与压测口径

### 3.1 负载定义

用 B 线自带的 raw-payload 客户端（不用 `vllm-bench`：它**发不出 `tools`**，
见 `harness/profile/README.md` §1）。全部为 **SSE 流式**（理由见 §3.3）。

| ID | 负载 | 采样 | 窗口 |
|---|---|---|---|
| B1 | chat + tools，ISL=1k，OSL=128，c=1 | `perf record -e cpu-clock -F 999 --call-graph fp` | 30 s |
| B1n | 同 B1 但**去掉 tools**（把 tools 开销从 ISL/OSL 效应里剥出来） | 同上 | 30 s |
| B2 | chat（无 tools），ISL=8k，OSL=16，c=1 | 同上 | 30 s |
| B3 | chat（无 tools），ISL=1k，OSL=512，c=1 | 同上 | 30 s |
| B4 | chat（无 tools），ISL=1k，OSL=128，c=64 | 同上 | 30 s |
| B5 | 同 B1 负载 | `perf stat`（cycles/instructions/branches/cache/L1d） | 30 s + 4 s |
| B1x | 同 B1 负载，**完全不开 perf**（采样开销对照，§10） | — | 30 s |

**与 `plan/experiment-matrix.md` §2 的三处偏差（必须写明）**：

1. 计划里 B1 是「chat + tools」，但共享 harness 指定的 `vllm-bench` 发不出 `tools`
   ⇒ 改用 B 线自带的 raw-payload 客户端。因此 **B 线的吞吐/延迟与 C 线（用 `vllm-bench`）
   不是同一客户端口径，不能直接相减**。
2. 计划里 B1 带 tools 而 B2–B4 不带，会在「tools 开关」上混入第二个变量
   ⇒ **额外加 B1n**（B1 同负载但无 tools）把这一轴单独隔离。
3. 计划写「窗口 60 s」，任务书要求 **≥30 s**；实测 30 s 的样本量
   （B1 ≈ 1.1 万样本）足够支撑 top-N 稳定性（§6.4 复采一致性）。

### 3.2 负载实测

`data/profiles/<tag>.load.json` 是每一跑的原始结果：窗口起止 epoch、
窗口内成功/失败请求数、`completion_tokens`（取自响应 `usage`，不是本地估计）、
延迟分位、以及**压测端自己的** `client_cpu_seconds`（utime+stime，**不算进服务端**）。

### 3.3 为什么用流式（SSE）

`mock engine` 的 `output_token_chunk_size=1`，即**每 token 一个 chunk**。
SSE 能同时压到 P8（增量解码）/P9（parser）/P10（每 chunk 序列化 + 写）；
非流式会把 P10 压成一次大序列化，丢掉「每 chunk 一次 syscall」这条成本。
G1 门禁的冒烟也是流式，两者口径一致。

---

## 4. 火焰图

| 图 | 工况 | 文件 | 前端 on-CPU |
|---|---|---|---|
| B1 | chat + tools，ISL=1k，OSL=128，c=1 | `figures/02-flame-B1.svg` | 15.74 core-s |
| B1（按 P 分段着色） | 同上 | `figures/02-flame-B1-by-segment.svg` | 同上 |
| B2 | chat，ISL=8k，OSL=16，c=1 | `figures/02-flame-B2.svg` | 22.23 core-s |
| B3 | chat，ISL=1k，OSL=512，c=1 | `figures/02-flame-B3.svg` | 16.63 core-s |
| B4 | chat，ISL=1k，OSL=128，c=64 | `figures/02-flame-B4.svg` | 24.05 core-s |

**怎么读这几张图**：

1. **最底下三条粗带**是线程名（`tokio-rt-worker` / `vllm-request` / `vllm-zmq-0`），
   它们不是函数，是 perf 加的 comm 帧；宽度 = 该线程的 on-CPU 占比。
2. **整张图极"平"**：最大的单个叶子帧也只占 15.2%，绝大多数帧 <1%。
   这与 Python 侧 `PREPARE_INPUT_PROJECT` 的观察一致（top-10 self 合计 22.83%），
   但**成因不同**：Python 侧是「解释器逐条派发」导致极平，Rust 侧是
   「真正的计算已消失，剩下的是一堆小额的内存/调度开销」。
3. **`02-flame-B1-by-segment.svg`** 按 `harness/profile/segments.json` 的分段规则重新着色
   （图底部有图例）。同一张图里可以直接看出：橙红系（P1–P10）是"语义段"，
   灰蓝系（X-*）是"跨段基础开销"，**后者总面积更大**。
4. B1 图里有一根很高的细柱（栈深 128），那是单条深栈；按宽度读是噪声级别的存在，
   但它把图的高度撑开了——这是 fp 展开质量的副产物，不是热点。

---

## 5. 把「名字不明」的帧钉死（三处，都有反汇编证据）

### 5.1 `[libc.so.6]` = glibc 的 AVX-512 `memmove/memcpy`

perf 报的叶子符号只有 `[libc.so.6]`（未解析）。用 `sym_offset.py` 把该 dso 的样本
按**文件内偏移**展开后（`data/profiles/B1.libc-leaves.csv`），样本高度集中：

| 偏移 | 样本 | 说明 |
|---|---:|---|
| `0x18cdd3` | 127 | 大尺寸分支的第一条 `vmovdqu64` |
| `0x18cdc0` | 20 | 函数入口（`cmp $0x40,%rdx; jb`） |
| `0x18cedd` / `0x18cf3f` / `0x18cea0` / `0x18ceb0` / `0x18cde5` … | 各 6–17 | 同一函数的尺寸分发/尾部 |

`0x18cdc0` 起反汇编（`objdump -d /usr/lib/libc.so.6`）：

```asm
18cdc0: endbr64
18cdc4: mov    %rdi,%rax                 ; 返回值 = dst
18cdc7: cmp    $0x40,%rdx                ; len >= 64 ?
18cdcb: jb     18ce10                    ; 小尺寸分发
18cdcd: vmovdqu64 (%rsi),%zmm16          ; ← 样本最多的地址 0x18cdd3
...
18ce10: cmp    $0x20,%edx                ; 32/16/8/4/1 的尺寸分支
```

* `0x18cd70` / `0x18cd90` 两处入口都是 `cmp %rdx,%rcx; jb <__chk_fail>` ——
  `__memcpy_chk` / `__memmove_chk` 的 fortify 前置检查，**落下来直接进 0x18cdc0**；
* `0x18cde8` 的 `vmovdqu64 %zmm16,(%rdi)` 加尾部 `movzwl 0x2(%rsi,%rdx,1)`
  是 glibc 块拷贝的**重叠处理尾部**。

⇒ `0x18cdc0` 起这段是 **glibc 的向量化 `memmove/memcpy` 实现**（AVX-512 变体）。
它是 `local` 符号：`readelf --dyn-syms` 里最后一个导出函数在 `0x1733a0`，本地址在其之后
⇒ 任何符号表都查不到名字，这不是 perf 的解析问题。
**`memmove` 与 `memcpy` 共用同一入口，二者不可区分**，本文统一称「glibc 向量化块拷贝」。
「实测 + 反汇编」

`0x1837xx` 是另一段（≈10% 的该 dso 样本），同属块操作家族但**未定名**；
本文不把它并入上面的结论。

### 5.2 `[perf-<pid>.map]_[j]` = fastokens 的 PCRE2 JIT 代码区

三条证据合起来唯一确定：

1. 前端进程 `/proc/<pid>/maps` 里**只有一个可执行匿名映射**
   （`7f504e889000-7f504e899000 rwxp`，64 KiB）；
2. JIT 样本地址（`7f504e8965c3` 等）**全部落在该区间内**；
3. `rust/Cargo.lock` 逐 package 反查：**只有 `fastokens` 依赖 `pcre2`**
   （`data/profiles/B1.deps.json`）。

⇒ `[j]` 帧 = PCRE2 JIT 代码 ⇒ **fastokens 的预分词正则** ⇒ **P4**。「实测 + 依赖反查」

### 5.3 `LocalKey<T>::with` 的名字是误导

`std::thread::local::LocalKey<T>::with` 是 B1 的第二大叶子帧（**4.22%**）。但：

1. `nm` 在同一二进制里找到 **58 个同名符号**（泛型实例共用同一个 demangle 名）；
2. 按偏移展开后 **78% 集中在一个实例** `0xaa3630`（`data/profiles/B1.tls-sites.csv`）；
3. 对 `0xaa3630-0xaa37c0` 全函数反汇编，**搜不到任何 `%fs:` 或 `__tls_get_addr`**
   （grep 计数 0）——它根本不在做 TLS 访问；
4. 该函数体实际做的是：`call *0x2206610(%rip)` → **`mi_malloc_aligned`**
   （GOT 重定位解析）、`call *0x2206650` → **`mi_free`**、
   `call memcpy@GLIBC_2.14`、`call alloc::raw_vec::handle_error`（`Vec` 分配失败路径），
   以及 `0x8/0x10/0x18`（ptr/len/cap）三元组搬移。

⇒ 热点实例是**「TLS 包装里内联了 `Vec` 增长」**，符号名只反映了外层包装。
所以：**本文不把它称作「TLS 开销」**，而是单列成 `X-tls` 桶（4.22%）。
「实测 + 反汇编」

---

## 6. 帧级 top-N（B1 = chat+tools / ISL=1k / OSL=128 / c=1 / 30 s）

单位：core-ms = 该帧的 self（on-CPU）时间。完整 40 行在 `data/profiles/B1.topn.csv`。

| # | 帧 | core-ms | self% | 分段 | 归属依据 |
|---:|---|---:|---:|---|---|
| 1 | `[libc.so.6]`（= memmove/memcpy + memcmp） | 2392 | **15.20%** | X-copy | 反汇编（§5.1） |
| 2 | `std::thread::local::LocalKey<T>::with` | 664 | 4.22% | X-tls | 反汇编（§5.3） |
| 3 | `futures_util::stream::stream::StreamExt::poll_next_unpin` | 633 | 4.02% | X-runtime | 斜率：OSL 驱动 |
| 4 | `_mi_page_malloc_zero` | 581 | 3.69% | X-alloc | 符号 + 依赖 |
| 5 | `[perf-3639361.map]_[j]`（PCRE2 JIT） | 457 | 2.91% | **P4** | 反汇编 + 依赖 + 斜率 ISL 驱动 |
| 6 | `<core::iter::adapters::map::Map<I,F>>::try_fold` | 432 | 2.75% | X-rust | 斜率：OSL 驱动（→ 响应段，但定不到具体段） |
| 7 | `rmp_serde::decode::Deserializer::any_inner` | 404 | 2.57% | **P7** | 符号 + 斜率 |
| 8 | `mi_free` | 394 | 2.51% | X-alloc | 符号 |
| 9 | `vllm_tokenizer::byte_level_decode::decode_byte_level` | 330 | 2.10% | **P8** | 符号 + 斜率 OSL 驱动（133 ns/token） |
| 10 | `serde_core::ser::SerializeMap::serialize_entry` | 243 | 1.55% | X-serde | 泛型 serde：JSON(P10)/msgpack(P6) 不可分 |
| 11 | `<S as futures_core::stream::TryStream>::try_poll_next` | 222 | 1.41% | X-runtime | 符号 |
| 12 | `mi_theap_malloc_aligned` | 207 | 1.32% | X-alloc | 符号 |
| 13 | `<asynk_strim::AsynkStrim<..> as Stream>::poll_next` | 201 | 1.28% | X-runtime | 符号 |
| 14 | `serde_json::ser::format_escaped_str_contents` | 189 | 1.20% | **P10** | 符号 + 斜率 OSL 驱动 |
| 15 | `core::hash::BuildHasher::hash_one` | 179 | 1.14% | X-hash | 符号 |
| 16 | `[[vdso]]_[k]`（clock_gettime 等） | 166 | 1.06% | X-kernel | 符号 |
| 17 | `pcre2::bytes::Regex::find_at` | 158 | 1.00% | **P4** | 依赖 + 斜率 ISL 驱动 |
| 18 | `rmp::encode::uint::write_uint` | 136 | 0.86% | **P6** | 符号 + 斜率 ISL 驱动 |
| 19 | `_mi_theap_malloc_zero` | 135 | 0.86% | X-alloc | 符号 |
| 20 | `…run_output_dispatcher_loop::{{closure}}` | 126 | 0.80% | **P7** | 符号 |
| 21 | `<tracing_futures::Instrumented<T> as Stream>::poll_next` | 118 | 0.75% | X-runtime | 符号 |
| 22 | `<&mut A as serde_core::de::SeqAccess>::next_element` | 114 | 0.73% | X-serde | 泛型 serde：斜率显示 OSL 驱动（多半在 msgpack 侧） |

### 6.1 三个「意料之外」的观察

1. **`serde_json` 几乎不在榜上。** 计划 §2 预期「P2 是大 prompt 的 memcpy 大户」——
   实测 P2 最多只占 **1.79%**（还是上界口径：含 axum 的 `serde_path_to_error`）。
   真正的大户是 **glibc 的块拷贝/比较**（15.20%）与 **mimalloc**（14.18%），
   它们**不落在任何 P 段里**（分配/拷贝被所有段共用）。
2. **msgpack 两侧都在榜上**：P7（`any_inner` 2.57%，段合计 6.81%）
   比 P6（`write_uint` 0.86%，段合计 1.19%）贵 5.7 倍。
   原因在 A 线的静态结论里已经写好：P7 是**每个引擎 tick 解一整包**（含多请求多 token），
   而 mock engine 的 tick 频率高、每 tick 只解一个请求 ⇒ 摊销差（§10）。
3. **PCRE2 JIT 是一个独立的大项（2.91%）**，而它属于**分词**而不是 parser。
   A 线的静态分解里没有预料到正则子系统（A 线已核实 `parser` crate 不依赖 `regex`）。

### 6.2 跨点稳定性

各点的 top-6（`self%` 排序，`data/profiles/<tag>.topn.csv`）：

| 点 | top-1 | top-2 | top-3 | top-4 | top-5 | top-6 |
|---|---|---|---|---|---|---|
| B1 | `[libc.so.6]` 15.20% | `LocalKey` 4.22% | `poll_next_unpin` 4.02% | `_mi_page_malloc_zero` 3.69% | PCRE2 JIT 2.91% | `Map::try_fold` 2.75% |
| B1n | `[libc.so.6]` 15.08% | `LocalKey` 4.04% | `_mi_page_malloc_zero` 3.84% | `poll_next_unpin` 3.72% | `Map::try_fold` 3.23% | `rmp_serde::decode` 2.89% |
| B2 | **PCRE2 JIT 18.26%** | `LocalKey` 17.29% | `[libc.so.6]` 9.32% | `Regex::find_at` 8.20% | `pcre2_match_8` 3.96% | `rmp::encode::uint` 2.36% |
| B3 | `[libc.so.6]` 19.24% | `poll_next_unpin` 4.71% | `_mi_page_malloc_zero` 3.95% | `Map::try_fold` 3.41% | `rmp_serde::decode` 3.29% | `byte_level_decode` 2.91% |
| B4 | `[libc.so.6]` 16.87% | `_mi_page_malloc_zero` 5.17% | `poll_next_unpin` 3.79% | PCRE2 JIT 3.36% | `LocalKey` 3.26% | `Map::try_fold` 3.25% |

**准确的表述（不要过度概括）**：

* **唯一在五点都进 top-3 的帧是 `[libc.so.6]`**（块拷贝/比较）——它是这套负载下
  最稳定的头号热点；
* **B2 是唯一的例外点**：ISL=8k 把 **PCRE2 JIT 顶到 18.26%**、`Regex::find_at` 8.20%，
  而 `[libc.so.6]` 掉到第三（9.32%）——即"长 prompt 下热点换人"；
* **top-6 的成员集合**在 B1/B1n/B3/B4 之间基本一致
  （`[libc.so.6]` / mimalloc / tokio-futures / TLS / `Map::try_fold` / msgpack 或
  `byte_level_decode` 轮换），但**排序与占比**随负载形态明显移动。
⇒ 「谁是热点」**必须带负载形态回答**，不存在单一答案；
唯一可以无条件说的是「块拷贝/比较 + 分配 + 调度这三类一直在大头」。

---

## 7. 帧 → P1–P10 分段映射表与占比

### 7.1 映射规则（可审计）

规则在 `harness/profile/segments.json`，**按顺序匹配、先命中先用**，
每条都带 `basis`（归属依据）与 `note`。四条依据的强度不同，引用时要带上：

| basis | 含义 | 强度 |
|---|---|---|
| `code` | 依赖反查 / 反汇编 / 源码语义**直接确定**（如 PCRE2 JIT 区域） | 最强 |
| `symbol` | 符号名直接给出段（如 `rmp_serde::decode` ⇒ P7） | 强 |
| `slope` | 由 §8 的 ISL/OSL 斜率判定（见下） | 中 |
| `heuristic` | 只能给到「跨段桶」，或由名字形状猜 | 弱（文中会标推断） |

⚠️ **一个必须一起引用的偏差**：serde 的泛型适配层（`serde_core::de/ser`）**无法按名字分方向**，
被单独放进 `X-serde`（2.08%）⇒ **P2 的实测值是下界**（1.79%），
真实 P2 应当再加上 `X-serde` 里属于 JSON 的那一部分。
同理 P10 也不含 `SerializeMap::serialize_entry`（1.55%，现属 `X-serde`）。
「P2 到底多少」的正解在 D 线的**同输入微基准**里（`docs/05`：1k 请求体
Rust 侧 json 解析 30.5 µs 量级的四段合计），本线不做归因赌博。

分段本体沿用 `docs/01-request-path.md` 的定义，本文不重新定义。
**`X-*` 是"跨段桶"**：这些成本（分配器、通用 memcpy、tokio 调度、哈希）
被 P1–P10 全部使用，栈浅的条件下**无法归到单一段**。
把它们硬摊到某一段会让那张表看起来更完整，但那是在编数字——
所以本文**单列**，并给出它们的**斜率**（§8）让读者知道它们服务哪一侧。

### 7.2 B1 的分段 self-time 占比表

| 分段 | core-ms | 占全部 self | 占 P1–P10 | µs/请求 | 该段 top 帧 |
|---|---:|---:|---:|---:|---|
| P1 HTTP 接入/回写 | 941 | 5.98% | 18.31% | 56.5 | `http_body_util…poll_frame` 85.1ms、`hyper…poll_write` 41.0ms |
| P2 JSON 反序列化（**下界**） | 281 | 1.79% | 5.47% | 16.9 | `serde_path_to_error…deserialize`、`serde_json::read::*` |
| P3 chat 模板 | 260 | 1.65% | 5.06% | 15.6 | `minijinja::vm::Vm::eval_impl` 60.1ms、`indexmap…insert_full` 15.0ms |
| **P4 分词（编码）** | **1034** | **6.57%** | **20.12%** | 62.0 | PCRE2 JIT 457.5ms、`Regex::find_at` 158.2ms、`pcre2_match_8` 65.1ms |
| P5 lower/校验 | 15 | 0.10% | 0.29% | 0.9 | `convert::prepare_chat_request` 10.0ms |
| P6 序列化下发 | 187 | 1.19% | 3.64% | 11.2 | `rmp::encode::uint::write_uint` 136.1ms |
| **P7 响应反序列化/分流** | **1072** | **6.81%** | **20.86%** | 64.3 | `rmp_serde::decode::any_inner` 404.4ms、`run_output_dispatcher_loop` 126.1ms |
| P8 增量解码 | 399 | 2.54% | 7.77% | 24.0 | `byte_level_decode` 330.3ms、`DecodeStream::push_token` 30.0ms |
| P9 parser | 439 | 2.79% | 8.55% | 26.4 | `DelimitedReasoningParser::push` 70.1ms、`parse_next_json_tool_call_event` 57.1ms |
| P10 JSON+SSE 回写 | 510 | 3.24% | 9.91% | 30.6 | `serde_json::ser::format_escaped_str_contents` 189.2ms、`itoa::fmt` 32.0ms |
| **P1–P10 合计** | **5138** | **32.65%** | 100% | **308** | — |
| **X-alloc 分配器** | **2232** | **14.18%** | — | 133.9 | `_mi_page_malloc_zero` 580.6ms、`mi_free` 394.4ms |
| **X-copy 块拷贝/比较** | **2392** | **15.20%** | — | 143.6 | `[libc.so.6]`（memmove/memcpy 80% + memcmp 11%） |
| **X-runtime tokio/futures** | **2187** | **13.90%** | — | 131.2 | `poll_next_unpin` 632.6ms、`try_poll_next` 222.2ms |
| X-rust 未定段的标准库/泛型 | 977 | 6.21% | — | 58.6 | `Map::try_fold` 432.4ms（斜率显示属响应段，但定不到具体段） |
| X-tls TLS 包装 | 664 | 4.22% | — | 39.8 | `LocalKey::with`（实为 Vec 增长） |
| X-hash 哈希表 | 401 | 2.55% | — | 24.1 | `hash_one` 179.2ms、`sip::Hasher::write` 61.1ms |
| X-serde 泛型适配层 | 327 | 2.08% | — | 19.6 | `SerializeMap::serialize_entry` 243.2ms |
| X-log 日志/追踪 | 287 | 1.83% | — | 17.2 | `sharded_slab::Pool::get` 98.1ms |
| X-str UTF-8/子串搜索 | 255 | 1.62% | — | 15.3 | `from_utf8` 101.1ms、`StrSearcher::new` 84.1ms |
| X-bytes byte buffer | 196 | 1.25% | — | 11.8 | `Bytes::shared_drop` 46.0ms |
| X-kernel 内核/vDSO | 185 | 1.18% | — | 11.1 | `[[vdso]]_[k]` 166.2ms |
| X-metrics 指标/计时 | 160 | 1.02% | — | 9.6 | `RequestMetricsTracker::observe_output` 31.0ms |
| X-unclassified | 149 | 0.95% | — | 8.9 | `generate_inner::{{closure}}` 14.0ms |
| X-park 线程池等待 | 146 | 0.93% | — | 8.8 | `__sched_yield` 71.1ms、rayon `wait_until_cold` 30.0ms |
| X-unknown 未解析 | 39 | 0.25% | — | 2.3 | `[libm.so.6]` 32.0ms |
| **总计** | **15739** | **100%** | — | **944** | — |

**一张图看清结构**：P1–P10 合起来只有 32.65%，跨段桶 67.35%。
其中「分配（14.18%）+ 拷贝（15.20%）+ 调度（13.90%）」三项就占 **43.28%**。

### 7.3 `[libc.so.6]` 的构成（按文件内偏移分解）

`data/profiles/B1.libc-leaves.csv`（`sym_offset.py` 产出，含 `identified_function` 列）：

| 帧 | 对应的 glibc 实现 | 样本 | 占该 dso |
|---|---|---:|---:|
| `[libc.so.6]` | `memmove/memcpy`（AVX-512，`0x18cd70–0x18d108`） | 1881 | **80.0%** |
| `[libc.so.6]` | `memcmp`（AVX-512/evex，`0x183780`） | 255 | 10.9% |
| `[libc.so.6]` | 未登记区间 | 214 | 9.1% |

### 7.4 线程归属（唯一稳定的"粗粒度调用方"）

| 线程 | 是什么（依据） | B1 | B1n | B2 | B3 | B4 |
|---|---|---:|---:|---:|---:|---:|
| `tokio-rt-worker` | **HTTP/axum runtime**（tokio 1.52 默认线程名；vllm 只给另两个 runtime 起名） | 53.16% | 54.79% | 14.76% | **62.18%** | 58.60% |
| `vllm-request` | 请求 runtime（`server/src/runtime.rs:20`） | 24.58% | 21.73% | **80.37%** | 8.81% | 23.45% |
| `vllm-zmq-0` | 传输 runtime（`engine-core-client/src/runtime.rs:62`） | 22.27% | 23.48% | 4.87% | 29.01% | 17.95% |

这张表是**对分段归属的独立交叉验证**，因为它不依赖符号命名：

* **B2（ISL=8k、OSL=16）** 把 80.4% 的时间压在 `vllm-request` 上
  ⇒ 长 prompt 的成本确实在"前端预处理 runtime"（P2/P3/P4/P5/P6）；
* **B3（OSL=512、ISL=1k）** 把 62.2% 压在 HTTP runtime 上
  ⇒ 长输出的成本确实在"响应体被 poll 出去的地方"——
  与 A 线引用的 `server/src/middleware/offload.rs:76-79` 注释
  （"For streaming HTTP responses, the response body is still polled on the HTTP runtime"）
  **完全一致**，即 P8/P9/P10 跑在 HTTP runtime 上；
* `vllm-zmq-0`（P7）的占比在 B3 最高（29.0%）——因为 OSL 大 ⇒ 引擎 tick 多 ⇒ 收包多。

⚠️ **口径提醒**：`tokio-rt-worker` 这个名字**不是** vllm 起的，是 tokio 的默认名
（`data/profiles/B1.deps.json` 里有 tokio 1.52.3 源码行号）。
如果有别的未命名 runtime，也会落到这个名字上。

---

## 8. 差分斜率：把"名字判不出段"的帧按斜率归段

### 8.1 每请求总成本的三点线性分解

取三个 **c=1、只有长度不同** 的点解 `cost = const + a·ISL + b·OSL`（单位 ns/请求）：

| 点 | ISL（实测 prompt tokens） | OSL | 每请求 on-CPU |
|---|---:|---:|---:|
| B1n | 1043 | 128 | 906.3 µs |
| B2 | 8211 | 16 | 989.6 µs |
| B3 | 1043 | 512 | 2526.8 µs |

解得（`harness/profile/slope_model.py`）：

```
每请求 on-CPU ns ≈ 285 223 + 77.56 × ISL + 4 220.0 × OSL
```

**留一点验证（唯一的检验）**：B1（ISL=1221、OSL=128、c=1）**没有参与拟合**，
用上式预测 = 920.1 µs，实测 = 944.4 µs ⇒ **误差 −2.6%**。
（三个拟合点的误差恒为 0（3 点 3 参数），不构成检验，这里不引用。）

**并发摊薄**：B4（c=64）实测 678.0 µs/请求，比同长度的 c=1 外推值 906.3 µs
低 **25.2%** ⇒ 并发确实摊掉了每请求的固定开销（连接/任务/每 tick 一次的分派）。

### 8.2 帧级斜率（只列 top 帧）

`data/profiles/slope-model.csv`（68 帧）。判据：系数 > 0.05 ns/token 才算"该轴驱动"。

| 帧 | 类型 | 每 ISL token | 每 OSL token | 由此得出的段 |
|---|---|---:|---:|---|
| `[libc.so.6]`（拷贝+比较） | ISL+OSL | 8.02 ns | **910.2 ns** | 跨段；**响应侧是大头** |
| `[perf-…map]_[j]`（PCRE2 JIT） | **ISL 驱动** | 22.13 ns | ≈0 | **P4**（编码） |
| `pcre2::bytes::Regex::find_at` | ISL | 10.22 ns | 3.07 ns | **P4** |
| `pcre2_match_8` / `pcre2_jit_match_8` | ISL | 4.98 / 2.92 ns | ≈0 | **P4** |
| `fastokens::…find_matches_pcre2(_parallel)` | ISL | 1.42 / 2.56 ns | ≈0 | **P4** |
| `icu_normalizer::ComposingNormalizerBorrowed::normalize` | ISL | 1.68 ns | 1.27 ns | **P4** |
| `rmp::encode::uint::write_uint` | ISL+OSL | 2.14 ns | 1.25 ns | **P6** |
| `vllm_tokenizer::byte_level_decode` | **OSL 驱动** | ≈0 | **133.2 ns** | **P8** |
| `rmp_serde::decode::Deserializer::any_inner` | OSL | ≈0 | 148.0 ns | **P7** |
| `serde_json::ser::format_escaped_str_contents` | OSL | ≈0 | 80.1 ns | **P10** |
| `serde_core::ser::SerializeMap::serialize_entry` | OSL | ≈0 | 103.5 ns | **P10** |
| `futures_util::…StreamExt::poll_next_unpin` | OSL | ≈0 | 221.9 ns | 跨段（响应侧调度） |
| `Map::try_fold` | OSL | ≈0 | 148.3 ns | 未定段（**属响应段 P8/P9/P10 之一**） |
| `_mi_page_malloc_zero` | OSL | 0.93 ns | **169.4 ns** | 跨段（分配器，响应侧为主） |
| `mi_free` | OSL | 0.06 ns | 122.2 ns | 跨段 |
| `mi_theap_malloc_aligned` | OSL | ≈0 | 63.4 ns | 跨段 |
| `core::hash::BuildHasher::hash_one` | OSL | ≈0 | 65.5 ns | 跨段（哈希，响应侧为主） |
| `std::thread::local::LocalKey<T>::with` | ISL+OSL | 19.08 ns | 20.38 ns | 跨段（两侧都占，见 §5.3） |
| `[[vdso]]_[k]`（时钟） | OSL | ≈0 | 68.7 ns | 跨段（计时/指标） |

**这张表的核心价值**：它把两个**只靠符号名判不出段**的问题解开了——

1. **PCRE2 那 4.7% 到底属于编码还是解码？** 斜率说 **ISL 驱动（22 ns/输入 token）**
   ⇒ 编码（P4）。这同时解释了为什么 `byte_level_decode`（P8）反而按 OSL 计费：
   它们**是两个不同的子系统**，一个在入站、一个在出站。
2. **`[libc.so.6]` 那 15.2% 服务哪一侧？** 斜率说 **两侧都服务，但量级差 113 倍**
   （910 ns/输出 token vs 8 ns/输入 token）⇒ 拷贝成本主要产生在**响应侧**
   （每个 chunk 的 JSON/SSE/ZMQ 帧搬运），而不是"大 prompt 的 memcpy"。

### 8.3 每个分段的每请求成本（µs/请求）与它的斜率

| 分段 | B1 | B1n | B2 | B3 | B4 | 斜率类型 | ns/ISL token | ns/OSL token |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| **P4 分词** | 62.0 | 49.2 | **412.8** | 53.5 | 51.1 | **ISL 驱动** | **50.89** | 11.1 |
| P6 序列化下发 | 11.2 | 11.7 | 27.8 | 10.5 | 11.1 | **ISL 驱动** | 2.20 | ≈0 |
| P2 JSON | 16.9 | 15.3 | 13.2 | 25.7 | 11.6 | ISL+OSL | 0.14 | 27.1 |
| P3 模板 | 15.6 | 14.5 | 13.0 | 14.3 | 9.3 | **常数级** | ≈0 | ≈0 |
| P5 lower | 0.9 | 0.4 | 1.2 | 0.9 | 0.4 | 常数级 | 0.13 | 1.3 |
| **P7 反序列化/分流** | 64.3 | 65.5 | 13.1 | **214.6** | 36.1 | **OSL 驱动** | ≈0 | **388.2** |
| P10 JSON+SSE | 30.6 | 30.2 | 5.6 | **107.8** | 23.6 | OSL 驱动 | ≈0 | 202.2 |
| P1 HTTP/回写 | 56.5 | 63.6 | 40.4 | 128.5 | 44.5 | OSL 驱动 | ≈0 | 168.9 |
| P8 增量解码 | 24.0 | 25.8 | 6.4 | 86.7 | 20.1 | OSL 驱动 | ≈0 | 158.5 |
| P9 parser | 26.4 | 16.4 | 5.3 | 45.3 | 10.8 | OSL 驱动 | ≈0 | 75.2 |
| **X-copy 拷贝/比较** | 143.6 | 136.6 | 92.2 | **486.1** | 114.5 | ISL+OSL | 8.02 | **910.2** |
| **X-alloc 分配** | 133.9 | 136.4 | 64.4 | **383.6** | 112.2 | OSL 驱动 | ≈0 | 643.8 |
| **X-runtime 调度** | 131.2 | 128.0 | 36.7 | **415.1** | 87.4 | OSL 驱动 | ≈0 | 747.7 |
| X-tls | 39.8 | 36.6 | **171.1** | 44.4 | 22.1 | ISL+OSL | 19.08 | 20.4 |
| X-hash | 24.1 | 22.9 | 7.0 | 70.9 | 15.4 | OSL 驱动 | ≈0 | 124.9 |
| X-serde | 19.6 | 18.6 | 4.2 | 62.3 | 11.7 | OSL 驱动 | ≈0 | 113.8 |
| X-rust | 58.6 | 58.7 | 31.1 | 158.3 | 41.6 | ISL+OSL | 0.21 | 259.4 |
| X-log | 17.2 | 16.8 | 7.5 | 54.4 | 14.6 | ISL+OSL | 0.23 | 98.0 |
| X-str | 15.3 | 11.5 | 4.4 | 31.8 | 7.8 | OSL 驱动 | ≈0 | 52.7 |
| X-bytes | 11.8 | 10.4 | 3.7 | 27.7 | 6.2 | OSL 驱动 | ≈0 | 45.0 |
| X-kernel | 11.1 | 10.5 | 3.3 | 38.6 | 9.6 | ISL+OSL | 0.14 | 73.2 |
| X-metrics | 9.6 | 11.5 | 4.1 | 36.2 | 8.8 | OSL 驱动 | ≈0 | 64.2 |
| X-park | 8.8 | 3.0 | 11.0 | 5.2 | 1.8 | ISL+OSL | 1.19 | 5.5 |
| X-unclassified | 8.9 | 10.4 | 9.3 | 19.5 | 4.9 | ISL+OSL | 0.21 | 23.6 |
| X-unknown | 2.3 | 1.4 | 0.8 | 4.9 | 0.8 | 常数级 | — | — |
| **合计** | **944** | **906** | **990** | **2527** | **678** | — | 77.6 | 4220 |

（斜率列来自 `data/profiles/slope-segments.csv`，与 §8.1 的总模型同源；
「≈0」= 系数绝对值 ≤0.05 ns/token，落在噪声内。）

**读法**：

* **P4 是唯一被 ISL 放大的业务段**（49.2 → 412.8 µs，×8.4，与 ISL ×7.9 同阶），
  斜率 **50.9 ns/输入 token**；
* **P7–P10 + X-copy/X-alloc/X-runtime 全被 OSL 放大**：B3（OSL=512）全面上涨，
  其中**跨段三项（拷贝 910 + 分配 644 + 调度 748 ns/token）就占每 token 边际成本
  4.22 µs 的 55%**；
* **X-tls 被 ISL 放大**（36.6 → 171.1 µs），与 §5.3 的反汇编一致：
  那个热点实例是 `Vec` 增长，长 prompt 要在分词/序列化路上反复增长缓冲；
* **B4（c=64）比 B1 低 28%**（678 vs 944 µs）：并发摊掉了固定项
  （P7 64.3 → 36.1、X-runtime 131.2 → 87.4、P1 56.5 → 44.5），
  **但按 token 计费的段几乎不变**（P4 62.0 → 51.1、P8 24.0 → 20.1、P10 30.6 → 23.6）。
  ⇒ **可摊薄的是"每请求/每 tick 的固定成本"，摊不掉的是"每 token 的搬运成本"。**

### 8.4 tools 开关（B1 vs B1n）

唯一差别是请求体里有没有 `tools` 数组（一个真实 function-calling 定义，≈250 字节）：

| 项 | B1（有 tools） | B1n（无 tools） | 差 |
|---|---:|---:|---:|
| 每请求 on-CPU | 944.4 µs | 906.3 µs | **+38.1 µs（+4.2%）** |
| 其中 P3（模板） | 15.62 | 14.52 µs | +1.1 µs |
| 其中 P9（parser） | 26.37 | 16.44 µs | **+9.9 µs** |
| 其中 P2 | 35.26 | 33.29 µs | +2.0 µs |
| X-copy | 143.56 | 136.62 µs | +6.9 µs |
| 吞吐 | 555.5 req/s | 558.3 req/s | −0.5% |

⇒ **tools 的代价 ≈ +4%**，主要落在 P9（响应侧要按 tool 解析状态机扫描）与 P2（多解析一个数组）。
吞吐差异（−0.5%）在单点噪声范围内，**不作为结论**。

---

## 9. 硬件计数（B5：与 B1 同负载）

`perf stat -p <前端pid> -e cycles:u,instructions:u,branches:u,branch-misses:u,L1-dcache-loads:u,L1-dcache-load-misses:u,cache-references:u,cache-misses:u`
（`--timeout` = 34 s；前端在负载前后是空闲的，空闲进程不计周期 ⇒ IPC 这个比值不受窗口余量影响）

| 计数 | 值 |
|---|---:|
| cycles:u | 28 106 409 361（28.1 G） |
| instructions:u | 31 480 307 245（31.5 G） |
| **IPC** | **1.120** |
| branches:u | 5 789 270 588 |
| branch-misses:u | 122 082 583 |
| **分支失败率** | **2.109%** |
| L1-dcache-loads:u | 14 130 720 203 |
| L1-dcache-load-misses:u | 649 268 479 |
| **L1d load miss 率** | **4.595%** |
| cache-references:u | 2 186 045 084 |
| cache-misses:u | 435 010 573 |
| cache miss 率 | 19.90% |

原始输出：`data/profiles/B5.perf-stat.json`（含 `raw_text`）。

**怎么解读（同装置内的自洽，不跨装置比）**：

* **IPC 1.12**：对一个"内存搬运 + 分配"为主的负载来说属于正常偏低。
  作为量级参照：同机的 Python 前端我们没有同口径数据（见 §11 未测项），
  `PREPARE_INPUT_PROJECT` 的 0.77 是**另一台机器（Kunpeng 920B）的 engine core 主线程**，
  **不构成对照**（见 `docs/03` 的口径三层）。
* **分支失败率 2.11%**：对 Rust 来说偏高（编译器内联后通常 <1%），
  与"大量哈希/比较/分发"的结构一致；但**没有做同装置 Python 对照**，所以只能当描述。
* **L1d load miss 4.60% / cache miss 19.90%**：数据侧压力中等。
  ⚠️ `cache-misses` 在 AMD 上对应的事件语义与 Intel 的 LLC miss 不同，
  本文只报数不下结论。

### 9.1 派生量

窗口内实测（`data/profiles/B5.load.json`）：**8145 个请求 / 1 042 560 个输出 token / 30.0017 s**。

| 派生量 | 值 | 怎么算 |
|---|---:|---|
| 每请求 retired instructions | **3.87 M** | 31.480 G / 8145 |
| 每请求 cycles | **3.45 M** | 28.106 G / 8145 |
| 每输出 token instructions | **30.2 k** | 31.480 G / 1.04256 M |
| 每输出 token cycles | **27.0 k** | 28.106 G / 1.04256 M |

⚠️ **这三行数不能说成"正常负载下的每 token 成本"**：见 §10——`perf stat` 把吞吐从
618.9 req/s 压到 **271.5 req/s**（−56%），所以同一份工作量分摊到的周期被整体抬高了。
IPC 是比值、受影响较小，可以引用；**绝对计数与派生量只在"被 perf stat 观测中"这个口径下成立**。

---

## 10. 采样开销（999 Hz 对吞吐的影响）

同一负载（B1：chat+tools / ISL=1k / OSL=128 / c=1 / 30 s）、同一绑核，**只差开不开 perf**：

| 项 | B1（开 `perf record -F 999`） | B1x（**完全不开 perf**） | B5（`perf stat`，8 个硬件事件） |
|---|---:|---:|---:|
| 吞吐 | 555.5 req/s | **618.9 req/s** | **271.5 req/s** |
| 相对 B1x | **−10.2%** | — | **−56.1%** |
| 输出吞吐 | 71 100 tok/s | 79 221 tok/s | 34 750 tok/s |
| p50 端到端延迟 | 1.73 ms | 1.58 ms | 4.30 ms |
| p99 | 3.72 ms | 2.45 ms | 6.67 ms |
| 前端 on-CPU（仅 B1 可得） | 15.74 core-s / 31.1 s | — | — |

⚠️ B5 那一列**不是**同一个负载点（虽然压测参数相同）：`perf stat` 的 8 个事件
互相多路复用，代价远高于 `perf record` 的单个软件事件。
**这是本节最重要的一条口径**：B5 的 IPC 可以用（比值），B5 的吞吐/延迟/绝对计数
**不能**当成"前端正常跑起来的表现"。

⇒ **999 Hz 的 `perf record` 对"每请求 0.94 ms"的前端是可测的干扰**：
吞吐掉约一成、尾延迟变差一半。含义：

1. 火焰图适合回答"**时间花在哪**"（占比），不适合回答"**能跑多快**"；
   任何吞吐数字都应该用 B1x 这类**不开采样**的跑法，或至少标注采样状态。
2. 采样本身的开销主要落在**高频唤醒 + 每样本写 perf 环形缓冲**上，
   所以它对"请求越碎（chunk 越多）"的负载影响越大——B3 这类负载的干扰只会更大。
3. `perf stat`（多事件多路复用）的干扰是 `perf record` 的 5 倍以上 ⇒
   **不要用同时开 `perf record` 与 `perf stat` 的跑法**（计划 §5.1 的"互斥"要求是对的）。

⚠️ **诚实标注**：B1 与 B1x 是**先后两次运行**，不是交替重复，
所以 −10.2% 里含 run-to-run 漂移。**没有做重复实验**（见 §11 未测项）；
引用时应写成"单次对照 −10.2%"，不要写成精确的采样开销。

---

## 11. 局限、未测项与复现

### 11.1 局限（会改变结论解释方式的）

| # | 局限 | 影响 |
|---|---|---|
| 1 | **fp 栈浅**：47.99%（B1）的样本只有"线程名 + 叶子帧" | 分段归属靠符号 + 线程 + 斜率三角验证，**不能**给出"从 HTTP 入口到回写的完整调用链成本" |
| 2 | **dwarf 不可用**（§2.1） | 无法用更精确的展开补上第 1 条；AMD 这台机器 `--call-graph lbr` 也不支持（实测报 "PMU Hardware or event type doesn't support branch stack sampling"） |
| 3 | **mock engine 无节流** | 引擎侧不构成瓶颈，所以测到的是"前端能跑多快"的上界；真实引擎下的占比会变（尤其 P7 的每 tick 摊薄） |
| 4 | **跨段桶 67.35%** | 分配/拷贝/调度无法归到单段；本报告用斜率给出"服务哪一侧"，但没有"每段含多少分配"这种分解 |
| 5 | **`[libc.so.6]` 有 9.1% 未登记区间** | X-copy 里有约 1.4% 的成分未定名 |
| 6 | `cache-misses` 在 AMD 上语义可疑 | 只报数 |

### 11.2 未测项

| 项 | 状态 | 原因 |
|---|---|---|
| 采样开销的重复实验（交替开/关各 N 轮） | **未测** | 重活锁排队紧张；只做了单次对照（§10） |
| `--call-graph` 在 Python 前端上的同口径对比 | **未测** | 属 C 线；本文只测 Rust 侧 |
| 真实引擎（非 mock）下的前端火焰图 | **未测** | 属 C 线（G3）；mock 下引擎不构成瓶颈 |
| 每段内部的"分配次数"分解 | **未测** | 需要插桩或 eBPF，本线按计划只做不侵入采样 |
| `server` 端点的非 chat 路径（/completions、/tokenize） | **未测** | 计划外（`plan/EXECUTION.md` §9） |
| libc `0x1837xx` 之外剩余的未登记区间 | 部分 | 已定名 `memmove/memcpy` 与 `memcmp`（§5.1、§7.3），余下 9.1% 未定名 |
| NUMA / 核间迁移对占比的影响 | **未测** | 单机固定绑核 |
| B5 与 B1 之外的高并发 `perf stat`（如 c=64） | **未测** | 矩阵只要求 B5 与 B1 同负载 |

### 11.3 一键复现

```bash
harness/common/stack.sh start --run runs/b-matrix
scripts/heavy_lock.sh scripts/limit.sh env CORES=1-3 \
  harness/profile/run_matrix.sh --run runs/b-matrix --out-dir data/profiles --duration 30
harness/profile/flamegraph.sh --folded data/profiles/B1.folded \
  --out figures/02-flame-B1.svg --title "B1 ..." --by-segment figures/02-flame-B1-by-segment.svg
python3 harness/profile/slope_model.py
harness/common/stack.sh stop --run runs/b-matrix
```

每份 `data/profiles/<tag>.perf-manifest.json` 带：call-graph 方式、freq、窗口起止 epoch、
样本数、折叠栈 sha256、制品 sha256；`data/profiles/<tag>.load.json` 带窗口内请求数、
吞吐、延迟分位、客户端自身 CPU。脚本清单与踩坑见 `harness/profile/README.md`。

---

## 12. 与其它文档的口径对齐

B 线在采集**早期**（10 s 探针、非流式负载）曾向根代理报告过一组数字，
**D 线的 `docs/05-segment-costs.md` 当时引用了那一组**。正式矩阵（30 s、SSE 流式）跑完后，
**D 线已按本节正式矩阵校正其引用**（`D-micro: 按 B 线正式 30s 矩阵校正 docs/05 里引用的火焰图数字`），
**旧值只保留在新旧口径对照表中**；本表保留下来是为了说明差异来源：

| 项 | 早期探针（10 s，非流式） | **正式矩阵（30 s，SSE，B1）** | 差异原因 |
|---|---:|---:|---|
| `memcpy/memmove` | 10.6% | **`[libc.so.6]` 15.20%**（其中 memmove/memcpy ≈80% ⇒ **12.2%**，memcmp ≈11% ⇒ 1.7%） | 正式口径把**未解析帧整体**单列；流式（每 token 一个 chunk）放大拷贝 |
| mimalloc 家族 | ≈11% | **14.18%** | 同上（SSE 每 chunk 多次分配） |
| PCRE2（JIT + match） | ≈4.8% | **4.7%**（P4 段合计 6.57%） | 一致 |
| `LocalKey<T>::with` | 6.25% | **4.22%** | 同上 |

⇒ 引用时以本表的"正式矩阵"列为准；D 线原文的定性结论
（"成本在搬运与分配、不在解析算法"）不受影响，反而更强。

### 12.1 与 D 线/micro 的数字**不能互相折算**

D 线已在自己的文档里加了警告，这里也写一条对称的边界：

| | D 线微基准（`docs/05`，含 D6 预分词） | B 线（本文） |
|---|---|---|
| 量的是什么 | **单次操作的墙钟 µs**（多线程时是墙钟，不是 CPU 时间） | **整进程 on-CPU 的 self 时间占比** |
| 线程口径 | D6 预分词在 ≥16 个 split 时走 **rayon 多线程** | 采样累计该进程**所有线程**的 on-CPU |
| 负载形态 | 固定 fixture、单操作循环 | 真实 HTTP 负载（SSE、每 token 一个 chunk） |
| 含不含等待 | 含（墙钟） | 不含（on-CPU） |

⇒ **两边的百分比不能相减、不能互相折算**，只能**互证方向**
（例：B 线看到 PCRE2 帧全是 ISL 驱动 ⇒ 属 P4；D6 独立测出预分词占 fastokens
encode 的 71–89% ⇒ 同一段，同向）。本文所有"占比"都只在本装置、本口径内成立。

---

## 13. 每负载点的前端 CPU 时间（必采项 ④）

### 13.1 ⚠️ 先读这个：本文前 12 节的占比是**用户态**占比

`perf_event_paranoid=2` 下，`perf record -e cpu-clock` **只能采用户态**
（证据：perf 自己报的事件名是 `cpu-clock:u`，见 `data/gates/g2-perf-symbol-check.txt` 表头，
以及本线每份 manifest 的 `perf.event=cpu-clock`）。
所以 §6–§8 的所有占比都是 **「用户态 on-CPU 的时间占比」**，
**不是「前端进程总 CPU 的占比」**——两者差约一倍（见 §13.2 的 stime 列表）。

**这条不影响 §6–§10 的内部一致性**（同一口径内的排序、斜率、对照都成立），
也**不影响与 C 线的对比**（只要两侧用同一套 perf 参数）——
它影响的是「前端 CPU 到底花在哪」的**绝对**画像：**大约一半在内核态，而火焰图看不见。**

### 13.2 每负载点的前端 CPU 时间表

采集方式：`harness/profile/cpu_windows.sh`，**窗口内不开任何 perf**（见 §13.3 的理由）；
前端 CPU 来自 `harness/common/procstat.sh`（`utime+stime`，**不含子进程**），
before 快照取在**预热之后 / 窗口之前**、after 取在**窗口之后**。
10 个点的原始 JSON：`data/profiles/<ID>.cpu-load.json`、`<ID>.frontend-cpu.json`；
汇总 CSV：`data/profiles/load.csv`。

| ID | 负载（chat，SSE） | 窗口 s | 请求数 | **前端 CPU s** | **前端 CPU s/请求** | **s/千输入 token** | **s/千输出 token** | 其中 utime / stime | 压测端 CPU s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **B1** | +tools，ISL=1k，OSL=128，c=1 | 20.000 | 11 129 | 20.35 | **1828.6 µs** | 0.0014976 | 0.0142856 | 10.30 / **10.05** | 14.63 |
| B1n | 无 tools，其余同 B1 | 20.001 | 11 918 | 20.10 | 1686.5 µs | 0.0016170 | 0.0131760 | 9.81 / 10.29 | 15.29 |
| **B2** | ISL=8k，OSL=16，c=1 | 20.001 | 16 422 | 20.32 | **1237.4 µs** | **0.0001507** | 0.0773353 | 14.46 / 5.86 | 6.58 |
| **B3** | ISL=1k，**OSL=512**，c=1 | 20.003 | 4 367 | 23.00 | **5266.8 µs** | 0.0050496 | **0.0102867** | 10.81 / 12.19 | 17.22 |
| **B4** | ISL=1k，OSL=128，**c=64** | 20.043 | 23 926 | 26.22 | **1095.9 µs** | 0.0010507 | **0.0085616** | 15.28 / 10.94 | 19.79 |
| B5 | =B1（干净窗口，无 perf） | 20.002 | 11 068 | 20.24 | 1828.7 µs | 0.0014977 | 0.0142867 | 10.40 / 9.84 | 14.49 |

**对照/诊断点（同一张 CSV，用 `note` 列区分）**：

| ID | 是什么 | 窗口 s | 请求数 | 前端 CPU s | 前端 CPU s/请求 | 吞吐 req/s | 其中 utime / stime |
|---|---|---:|---:|---:|---:|---:|---:|
| B1perf20 | 同 B1，但窗口内 `perf record -F 999` 在跑 | 20.001 | 11 141 | 21.71 | 1948.7 µs | 557.0 | 10.31 / 11.40 |
| B5stat20 | 同 B1，但窗口内 `perf stat`（8 事件）在跑 | 20.002 | 5 420 | 26.84 | 4952.0 µs | 271.0 | 4.44 / **22.40** |
| B1nostream | 同 B1 但**非流式** | 20.001 | 12 751 | 21.00 | 1646.9 µs | 637.5 | 8.56 / **12.44** |
| B1chunk32 | 同 B1，但 mock engine `--output-token-chunk-size 32` | 20.000 | 29 881 | 15.24 | **510.0 µs** | **1494.0** | 9.68 / 5.56 |

### 13.3 三个必须一起引用的口径说明

1. **窗口长度与上一版不同**：§3.1 的 B1–B4 是 **30 s** 火焰图窗口，本节全部是 **20 s**，
   且 20 s 是**六个点共用的同一窗口长度**（任务书允许）。两者负载完全相同
   （请求体文件复用，`body_sha256` 一致），只是窗口时长不同，**不要跨表相减**。
2. **本节窗口内不开 perf**：§10 已量出 `perf record -F 999` 会把吞吐压低约一成；
   要回答"正常运行时的每请求 CPU"就不能带采样。带采样的两种观测态单独列为
   `B1perf20` 与 `B5stat20`（后者即"B5 的 perf stat 实际窗口"）。
   ⚠️ `perf stat` 的代价远大于 `perf record`：**4952 vs 1829 µs/请求（+171%）**，
   其中 **stime 从 10.05 s 涨到 22.40 s**（多路复用 8 个硬件事件把内核时间打爆）。
   ⇒ **B5 的 IPC 可以用（比值），B5 的 CPU 时间/吞吐不能当正常表现**（与 §10 结论一致）。
3. **压测端 CPU 单独记**：表里最后一列是**客户端进程自己的** CPU
   （`getrusage` 与 procstat 交叉校验过），与前端**是两个进程、两个数、绝不相加**。
   注意 `B1nostream` 的压测端只用了 2.45 s——因为非流式下它不用解析 SSE。

### 13.4 stime 占一半：内核时间从哪来（含两个对照实验）

| 观察 | 证据 |
|---|---|
| 前端 CPU 里 **49% 是内核态**（B1：stime 10.05 / 20.35 s） | procstat 的 utime/stime 拆分 |
| **不是** SSE 每 chunk 写造成的 | `B1nostream`（非流式）stime **升到** 12.44 s ⇒ 与假设相反 |
| **是** ZMQ 侧"每 tick 一次收包"造成的 | `B1chunk32`：mock engine 每 tick 32 个 token ⇒ stime **降到 5.56 s**（−45%），前端 CPU/请求 **1829 → 510 µs（−72%）** |
| 与 ISL 弱相关、与输出 token 强相关 | B2（ISL=8k、OSL=16）stime 只有 5.86 s；B3（OSL=512）12.19 s |

**推断（标注为推断）**：mock engine 的 `output_token_chunk_size=1` 让**每个输出 token
产生一次 ZMQ 消息**，前端每收一条就要走一轮 `recv → msgpack 解码 → mpsc → 任务唤醒`，
其中系统调用与唤醒的代价记在 stime 上。按这个推断：

* 本文的 **P7（6.81%）与 X-runtime（13.90%）是被 mock engine 放大的部分**，
  真引擎（batch 内多 token 一次下发）下会显著变小；
* 反过来，**`B1chunk32` 的 510 µs/请求**更接近"每请求固定 + 每 token 计算"的成本，
  但它仍然不是真引擎（真引擎的 tick 节奏由调度器决定）。

⇒ 结论：**"前端 CPU 时间/请求"这个数在 mock engine 口径下是"上界"，
其中约一半是内核态、且内核态主要由 chunk=1 的收包频率造成。**
这一点已写入 §11.1 的局限表。

### 13.5 B1(c=1) → B4(c=64)：前端成本**随并发摊薄**（任务书第 4 点）

| 指标 | B1（c=1） | B4（c=64） | 变化 |
|---|---:|---:|---:|
| 前端 CPU s/请求 | **1828.6 µs** | **1095.9 µs** | **−40.1%** |
| 前端 CPU s/千输出 token | 0.0142856 | 0.0085616 | −40.1% |
| 其中 utime/请求 | 925 µs | 639 µs | −30.9% |
| 其中 stime/请求 | **903 µs** | **457 µs** | **−49.4%** |
| 吞吐 | 556.4 req/s | 1193.7 req/s | +114.6% |
| 前端占用（CPU s / 窗口 s） | 1.02 核 | 1.31 核 | +0.29 核 |

**判断（一句话）**：**变小——前端 CPU/请求从 1.83 ms 降到 1.10 ms（−40%），
且下降主要来自内核态（−49%）而不是用户态（−31%），
说明可摊薄的是"每请求一次的收包/唤醒/任务分发"，摊不掉的是"每 token 的计算与搬运"。**

**两个边界**：

1. 与 §8.3 的结论一致（那里是用户态口径：B1 944 → B4 678 µs，−28%），
   本节把内核态算进来后摊薄幅度更大（−40%），因为内核态里"每请求固定"的成分更多。
2. 这只到 c=64；**前端在 B4 只用了 1.31 个核**（绑了 2 核），
   还没有触到"前端变瓶颈"的拐点 ⇒ 拐点位置**未测**（属 C 线/Q4）。

### 13.6 重复性

同一个负载（B1，chunk=1）在本节采到三次：
**1757.7 / 1828.7 / 1828.6 µs/请求**（第一次是命名修复前的 B1、后两次是 B5 与 B1 复跑）
⇒ **run-to-run 离散 ±4%**。所以本节的数按 **±4%** 读，
量级小于 4% 的差异**不要当结论**。
（对照：B1 与 B1n 的 "tools 差价" 在两个口径下方向一致——B1 更贵——
但幅度不同：用户态口径 **+38 µs / +4.2%**（§8.4），总 CPU 口径 **+142 µs / +7.8%**（本节）；
两者的差落在重复性边界上，本文只保留"方向"，不给"tools 精确值"。）

### 13.7 procstat 口径的每请求线性模型（总 / 用户态 / 内核态三条分开解）

§8.1 给的模型是 **perf 用户态口径**（`285 223 + 77.56×ISL + 4220×OSL`）。
那是"火焰图能看见的那一半"。下面是**同一形式、但用 procstat（utime+stime）**解的模型，
并用 §13.2 的表做三点拟合（B1n / B2 / B3，c=1），**B1 留一点验证**；
同时给出**用户态与内核态各一条**——因为两条斜率的物理来源不同：
utime 主要随 token/字节走，stime 主要随"每个 tick 一次的系统调用"走。

一键复跑：`python3 harness/profile/procstat_model.py`（输出 `data/profiles/cpu-model.{json,csv}`）。

#### 三点模型（B1n / B2 / B3）

```
tot_ns/请求  ≈ 406,522 + 83.019 × ISL + 9,323.57 × OSL     （= utime + stime）
ut_ns/请求   ≈ 193,898 + 75.239 × ISL + 4,302.76 × OSL     （用户态）
st_ns/请求   ≈ 212,622 +  7.780 × ISL + 5,020.81 × OSL     （内核态）
```

| 项 | 实测（B1，未参与拟合） | 模型预测 | 误差 |
|---|---:|---:|---:|
| 总 CPU | 1828.6 µs | 1701.3 µs | **−7.0%** |
| 用户态 | 925.5 µs | 836.5 µs | −9.6% |
| 内核态 | 903.0 µs | 864.8 µs | −4.2% |

⚠️ **B1 的验证误差（−7%）大于 §13.6 的重复性（±4%）**，原因清楚：
B1 是**唯一带 tools** 的点，而模型里没有"tools"这一维；tools 的额外成本
（用户态 +4.2%、总 CPU +7.8%，见 §8.4/§13.6）正好落在这个残差上。
所以这个 −7% **不是模型错了，而是"tools"被当成了纯噪声**。

#### 最小二乘（5 个 c=1 点：B1 / B1n / B2 / B3 / B5）

三点模型没有残差自由度，把 5 个点一起拟合才第一次给出真实的模型误差：

| 口径 | 模型 | R² | 最大单点误差 |
|---|---|---:|---:|
| **总 CPU** | `536,377 + 67.903×ISL + 9,102.0×OSL` | **0.99895** | 5.1% |
| 用户态 | `291,870 + 63.835×ISL + 4,135.6×OSL` | 0.99676 | 7.9% |
| 内核态 | `244,507 + 4.069×ISL + 4,966.4×OSL` | **0.99978** | 2.4% |

**推荐外部（如 `docs/06` 容量表）使用最后这一组 OLS 数字**：
R² ≥ 0.997、最大单点误差 ≤8%，且 5 个点里既含 tools / 无 tools，也含长短 prompt。

#### 边际成本的构成（这份表才是"为什么"）

| 轴 | 总 | 用户态 utime | 内核态 stime | **stime 占比** |
|---|---:|---:|---:|---:|
| 每请求（常数项） | 406.52 µs | 193.90 µs | 212.62 µs | **52.3%** |
| 每 **输入** token | 83.02 ns | 75.24 ns | 7.78 ns | **9.4%** |
| 每 **输出** token | 9 323.57 ns | 4 302.76 ns | 5 020.81 ns | **53.9%** |

**两条结论（`docs/03`/`docs/06` 都要用）**：

1. **每输入 token 的成本 91% 在用户态**（75.2 / 83.0 ns）——
   prompt 侧就是分词/JSON/msgpack 的纯计算，**几乎没有系统调用**；
2. **每输出 token 与每请求的固定成本里，内核态各占 54% / 52%**——
   出站方向（每 tick 一次收包 + 每次响应写出）是**系统调用密集**的。
   ⇒ 前端成本随 OSL 增长的那一半，**光换更快的用户态代码没用**。

### 13.8 mock engine 的放大因子：`--output-token-chunk-size`（口径折扣结论）

**先看事实**（三个点，同 B1 负载、同 20 s 窗口、都不开 perf，见 §13.2 的表）：

| 观测 | 前端 CPU/请求 | utime | stime | 吞吐 |
|---|---:|---:|---:|---:|
| chunk=1（本项目全矩阵的默认口径） | **1 828.6 µs** | 10.30 s | 10.05 s | 556 req/s |
| chunk=32 | **510.0 µs** | 9.68 s | 5.56 s | 1 494 req/s |
| 非流式（chunk=1，stream=false） | 1 646.9 µs | 8.56 s | **12.44 s** | 638 req/s |

**再看 mock engine 的行为（源码核实，不是猜）**：`Engine::step()`
（`rust/src/mock-engine/src/engine.rs:322-378`）遍历**所有** active request，
把它们的输出**合并成一条** `EngineOutput` 发出 ⇒
**每个 step 一条 ZMQ 消息，与并发数无关**；每个 request 每个 step 前进
`output_token_chunk_size` 个 token。

⇒ **chunk=1 与真实引擎（无投机解码/MTP）是同构的**：
vLLM v1 的 engine core 同样是「每个 step 发一条 `EngineCoreOutputs`，内含该 step
所有请求的输出」，而非投机解码时每 step 每请求恰好 1 个 token。
**chunk=32 才是 MTP / spec-decode 形态**（每 step 每请求 32 个 token）。

**结论（可直接引用）**：

> `--output-token-chunk-size` 是**前端 CPU 的强放大因子**：chunk=1 → **1 828.6 µs/请求**，
> chunk=32 → **510.0 µs/请求（−72%）**。但由于 mock engine 与 vLLM v1 在
> **"每个 engine step 发一条消息、每请求每 step 一个 token"** 这一点上同构，
> **chunk=1 对应的是常规（非投机）引擎形态，chunk=32 对应 MTP/spec-decode**。
> ⇒ **本项目所有基于 mock engine chunk=1 的前端 CPU 数字不虚高**，
> 可以代表常规引擎的前端成本；但**必须写明它依赖 engine tick 粒度**：
> 一段 OSL=128 的生成会产生 **128 次 engine tick**，前端要为每一次付
> 一次收包/解码/唤醒的代价。

**两条限制（必须一起引用）**：

1. **非流式对照证伪了"stime 来自 SSE 每 chunk 写"**（§13.4）：
   非流式 stime 反而**更高**（12.44 s）⇒ 内核时间主要来自**入站方向**
   （ZMQ 收包/唤醒）而不是回写；
2. **但 stime 也不能全部归给"每 tick 一次收包"**：把 chunk=1 的 B1 与 c=64 的 B4 相比，
   B4 的每请求消息数降到 1/64（每 step 一条消息含 64 个请求的输出），
   而 B4 的 stime/请求只降到一半（903 → 457 µs）——
   说明 stime 里还有一份**与 token 数（或字节数）成正比**的成分。
   **本节不对这两份成分的比例下结论**（x86 本机 `perf_event_paranoid=2`，
   `cpu-clock` 被降级成 `:u`，内核态在火焰图里完全不可见）。
   **REMOTE_HOST 上做了两件事来补这个缺口**：§14.4 的 syscall tracepoint 计数（每请求的系统调用次数），
   以及 §14.2 坑 2 记录的「内核符号不可解析」——后者限制了能拿到什么，如实写在那里。

---

## 14. REMOTE_HOST chip4（真 NPU）主 profiling

> 本节起是**主口径**：REMOTE_HOST（Kunpeng 920B + Ascend 910）、vLLM 0.26 镜像、
> **真引擎**、chip4 = `/dev/davinci4`。装置与用卡纪律见 `harness/a3/README.md`。
> 采集脚本在 `harness/profile/a3/`（`prof_point.sh` / `batch_remote.sh` /
> `run_batch.sh` / `collapse_a3.sh` / `summarize_a3.py` / `share_anchor.py`），
> 全部带 `--help`；结果在 `data/profiles/a3/`。

### 14.1 装置与口径

| 项 | 值 |
|---|---|
| 机器 | REMOTE_HOST（Kunpeng 920B，aarch64，640 逻辑核；`uname -m` = aarch64） |
| 卡 | **chip4 = `/dev/davinci4`**（`npu-smi -i 2` 的 Chip ID 0；⚠️ `-i` 是 NPU ID 不是 davinci 号） |
| 镜像 | `quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler` |
| 镜像内 vLLM | `/vllm-workspace/vllm` @ `568afb3a`（与计划锁定值一致）；vllm-ascend @ `f2f74a16c` |
| 前端二进制 | aarch64 wheel 抽取，`~/projects/vllm/vllm-rs/bin/vllm-rs`，sha256 `cae05321…`，not stripped |
| 服务绑核 | 容器 cpuset `160-199`、NUMA 2（chip N ⇒ CPU `40N..40N+39`） |
| 压测客户端 | **独立容器**（不带 NPU 设备），cpuset `200-201` |
| 负载 | `vllm bench serve --backend openai-chat --endpoint /v1/chat/completions`，`--dataset-name random` |
| 前端 CPU 口径 | 容器内前端进程的 `utime+stime`（`harness/common/procstat.sh`，**不含子进程**） |
| 引擎 CPU 口径 | 容器内 `VLLM::EngineCor*` / `VLLM::Worker*` 的 `utime+stime`（同一把尺子） |

**两侧唯一的变量是前端**：同一个镜像、同一个引擎、同一张卡、同一个客户端容器，
只差 `VLLM_USE_RUST_FRONTEND`（`1` + `VLLM_RUST_FRONTEND_PATH` vs `0`）。
这正是 `docs/03` **层 1（同装置同口径）** 要求的对照。

### 14.2 三个必须知道的方法学坑（都在本节实测撞到）

这三条决定了本节的数据**能采到什么、采不到什么**，引用任何 REMOTE_HOST 数字前先读。

#### 坑 1：容器内路径 ⇒ 符号全丢（已解：`--symfs`）

被采进程在容器里，perf 记录的 mmap 路径是**容器内路径**
（`/opt/vllm-rs-bin/vllm-rs`、`/usr/lib64/libc.so.6`），这些路径在**宿主上不存在**
⇒ 直接 `perf script` 得到的帧名全是 `[unknown]`：

```
vllm-rs 1746147 626784.532076:    1001001 cpu-clock:
	ffffabfb9de8 [unknown] (/usr/lib64/libc.so.6)
	aaaabd5dd830 [unknown] (/opt/vllm-rs-bin/vllm-rs)      ← 符号没解析
```

**解法**：构造一个 `--symfs` 目录树，把容器内路径映射到真实文件——
`vllm-rs` 用宿主副本（同一个 sha256），动态库用 `docker cp` 从容器里取
（容器内的 glibc 版本与宿主不同，必须取容器内的那一份）。
`prof_point.sh` 已自动做这一步，并打印**符号自检**（未解析帧占比）。

#### 坑 2：`/proc/kallsyms` 的地址被清零 ⇒ **内核符号不可解析**

```
$ head -2 /proc/kallsyms
0000000000000000 T _text          ← 地址全是 0（`kptr_restrict=0` 也不行）
```

（对比：`PREPARE_INPUT_PROJECT` 项目在同一台机器上采到过内核符号名，
可能与其采集时段或 perf 版本/内核配置有关；**本轮实测不可解析**，如实记录。）

⇒ 内核态帧只能拿到裸地址 `[k] 0xffff…`，**做不出内核火焰图**。
本节因此用两个替代证据回答「内核态去哪了」：
① `procstat` 的 `stime` 比例（定量），② **syscall tracepoint 计数**（定性 + 每请求次数）。

#### 坑 3：`--call-graph dwarf` 在 REMOTE_HOST 上**不可用**

```
$ sudo perf record -p <前端pid> -e cpu-clock -F 999 --call-graph dwarf,16384 …
Error:
cpu-clock: PMU Hardware doesn't support sampling/overflow-interrupts. Try 'perf stat'
```

⇒ REMOTE_HOST 上 **`cpu-clock` 事件不支持 dwarf 展开所依赖的 overflow 中断**（aarch64 侧限制），
perf.data 落成 0 字节。本节全部火焰图使用 `--call-graph fp`。
（对照：x86 那台是**能 record 但展开出垃圾**——两台机器上 dwarf 都不可用，原因不同。）

### 14.3 采样参数（两侧完全一致）

```
sudo perf record -p <前端容器内进程的宿主 pid> -e cpu-clock -F 999 --call-graph fp
sudo perf stat   -p <同一 pid> -e instructions:u,cycles:u,branches:u,branch-misses:u,\
                                       cache-misses:u,cache-references:u \
                              [,syscalls:sys_enter_recvmsg,syscalls:sys_enter_sendto,\
                                syscalls:sys_enter_write]
```

* 采样对象是**宿主 pid**（`docker top` 取），perf 在宿主上跑（容器内没有 perf）；
* `perf record` 的窗口 = 负载窗口（预热之后、正式负载之前启动 perf，负载结束立即停）；
* `perf stat` 的花费远大于 `perf record`（x86 侧实测 +171% CPU/请求），
  所以**吞吐结论一律取「窗口内不开 perf」的点**（`mode=none`）；
* 每份结果写 `runs/<run>/<tag>-<side>/point.json`，含 `perf_record{event,freq,call_graph}`、
  窗口起止、pids、前端/引擎 CPU 分桶、e2e 指标。

### 14.4 A1：Rust 前端 + 真引擎（ISL=1k / OSL=128 / c=1）

> 采集：`runs/b-t3/A1-rust`（`sudo perf record -p <前端宿主pid> -e cpu-clock -F 999 --call-graph fp`）。
> 窗口 **151.6 s**、完成 192 请求、**2011 个样本**、符号未解析率 **30.2%**
> （未解析的绝大多数是 `[k]` 内核帧——见 §14.2 坑 2；用户态符号已用 `--symfs` 解析）。
> 折叠栈 `data/profiles/a3/a3-A1-rust.folded`，图 `figures/02-flame-a3-A1-rust.svg`
> 与 `…-by-segment.svg`。

#### 帧级 top-20（self）

| # | 帧 | self% | 分段 |
|---:|---|---:|---|
| 1 | `[[kernel.kallsyms]]_[k]`（未解析的内核帧） | **30.03%** | X-kernel |
| 2 | `std::thread::local::LocalKey<T>::with` | **8.63%** | X-tls |
| 3 | `tokio::runtime::scheduler::multi_thread::worker::Context::run` | 3.91% | X-runtime |
| 4 | `[libc.so.6]`（块拷贝/比较） | 2.78% | X-copy |
| 5 | `futures_util::stream::StreamExt::poll_next_unpin` | 2.17% | X-runtime |
| 6 | `rmp_serde::decode::Deserializer::any_inner` | 1.51% | **P7** |
| 7 | `mi_free` | 1.41% | X-alloc |
| 8 | `tokio::process::imp::orphan::OrphanQueueImpl::reap_orphans` | 1.37% | X-runtime |
| 9 | `parking_lot::condvar::Condvar::wait_until_internal` | 1.32% | X-runtime |
| 10 | `tokio::…::park::Parker::park` | 1.27% | X-runtime |
| 11 | `[[vdso]]_[k]` | 1.23% | X-kernel |
| 12 | `[nf_tables.ko.xz]`（netfilter 模块） | 1.08% | X-unclassified |
| 13 | `tokio::runtime::io::driver::Driver::turn` | 0.99% | X-unclassified |
| 14–17 | `tokio` 调度器内部（`steal_into` / `Unparker::unpark` / `poll_readiness` / `time::Handle::…`） | 0.90–0.94% 各 | X-runtime |
| 18 | `tokio::sync::mpsc::list::Tx::push` | 0.85% | X-runtime |
| 19 | `epoll_pwait` | 0.80% | X-kernel |
| 20 | `crossbeam_deque::Stealer::steal` | 0.75% | X-park |

#### 分段占比（与 §7.2 的 x86 表**不能混**）

| 分段 | REMOTE_HOST chip4（真引擎，aarch64） | x86 mock（§7.2） | 变化 |
|---|---:|---:|---|
| P1–P10 合计 | **10.80%** | 32.65% | **−21.9 pp** |
| ├ P7（msgpack 解/分流） | 3.91% | 6.81% | 相对占比仍最大 |
| ├ P1（HTTP） | 2.22% | 5.98% | |
| ├ P4（分词） | 2.17% | 6.57% | |
| └ P2/P3/P8/P9/P10 | 各 0.09–1.37% | 各 1.6–3.2% | |
| **X-kernel（内核态）** | **32.86%** | 1.18%（**采不到，非真实占比**） | 见下 |
| **X-runtime（tokio/futures）** | **21.92%** | 13.90% | +8.0 pp |
| X-tls | 8.63% | 4.22% | +4.4 pp |
| **X-copy（块拷贝/比较）** | **2.97%** | 15.20% | **−12.2 pp** |
| X-alloc | 4.90% | 14.18% | −9.3 pp |
| X-unclassified | 9.76% | ~1% | 含 nf_tables / tokio io-driver 等未登记帧 |

#### 三条读数

1. **真引擎下前端变成「I/O 与调度密集型」，不再是「搬运密集型」。**
   拷贝从 15.2% 掉到 **3.0%**、分配从 14.2% 掉到 **4.9%**，
   而 tokio 运行时分发从 13.9% 涨到 **21.9%**、内核态占 **32.9%**。
   `[推断]`：引擎快（TPOT 4.8 ms）⇒ 每个 tick 间隔短、每 tick 的数据量小
   ⇒ 前端花在「醒来—轮询—park—收包」上的**相对**时间上升，而每次搬运的字节数下降。
2. **内核态第一次被看见，且它主要是 I/O 就绪与网络栈**：
   `epoll_pwait`（0.80%）、`[[vdso]]`（1.23%）、**`nf_tables.ko`（1.08%）**、
   以及 30.03% 的未解析内核帧。`[推断]`：前端与引擎之间是 **loopback TCP**（ZMQ），
   每个 tick 一次收发 ⇒ 内核网络栈 + netfilter 被反复穿过。
   ⚠️ 因为 `/proc/kallsyms` 地址被清零（§14.2 坑 2），**这 30.03% 里没有一个函数名**，
   所以「内核态去向」在本文只是**定性**结论，不是函数级分解。
3. **一个意外项：`reap_orphans`（1.37%）+ `Parker::park`/`Condvar::wait`（2.59% 合计）。**
   前者是 tokio 的**子进程回收**——Rust 前端在这套部署里是
   `vllm serve`（Python 主进程）拉起的**子进程**，却自己在回收孤儿进程；
   后者是运行时空转/等待。这两项在 x86 的 mock 负载里几乎看不见
   （那个负载下前端一直在算，从不空等）。

#### 与 x86 的「前端 CPU/请求」对比（跨装置，**不可相减**）

| 装置 | 引擎 | 前端 CPU s/请求 | 前端 CPU s/千输出 token |
|---|---|---:|---:|
| x86（§13.2 B1） | mock（瞬时） | **0.00183** | 0.01429 |
| REMOTE_HOST chip4（A1） | 真 NPU（TPOT 4.81 ms） | **0.00953** | 0.07445 |

⇒ 真引擎下前端每请求 CPU 是 mock 引擎下的 **5.2×**。
**这不是"前端在真引擎下更累"**，而是两类成本的构成不同：
mock 引擎一次性把 128 个 token 灌回来（前端只有"处理"没有"等待/轮询"），
真引擎每个 tick 只回 1 个 token 且间隔 4.8 ms（前端要维持 I/O 就绪、定时器、子进程管理）。
⇒ **mock engine 口径会低估前端的"运行成本"，但高估它的"数据搬运成本"**。

### 14.5 A5：双侧 `perf stat`（同装置同口径的 IPC 对照）

采集方式：`sudo perf stat -p <前端宿主pid>`，事件
`instructions:u,cycles:u,branches:u,branch-misses:u,cache-misses:u,cache-references:u`
加上一组 syscall tracepoint（见下）。⚠️ **只取用户态事件（`:u`）**——
两侧一致，所以 `IPC = instructions:u / cycles:u` 可比。

#### Rust 前端（A5-rust，96 请求，窗口 85.3 s）

| 计数 | 值 |
|---|---:|
| instructions:u | 938 373 368 |
| cycles:u | 1 295 436 135 |
| **IPC** | **0.7243** |
| branches:u | 192 574 155 |
| branch-misses:u | 12 092 168 |
| **分支失败率** | **6.28%** |
| cache-references:u | 391 295 878 |
| cache-misses:u | 17 666 529 |
| cache miss 率 | 4.51% |

#### syscall tracepoint：前端每请求要过多少次系统调用

（同一窗口。**这是内核态去向的直接计数证据**，绕开了「内核符号不可解析」。）

| tracepoint | 计数 | 每请求 |
|---|---:|---:|
| `sys_enter_write` | **19 988** | **208.2** |
| `sys_enter_sendto` | 96 | 1.0 |
| `sys_enter_recvmsg` | **0** | 0 |

**读数**：

1. **`write` 系统调用 ≈ 208 次/请求**，而 OSL=128 ⇒ 与「每个 SSE chunk 一次或两次 write」
   完全吻合（chunk 数 128 + chunked 编码/其它 = 208）。这就是内核态时间的主要来源之一。
2. **`recvmsg` 是 0** ⇒ zeromq 收包不走 `recvmsg`（走 `recvfrom`/`read`），
   这也是一个容易写错的口径坑（第一版 tracepoint 列表里只有 `recvmsg`，得 0，
   差点得出「前端不收包」的错误结论）。补上 `recvfrom`/`read` 后的数字见 §14.7。
3. `sendto` = 1 次/请求 ⇒ 前端向引擎**每请求只发一次**（P6 的 msgpack 下发确实是每请求一次，
   与 A 线的静态结论一致）。

#### 与 x86 的 stime 对照：**「Rust 前端有 1/3–1/2 的 CPU 在内核里」**

| 装置 | 内核态的量法 | 结果 |
|---|---|---|
| x86 LOCAL_HOST（mock，§13.4） | procstat 的 **`stime`** 占比 | **49%**（B1：10.05 s / 20.35 s） |
| REMOTE_HOST chip4（真引擎，本节） | perf 全栈里**内核帧**的样本占比 | **32.86%** |

⚠️ **两个数口径不同、不能相减**：前者是「进程在内核态消耗的 CPU 时间比例」，
后者是「采样到的栈里含内核帧的样本比例」（受采样偏差与未解析帧影响）。
但两者**方向一致、量级同阶** ⇒

> **「Rust 前端有三分之一到一半的 CPU 花在内核里」是一个稳健结论。**

**由此得到一条对 x86 那批数据的重要限定**：
§1–§13 的全部占比来自 `cpu-clock:u`（**仅用户态**）⇒ 它们**系统性低估前端成本**，
且**低估幅度与引擎 tick 粒度强相关**（tick 越稀疏、I/O 就绪与唤醒越多，内核占比越高）。
引用 x86 那张分段表时，必须带上「**这是用户态口径，不是前端 CPU 的完整画像**」。

### 14.6 ⚠️ 方法学：aarch64 的 `fp` 展开**质量与 x86 完全相反**

这是本节最重要的方法学发现之一——它决定了两套装置的**数据可用度不同**：

| 装置 | 栈深 ≤3 的样本占比 | 栈深 ≥10 的样本占比 | 最大深度 |
|---|---:|---:|---:|
| **REMOTE_HOST chip4（aarch64 真引擎）** | **0.00%** | **99.15%** | 128 |
| x86 LOCAL_HOST（mock） | **84.67%** | 0.26% | 128 |

（数据：`data/profiles/a3/a3-A1-rust.depth.csv` vs `data/profiles/B1.depth.csv`。）

**含义**：

1. 在 REMOTE_HOST 上，`--call-graph fp` **拿到了完整的调用链**（典型栈深 13–20），
   `perf script` 里能直接读出
   `fastokens::pre_tokenizers::split::Split::pre_tokenize` →
   `fastokens::Tokenizer::encode_with_special_tokens` →
   `<vllm_tokenizer::hf::HuggingFaceTokenizer as Tokenizer>::encode` →
   `vllm_server::routes::tokenize::tokenize_completion` → `axum::…::poll` 这样的链。
   ⇒ **在 REMOTE_HOST 上不需要 §8 那套「差分斜率」补丁**：分段归属可以直接读调用链。
2. 在 x86 上 fp 几乎展不开（84.67% 只有 2–3 帧），所以那份数据的分段归属**必须**靠
   「叶子符号 + 线程 + 斜率」三角验证（§8），而 REMOTE_HOST 这份不用。
3. 两台机器**同一条采样命令**（`-e cpu-clock -F 999 --call-graph fp`）得到完全不同的展开质量
   ⇒ 这**不是**「fp 好不好」的普遍结论，而是**具体二进制/工具链/架构的组合结果**。
   引用任何一份时都要带上装置。

（x86 那份是 x86_64 wheel 抽取的二进制；REMOTE_HOST 那份是 aarch64 wheel 抽取的二进制，
两者不是同一次构建，`[推断]`编译选项/`.eh_frame` 完备度不同是主因。）

### 14.7 线程归属（REMOTE_HOST，A1）

| 线程 | 是什么 | REMOTE_HOST A1 | x86 B1（对照） |
|---|---|---:|---:|
| `tokio-rt-worker` | HTTP/axum runtime | **51.06%** | 53.16% |
| `vllm-zmq-0` | 传输 runtime（ZMQ 收包 + msgpack 解码 + 分发） | **29.61%** | 22.27% |
| `vllm-request` | 请求 runtime（预处理 + 响应侧） | **19.28%** | 24.58% |

⇒ 真引擎下 **`vllm-zmq-0`（传输侧）的占比明显上升**（22.3% → 29.6%），
与「每 tick 一次收包」的推断一致；`vllm-request`（纯计算那一侧）相应下降。

### 14.8 ★ 成本构成的迁移：前端热点**随引擎 tick 粒度而变**

这是本项目最有价值的单条发现，它把 Q1 的答案从「**是什么**」推进到
「**在什么条件下是什么**」。

| 分段 | x86 + mock engine（密集 tick，§7.2） | **REMOTE_HOST + 真引擎（稀疏 tick，§14.4）** | 变化 |
|---|---:|---:|---|
| **X-copy（块拷贝/比较）** | **15.20%** | **2.97%** | **−12.2 pp** |
| **X-alloc（分配器）** | **14.18%** | **4.90%** | **−9.3 pp** |
| **X-runtime（tokio/futures 调度）** | **13.90%** | **21.92%** | **+8.0 pp** |
| **X-kernel（内核态）** | 1.18%（**采不到，非真实占比**） | **32.86%** | 见下 |
| P7（msgpack 解码/分流） | 6.81% | 3.91% | −2.9 pp |
| P4（分词） | 6.57% | 2.17% | −4.4 pp |

**机制（两套装置各自的直接证据）**：

* **密集 tick（mock engine）**：`--output-token-chunk-size` 从 1 调到 32，
  前端 CPU/请求从 **1829 → 510 µs（−72%）**（§13.8）⇒
  说明这时前端**能批量处理**：一次醒来处理一大块数据，拷贝/分配是主成本，且**能摊销**。
* **稀疏 tick（真引擎）**：TPOT = **4.81 ms**，每 tick 只回 **1 个 token**（c=1）⇒
  前端**无法批量摊销**：每个 tick 都要「被唤醒 → 轮询 I/O → 收包 → 可能 park」。
  证据：`Parker::park` 1.27% + `Condvar::wait_until_internal` 1.32% +
  `Unparker::unpark` 0.94% + `Steal::steal_into` 0.94% + `epoll_pwait` 0.80%
  —— **这些"空转/唤醒"类帧在 x86 的 mock 负载里几乎看不见**（那个负载下前端一直在算）。

**结论（可直接引用）**：

> **前端成本的形状由「引擎 tick 粒度」决定**：
> **密集 tick（能批量）⇒ 拷贝/分配主导，且可摊销**；
> **稀疏 tick（每 tick 1 token）⇒ 唤醒/轮询/收包/内核态主导，按 tick 计费、无法摊销**。
> 因此「Rust 前端的热点是什么」**没有静态答案**，必须连同引擎的 tick 粒度一起回答。

**这条为什么重要（对 `docs/06` 的输入）**：
它说明「换 Rust 前端能省多少」在两种引擎形态下**收益来源不同**：
密集 tick 下省的是**搬运**（Rust 的 memcpy/malloc 比 CPython 的逐对象操作便宜），
稀疏 tick 下省的是**每次唤醒的固定开销**（Rust 的任务/唤醒路径比 asyncio 短），
而后者**不能靠更高的并发摊薄**（每个请求都要走同样多次 tick）。

### 14.9 ★ A4：Python 前端同负载对照（Q1 的核心证据）

> 采集：`runs/b-t4/A4-python`，与 A1 **同装置、同镜像、同引擎、同卡、同负载**
> （ISL=1k / OSL=128 / c=1；96 请求 / 83.5 s / 4K 样本）；
> 唯一变量是 `VLLM_USE_RUST_FRONTEND=0`。
> 脚本与参数见 §14.3。折叠栈 `data/profiles/a3/a3-A4-python.folded`，
> 图 `figures/02-flame-a3-A4-python.svg`（+ `…-by-segment.svg`）。

#### top-N 并列（self 占比）

| # | **Rust（A1）** | **Python（A4）** |
|---:|---|---|
| 1 | `[kernel.kallsyms]_[k]`（内核，未解析） **30.03%** | **`_PyEval_EvalFrameDefault`** **18.31%** |
| 2 | `std::thread::local::LocalKey<T>::with`（实为 `Vec` 增长）8.63% | `[kernel.kallsyms]_[k]` 9.79% |
| 3 | `tokio::…::worker::Context::run` 3.91% | `[_pydantic_core….so]` 4.11% |
| 4 | `[libc.so.6]`（块拷贝/比较）2.78% | `[libc.so.6]` 3.44% |
| 5 | `futures_util::…::poll_next_unpin` 2.17% | `_PyType_Lookup` 2.68% |
| 6 | `rmp_serde::decode::…::any_inner` 1.51% | `[libzmq….so]` 2.22% |
| 7 | `mi_free` 1.41% | `tokenizers::models::bpe::word::Word::merge_all` 1.78% |
| 8 | `tokio::process::…::reap_orphans` 1.37% | `_PyObject_Malloc` 1.73% |
| 9 | `parking_lot::condvar::…::wait_until_internal` 1.32% | `unicodekeys_lookup_unicode` 1.55% |
| 10 | `tokio::…::Parker::park` 1.27% | `_PyObject_Free` 1.36% |
| 11 | `[[vdso]]_[k]` 1.23% | `_Py_dict_lookup` 1.36% |
| 12 | `[nf_tables.ko.xz]` 1.08% | `_PyObject_GenericGetAttrWithDict` 1.22% |

#### 分段占比并列

| 分段 | Rust（A1） | Python（A4） | 说明 |
|---|---:|---:|---|
| **X-kernel**（内核态） | **32.86%** | 10.23% | 见 §14.5 的 `write` 208 次/请求 |
| **X-runtime**（tokio） | **21.92%** | — | Rust 专属 |
| **X-py-interp**（CPython 解释器/对象内务） | — | **47.25%** | **Python 专属；这就是被换掉的那一层** |
| X-py-venv（uvloop/asyncio） | — | 1.41% | 对应 Rust 的 X-runtime |
| X-tls | 8.63% | — | |
| X-alloc（分配器） | 4.90% | 1.29% | CPython 有自己的一套对象池 |
| X-copy（块拷贝/比较） | 2.97% | 3.67% | **两边都不是大头** |
| P4（分词） | 2.17% | 3.85% | Python 侧是 HF tokenizers；Rust 侧是 fastokens |
| P2（JSON/校验） | 1.37% | 4.11% | Python 侧 pydantic_core |
| P7（msgpack/ZMQ） | 3.91% | 3.00% | |
| P1/P3/P8/P9/P10 | 各 0.09–2.22% | 未单独出现在 top（被解释器开销吸收） | |

#### Q1 的最终答案

> **迁移的实质：把「CPython 逐条派发」这 47.25% 的账，换成了
> 「tokio 分派 21.92% + 内核态 32.86% + 拷贝/分配 7.87%」。**
>
> * Python 前端：`_PyEval_EvalFrameDefault` 18.31% 领跑，后面跟着一整套
>   `_PyType_Lookup` / `_PyObject_Malloc` / `unicodekeys_lookup_unicode` /
>   `_Py_dict_lookup` / `_PyObject_GenericGetAttrWithDict`
>   —— **解释器逐条派发 + 对象内务**的指纹，合计 **47.25%**。
> * Rust 前端：**没有任何"解释器"痕迹**，前 12 名里 7 个是 tokio 调度器/唤醒类，
>   第 1 名是内核帧（30.03%）—— **调度/唤醒/系统调用**的指纹。

#### 前端 CPU 与占比

| 指标 | Rust（A1） | Python（A4） | 比 |
|---|---:|---:|---:|
| 前端 CPU s/请求 | **0.00953** | **0.04333** | **0.220（省 4.5×）** |
| 其中 utime / stime | 1.04 / 0.79 s | 3.67 / 0.49 s | — |
| **前端占服务端 CPU** | **1.12%** | **4.93%** | 4.4× |
| 引擎 CPU s（同窗口） | 161.13 | 80.30 | — |
| 吞吐 / TTFT / TPOT | 1.436 req/s / 84.9 ms / 4.81 ms | 1.440 req/s / 89.4 ms / 4.76 ms | 引擎相同 |

⇒ **同装置同口径下，Rust 前端的前端 CPU 是 Python 的 22%，前端占比从 4.93% 降到 1.12%。**
（与 C 线独立测的 1.22% / 5.10% 同量级，互证 ✅。）

#### 一个必须解释的反直觉现象：**Python 的 IPC 更高**

见 §14.10。

### 14.10 ★ 层 1：双侧 `perf stat`（同装置同口径的 IPC 对照）

| 指标 | **Rust（A5-rust）** | **Python（A5-python）** |
|---|---:|---:|
| 窗口 / 完成请求 | 82.0 s / 96 | 59.4 s / 64 |
| `instructions:u` **每请求** | **9.775 M** | **131.247 M** |
| `cycles:u` **每请求** | **13.494 M** | **112.742 M** |
| `branches:u` 每请求 | 2.006 M | 27.163 M |
| `branch-misses:u` 每请求 | 0.126 M | 1.508 M |
| `cache-misses:u` 每请求 | 0.184 M | 1.854 M |
| **IPC**（= instructions/cycles） | **0.7243** | **1.1638** |
| 分支失败率 | 6.28% | 5.55% |
| cache miss 率（占 cache-refs） | 4.51% | 3.27% |

⚠️ **归一化口径（这一步很容易做错）**：两次 A5 完成的请求数**不同**（Rust 96 / Python 64），
所以**必须先按请求归一化再比**。下表把两种算法都列出来，用错会夸大 Rust 优势：

| 指标 | 按请求归一化（**正确**） | 直接比总量（**错误**，因请求数不同） |
|---|---:|---:|
| instructions | **0.0745（Rust 省 13.4×）** | 0.1117 |
| cycles | **0.1197（省 8.4×）** | 0.1795 |
| branches | 0.0738 | 0.1108 |
| branch-misses | 0.0835 | 0.1253 |
| cache-misses | 0.0992 | 0.1489 |
| cache-references | 0.0719 | 0.1079 |
| 前端 CPU 秒 | **0.217（省 4.6×）** | — |

#### 为什么 Python 的 IPC 更高——而它仍然慢 4.6×

> **Python 走的指令多（13.4×）但每条都"轻"**：解释器逐条派发、小对象操作，
> 依赖少、可流水化 ⇒ IPC 1.164。
> **Rust 走的指令少 13.4× 但每条都"重"**：内存搬运 + 系统调用 + 内核态
> （实测 32.9% 的样本在内核、`write` 208 次/请求）⇒ IPC 0.724。
> ⇒ **Rust 的优势来自「指令数少了 13 倍」，不是「每条指令更快」。**
> **IPC 不能跨实现直接比大小**——它只在同一实现的不同负载点之间有意义。

#### 与 engine core 的 66% 口径对照（形状相似、成因相反）

| | `PREPARE_INPUT_PROJECT`（engine core 主线程，Kunpeng 920B） | **本节的 Rust 前端（REMOTE_HOST chip4）** |
|---|---|---|
| IPC | 0.771 | **0.724** |
| 低 IPC 的成因 | **取指/解码受阻**（topdown `frontend_bound 66.01%`、`latency_bound 59.89%`） | **内存/系统调用受阻**（内核态 32.86%、`write` 208 次/请求、块拷贝+分配） |
| 装置/口径 | 真机 topdown（libkperfx，**aarch64**） | REMOTE_HOST `perf stat`（`:u` 事件） |

⇒ **两者 IPC 几乎相同（0.72 vs 0.77），但成因完全相反**。
这既证明「IPC 数值相近 ≠ 瓶颈相同」，也是「**不能拿 engine core 的 66% 去推断前端**」的又一个实证
（第一个理由见 `docs/03` 层 3：那个数字采的是 engine core 进程）。

### 14.11 采样与符号解析：可复用的两条做法

#### ① 容器内进程的符号解析（`--symfs` + 自动反推 DSO 列表）

| 阶段 | Python 臂（A4）的未解析帧占比 |
|---|---:|
| 初始（`prof_point.sh` 里固定的 8 个库） | **97.2%** |
| 用 `harness/profile/a3/resolve_syms.sh` 之后 | **14.2%** |

`resolve_syms.sh` 的做法（**对任何容器/语言都通用**）：

1. 从 `perf.data` 自己**反推**需要哪些 DSO（解析 `perf script` 输出里的 `(路径)`，
   Python 臂有 **22 个**：libpython、uvloop、tokenizers、pydantic_core、libzmq…）；
2. 逐个 `docker cp` 进 `--symfs` 目录树（**容器已停也能做**：用同一个镜像
   `docker create` 一个**不带 NPU 设备、不跑负载**的临时容器来取文件 ⇒ **不需要 chip4 锁**）；
3. 用 `--symfs` 重新导出 `perf script` / `perf report`。

残留的 14.2% 基本是**内核帧**与**内核模块**（`nf_conntrack/nf_nat/nf_tables.ko.xz`
在容器里不存在，取不到）——与 §14.2 坑 2 的 kallsyms 限制一致。

#### ② 采样开销对照（REMOTE_HOST 侧）

| 点 | 窗口内 perf | 前端 CPU s/请求 | 吞吐 |
|---|---|---:|---:|
| A1-noperf（`mode=none`） | **无** | **0.008594** | 1.436 req/s |
| A1（`mode=perf`，`perf record -F 999`） | `perf record` | 0.009531 | 1.436 req/s |
| A5-rust（`mode=trace`，`perf stat` 6 个 `:u` 事件 + 8 个 tracepoint） | `perf stat` | 0.009479 | 1.476 req/s |

⇒ **在 REMOTE_HOST 上，`perf record` 999 Hz 对"每请求 9.5 ms"的前端影响很小**
（0.0086 → 0.0095 s/请求，+10.9%，**在 §13.6 那 ±4% 的重复性之外但仍属同量级**；
吞吐无差异 1.436 vs 1.436）。
这与 x86 的结论（−10.2% 吞吐）**不同**，原因也清楚：
x86 上前端每请求只有 0.94 ms、采样窗口里请求密度高得多
⇒ 同样 999 Hz 的采样打断对"更短的事务"影响更大。
**结论：采样开销与"前端每请求耗时"成反比，跨装置不能套用同一个折扣系数。**

### 14.12 REMOTE_HOST 采集点汇总

（由 `harness/profile/a3/summarize_a3.py` 从各点的 `point.json` 生成，
落盘 `data/profiles/a3/points.csv` 与 `ipc.csv`。）

| 点 | 前端 | 负载 | 窗口 s | 完成 | 吞吐 req/s | TTFT ms | TPOT ms | 前端 CPU s | utime/stime | 引擎 CPU s | 前端占比 | 采样 |
|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|
| A1-noperf | rust | ISL=1024 OSL=128 c=1 | 61.2 | 64 | 1.44 | 85.0 | 4.81 | 0.550 | 0.36/0.19 | 54.25 | 1.00% | 无 |
| **A1** | **rust** | ISL=1024 OSL=128 c=1 | 151.6 | 192 | 1.44 | 84.9 | 4.81 | 1.830 | 1.04/0.79 | 161.13 | **1.12%** | `perf record` |
| **A4** | **python** | 同上 | 83.5 | 96 | 1.44 | 89.4 | 4.76 | 4.160 | 3.67/0.49 | 80.30 | **4.93%** | `perf record` |
| A5-rust | rust | 同 A1 | 82.0 | 96 | 1.48 | 82.5 | 4.68 | 0.910 | 0.48/0.43 | 78.79 | 1.14% | `perf stat` |
| A5-python | python | 同 A1 | 59.4 | 64 | 1.49 | 86.1 | 4.60 | 2.800 | 2.38/0.42 | 51.99 | 5.11% | `perf stat` |

**未测**（本轮时间盒内未做，如实列出）：A2（c=64，需 `MAX_NUM_SEQS=64`）、
A3（ISL=8k，需 `MAX_MODEL_LEN=16384`）。
⚠️ 另：`b-t5-rust` 那次事务因 `run_batch.sh` 的一处参数丢失 bug
（`--point` 未传给远端）而**空转并失败**，数据未采到——bug 已修（见 `agents/B-profile/REPORT.md` 踩坑表）。
