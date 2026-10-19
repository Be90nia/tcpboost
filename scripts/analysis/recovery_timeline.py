"""68m 恢复时间线离线分析 (零 CI)。

数据源: scripts/wave1_sim/common.py 的 iperf3-server-*.log 每秒序列
(bbrplusv3 / bbr / cubic 三轮 atj A/B/C)。streams/*.jsonl 相位错位弃用,
timeseries.csv 的 total=16×p50 派生, 仅作交叉校验。

三分法 (预注册, 见 docs/handoff-2026-10-19.md):
  - DRS: 某流 <12 Mbps 持续 >=10s (绝对地板) -> 0tg 全搁置
  - C1/C2: 发端恢复动力学: <2 Mbps 空窗 >=2s, 或深跌后 60s 内未回到 80% 基线
  - C3: 增益锯齿: 深跌间隔规律 (CV<0.35 且 >=8 次)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "wave1_sim"))
import common  # noqa: E402

DIP_FRAC = 0.50          # 深跌阈值: 30s 滚动中位数的 50%
DIP_MERGE_GAP = 2        # 相邻深跌间隔 <=2s 合并
RECOVER_FRAC = 0.80      # 恢复目标: 跌前 10s 中位数的 80%
RECOVER_WINDOW = 60      # 恢复观察窗 (s)
RECOVER_HOLD = 2         # 需连续 2s 达标
IDLE_MBPS = 2.0          # 发端空窗阈值
IDLE_MIN_DUR = 2         # 空窗最短持续 (s)
FLOOR_MBPS = 12.0        # 绝对地板
FLOOR_MIN_DUR = 10       # 地板最短持续 (s)
STARVE_FRAC = 0.25       # 相对饿死: 全流中位数的 25%
STARVE_MIN_DUR = 10


def rolling_median(x: np.ndarray, width: int = 30) -> np.ndarray:
    out = np.full(len(x), np.nan)
    for i in range(len(x)):
        seg = x[max(0, i - width + 1):i + 1]
        seg = seg[~np.isnan(seg)]
        if len(seg):
            out[i] = np.median(seg)
    return out


def episodes(mask: np.ndarray) -> list[tuple[int, int]]:
    out, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(mask)))
    return out


def merge_episodes(eps: list[tuple[int, int]], gap: int) -> list[tuple[int, int]]:
    if not eps:
        return []
    out = [list(eps[0])]
    for a, b in eps[1:]:
        if a - out[-1][1] <= gap:
            out[-1][1] = b
        else:
            out.append([a, b])
    return [tuple(e) for e in out]


def series_dips(x: np.ndarray) -> dict:
    """深跌 episode + 恢复到跌前 80% 的时间/斜率。"""
    base = rolling_median(x, 30)
    with np.errstate(invalid="ignore"):
        dips = [e for e in merge_episodes(episodes(x < DIP_FRAC * base), DIP_MERGE_GAP)
                if e[1] - e[0] >= 1]
    rows = []
    for a, b in dips:
        pre = np.nanmedian(base[max(0, a - 10):a])
        if np.isnan(pre):
            continue
        target = RECOVER_FRAC * pre
        recovered_at, run = None, 0
        for k in range(b, min(len(x), b + RECOVER_WINDOW)):
            run = run + 1 if (not np.isnan(x[k]) and x[k] >= target) else 0
            if run >= RECOVER_HOLD:
                recovered_at = k - RECOVER_HOLD + 1
                break
        dip_min = float(np.nanmin(x[a:b]))
        rec_s = None if recovered_at is None else recovered_at - a
        slope = None if not rec_s else (target - dip_min) / max(rec_s, 1)
        rows.append({
            "start": a, "end": b, "dur_s": b - a, "min_mbps": dip_min,
            "baseline_mbps": float(pre), "recover_s": rec_s,
            "recover_slope_mbps_s": None if slope is None else float(slope),
        })
    return {"rows": rows, "base": base}


def interval_stats(rows: list[dict]) -> dict:
    if len(rows) < 2:
        return {"count": len(rows), "cv": None, "modal_share": None}
    starts = [r["start"] for r in rows]
    gaps = np.diff(starts)
    cv = float(np.std(gaps) / np.mean(gaps)) if np.mean(gaps) else None
    # 规律性: 落在众数 ±30% 的比例
    hist, edges = np.histogram(gaps, bins=max(4, min(20, len(gaps) // 3)))
    mode = 0.5 * (edges[hist.argmax()] + edges[hist.argmax() + 1])
    modal_share = float(np.mean(np.abs(gaps - mode) <= 0.3 * mode)) if mode else None
    return {"count": len(rows), "cv": cv, "modal_share": modal_share,
            "median_interval_s": float(np.median(gaps))}


def summarize(x: np.ndarray) -> dict:
    d = series_dips(x)
    rows = d["rows"]
    rec = [r["recover_s"] for r in rows if r["recover_s"] is not None]
    slopes = [r["recover_slope_mbps_s"] for r in rows if r["recover_slope_mbps_s"] is not None]
    with np.errstate(invalid="ignore"):
        idle = [e for e in merge_episodes(episodes(x < IDLE_MBPS), DIP_MERGE_GAP)
                if e[1] - e[0] >= IDLE_MIN_DUR]
        floor = [e for e in merge_episodes(episodes(x < FLOOR_MBPS), DIP_MERGE_GAP)
                 if e[1] - e[0] >= FLOOR_MIN_DUR]
    return {
        "seconds": int(len(x)),
        "dips": len(rows),
        "dip_dur_med_s": float(np.median([r["dur_s"] for r in rows])) if rows else 0.0,
        "dip_min_med_mbps": float(np.median([r["min_mbps"] for r in rows])) if rows else None,
        "recovered": len(rec),
        "unrecovered_60s": len(rows) - len(rec),
        "recover_med_s": float(np.median(rec)) if rec else None,
        "recover_p90_s": float(np.percentile(rec, 90)) if rec else None,
        "recover_slope_med_mbps_s": float(np.median(slopes)) if slopes else None,
        "idle_episodes": len(idle),
        "idle_s": int(sum(b - a for a, b in idle)),
        "floor_episodes": len(floor),
        "floor_s": int(sum(b - a for a, b in floor)),
        "dip_intervals": interval_stats(rows),
    }


def starved_summary(m: np.ndarray) -> dict:
    lab = common.starved_labels(m, frac=STARVE_FRAC, sustain=STARVE_MIN_DUR)
    eps = []
    for j in range(m.shape[1]):
        eps += [(j, a, b) for a, b in common.merge_eps(common.episodes(lab[:, j]), gap=5)]
    return {"episodes": len(eps), "total_s": int(sum(b - a for _, a, b in eps)),
            "max_s": int(max((b - a for _, a, b in eps), default=0))}


def validate_series(x: np.ndarray, name: str) -> None:
    """防线: 旧 loader 把 summary 行拼成 300s 恒值块 -> 单值占比 ~50%。"""
    vals = x[~np.isnan(x)]
    if not len(vals):
        raise ValueError(f"{name}: empty series")
    share = np.unique(np.round(vals, 6), return_counts=True)[1].max() / len(vals)
    if share > 0.20:
        raise ValueError(f"{name}: constant block detected (max value share={share:.2f})")


def analyze_matrix(label: str, m: np.ndarray, ports: list[int]) -> dict:
    per_stream = {}
    for j, p in enumerate(ports):
        x = m[:, j]
        validate_series(x, f"{label}/p{p}")
        per_stream[str(p)] = summarize(x)
    total = np.nansum(m, axis=1)
    mn = np.nanmin(m, axis=1)
    ps = list(per_stream.values())
    rec_med = [s["recover_med_s"] for s in ps if s["recover_med_s"] is not None]
    return {
        "arm": label,
        "shape": [int(m.shape[0]), int(m.shape[1])],
        "total_mbps_mean": float(np.nanmean(total)),
        "total_mbps_median": float(np.nanmedian(total)),
        "min_stream_mbps_mean": float(np.nanmean(mn)),
        "min_stream_mbps_median": float(np.nanmedian(mn)),
        "dips_total": int(sum(s["dips"] for s in ps)),
        "unrecovered_60s_total": int(sum(s["unrecovered_60s"] for s in ps)),
        "recover_med_s_median": float(np.median(rec_med)) if rec_med else None,
        "idle_episodes_total": int(sum(s["idle_episodes"] for s in ps)),
        "floor_episodes_total": int(sum(s["floor_episodes"] for s in ps)),
        "starved": starved_summary(m),
        "per_stream": per_stream,
    }


def analyze_round(name: str) -> dict:
    rd = common.load_round(name)
    m, ports = common.mat(rd)
    return analyze_matrix(name, m, ports)


def find_results_dir(root: Path) -> Path:
    """任意 artifact 根目录 → 含 timeseries.csv 的结果目录。"""
    if (root / "timeseries.csv").exists():
        return root
    for cand in sorted(root.glob("*/timeseries.csv")) + sorted(
            root.glob("soak-test-results/*/timeseries.csv")):
        return cand.parent
    raise FileNotFoundError(f"no soak results under {root}")


def analyze_dir(label: str, root: Path) -> dict:
    rdir = find_results_dir(root)
    logs = sorted(rdir.glob("iperf3-server-*.log"))
    if not logs:
        raise FileNotFoundError(f"no iperf3 server logs in {rdir}")
    rd = {int(p.stem.rsplit("-", 1)[1]): common.load_stream_log(rdir, int(p.stem.rsplit("-", 1)[1]))
          for p in logs}
    m, ports = common.mat(rd)
    return analyze_matrix(label, m, ports)


def route(arms: dict, candidate: str) -> dict:
    a = arms[candidate]
    ps = list(a["per_stream"].values())
    idle = sum(s["idle_episodes"] for s in ps)
    floor = sum(s["floor_episodes"] for s in ps)
    dips = sum(s["dips"] for s in ps)
    unrecovered = sum(s["unrecovered_60s"] for s in ps)
    cv = np.median([s["dip_intervals"]["cv"] for s in ps
                    if s["dip_intervals"]["cv"] is not None])
    modal = np.median([s["dip_intervals"]["modal_share"] for s in ps
                       if s["dip_intervals"]["modal_share"] is not None])
    if floor >= 3:
        verdict = "DRS"
        reason = f"绝对地板 <{FLOOR_MBPS}Mbps >= {FLOOR_MIN_DUR}s: {floor} 次"
    elif unrecovered / max(dips, 1) >= 0.05 or idle >= 3:
        verdict = "C1/C2"
        reason = (f"深跌 {dips} 次, {unrecovered} 次 60s 内未恢复 ("
                  f"{unrecovered / max(dips, 1):.1%}); <2Mbps 空窗 {idle} 次")
    elif cv is not None and cv < 0.35 and modal >= 0.5:
        verdict = "C3"
        reason = f"深跌间隔规律 CV={cv:.2f}, 众数覆盖={modal:.0%}"
    else:
        verdict = "INCONCLUSIVE"
        reason = f"C1/C2 未达阈 (unrecovered {unrecovered}/{dips}), 无地板, 无规律锯齿"
    return {"verdict": verdict, "reason": reason,
            "inputs": {"dips": dips, "unrecovered_60s": unrecovered,
                       "idle_episodes": idle, "floor_episodes": floor,
                       "dip_interval_cv_med": None if cv is None else float(cv),
                       "dip_interval_modal_share_med": None if modal is None else float(modal)}}


def compare(base: dict, cand: dict) -> dict:
    def pct(a, b):
        return None if not a else round((b / a - 1) * 100, 2)
    keys = ["total_mbps_mean", "total_mbps_median", "min_stream_mbps_mean",
            "dips_total", "unrecovered_60s_total", "recover_med_s_median"]
    return {"baseline": base["arm"], "candidate": cand["arm"],
            "delta_pct": {k: pct(base[k], cand[k]) for k in keys}}


def probe_markdown(result: dict) -> str:
    base, cand = result["arms"][result["compare"]["baseline"]], result["arms"][result["compare"]["candidate"]]
    d = result["compare"]["delta_pct"]
    keys = [("total_mbps_mean", "total 均值 (Mbps)"), ("total_mbps_median", "total 中位 (Mbps)"),
            ("min_stream_mbps_mean", "min 流均值 (Mbps)"), ("dips_total", "深跌次数"),
            ("unrecovered_60s_total", "60s 未恢复次数"), ("recover_med_s_median", "恢复中位 (s)")]
    lines = [f"# C1 beta probe — {base['arm']} vs {cand['arm']}", "",
             "| 指标 | baseline | candidate | delta |", "|---|---:|---:|---:|"]
    for k, name in keys:
        b, c, v = base[k], cand[k], d[k]
        lines.append(f"| {name} | {b:.3f} | {c:.3f} | {'-' if v is None else f'{v:+.1f}%'} |")
    lines += ["", f"shape: {base['shape']} vs {cand['shape']}",
              f"starved: {base['starved']} vs {cand['starved']}", ""]
    return "\n".join(lines)


def selftest() -> None:
    rng = np.random.default_rng(0)
    steady = np.full(300, 50.0) + rng.normal(0, 2, 300)
    s = summarize(steady)
    assert s["dips"] == 0 and s["idle_episodes"] == 0 and s["floor_episodes"] == 0, s

    crash = np.r_[np.full(60, 50.0), 1.0, 1.0, 5, 15, 30, 45, np.full(60, 50.0)]
    s = summarize(crash)
    assert s["dips"] >= 1 and s["idle_episodes"] >= 1, s
    assert s["recovered"] >= 1, s

    saw = np.full(400, 50.0)
    for at in range(60, 360, 30):
        saw[at:at + 4] = 5.0
    s = summarize(saw)
    assert s["dips"] >= 8 and s["dip_intervals"]["cv"] < 0.35, s

    m = np.full((300, 8), 50.0)
    m[100:115, 3] = 5.0
    assert starved_summary(m)["episodes"] == 1

    m2 = np.full((300, 8), 50.0)
    m2[100:112, 2] = 11.0
    sf = summarize(m2[:, 2])
    assert sf["floor_episodes"] == 1, sf

    try:
        validate_series(np.r_[np.full(300, 65.5), rng.normal(50, 5, 300)], "bad")
    except ValueError:
        pass
    else:
        raise AssertionError("constant block not detected")
    print("selftest: PASS")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--out", default="reports/68m")
    ap.add_argument("--rounds", default="bbrplusv3,bbr,cubic")
    ap.add_argument("--dirs", default="", help="label=path,label=path (probe artifacts)")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return
    params = {
        "dip_frac": DIP_FRAC, "recover_frac": RECOVER_FRAC,
        "recover_window_s": RECOVER_WINDOW, "idle_mbps": IDLE_MBPS,
        "floor_mbps": FLOOR_MBPS, "floor_min_dur_s": FLOOR_MIN_DUR,
        "starve_frac": STARVE_FRAC, "starve_min_dur_s": STARVE_MIN_DUR,
    }
    if args.dirs:
        specs = [item.split("=", 1) for item in args.dirs.split(",")]
        arms = {label: analyze_dir(label, Path(path)) for label, path in specs}
        if len(specs) < 2:
            raise SystemExit("--dirs needs baseline,candidate")
        base, cand = specs[0][0], specs[1][0]
        result = {"arms": arms, "compare": compare(arms[base], arms[cand]), "params": params}
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        (out / "probe.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))
        (out / "probe.md").write_text(probe_markdown(result))
        print(probe_markdown(result))
        print(f"written: {out/'probe.json'}")
        return
    arms = {name: analyze_round(name) for name in args.rounds.split(",")}
    result = {"arms": arms, "route": route(arms, "bbrplusv3"), "params": params}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "recovery-timeline.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))
    print(json.dumps(result["route"], ensure_ascii=False, indent=2))
    print(f"written: {out/'recovery-timeline.json'}")


if __name__ == "__main__":
    main()
