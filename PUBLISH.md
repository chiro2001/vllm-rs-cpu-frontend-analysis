# 发布记录

> 本文件**排除在净化流程之外**（它的正文就在列举占位符名与替换计数，卷进替换会自指）。
> 净化规则与理由见 [`docs/SANITIZATION.md`](docs/SANITIZATION.md)。

---

## 1. 发布方式

**不走「就地净化后 push」**，而是导出一份全新的、单一起点的历史：

```bash
bash scripts/sanitize_for_publish.sh --check     # 1) 先看命中数（安全，不改文件）
bash scripts/export_publish.sh --no-push         # 2) 导出到 ../vllm-rs-publish 并复查
bash scripts/export_publish.sh                   # 3) 复查通过后建私有仓库并 push
```

原因：本仓库的 **git 历史**含内部标识（早期 `plan/` 引用了内部项目目录名与
本机绝对路径），`sed` 改不了历史（详见 `docs/SANITIZATION.md §1`）。

## 2. 净化命中数（导出前基线）

`bash scripts/sanitize_for_publish.sh --check` 在收口时的输出：

| 占位符 | 命中行数 | 说明 |
|---|---:|---|
| `REPO_HOME` | ~196 | 本机工作区**绝对路径前缀**（含本地用户名）——命中最多 |
| `REMOTE_HOST` | ~184 | 远端 aarch64 分析机名 |
| `PREPARE_INPUT_PROJECT` | ~53 | 前一个项目的目录名 |
| `LOCAL_HOST` | ~42 | 本机开发机主机名 |
| `UPSTREAM_PROJECT` | ~15 | 上游源码所在的内部分析项目目录名 |
| `REMOTE_HOST_HIST` | 2 | 历史远端机器名 |
| `REMOTE_USER` / `REMOTE_HOSTNAME` / `PUBLISHER_EMAIL` / `TOKENIZER_PROJECT_*` | 0 | 保留在表中，供后续复用 |

> ⚠️ 本表**只写占位符与计数，不写原值**——原值见本地 `.sanitize-map.tsv`（不进 git）。
> 导出时脚本会打印逐条命中数，以那份输出为准。

## 3. 导出时的硬门禁（任一不过则不提交、不推送）

1. 每个原值的**残留文件数必须为 0**；
2. 不得存在 `refs/`、`target/`、`runs/`、`.locks/`、`.sanitize-map.tsv`；
3. 不得残留任何 `*perf.data*`；
4. 打印导出后的文件数与体积供人工核对。

## 4. 发布状态

| 项 | 状态 |
|---|---|
| 净化映射表 | ✅ 已建（`.sanitize-map.tsv`，gitignore） |
| 撞名预检 | ✅ 无撞名 |
| 净化脚本干跑 | ✅ 已跑（见 §2） |
| **导出到本地目录** | ✅ **通过全部门禁**：11 个原值残留文件数**全为 0**；683 个文件 / 9.7 MB；单点历史；作者为 GitHub noreply；无 `refs/`、`runs/`、`target/`、`.locks/`、`.sanitize-map.tsv`、`*perf.data*` |
| **创建远端仓库 / push** | ✅ **已完成**：<https://github.com/chiro2001/vllm-rs-cpu-frontend-analysis>（**PRIVATE**，分支 `main`） |

> ⚠️ **为什么这里不写提交 sha**：`PUBLISH.md` 本身也随仓库发布，
> 若在其中写死「本快照的 sha」，那么每次更新它都会产生新提交、使 sha 落后一次——
> 这是个**自指**问题，无解。**以仓库 `main` 的 HEAD 为准**；
> 历次推送记录见 §4.4。

### 4.1 导出时发现并修掉的三处自身泄漏

第一次导出时，**导出脚本自己的复查门禁把结果拦下了**（这一步设计对了）——
发现三处「不该含原值」的文件带了真实内部标识，逐一修掉后重跑才通过：

1. `scripts/sanitize-map.example.tsv` —— 模板里用了**真实**项目名/主机名当示例
   ⇒ 改成通用假例（`SOMEUSER`、`local-hostname`、`internal-project` 等）；
2. `PUBLISH.md` —— 基线表里写了原值 ⇒ 改为**只列占位符与计数**（本文件即现状）；
3. `docs/SANITIZATION.md` —— 正文提到前一个项目的真实目录名 ⇒ 改用占位符指代。

这三个文件都被排除在净化流程之外（自指），因此**必须自身不含原值**。
验证方式：对 11 个原值逐个 `grep -rIl`，命中数必须为 0。

### 4.2 发布命令

```bash
# 本地导出（不推送），产物在 ../vllm-rs-publish2
bash scripts/export_publish.sh --no-push --out ../vllm-rs-publish2

# 确认后推送到私有仓库（仓库名可用 --repo 覆盖）
bash scripts/export_publish.sh --repo <repo-name>
```

### 4.3 本次推送遇到的网络问题与绕行（可复现）

推送当天**内网 VPN 中断**，导致本地代理（TUN 模式）对 `github.com` 的
fake-IP 路由失效。特征与诊断：

| 现象 | 说明 |
|---|---|
| `getent hosts github.com` → `198.18.0.4` | TUN 代理分配的 fake-IP（198.18.0.0/15 段） |
| `github.com:443` TLS 失败（`unexpected eof`） | 该 fake-IP 的路由已断 |
| **但** `api.github.com` / `raw.githubusercontent.com` / `codeload.github.com` **全部正常** | ⇒ 是 `github.com` **单域名**的路由问题，不是整体断网 |
| **且** `ssh.github.com:443` 的 SSH 握手成功 | ⇒ SSH 通道可用 |
| 另一个坑：git 全局配了 `http.proxy=http://127.0.0.1:14514` | 代理自己做 DNS，**因此改 `/etc/hosts` 对 git 无效** |

**最终采用的绕行**（HTTPS 长连接不稳，9.7 MB 推送反复失败）：

1. 用 API（`api.github.com` 可用）注册一把**临时 SSH 密钥**：
   `gh api -X POST user/keys -f title=... -f key="$(cat tmp.pub)"`；
2. 用 SSH over 443 推送：
   ```bash
   GIT_SSH_COMMAND="ssh -i <tmpkey> -o IdentitiesOnly=yes -p 443" \
     git push git@ssh.github.com:chiro2001/vllm-rs-cpu-frontend-analysis.git main
   ```
3. **推完立即删除该密钥**（`gh api -X DELETE user/keys/<id>`）并擦除本地临时私钥
   ⇒ 账户恢复到推送前的状态（密钥数回到 0）。

> ⚠️ **对后续维护者的提醒**：若再次遇到 `github.com` TLS 失败而其它 GitHub 域名正常，
> 先查是不是代理的单域名路由问题；排查顺序是
> ① `api.github.com` 是否可用（可用即说明是 github.com 专属问题）
> ② git 是否配了 `http.proxy`（它会让 `/etc/hosts` 失效）
> ③ 退路是 SSH over 443（`ssh.github.com`）。

### 4.4 历次推送

| # | 时间 | 提交 | 文件数 | 说明 |
|---|---|---|---:|---|
| 1 | 10:03 | `5c3a8ef` | 683 | 首次推送（含一个 0 字节遗留物 `_inline_code.py`） |
| 2 | 10:05 | `6baea58` | **682** | 清理遗留物后 force push（重建的单点历史，非增量） |

> 因为是「导出全新单点历史」的发布方式，第二次推送用了 `--force`——
> 新旧提交**没有共同的祖先**，不是常规的增量更新。

> ⚠️ `export_publish.sh` 默认会 `gh repo create --private` 并 push。
> 若只想本地导出，加 `--no-push`；仓库名用 `--repo NAME` 覆盖
> （默认 `vllm-rs-cpu-frontend-analysis`）。
