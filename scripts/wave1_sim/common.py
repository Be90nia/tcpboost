"""Wave-1 offline-sim shared loader.

数据源: D:/tmp/atj_harvest/ 三轮 CI soak artifact (bbrplusv3/cubic/bbr)。
权威流级序列 = iperf3-server-*.log (显式每秒区间); streams/*.jsonl 是有损修复
产物 (成对重复+相位漂移), 仅用于交叉验证, 不作为算法输入。
"""
from __future__ import annotations

import csv
import re
from pathlib import Path

import numpy as np

HARVEST = Path("D:/tmp/atj_harvest")
ROUNDS = {  # name -> run id (契约 2026-10-17)
    "bbrplusv3": "38887594698",
    "cubic": "38887614387",
    "bbr": "38913043898",
}

_INTERVAL_RE = re.compile(
    r"\[\s*\d+\]\s+([\d.]+)-\s*([\d.]+)\s+sec\s+"
    r"([\d.]+)\s+(\w*)Bytes\s+([\d.]+)\s+(\w*)bits/sec"
)


def find_results_dir(run_id: str) -> Path:
    """两代目录布局兼容: <run>/<stamp>/ 或 <run>/soak-test-results/<stamp>/"""
    root = HARVEST / run_id
    for cand in sorted(root.glob("*/timeseries.csv")) + sorted(
        root.glob("soak-test-results/*/timeseries.csv")
    ):
        return cand.parent
    raise FileNotFoundError(f"no soak results under {root}")


def load_timeseries(results_dir: Path) -> list[dict]:
    with (results_dir / "timeseries.csv").open() as f:
        return list(csv.DictReader(f))


def load_stream_log(results_dir: Path, port: int) -> np.ndarray:
    """iperf3 server log → 每秒 Mbps 序列。

    server 顺序接受多个 ~5min 测试, Interval 每次从 0 重启:
    按"start < 前一 end"检测边界并偏移拼接。缺口留 NaN。
    """
    txt = (results_dir / f"iperf3-server-{port}.log").read_text(errors="replace")
    mult = {"K": 1e-3, "": 1.0, "M": 1.0, "G": 1e3}
    rows = [
        (float(m[0]), float(m[1]), float(m[4]) * mult[m[5]])
        for m in _INTERVAL_RE.findall(txt)
        if m[5] in mult
    ]
    if not rows:
        return np.array([])
    segs: list[tuple[float, float, float]] = []  # (start,end,mbps) 全局时间
    offset = 0.0
    prev_end = 0.0
    for a, b, mbps in rows:
        if a < prev_end - 1e-6:  # 新测试从头开始
            offset += prev_end
        segs.append((a + offset, b + offset, mbps))
        prev_end = b
    dur = int(np.ceil(max(b for _, b, _ in segs)))
    out = np.full(dur, np.nan)
    for a, b, mbps in segs:
        i0, i1 = int(np.floor(a)), min(int(np.ceil(b)), dur)
        if i1 > i0:
            slot = out[i0:i1]
            # 仅填空槽: 每测试末尾的 summary 行 (0.00-29.19 receiver) 不得覆写每秒数据
            slot[:] = np.where(np.isnan(slot), mbps, slot)
    return out


def load_round(name: str) -> dict[str, np.ndarray]:
    """round name -> {port(int): per-second Mbps array}"""
    rdir = find_results_dir(ROUNDS[name])
    logs = sorted(rdir.glob("iperf3-server-*.log"))
    if not logs:
        raise FileNotFoundError(f"no iperf3 server logs in {rdir}")
    out = {}
    for p in logs:
        port = int(p.stem.rsplit("-", 1)[1])
        out[port] = load_stream_log(rdir, port)
    return out


def mat(round_data: dict[str, np.ndarray]) -> tuple[np.ndarray, list[int]]:
    """对齐各流为矩阵 (T×N, 短流尾部 NaN), 返回 (矩阵, 端口列表)。"""
    ports = sorted(round_data)
    n = max(len(round_data[p]) for p in ports)
    m = np.full((n, len(ports)), np.nan)
    for j, p in enumerate(ports):
        s = round_data[p]
        m[: len(s), j] = s
    return m, ports


def bucket(mat_: np.ndarray, width: int = 30) -> np.ndarray:
    """每秒矩阵 → 30s 桶均值矩阵 (尾部不足一桶丢弃), NaN 流忽略均值。"""
    t = mat_.shape[0] - mat_.shape[0] % width
    w = mat_[:t].reshape(t // width, width, mat_.shape[1])
    with np.errstate(invalid="ignore"):
        return np.nanmean(w, axis=1)


def stream_jsonl_mbps(results_dir: Path, sid: int) -> np.ndarray:
    """修复产物读入 (仅交叉验证用): 成对重复容差去重。"""
    vals = [float(x) for x in (results_dir / f"streams/stream-{sid}.jsonl").read_text().split()]
    return np.array(vals[0::2]) / 1e6


# ---- ground-truth 标注 (评估参照, 算法不可见) ----

def starved_labels(mat_: np.ndarray, frac: float = 0.25, sustain: int = 10) -> np.ndarray:
    """逐秒逐流饿死标签: rate < frac×全流中位数 持续 ≥sustain 秒。

    返回 bool 矩阵 (T×N)。这是"流间饿死"现象的代理 ground truth:
    低速率+持续, 排除单秒抖动。参数取 campaign 语境 (饿死=长期钉地板)。
    """
    with np.errstate(invalid="ignore"):
        med = np.nanmedian(mat_, axis=1, keepdims=True)
        low = mat_ < frac * med
    lab = np.zeros_like(mat_, dtype=bool)
    t, n = mat_.shape
    for j in range(n):
        run = 0
        for i in range(t):
            v = mat_[i, j]
            if not np.isnan(v) and low[i, j]:
                run += 1
            else:
                if run >= sustain:
                    lab[i - run : i, j] = True
                run = 0
        if run >= sustain:
            lab[t - run :, j] = True
    return lab


def episodes(lab_col: np.ndarray) -> list[tuple[int, int]]:
    """bool 列 → [(start, end)) 区间列表。"""
    out, start = [], None
    for i, v in enumerate(lab_col):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(lab_col)))
    return out


def merge_eps(eps: list[tuple[int, int]], gap: int = 5) -> list[tuple[int, int]]:
    """合并间隔 <gap 秒的相邻触发段 (单次事件抖动不算两次触发)。"""
    if not eps:
        return []
    out = [list(eps[0])]
    for a, b in eps[1:]:
        if a - out[-1][1] < gap:
            out[-1][1] = b
        else:
            out.append([a, b])
    return [tuple(e) for e in out]


def score_detection(true_eps: list[tuple[int, int]], det_eps: list[tuple[int, int]],
                    grace: int = 5) -> dict:
    """对每段真实事件: 是否在 [start, end+grace] 内有触发 → 延迟; 其余触发=误报。"""
    caught, delays = 0, []
    for ta, tb in true_eps:
        hit = [da for da, db in det_eps if da <= tb + grace and db > ta]
        if hit:
            caught += 1
            delays.append(max(0, min(da for da in hit) - ta))
    fp = [d for d in det_eps if not any(da <= tb + grace and db > ta for da, db in true_eps)]
    fp_seconds = sum(b - a for a, b in fp)
    return {
        "true": len(true_eps), "caught": caught,
        "delays": delays, "median_delay": float(np.median(delays)) if delays else None,
        "false_eps": len(fp), "false_seconds": int(fp_seconds),
    }


def prepare_round(name: str) -> dict:
    """round → {'m','ports','r','dead','dep30','slow'} (评估参照, 与检测器解耦)。"""
    m, ports = mat(load_round(name))
    with np.errstate(invalid="ignore"):
        r = m / np.nanmedian(m, axis=1, keepdims=True)
    lab = lambda frac, sus: starved_labels(m, frac=frac, sustain=sus)
    return {
        "name": name, "m": m, "ports": ports, "r": r,
        "dead": lab(0.25, 10),    # 重度: r<0.25 连续≥10s
        "dep30": lab(0.5, 30),    # 必须捕获的持续 depression: r<0.5 连续≥30s
        "slow": lab(0.5, 10),     # 轻度参考: r<0.5 连续≥10s
    }
