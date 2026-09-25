# 发布前净化：替换了什么、为什么

> 本文件**本身不进净化流程**（它的正文就在列举占位符，卷进替换会自指）。
> 配套：`scripts/sanitize_for_publish.sh`（执行）、`scripts/sanitize-map.example.tsv`（模板）、
> `scripts/export_publish.sh`（导出可发布副本）、根目录 `.sanitize-map.tsv`（真实值，**不进 git**）。

---

## 1. 为什么不能「就地净化后 push」

本仓库的 **git 历史**里含有内部标识（早期提交的 `plan/` 引用了内部项目目录名与本机绝对路径）。
`sed` 只能改工作树文本，**改不了历史**。所以发布走的是
`export_publish.sh`：**导出 → 净化 → 重建单一起点的历史 → 复查 → 推送**，
与前两个项目（`tokenizer` 与 `PREPARE_INPUT_PROJECT`）的做法一致。

## 2. 替换表（真实值 → 占位符）

真实值见本地 `.sanitize-map.tsv`（已 gitignore）。占位符与理由：

| 占位符 | 替换掉什么 | 为什么必须替换 |
|---|---|---|
| `REPO_HOME` | 本机工作区绝对路径前缀（本地用户 home 目录，**≈196 处**） | 路径里含**本机用户名**，属于能定位到具体人的标识 |
| `REMOTE_HOST` | 远端 aarch64 分析机名（**≈184 处**） | 内网主机名 |
| `REMOTE_HOST_HIST` | 历史远端机器名 | 同上 |
| `REMOTE_HOSTNAME` | 远端 `hostname` 输出 | 同上 |
| `REMOTE_USER` | 远端内部员工号 | 同上（本次实测命中 **0**，保留以备后续） |
| `LOCAL_HOST` | 本机开发机主机名（**≈42 处**） | 内网主机名 |
| `UPSTREAM_PROJECT` | 上游 vLLM 源码所在的内部分析项目目录名（**15 处**） | 内部项目结构 |
| `PREPARE_INPUT_PROJECT` | 前一个项目的目录名（**≈53 处**） | 内部项目结构 |
| `TOKENIZER_PROJECT_*` | 上一个项目的工作树/发布目录名 | 同上（本次命中 **0**） |
| `PUBLISHER_EMAIL` | 发布者邮箱 | 隐私（本次实测命中 **0**——它只出现在 git config，导出时用 GitHub noreply 重建） |

## 3. **有意不替换**的东西（否则读者无法复现）

| 保留项 | 理由 |
|---|---|
| `vllm`、`vllm-rs`、`vllm-bench`、`vllm-mock-engine`、`vllm-ascend` | **本项目的分析对象与上游项目名**，替换掉就没法复现 |
| `Qwen3-0.6B`、`Qwen3.5-0.8B` | 模型标识，公开可得 |
| commit `568afb3a13806beb53bb2e6bd518269357b237c0` | 计划锁定的上游 commit，是复现的前提 |
| `tokenizer` / `tokenizer.json` 等 crate/module 名 | 上游代码标识；本项目里绝大多数 `tokenizer` 是这类，**只有绝对路径里的目录名需要处理**（由路径前缀那条兜住） |
| `github.com`、`pypi.org`、`wheels.vllm.ai`、`files.pythonhosted.org` | 公开的制品源 |
| `quay.nju.edu.cn`（12 处） | **公开**的 quay 镜像站；镜像 tag 是复现链条的一环（`vllm-ascend:v0.26.0rc1-a3-openeuler`）。**若评审认为不宜公开，请在映射表里加一条** |
| HuggingFace 模型名、`transformers` 等公共依赖 | 公开 |

## 4. 撞名预检（踩过的坑）

`sanitize_for_publish.sh --apply` 会先检查「占位符是否已在语料里存在」：
若占位符与既有标识符同名，`--revert` 会不可逆地改坏内容。
上一个项目的真实教训：占位符 `LINKS_HOST` 与脚本里本来就叫 `LINKS_HOST` 的变量撞名，
revert 时把变量名也换成真实值，脚本直接语法错误。

本次预检结果：**无撞名**（占位符全部带项目前缀，且都是 ASCII 大写+下划线）。

## 5. 复查（导出时的硬门禁）

`export_publish.sh` 在提交前会复查，任一条不过就**不提交、不推送**：

1. **每个原值的残留文件数必须为 0**；
2. **不得存在** `refs/`、`target/`、`runs/`、`.locks/`、`.sanitize-map.tsv`；
3. **不得残留任何 `*perf.data*`**（原始采样，体积大且无必要）；
4. 导出目录里 `git ls-files` 的文件数与体积会被打印出来供人工核对。

## 6. 发布记录

见根目录 `PUBLISH.md`（该文件同样排除在净化之外，因为它会列举占位符名与替换计数）。

## 7. 已知的净化盲区（如实记录）

| 项 | 说明 |
|---|---|
| 二进制文件 | `sed` 改不了；本项目 `figures/*.svg` 是文本（可净化），`.gz`/`.png` 若有则不处理（已尽量不入库） |
| git 历史 | 不净化，靠**重建单点历史**解决 |
| 时间戳与 loadavg | **保留**：它们是实验口径的一部分（manifest 要求），不属于个人标识 |
| 远端镜像仓库地址 | 见 §3 的保留说明；如需隐藏请自行加映射 |
