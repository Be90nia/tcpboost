"""tcpboost-3wi 原型: cp-1 (mercury change-point) 争抢感知证据重设计的离线验证。

batch-3 REJECT 尸检 (票面): 8 流争抢下 bw 3σ 波动是常态 + min_rtt 窗口过期上移
>10%, 双证据 AND 频繁误触发 (min 流 -63% 自锁, total -20%)。

离线范围 (报告 §2 记录): 证据 B (min_rtt +10%) 无法离线复现 (trace 无 RTT),
只评价证据 A 链 (bw 突降) 及其重设计:
  old_A      : r < mean30 - 3σ30 (普通均值/方差, 忠实复刻票面 3σ 语义)
  resid_k4_5o7 : 残差滤波 — r < med30 - 4·1.4826·MAD30, 7 秒内 5 中 (持久化替代第二证据)
  gated_8o10   : 争抢门控 — 残差滤波, 但跨流离散 (CV30) > 阈值时加严到 10 秒 8 中
                   (PROBE_BW 争抢态禁触发的离线同构)
真值: dep30 段起点 = 真实 change-point; 其余触发 = 误触发 (batch-3 的失效模式)。
"""
from __future__ import annotations

import numpy as np

from common import episodes, merge_eps, score_detection


def rolling_mean_sd(x: np.ndarray, win: int = 30) -> tuple[np.ndarray, np.ndarray]:
    n = len(x)
    mu = np.full(n, np.nan)
    sd = np.full(n, np.nan)
    for i in range(n):
        w = x[max(0, i - win):i]
        w = w[~np.isnan(w)]
        if len(w) >= 15:
            mu[i] = w.mean()
            sd[i] = w.std()
    return mu, sd


def rolling_med_mad(x: np.ndarray, win: int = 30) -> tuple[np.ndarray, np.ndarray]:
    n = len(x)
    med = np.full(n, np.nan)
    mad = np.full(n, np.nan)
    for i in range(n):
        w = x[max(0, i - win):i]
        w = w[~np.isnan(w)]
        if len(w) >= 15:
            med[i] = np.median(w)
            mad[i] = 1.4826 * np.median(np.abs(w - np.median(w)))
    return med, mad


def cross_cv(rmat: np.ndarray, win: int = 30) -> np.ndarray:
    """跨流离散度: 每秒过去 win 秒各流均值的 CV (争抢态门控信号)。"""
    with np.errstate(invalid="ignore"):
        m = np.nanmean(rmat, axis=1)
    n = len(m)
    out = np.full(n, np.nan)
    for i in range(n):
        w = m[max(0, i - win):i + 1]
        w = w[~np.isnan(w)]
        if len(w) >= 10 and w.mean() > 0:
            out[i] = w.std() / w.mean()
    return out


def k_of_window(viol: np.ndarray, k: int, win: int) -> np.ndarray:
    """过去 win 秒内 ≥k 次违例 → 触发 (在线因果窗)。"""
    c = np.cumsum(np.concatenate([[0], viol.astype(int)]))
    n = len(viol)
    out = np.zeros(n, dtype=bool)
    for i in range(n):
        lo = max(0, i - win + 1)
        if c[i + 1] - c[lo] >= k:
            out[i] = True
    return out


def old_A(r: np.ndarray) -> np.ndarray:
    mu, sd = rolling_mean_sd(r)
    thr = mu - 3 * np.maximum(sd, 1e-6)
    return np.where(np.isnan(thr), False, r < thr)


def resid_k4_5o7(r: np.ndarray, kmult: float = 4.0) -> np.ndarray:
    med, mad = rolling_med_mad(r)
    viol = np.where(np.isnan(med), False, r < med - kmult * np.maximum(mad, 0.02))
    return k_of_window(viol, 5, 7)


def gated_8o10(r: np.ndarray, rmat: np.ndarray, cv_hi: float = 0.45) -> np.ndarray:
    med, mad = rolling_med_mad(r)
    viol = np.where(np.isnan(med), False, r < med - 4.0 * np.maximum(mad, 0.02))
    cv = cross_cv(rmat)
    easy = k_of_window(viol, 5, 7)
    hard = k_of_window(viol, 8, 10)
    gate = np.where(np.isnan(cv), True, cv <= cv_hi)  # CV 缺失按低争抢处理
    return np.where(gate, easy, hard)


def evaluate(pr: dict) -> dict:
    rmat, n, ports = pr["r"], pr["r"].shape[0], pr["r"].shape[1]
    cv = cross_cv(rmat)
    cv_hi = float(np.nanquantile(cv, 0.75))  # 争抢阈值 = CV75 分位 (数据驱动)
    res: dict[str, dict] = {}
    for name, fn in (("old_A", old_A), ("resid_4of7", resid_k4_5o7),
                     ("gated_8of10", lambda x: gated_8o10(x, rmat, cv_hi))):
        agg = {"stream_hours": 0.0, "false_eps": 0, "false_seconds": 0, "delays": [],
               "dep30": {"true": 0, "caught": 0}, "dead": {"true": 0, "caught": 0}}
        for j in range(ports):
            x = rmat[:, j]
            det = merge_eps(episodes(fn(x)), gap=30)
            agg["stream_hours"] += len(x) / 3600.0
            for cls in ("dep30", "dead"):
                eps_true = episodes(pr[cls][:, j])
                agg[cls]["true"] += len(eps_true)
                sc = score_detection(eps_true, det)
                agg[cls]["caught"] += sc["caught"]
                if cls == "dep30":
                    agg["delays"] += sc["delays"]
                    agg["false_eps"] += sc["false_eps"]
                    agg["false_seconds"] += sc["false_seconds"]
        agg["fp_per_sh"] = round(agg["false_eps"] / agg["stream_hours"], 3)
        agg["median_delay"] = float(np.median(agg["delays"])) if agg["delays"] else None
        res[name] = agg
    res["_cv_hi"] = round(cv_hi, 3)
    return res
