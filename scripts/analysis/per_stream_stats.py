#!/usr/bin/env python3
"""per-stream 速率统计: 直接复用 common.load_stream_log (与 CI 分析同源解析)。

用法: python scripts/analysis/per_stream_stats.py <dir-with-iperf3-server-*.log>
输出: 每流 mean/min/p5/p50/max Mbps + 地板占比 (<12Mbps 的秒数占比, CI 预注册地板阈值)
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "wave1_sim"))
import common  # noqa: E402

FLOOR_MBPS = 12.0  # CI 预注册: 绝对地板阈值


def main() -> None:
    d = Path(sys.argv[1])
    logs = sorted(d.glob("iperf3-server-*.log"))
    if not logs:
        raise SystemExit(f"no iperf3-server-*.log in {d}")
    allm = []
    print(f"{'port':>6} {'n_s':>6} {'mean':>8} {'min':>8} {'p5':>8} {'p50':>8} {'max':>8} {'floor%':>7}")
    for p in logs:
        port = int(p.stem.rsplit("-", 1)[1])
        x = common.load_stream_log(d, port)
        x = x[~np.isnan(x)]
        if not len(x):
            print(f"{port:>6} {'EMPTY':>6}")
            continue
        allm.append(x)
        print(f"{port:>6} {len(x):>6} {x.mean():>8.2f} {x.min():>8.2f} "
              f"{np.percentile(x, 5):>8.2f} {np.median(x):>8.2f} {x.max():>8.2f} "
              f"{100 * (x < FLOOR_MBPS).mean():>6.1f}%")
    if allm:
        m = np.array([a for a in allm if len(a) == min(len(b) for b in allm)])
        tot = m.sum(axis=0)
        print(f"\nTOTAL  mean={tot.mean():.2f} Mbps  min-stream mean={m.min(axis=0).mean():.2f}  "
              f"ratio={m.min(axis=0).mean() / tot.mean() * 100:.1f}%  spread(max-min)={m.max(axis=0).mean() - m.min(axis=0).mean():.2f}")


if __name__ == "__main__":
    main()
