# REMOTE_HOST chip4 上的实验基础设施

> 主 profiling 与 A/B 在 REMOTE_HOST 的 **chip4 = `/dev/davinci4`** 上做
> （用户指示，见 `plan/COORDINATION.md §2.1`）。本目录是四条线共用的执行层，
> **由根代理维护；各线只调用、不修改**（需要扩展时提给根代理）。

## ⚠️ 第一个坑：`npu-smi` 的 `-i` 是 **NPU ID**，不是 davinci 编号

这是本项目踩过的坑（C 线据此误判过「chip4 被占」）：

| `npu-smi -i N` | 对应设备 | 说明 |
|---|---|---|
| 0 | `/dev/davinci0`, `/dev/davinci1` | |
| 1 | `/dev/davinci2`, `/dev/davinci3` | |
| **2** | **`/dev/davinci4`, `/dev/davinci5`** | ← **我们的目标在这里** |
| 3 | `/dev/davinci6`, `/dev/davinci7` | |
| 4 | `/dev/davinci8`, `/dev/davinci9` | 与本项目无关 |

⇒ **用户说的 `davinci4` = `npu-smi -i 2` 的 Chip ID 0**。
用卡前自检：

```bash
ssh REMOTE_HOST 'npu-smi info -t proc-mem -i 2'   # 应显示 "No process in device."
ssh REMOTE_HOST 'npu-smi info -t usages -i 2'     # 两段 Chip ID 0/1 分别对应 davinci4/5
```

## ⚠️ 第二个坑：多线必须设 `AB_OWNER`，否则「清场」会误伤别线

chip4 是四条线共用的，**容器名与 label 必须能区分线**。踩过的坑：
C 线的「起栈前按 `label=vrs.project=vllm-rs-analysis` 清场」把 **B 线正在跑的**
容器 `vrs-ab-b-t1` 删了——因为 label 是共用的。

**用法**：调用前设 `AB_OWNER`（建议 == 你的线名）：

```bash
AB_OWNER=c-ab ./harness/a3/ab_serve.sh start --run c1-rust --frontend rust
```

* 容器名变成 `vrs-ab-c-ab-c1-rust`，label 变为 `vrs.owner=c-ab`；
* `ab_serve.sh cleanup` **只清自己 owner** 的残留容器
  （`docker ps -a --filter label=vrs.owner=<你>`），**绝不**按 `vrs.project` 全清；
* 不设 `AB_OWNER` 时沿用旧命名（`vrs-ab-<run>`、`vrs.owner=shared`），且
  `stop/status/pids/logs` 会**自动回落旧命名**，因此早期起的容器仍能收掉。

## 脚本

| 脚本 | 在哪跑 | 作用 |
|---|---|---|
| `chip_lock.sh` | **本地** | chip4 远端互斥锁：`-- <命令>` 拿锁执行；`--status` / `--release` |
| `ab_serve.sh` | 本地 | 起停服务容器：`start --run <n> --frontend rust\|python --chip 4 --port 183xx`；`pids` 打宿主 pid |
| `point.sh` | **远端** | 一个负载点的完整测量（procstat 全进程分桶 + 可选 perf stat + 归一化指标） |
| `sync.sh` | 本地 | `push` 同步脚本、`fetch <run>` 取回结果 |

### 典型事务（保持短事务，别在锁里做分析）

```bash
cd <你的 worktree>
./harness/a3/chip_lock.sh -- bash -lc '
  cd $HOME/projects/vllm/vllm-rs
  ./harness/a3/ab_serve.sh start --run c1r1-rust --frontend rust --chip 4 --port 18310
  ./harness/a3/point.sh --run c1r1-rust --side rust --tag C1 --port 18310 \
    --num-prompts 32 --max-concurrency 1 --warmup 2 --perf
  ./harness/a3/ab_serve.sh stop --run c1r1-rust
'
./harness/a3/sync.sh fetch c1r1-rust      # 锁外取回结果
```

## 口径（与 `plan/COORDINATION.md §5` 一致）

| 角色 | 位置 | 绑核 |
|---|---|---|
| 前端 / 引擎 | 服务容器（chip4，默认 cpuset `160-199`、NUMA 2） | 160–199 |
| 压测客户端 | **独立容器**（不带 NPU 设备） | `200-201` |

**两侧唯一变量是前端**：同一个镜像、同一个引擎、同一张卡、同一个客户端，
只差 `VLLM_USE_RUST_FRONTEND` + `VLLM_RUST_FRONTEND_PATH`。

## 已踩过的坑（都已修进脚本，别再踩）

1. `sudo perf ... &` 会 fork 真 perf 子进程；给 sudo 的 pid 发 SIGINT
   **不转发** ⇒ `wait` 挂死。修法：`setsid` + 取孙进程 pid + `pkill -INT -f` 兜底 +
   有界等待后强杀。
2. **后台任务绝不能继承脚本 stdout**：ssh 的 `... | tail` 会等管道 EOF，
   有后台后代持有写端就永不返回。修法：`</dev/null >>log 2>>log`。
3. `vllm bench serve` 的 `--base-url` **不带 `/v1`**，且必须显式给
   `--endpoint /v1/chat/completions`。
4. 容器里用 `--entrypoint bash` 会跳过 CANN 环境 ⇒ `import torch_npu` 失败；
   用镜像默认入口。
5. 只统计**单个 pid** 会漏算子进程（Python 臂会 fork 辅助 `python3`）。
   `point.sh` 已改为**采容器内全部进程再按 comm 分桶**（frontend/engine/other）。

## 镜像与二进制

| 项 | 值 |
|---|---|
| 镜像 | `quay.nju.edu.cn/ascend/vllm-ascend:v0.26.0rc1-a3-openeuler` |
| 镜像内 vLLM | `/vllm-workspace/vllm` @ **`568afb3a`**（与计划锁定值一致） |
| 镜像内 vllm-ascend | `f2f74a16c` |
| `vllm-rs` | 镜像**不自带**（无 cargo）⇒ `scripts/fetch_vllm_rs.py --arch aarch64` 抽官方 wheel，<br>放在 `REMOTE_HOST:~/projects/vllm/vllm-rs/bin/vllm-rs`（sha256 `cae05321…`，not stripped） |
