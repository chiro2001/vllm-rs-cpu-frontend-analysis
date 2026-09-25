#!/usr/bin/env python3
"""等一个 TCP 端口可连接（用于判断前端是否已 bind handshake / HTTP 端口）。

用法：
  wait_port.py --port 29550 [--host 127.0.0.1] [--timeout 120] [--interval 0.5]
  wait_port.py --help

退出码：0 = 可连接；1 = 超时。
"""

from __future__ import annotations

import argparse
import socket
import sys
import time


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--timeout", type=float, default=120.0)
    p.add_argument("--interval", type=float, default=0.5)
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        s = socket.socket()
        s.settimeout(min(1.0, max(0.05, args.interval)))
        try:
            s.connect((args.host, args.port))
            s.close()
            if not args.quiet:
                print(f"[wait_port] {args.host}:{args.port} 已可连接")
            return 0
        except OSError:
            pass
        finally:
            s.close()
        time.sleep(args.interval)
    if not args.quiet:
        print(f"[wait_port] {args.host}:{args.port} 在 {args.timeout}s 内不可连接", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
