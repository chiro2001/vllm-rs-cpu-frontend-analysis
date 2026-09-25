# 共享 harness（root 维护，四条线只读复用）

所有实验必须走这里，保证 A/B 与 profile **同口径**（plan/COORDINATION.md §5、§9）。

| 文件 | 作用 |
|---|---|
| `env.sh` | 共享常量：制品路径、绑核、端口、manifest 写法。**所有脚本先 source 它** |
| `stack.sh` | 起停「前端 + 引擎」栈，落 PID/日志/绑定核 |
| `run_load.sh` | 用 `vllm-bench` 打一轮负载，前后各采一次前端与客户端 CPU 时间 |
| `procstat.sh` | `/proc/<pid>/stat` 快照与增量（前端 CPU 时间是必采项 ④） |

## 制品（大文件不进 git，只记路径 + sha256）

| 制品 | 默认路径 | 当前 sha256（前 16） |
|---|---|---|
| `vllm-rs`（x86_64，从 PyPI wheel 抽取） | `/tmp/d-nextgen-wheel/vllm-rs` | `0597bfc909f22d94` |
| `vllm-mock-engine`（自编译） | `~/.cache/d-nextgen-mock/target/release/vllm-mock-engine` | `601efc4bb2196a13` |
| `vllm-bench`（自编译） | `~/.cache/vllm-rs-bench/target/release/vllm-bench` | 见 manifest |
| 模型 | `REPO_HOME/models/Qwen3-0.6B` | — |

抽取 `vllm-rs`：`python3 scripts/fetch_vllm_rs.py --arch x86_64 --out /tmp/d-nextgen-wheel`
（HTTP Range，只下 ~6% 的 wheel）。
编译 `vllm-bench`：精简 workspace 在 `~/.cache/vllm-rs-bench/`，命令见
`scripts/build_bench.sh`。

## 绑核约定（CORES 是"绑到哪些核"，不是核数）

默认三段分开，互不抢核，合计 6 核（资源上限 ≤9 核）：

| 角色 | 变量 | 默认 |
|---|---|---|
| 前端（被分析对象） | `FE_CORES` | `4-5`（2 核） |
| 引擎 | `ENG_CORES` | `6-7`（2 核） |
| 压测客户端 | `CLIENT_CORES` | `8-9`（2 核） |

核数扫描（C5）时**同时**改前端与客户端的绑定，并记录到 manifest。

## 快速开始

```bash
# 1) 起栈（Rust 前端 + mock engine）
harness/common/stack.sh start --run runs/demo

# 2) 打负载（结果写 runs/demo/<tag>.*）
harness/common/run_load.sh --run runs/demo --out runs/demo --tag c1 \
  --backend openai-chat --dataset-name random --tokenizer REPO_HOME/models/Qwen3-0.6B \
  --random-input-len 1024 --random-output-len 128 --num-prompts 200 --max-concurrency 8 \
  --save-result --result-dir runs/demo

# 3) 收工
harness/common/stack.sh stop --run runs/demo
```

## 已踩过的坑

1. **启动顺序**：前端先绑好 ZMQ 握手插座，引擎才能连；HTTP（`/health`）要等握手
   完成才开。先等 `/health` 会一直等到超时。
2. **mock engine 没有节流**：单请求几乎瞬时返回，`--num-prompts` 要给足才能撑起
   采样窗口（c=8、ISL=1k 时约 1200 req/s）。prompt 生成是**一次性前置开销**，
   不计入采样窗口。
3. **`vllm-bench` 默认把人类可读报告写 stdout**，JSON 要靠 `--save-result
   --result-dir <dir>` 落到 `openai-chat-infqps-concurrency<N>-<model>-<时间>.json`。
4. **前端进程 CPU 只看 utime+stime**（不含子进程）；mock/真引擎是独立进程，不算进来。
5. 后台进程别用 `nohup ... &` 从短命 shell 里起，会被会话回收；用**受控会话**跑。

## P0 门禁现状（2026-09-25）

| 门禁 | 状态 | 证据 |
|---|---|---|
| G1 起栈 + 打通压测 | ✅ 通过 | `data/gates/g1-smoke-bench-result.json`（200/200 成功，1238 req/s @c=8、ISL=1k、OSL=128） |
| G2 perf 采到 Rust 帧 | ✅ 通过 | `data/gates/g2-perf-symbol-check.txt`（12175 样本；`vllm_tokenizer::byte_level_decode`、`mi_free` 等符号可解析） |
| G3 REMOTE_HOST 真引擎 | ⏳ 进行中 | 发现 `vllm serve --headless` 可与 `vllm-rs` 配对（见 `agents/root/REPORT.md`） |
