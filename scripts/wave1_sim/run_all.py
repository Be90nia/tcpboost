"""Wave-1 离线仿真统一入口: 四票 × 三轮真 trace, 汇总表 + results_all.json。

用法: python run_all.py  (约 2-3 分钟, 纯 CPU)
数据: D:/tmp/atj_harvest/{38887594698,38887614387,38913043898}
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import b9z_hier
import common
import e18_hmm
import t3wi_cp1
import t5pe_sprt
from common import ROUNDS, prepare_round


def run_ticket_5pe(pr):
    round_r = {p: pr["r"][:, j] for j, p in enumerate(pr["ports"])}
    return t5pe_sprt.evaluate(round_r, {"dep30": pr["dep30"], "dead": pr["dead"]})


def fmt_agg(agg):
    d30 = agg["dep30"]
    dead = agg["dead"]
    delay = agg.get("median_delay", d30.get("delays") and float(np.median(d30["delays"])))
    delay = f"{delay:.0f}" if isinstance(delay, float) else "-"
    fp = agg.get("fp_per_sh")
    fs = agg.get("false_seconds", agg.get("false_state_seconds", 0))
    return (f"{d30['caught']}/{d30['true']}", f"{dead['caught']}/{dead['true']}", delay,
            f"{agg.get('false_eps', '-')}", f"{fp}/sh" if fp is not None else "-",
            str(fs))


def main():
    t0 = time.time()
    all_results: dict = {}
    header = f"{'round':10s} {'detector':17s} {'dep30':>7s} {'dead':>7s} {'dly':>5s} {'FPeps':>6s} {'FP/sh':>9s} {'fsec':>6s}"
    for name in ROUNDS:
        pr = prepare_round(name)
        tickets = {
            "5pe": run_ticket_5pe(pr),
            "e18": e18_hmm.evaluate(pr),
            "b9z": b9z_hier.evaluate(pr),
            "3wi": t3wi_cp1.evaluate(pr),
        }
        all_results[name] = tickets
        print(f"\n===== round {name} ({time.time()-t0:.0f}s) =====")
        for ticket, dets in tickets.items():
            for det, agg in dets.items():
                if det.startswith("_"):
                    continue
                c30, cd, dly, fp, fps, fs = fmt_agg(agg)
                print(f"{ticket:4s} {det:17s} {c30:>7s} {cd:>7s} {dly:>5s} {fp:>6s} {fps:>9s} {fs:>6s}")
    out = Path(__file__).parent / "results_all.json"
    out.write_text(json.dumps(all_results, indent=1, default=float))
    print(f"\nsaved {out} ({time.time()-t0:.0f}s total)")


if __name__ == "__main__":
    main()
