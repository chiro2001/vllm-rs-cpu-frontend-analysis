#!/usr/bin/env python3
"""把 inferno 生成的火焰图 SVG 按 `segments.json` 的分段重新着色，并插入图例。

为什么不在生成时着色：inferno 的 `--nameattr` 只能改 `<g>` 上的属性，
而 `<rect>` 自带显式 `fill=` 属性（优先级高于继承），改不动。
所以这里直接后处理 SVG：按每帧 `<title>` 里的函数名分类，重写 `<rect fill=...>`。

用法见 `recolor_svg.py --help`。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# 分段 → 颜色。P1–P10 用暖到冷的顺序色，跨段桶统一用灰蓝。
SEG_COLORS = {
    "P1": "#f6c85f", "P2": "#f2a65a", "P3": "#e88b3d", "P4": "#e05c2b", "P5": "#c9412e",
    "P6": "#a63a2a", "P7": "#8e6ba8", "P8": "#6b8ecb", "P9": "#3f7fb5", "P10": "#2a6b8f",
    "X-alloc": "#9aa7b1", "X-copy": "#7f8b95", "X-hash": "#b0b8bf", "X-runtime": "#5f7484",
    "X-tls": "#8d99a6", "X-park": "#77848f", "X-str": "#c3c9ce", "X-log": "#6d7a86",
    "X-metrics": "#98a4af", "X-bytes": "#aab3ba", "X-kernel": "#4c5a66",
    "X-unknown": "#3b444b", "X-rust": "#c9d1d9", "X-unclassified": "#dde3e8",
}
FRAME_TITLE_RE = re.compile(r"<title>(?P<name>.*?) \([^)]*\)</title>")
RECT_FILL_RE = re.compile(r'(<rect[^>]*?)fill="rgb\(\d+,\d+,\d+\)"')
HTML_UNESCAPE = (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'"), ("&amp;", "&"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="按 P 分段给火焰图 SVG 重新着色")
    ap.add_argument("--svg", required=True)
    ap.add_argument("--segments", default=os.path.join(os.path.dirname(__file__), "segments.json"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--in-place", action="store_true")
    ap.add_argument("--no-legend", action="store_true")
    args = ap.parse_args(argv)

    rules = [(r["segment"], re.compile(r["match"])) for r in json.load(open(args.segments))["rules"]]

    def classify(frame: str) -> str:
        for seg, rx in rules:
            if rx.search(frame):
                return seg
        return "X-unclassified"

    svg = open(args.svg).read()
    used: dict[str, int] = {}
    out_parts = []
    pos = 0
    n_frames = 0
    # 逐个 <g>...</g> 块处理：块内第一个 <title> 是帧名
    for m in re.finditer(r"<g>.*?</g>", svg, re.S):
        block = m.group(0)
        tm = FRAME_TITLE_RE.search(block)
        if not tm:
            continue
        frame = tm.group("name")
        for a, b in HTML_UNESCAPE:
            frame = frame.replace(a, b)
        seg = classify(frame)
        used[seg] = used.get(seg, 0) + 1
        color = SEG_COLORS.get(seg, "#cccccc")
        block2 = RECT_FILL_RE.sub(lambda mm: f'{mm.group(1)}fill="{color}"', block, count=1)
        out_parts.append(svg[pos:m.start()])
        out_parts.append(block2)
        pos = m.end()
        n_frames += 1
    out_parts.append(svg[pos:])
    svg = "".join(out_parts)

    if not args.no_legend:
        # ⚠️ 不能用 HTML 的 <div>/<span>——SVG 渲染器会直接忽略，图例会消失（踩过）。
        #    必须在 SVG 坐标系里画 rect + text，并把 height/viewBox 撑高。
        head = re.search(r'<svg[^>]*?width="(\d+)"[^>]*?height="(\d+)"[^>]*?>', svg)
        vb = re.search(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"', svg)
        if head and vb:
            w, h = float(vb.group(1)), float(vb.group(2))
            per_row = 10
            rows = (len(SEG_COLORS) + per_row - 1) // per_row
            row_h = 17.0
            pad = 6.0
            extra = rows * row_h + row_h + pad          # 多留一行放标题
            new_h = h + extra
            svg = re.sub(r'(<svg[^>]*?)height="\d+"', rf'\1height="{new_h:.0f}"', svg, count=1)
            svg = svg.replace(f'viewBox="0 0 {vb.group(1)} {vb.group(2)}"',
                              f'viewBox="0 0 {w:g} {new_h:g}"', 1)
            parts = [f'<g font-family="monospace" font-size="11" fill="#111">',
                     f'<text x="{pad}" y="{h + row_h:.0f}">'
                     f'分段配色（本图 {n_frames} 帧；P*=业务语义段，X-*=跨段桶）：</text>']
            for i, s in enumerate(SEG_COLORS):
                r, c = divmod(i, per_row)
                x = pad + c * (w / per_row)
                y = h + row_h * (r + 2)
                parts.append(f'<rect x="{x:.1f}" y="{y - 11:.1f}" width="11" height="11" '
                             f'fill="{SEG_COLORS[s]}" stroke="#888"/>')
                parts.append(f'<text x="{x + 15:.1f}" y="{y:.1f}">{s}</text>')
            parts.append("</g>")
            svg = svg.replace("</svg>", "".join(parts) + "</svg>", 1)

    dest = args.svg if args.in_place else (args.out or args.svg)
    with open(dest, "w") as f:
        f.write(svg)
    print(f"[recolor_svg] {dest}：重着色 {n_frames} 帧；分段出现次数 "
          + ", ".join(f"{k}={v}" for k, v in sorted(used.items(), key=lambda kv: -kv[1])[:12]),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
