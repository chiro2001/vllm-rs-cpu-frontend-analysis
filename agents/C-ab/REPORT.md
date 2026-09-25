# C-ab 线交接报告

> 交付：`docs/04-ab-comparison.md`（★ 主结论）、`docs/ab-design.md`（实验设计）、
> `harness/ab/`（x86 装置）、`harness/a3/`（REMOTE_HOST chip4 主线）、`data/ab/`（原始数据）。
> 分支 `agent/C-ab`。全部工作在 chip4 独占锁 + `AB_OWNER=c-ab` 容器隔离下完成。

---

## 0. 头条结论（REMOTE_HOST chip4，同镜像/同引擎/同卡，只换前端）

| 点 | 负载 | Rust ms/请求 | Python ms/请求 | **比值 R/P** | 前端占服务端 CPU（R/P） |
|---|---|---:|---:|---:|---|
| C1 | 1k/128/c=1（**3 次重复**） | **10.31** | **45.94** | **0.225** | 1.22% / 5.14% |
| C2 | 1k/128/c=64 | **4.84** | **15.35** | **0.316** | 6.01% / **17.03%** |
| C3 | 8k/16/c=1 | **20.00** | **54.38** | **0.368** | 3.67% / 8.60% |
| C4 | 1k/512/c=1 | **36.88** | **164.38** | **0.224** | 1.14% / 5.08% |
| C5w | 1k/128/c=8，40 核 | **6.875** | **19.688** | **0.349** | 3.74% / 10.34% |
| C5n | 同上，16 核 | **7.344** | **20.156** | **0.364** | 3.83% / 10.71% |
| 补充 I8k | 8k/128/c=1（受控 ISL） | 26.88 | 85.63 | 0.314 | 2.29% / 6.52% |
| 补充 S16 | 1k/16/c=1 | 4.22 | 12.81 | 0.329 | 2.16% / 6.47% |

**边际成本（两点法 M32/M128，扣掉空转）**：
Rust **5.86 ms/请求**（空转 0.57% 单核）、Python **37.83 ms/请求**（空转 0.90%）
⇒ **比值 0.155，Rust 省 6.5×**（不确定度约 0.12–0.20）。

**三条最重要的判断**：

1. **换前端换不来吞吐，换来的是核预算。** C1/C2/C4/C5 的吞吐差异都在 −6.7% ~ +2.7% 之间；
   只有长 prompt 两点略高（C3 +16.7%、I8k +8.5%，都是单轮 n=16，噪声大）。
   因为引擎每请求吃 ≈840 ms CPU，前端只吃 5–46 ms。
2. **C2（c=64）是本项目「值得换」的最强证据**：Python 前端占服务端 CPU **17.0%**，
   Rust 只占 6.0%——同样 15.5 req/s，换前端能省 11 个百分点的服务端 CPU。
3. **长 prompt 的收益体现在 TTFT**：I8k 差 **−82.8 ms**、C3 差 **−77.1 ms**；
   而短 prompt（C1/C4）只有 −6 ms。机制：8k token 的模板+分词发生在前端、
   **与引擎串联**，所以省下的时间直接体现为 TTFT。

**核数不是瓶颈**：40 核 → 16 核，两侧变化都在单轮噪声内（±7%）。
前端根本没吃满核（C2 时 Rust 0.35 核 / Python 1.13 核）。

---

## 1. G3 门禁（x86 真引擎，已完成）

**打通了纯 CPU 真引擎**，路径是官方 `vllm-0.26.0+cpu` wheel（构建 commit
`568afb3a`，与计划锁定值一致）：

- `py:3.12-slim` + CPU wheel → `CpuPlatform`，无 `torch_npu`、无 NPU 插件。
- 镜像固化进 `harness/ab/build_image.sh`（含四个坑的修复）。
- **踩到的坑**（都已修复并写进脚本注释）：
  1. `vllm/_C*.so` 的 `PT_GNU_STACK` 带 X 位 → 内核拒绝 execstack
     （`ImportError: cannot enable executable stack`）⇒ 清掉 PF_X；
  2. 缺 `libnuma1`；3. inductor 需要 `g++`；4. 官方要求 LD_PRELOAD TCMalloc + Intel OpenMP。

**但该装置分辨率不足**：TPOT 245 ms/token，前端占服务端 CPU 只有 **0.08%**
⇒ 降级为附录（见 `docs/04` 附录 A），主线迁到 REMOTE_HOST chip4。

---

## 2. 关键方法学贡献（本项目其他线可直接复用）

### 2.1 「含空转」vs「边际」是两个口径

真引擎装置上单请求要跑几十秒 ⇒ 窗口里同时存在「前端一直在跑的空转」
与「随请求线性增长的处理成本」。只报 `CPU ÷ N` 会把空转摊进每请求成本。
**两点法**（同负载形态只变请求数，解 `CPU = r·W + m·N`）不需要预设空转，
是本项目测前端边际成本的首选方法。

### 2.2 六个会静默污染数据的陷阱（都真实踩过，见 `docs/ab-design.md` §5）

| 陷阱 | 现象 | 防护 |
|---|---|---|
| 只设 `VLLM_RUST_FRONTEND_PATH` 不设 `VLLM_USE_RUST_FRONTEND=1` | **静默退回 Python 前端**，数据看着正常 | 两个都设（`vllm/envs.py:557-566`） |
| 残留容器占端口 | 新容器 bind 失败退出，`/health` 由**旧容器**回答 200 | 起栈前清场 + 起栈后校验容器内真有该侧前端进程 |
| 共享远端目录被别线 `sync --delete` 覆盖 | 矩阵跑一半改用 ssh 回连自己 | C 线改用私有目录 `~/projects/vllm/cab/` |
| 按共享 label 清场 | **误删 B 线正在跑的容器** | 按 `vrs.owner` 过滤（`AB_OWNER=c-ab`） |
| `sudo perf` 进程树多一层 | SIGINT 不落到 perf，窗口关不掉 | 记录真 perf 孙进程 pid + 30 s 有界等待 |
| 远端 rsync 不带 `--perms` | 新脚本 644 ⇒ `Permission denied` | push 后统一 `chmod +x` |

### 2.3 容器名/端口解析（AB_OWNER 引入后）

`point.sh` 与 `matrix.sh` 一度硬编码旧容器名 `vrs-ab-<run>`，引入 `AB_OWNER` 后
容器变成 `vrs-ab-c-ab-<run>` ⇒ 整轮 C2–C5 报「找不到前端进程」。
已改为**动态解析**（新命名优先、回落旧命名）。

---

## 3. 踩坑与失败路径（如实记录）

| 事件 | 处置 |
|---|---|
| **编号误读**：用 `npu-smi -i 4` 查「chip4」，看到 5 个 `liftquant_moe` 进程（≈72 GB HBM），一度判断「卡被占用、可能需换卡」 | 根代理指出 `-i` 是 **NPU ID**：NPU 2 = davinci4/5。正确命令 `-i 2` 显示 **No process in device**。已写进 `docs/ab-design.md` §10 |
| **误删 B 线容器**：按 `vrs.project` label 清场，删掉 `vrs-ab-b-t1` | 立即收窄为按容器名前缀 + 立刻放锁给 B 线；根代理随后把 `AB_OWNER`/`cleanup` 修进 main（`dafbc39`） |
| **丢过一次工作区**：`git stash -u` 后 pop 因冲突失败，未察觉就 `stash drop`，丢了未提交的 `docs/ab-design.md` 与 x86 原始数据 | 从 dangling stash commit 的第三个父提交（`b4e465f`）全部恢复 |
| x86 空载对照 | 脚本就绪但 REMOTE_HOST 上首轮因缺执行位失败；**已由两点法替代且更强** |
| 局部 perf 采集 | 每点都存了 `perf.txt`，但本轮结论全部基于 `/proc` CPU 时间口径，perf 数据未纳入结论 |

---

## 4. 未做到的部分

| 项 | 原因 |
|---|---|
| **前端内部埋点**（把 TTFT 差拆成「前端处理」vs「排队」） | 需两侧各埋一套计时，超出本轮机时与改动范围；`docs/04` §7.1 只给近似并标【推断】 |
| **C2/C3/C4/C5 的多次重复** | chip4 需与 B 线串行；仅 C1 做了 3 次重复 |
| **topdown / frontend_bound 分解** | 依赖 Kunpeng 专用 libkperfx；且该指标属 engine core（见下） |
| **OSL 斜率的独立性验证** | `docs/04` §5 的每输出 token 成本建立在「空转速率不随 OSL 变化」之上，未独立验证 |
| **x86 mock 臂的 Python 侧拓扑 A** | mock 臂的 Python 前端用的是 `--data-parallel-size-local 0` 特制配置，与真引擎臂拓扑不同，只能做方向性交叉验证 |

---

## 5. 一条口径纠错（必须传下去）

计划早期版本把「Python 前端热点 = CPython 逐条派发（`frontend_bound 66.01%` /
`IPC 0.771`）」当作 Python 前端基线。**这是错的**：
那个采集目标是 **engine core 进程的主线程**
（`PREPARE_INPUT_PROJECT/docs/05-hotspots.md:243` 写明 `目标 = engine-core 宿主 TID 704908`），
分析对象是 engine core 内部的 `prepare_input`/scheduler，**不是 API server 前端**
（对照 `tokenizer/docs/02-cost-and-share.md:34-49`：`tokenizer:` 三 scope 在 pid=1 前端，
`Step:Model/phase:*` 在 pid=131 engine core）。

⇒ **换 Rust 前端不改变 engine core，该数字与本计划的前端收益无关。**
本线所有文档不再引用它作为 Python 前端基线；`docs/ab-design.md` §7 有完整说明。

---

## 6. 复跑方式

```bash
# ---- 主线：REMOTE_HOST chip4 ----
harness/a3/push_private.sh                  # 推到私有目录 ~/projects/vllm/cab/
harness/a3/chip_lock.sh -- bash -lc 'cd ~/projects/vllm/cab && \
  AB_OWNER=c-ab bash harness/a3/matrix.sh --configs C1,C2,C3,C4,C5'
harness/a3/push_private.sh --pull <run>     # 取回结果
harness/a3/collect.py --runs-root runs      # 出表
harness/a3/fit_model.py --runs-root runs    # 出边际成本模型

# ---- 附录：x86 装置 ----
harness/ab/build_image.sh                                   # 构建纯 CPU vLLM 镜像
scripts/heavy_lock.sh harness/ab/run_matrix.sh --kind mock   # mock 臂（前端受限）
scripts/heavy_lock.sh harness/ab/run_matrix.sh --kind real   # 真引擎臂（极慢，仅作参照）
```

所有脚本均带 `--help`。

---

## 7. 产物清单

| 路径 | 内容 |
|---|---|
| `docs/04-ab-comparison.md` | ★ 主结论（C1–C5 + 补充点 + 未测清单 + x86 附录） |
| `docs/ab-design.md` | 实验设计与公平性论证（含进程拓扑实证、两种口径、六个陷阱、编号陷阱） |
| `harness/a3/{matrix,point,ab_serve,idle,chip_lock,sync,push_private}.sh` | REMOTE_HOST 编排 |
| `harness/a3/{collect,fit_model,container_pids,idle_summary}.py` | 汇总/拟合工具 |
| `harness/ab/*` | x86 装置的起栈/压测/清场/镜像构建（含 mock 臂） |
| `data/ab/a3/{summary,fit}.json` | 主结论的结构化数据（20 个点的汇总 + 边际模型） |
| `data/ab/a3-chiplock/` | 根代理首发批（保留未动） |
| `data/ab/{C1,C1..C5*-mock,idle}/` | x86 装置的原始点数据（附录 A） |

---

## 8. 一句话给根代理

**「换 Rust 前端」在 NPU 引擎装置上的正确卖点是「省服务端 CPU」而不是「提吞吐」：
边际成本省 6.5×（含空转口径省 4.5×），c=64 时能省下服务端 CPU 的 11 个百分点；
长 prompt 场景额外拿到 ~80 ms 的 TTFT 收益。**

未做到的主要是「前端内部埋点」与「多点重复」，已在 §4 逐条列明原因。
