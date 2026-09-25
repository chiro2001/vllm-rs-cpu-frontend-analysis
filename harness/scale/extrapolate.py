#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""规模拐点外推：把 B 线的「前端每请求 on-CPU」线性模型外推到不同引擎速度下。

为什么要外推：本机只能测到两个极端——
  * mock engine：引擎≈免费 ⇒ 前端占比 ≈100%（前端差距的**上界**）；
  * x86 纯 CPU 真引擎：引擎极慢（TPOT 百 ms 量级）⇒ 前端占比 ≈0。
真实部署在两者之间，换前端值不值取决于**引擎有多快**与**并发有多高**。

本脚本把 B 线实测的前端成本模型
    F(ISL, OSL) = const + a·ISL + b·OSL          （ns/请求，c=1）
与「引擎每请求耗时 E」组合，算前端占比
    share = F / (F + E)
以及**吞吐口径**的前端核数需求
    cores = request_rate × F_per_request

⚠️ 全部为**推断**（extrapolation），不是实测：引擎耗时是**假设轴**，
   不是本计划采到的数据。文档引用时必须标注「推断」。

用法:
  extrapolate.py                       # 用 data/profiles/slope-segments.csv 的默认系数
  extrapolate.py --cores-per-request-mode concurrency
  extrapolate.py --help
"""
from __future__ import annotations

import argparse
import csv
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# B 线三点的实测值（data/profiles/slope-segments.csv 的「合计」是逐帧求和，
# 与 slope_model.py 解出的总模型一致；这里默认从 CSV 读，避免手抄漂移）。
DEFAULT_SEGMENTS = REPO_ROOT / "data/profiles/slope-segments.csv"


def load_model(path: pathlib.Path) -> tuple[float, float, float]:
    """返回 (const_ns, per_isl_token_ns, per_osl_token_ns) 的总和。"""
    rows = list(csv.DictReader(path.open()))
    if not rows:
        raise SystemExit(f"空文件：{path}")
    c = sum(float(r["const_ns"]) for r in rows)
    a = sum(float(r["per_isl_token_ns"]) for r in rows)
    b = sum(float(r["per_osl_token_ns"]) for r in rows)
    return c, a, b


def frontend_ns(model, isl: int, osl: int) -> float:
    c, a, b = model
    return c + a * isl + b * osl


# 引擎每请求耗时的假设轴（µs）。**这些是假设，不是实测**。
# 参考锚点：
#   * 245_000 µs/token：本机 x86 纯 CPU 真引擎实测（C 线，0.6B，c=1）
#   *   4_726 µs/token：**REMOTE_HOST chip4 实测**（0.8B，c=1，OSL=128）——本装置的真实锚点
#   *   4_915 µs/token：PREPARE_INPUT_PROJECT 在 Kunpeng 920B + Ascend 910 上
#                      实测的 engine core 单步 p50（B=1，0.8B 级模型；口径略窄）
#   更快的值属于**未测的假想档**，只为展示趋势。
ENGINE_TPOT_US = [
    ("x86 纯 CPU（本机实测，C 线）", 245_000),
    ("aarch64 + NPU（**REMOTE_HOST chip4 实测**）", 4_726),
    ("aarch64 + NPU（前项目 engine-core 口径）", 4_915),
    ("假想：小模型加速卡", 1_000),
    ("假想：极快 decode", 200),
]

# 前端每请求成本：**两套口径，差 5.2×，绝不能混用**（见 docs/06 §3.1）
#   mock：x86 + mock engine，tick 极密 ⇒ 前端可批量处理（docs/02 B1）
#   real：REMOTE_HOST chip4 + 真引擎，tick 稀疏 ⇒ 前端按 tick 计费（docs/02 A1/A5）
FRONTEND_MODELS = {
    "mock": ("x86 + mock engine（乐观上界）", None),     # 用 slope-segments.csv 拟合的线性模型
    # ns/请求 @ ISL=1024/OSL=128/c=1，取自 docs/04 的 C1（3 次重复中位数 10.31 ms）
    "real": ("REMOTE_HOST + 真引擎（**容量规划用这个**）", 10_310_000),
}

# 真引擎的 prefill（TTFT）模型 —— 由 `docs/04` 的 C1/C3 两点解出：
#   实测 TTFT：C1（ISL=1024）= 83.7 ms，C3（ISL=8192）= 353.4 ms
#   ⇒ 斜率 (353.4-83.7) ms / (8192-1024) token = **0.03763 ms/token = 37 630 ns/token**
#     （即每个输入 token 的 prefill 成本 37.6 µs，8k prompt 的 prefill ≈ 308 ms）
#   ⇒ 截距 = 83.7 − 0.03763×1024 = **45.2 ms**
# ⚠️ 两点拟合、且 C1/C3 的 OSL 不同（128 vs 16），故仅为**近似**；
#    长 prompt 的 prefill 时间必须计入「引擎每请求」，否则会严重低估引擎侧、高估前端占比。
PREFILL_TTFT_BASE_MS = 45.2
PREFILL_TTFT_NS_PER_ISL_TOKEN = 37_630.0


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--segments", type=pathlib.Path, default=DEFAULT_SEGMENTS,
                   help=f"slope-segments.csv 路径（默认 {DEFAULT_SEGMENTS}）")
    p.add_argument("--isl", type=int, default=1000)
    p.add_argument("--osl", type=int, default=128)
    p.add_argument("--ttft-ms", type=float, default=0.0,
                   help="引擎首 token 耗时（ms），计入每请求引擎时间（默认 0，即忽略）")
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--save", type=pathlib.Path, default=None,
                   help="把 markdown 表格写到该文件（默认打印到 stdout）")
    p.add_argument("--fe-model", choices=sorted(FRONTEND_MODELS), default="real",
                   help="前端成本模型：real=真引擎实测（默认，容量规划用）；mock=mock engine 乐观上界")
    p.add_argument("--fe-ms", type=float, default=None,
                   help="直接指定前端每请求成本（ms），覆盖 --fe-model（用于 C3 这类不同负载点）")
    p.add_argument("--no-prefill", action="store_true",
                   help="不计入 prefill 的 TTFT（默认计入；不计会把前端占比显著高估）")
    p.add_argument("--help-detail", action="store_true")
    args = p.parse_args()

    if not args.segments.exists():
        print(f"[extrapolate] 找不到 {args.segments}", file=sys.stderr)
        return 2

    model = load_model(args.segments)
    if args.fe_ms is not None:
        fe_ns = args.fe_ms * 1e6
        fe_label = f"指定值 {args.fe_ms} ms/请求"
    elif args.fe_model == "mock":
        fe_ns = frontend_ns(model, args.isl, args.osl)
        fe_label = FRONTEND_MODELS["mock"][0]
    else:
        fe_ns = float(FRONTEND_MODELS["real"][1])
        fe_label = FRONTEND_MODELS["real"][0]
    c, a, b = model

    lines: list[str] = []
    add = lines.append

    add("<!-- 由 harness/scale/extrapolate.py 生成；全部为推断，不是实测 -->")
    add("")
    add(f"**前端成本口径**：{fe_label}")
    add("")
    add("```")
    if args.fe_model == "mock":
        add(f"前端每请求 on-CPU ns = {c:,.0f} + {a:.2f} × ISL + {b:.2f} × OSL   （mock engine 拟合）")
    else:
        add(f"前端每请求 on-CPU = {fe_ns/1000:,.1f} µs   （REMOTE_HOST chip4 真引擎实测中位数，ISL=1024/OSL=128/c=1）")
        add(f"（mock engine 口径的拟合式 = {c:,.0f} + {a:.2f}×ISL + {b:.2f}×OSL，仅作乐观上界）")
    add(f"ISL={args.isl}, OSL={args.osl} ⇒ 前端 {fe_ns/1000:,.1f} µs/请求")
    add("```")
    add("")
    prefill_ns = 0.0 if args.no_prefill else (
        PREFILL_TTFT_BASE_MS * 1e6 + PREFILL_TTFT_NS_PER_ISL_TOKEN * args.isl)
    add(f"### 表 A：前端占「每请求总时间」的比例（ISL={args.isl}, OSL={args.osl}, c=1）")
    add("")
    if args.no_prefill:
        add("> ⚠️ 已按 `--no-prefill` **排除** prefill 的 TTFT——这会**高估**前端占比，仅供对照。")
        add("")
    else:
        add(f"> 引擎每请求 = **prefill TTFT**（{prefill_ns/1e6:,.1f} ms，按 ISL 估算）"
            f" + OSL × TPOT。长 prompt 时 prefill 才是引擎侧主项，**必须计入**。")
        add("")
    add("| 引擎 decode 速度（假设轴） | prefill µs | decode µs | 引擎合计 µs | 前端 µs | **前端占比** |")
    add("|---|---:|---:|---:|---:|---:|")
    for label, tpot in ENGINE_TPOT_US:
        decode_us = tpot * args.osl
        engine_us = decode_us + prefill_ns / 1000 + args.ttft_ms * 1000
        total = engine_us + fe_ns / 1000
        add(f"| {label}（TPOT {tpot/1000:,.1f} ms） | {prefill_ns/1000:,.0f} | {decode_us:,.0f} "
            f"| {engine_us:,.0f} | {fe_ns/1000:,.1f} "
            f"| **{fe_ns/1000/total*100:.3f}%** |")
    add("")
    add(f"### 表 B：吞吐口径——前端要吃掉几个核（ISL={args.isl}, OSL={args.osl}）")
    add("")
    add("| 目标请求率 | 前端核数需求（Rust，B 线实测） |")
    add("|---:|---:|")
    for rps in (10, 50, 100, 500, 1000, 2000):
        cores = rps * fe_ns / 1e9
        add(f"| {rps} req/s | {cores:.2f} 核 |")
    add("")
    add("> 注：核数 = 请求率 × 每请求前端 CPU 秒。c=64 时每请求成本比 c=1 低约 25%")
    add("> （B4 实测 678 µs vs B1 外推 906 µs），所以上表在**高并发下偏保守**。")
    add("")
    add("---")
    add("")
    add("**未测/推断声明**：表 A 的「引擎每请求 µs」除 x86 CPU 与 aarch64 NPU 两档")
    add("外均为**假想值**；前端成本模型来自 B 线在 **mock engine** 下的实测（引擎≈免费），")
    add("外推到真引擎时假设「前端成本不随引擎变化」——该假设**未验证**（真引擎下")
    add("前端可能因流量形态不同而变化）。")

    text = "\n".join(lines) + "\n"
    if args.save:
        args.save.parent.mkdir(parents=True, exist_ok=True)
        args.save.write_text(text)
        print(f"[extrapolate] -> {args.save}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
