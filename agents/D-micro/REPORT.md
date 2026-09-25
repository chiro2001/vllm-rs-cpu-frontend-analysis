# D-micro 线 · 交接报告

> 分支 `agent/D-micro`　工作区 `REPO_HOME/projects/vllm/vllm-rs-wt/D-micro`
> 产出：`docs/05-segment-costs.md`、`harness/micro/`、`data/micro/`

## 1. 一句话

把 P2/P3/P6/P7/P10 五段做了**同输入、同尺寸、同口径**的 Rust↔Python 对照基准
（外加一个 B 线要求的 D6 补测）。结论：**这几段加起来只有 30 µs（1k）/ 108 µs（8k），
Rust 是 Python 的 0.51–0.58×；真正的成本不在算法，而在分配与数据搬运。**

## 2. 交付物

| 文件 | 内容 |
|---|---|
| `docs/05-segment-costs.md` | 逐段结论（459 行）：口径、每段 µs、相对占比、未测清单、复跑方法、与 B 线的接口 |
| `harness/micro/gen_fixtures.py` | 生成公共 fixture；**用真实 tokenizer 计数**，不用字符数折算 |
| `harness/micro/rust/` | Rust 侧微基准 crate（`micro-bench`，子命令 d1/d2/d3/d4/d6，均支持 `--help`） |
| `harness/micro/python/micro_py.py` | Python 侧对照臂（d1/d2/d3/d4/emit-payload，均支持 `--help`） |
| `harness/micro/python/ecr_types.py` | msgspec 版 `EngineCoreRequest`（`array_like` + `omit_defaults`，与 vLLM 同形） |
| `harness/micro/run_micro.sh` | **一键复跑**（每一步都单走 heavy_lock + limit.sh），支持 `--points/--only/--smoke/--regen` |
| `harness/micro/summarize.py` | 汇总：`results.csv` / `segments.json` / `checks.json` / `manifest.json` / `d6_pretokenize.json` |
| `harness/micro/setup_py_env.sh` | 建 venv（msgspec 0.21.1 + msgpack + jinja2 3.1.6），不动宿主机 site-packages |
| `harness/micro/fixtures/` | 7 个 fixture + `fixtures_manifest.json`（尺寸/token 数/字段数/sha256） |
| `data/micro/results.csv` | 59 行原始结果（两侧、多 op、含分配计数列） |
| `data/micro/segments.json` | 分段组装：每段 µs、双侧占比、比值、P10 派生项 |
| `data/micro/checks.json` | **11 条一致性校验，全部通过**（`all_ok: true`） |
| `data/micro/d6_pretokenize.json` | D6（fastokens 预分词）汇总 |
| `data/micro/manifest.json` | 装置/绑核/loadavg/脚本 sha256/二进制 sha256/依赖版本/时间戳 |
| `data/micro/raw/` | 原始逐命令 CSV + payload + 渲染结果（供复核） |

## 3. 关键结论（3 条）

1. **这五段不是瓶颈，但 Rust 稳定更快**：P2+P3+P6+P7 合计
   **30.55 µs（1k）/ 108.26 µs（8k）**，对 Python 的 **52.25 / 210.77 µs**，
   比值 **0.58 / 0.51**。两侧渲染的 prompt 与序列化的响应体**字节 sha256 完全相同**，
   所以差值是引擎差，不是输入差。
2. **成本在分配与搬运，不在解析算法**：1k 请求体解析一次要做 **112 次分配 / 19.9 KB**
   （≈输入 3.7 倍），渲染一次模板要 **248 次分配 / 63.2 KB**（≈输入 11.3 倍）。
   这正好解释 B 线火焰图上 `[libc.so.6]` **15.20%**（其中块拷贝 **12.2%**）+
   mimalloc 家族 **14.18%** 而 `serde_json` 不进 top-20 ——
   **P2/P10 的战场是零拷贝，不是解析器**。
3. **D6 找到了那 4.7% 的 PCRE2 帧**（P4 段合计 **6.57%**，ISL=8k 时 **41.71%**）：
   fastokens 的**预分词正则**占全量 encode 的
   **71%（1k）/ 88.7%（8k）**，纯 BPE 只有 20.7 / 39.6 µs。⇒ 要优化 tokenizer，
   优先看预分词正则，而不是 BPE merge 表。这是对 D5（引用 `tokenizer` 项目结论）的
   **补充**，不是替代。

### 3.1 给 docs/06（规模拐点）最有用的一张斜率表

| 段 | Rust 1k→8k | Python 1k→8k | 比值 1k→8k | 拐点含义 |
|---|---|---|---|---|
| P2 JSON | 6.50→19.23（2.96×） | 11.62→53.20（**4.58×**） | 0.56→**0.36** | **ISL 越大 Rust 越划算** |
| P3 模板 | 14.89→19.45 | 25.07→41.16 | 0.59→0.47 | 常数级 + 一点放大 |
| P6 编码 | 4.14→31.02 | 3.18→20.68 | **1.30→1.50** | **Rust 唯一变差的一段** |
| P7 解码 | 5.02→38.57 | 12.38→95.74 | 0.41→0.40 | 严格线性 |
| P10 整流组帧 | 23.26 µs（与 ISL 无关） | 317.16 µs | **0.07** | 长输出才是主场 |

## 4. 口径与纪律（复核时先看这段）

- **所有 CPU 密集步骤都走 `scripts/heavy_lock.sh` + `scripts/limit.sh`**（绑核 4-7 = 4 核、
  8 GiB、`cargo -j 4`）；每次运行前后各记一次 loadavg 进 manifest。
  ⚠️ `run_micro.sh` 的每个子步骤**自己**拿锁，**不要**在外面再套一层（那把锁不可重入）。
- 预热 **10 s** + 采样 **30 s**（每点、每侧、每命令）；同一点的多个 op 在**同一个窗口内
  轮转**（~1 ms 时间片批量），两侧规则一致。`--smoke` 才允许更短。
- 计时器自身开销单独量了一行（`seg=meta, op=clock_overhead`）：Rust 0.020 µs、
  Python 0.080 µs —— **引用 <1 µs 的数字前先看这行**。
- **跨装置标注**：`tokenizer` 项目是 Kunpeng 920B aarch64 + Ascend，本文件是 x86_64
  ⇒ 绝对值不可直接比，只有趋势/比值可比。`PREPARE_INPUT_PROJECT` 同理。
- **未测写"未测"、推断标"推断"**：`docs/05` §8 有 10 条未测/部分项；P10 的
  "一个流式请求总成本"是两段实测相加 ⇒ 标了推断；D6 是多线程口径 ⇒ 单独标注。
- **已按 B 线正式矩阵校正引用**（第二轮修正任务）：`docs/05` §0 要点 3、§1.4 口径对照表、
  §6.2 D6 引言、§10 接口表共 4 处，原先引用的 B 线**早期 10 s 探针**数字
  （`memcpy/memmove` 10.6% + mimalloc ≈11% + PCRE2 ≈4.8%）已全部换成**正式 30 s 矩阵**
  数字（`[libc.so.6]` 15.20% / 块拷贝 12.2% / memcmp 1.7%、mimalloc 14.18%、
  PCRE2 相关合计 4.7%、P4 段 6.57%、ISL=8k 时 41.71%）；新增 `docs/05` **§1.5**
  记录两代口径的对照与差异原因（对照表在 `docs/02` §12），并明确 D6（微基准多线程）
  与 B 线（线上火焰图）**不同源、不可互相折算**。

## 5. 复跑

```bash
cd REPO_HOME/projects/vllm/vllm-rs-wt/D-micro
harness/micro/run_micro.sh            # 全量（基准本身约 12–14 分钟 CPU）
harness/micro/run_micro.sh --smoke    # 1 分钟验流程（数字不可引用）
```

依赖：`REPO_HOME/models/Qwen3-0.6B/tokenizer{,_config}.json`（已存在，sha256 进 manifest）、
`~/.cargo/bin` 下的 rustc/cargo、conda python3.12。

## 6. 踩坑记录（下一个接手的人必看）

1. **`serde_tuple` + 结构体级 `#[serde(default)]` 会炸**：`Deserialize_tuple` 派生的
   `Inner` 要求逐字段 `default`，否则报 `trait Default is not implemented for Inner`。
   必须把 `#[serde(default)]` 逐字段写。
2. **`EngineCoreRequest` 是数组不是对象**（Rust `serde_tuple` + Python
   `msgspec(array_like=True)`）⇒ fixture 必须是 **20 元素 list**，否则两侧一起解不动。
   一开始用 dict 写 fixture，两侧同时失败。
3. **msgspec 的 Struct 不能定义在函数里**：注解解析需要模块级名字空间，
   嵌套定义会报 `NameError: SamplingParams is not defined`。见 `ecr_types.py`。
4. **`notes` 字段里有逗号会撑坏 CSV**：两侧都改成 RFC4180 转义（Rust 手写 + Python `csv` 模块）。
5. **同窗口轮转会把快 op 饿死**：300 µs 的 op 与 5 µs 的 op 轮转，30 s 里快的只剩几十个样本。
   改成**按 ~1 ms 时间片批量**后，最慢的 op 也有 2 万+ 样本。
6. **crate 名是 `serde-json-fmt` 不是 `serde_json_fmt`**（crates.io 上找不到后者）。
7. **重活锁被别的线占着是常态**：本线全量跑期间被 C 线的真引擎探测挡了约 3 分钟，
   `heavy_lock.sh` 自带等待（`WAIT=1800`），不需要额外处理。

## 7. 没做到 / 留给别人的

| 项 | 状态 | 说明 |
|---|---|---|
| P5 lower/校验、P9 parser、P1 HTTP | **未测** | 见 `docs/05` §8；P1 归 B/C 线的 E2E 口径 |
| Python 侧分配次数 | **未测** | `tracemalloc` 会改变被测路径；要测得另开不带计时的基准 |
| D3 全字段（~40 个）SamplingParams | **部分** | 只用 24 个字段（与 Rust 侧同款）⇒ Rust "不做 omit_defaults" 的膨胀被**低估** |
| D2 多轮 + tool 结果 | **部分** | 只测单轮 + 2 tools；多轮模板段会更重 |
| D6 单线程对照 | **部分** | 默认 rayon 4 线程（多线程口径）；`RAYON_NUM_THREADS=1` 可复跑但未采 |
| D4 真实 hyper/tokio 回写 | **未测** | ③ 用裸 `write_all`/asyncio 代替 ⇒ 两侧都不是线上实现 |
| 128 / 512 ISL、OSL=512 点 | **未测** | 只做 1k/8k/osl128，与 B 线 B1/B2 对齐 |
| aarch64 复现 | **未测** | 全程 x86_64 |

## 8. 与其它线的接口

- **给 B 线**：`docs/05` §10 逐条回答了"`serde_json` 为什么不在 top-20"、
  "PCRE2 那 4.7% 是什么"、"序列化与 syscall 要分开报"。引用 D6 时**务必**带上
  "多线程口径 + 4 线程"。
- **给 C 线**：本文件的 P2/P3/P6/P7 是**每请求的固定成本下界**，可用来解释 A/B 里
  "前端 CPU 时间"的一部分；但**别拿它去减端到端延迟**。
- **给根代理／docs/06**：§7 的斜率表是拐点分析的输入；注意 §7.3 的三条限制
  （合计只是小头、P10 的 ⑤ 是推断、D6 是多线程）。
