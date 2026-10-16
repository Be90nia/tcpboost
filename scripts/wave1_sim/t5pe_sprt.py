"""tcpboost-5pe 原型: SPRT 序贯检验早判 (Wald 1945) 的离线移植验证。

观测域映射 (票面是 loss 域, trace 是吞吐域, 映射在报告 §2 记录):
  r_t = stream_t / median_all_streams(t)  (公平份额归一化速率比)
  H0: 瞬态抖动  r ~ N(1.0, sigma)      — 争抢噪声, 不动作
  H1: 持续退化  r ~ N(0.45, sigma)     — 应动作 (cut cwnd 类)
  sigma 滚动 MAD 估计; LLR 逐秒累积, |LLR| 越界即判并重置 (分段 SPRT)。
基线: 单点阈值 r<0.5 (票面要替代的 boolean thresh), 及 3 连续持久化版。
"""
from __future__ import annotations

import numpy as np

from common import episodes, merge_eps, score_detection

MU1 = 0.45
BOUNDS = {"log4": np.log(4.0), "log8": np.log(8.0), "log16": np.log(16.0)}


def rolling_sigma(x: np.ndarray, win: int = 300, floor: float | None = None) -> np.ndarray:
    """逐点过去 win 秒的滚动 MAD×1.4826。

    floor 缺省 = 全序列 MAD (争抢真实散布下限): σ 若取小常数, 瞬态抖动会
    伪积累 LLR (争抢噪声被当作拥塞证据) — batch-3 误触发的离线同构。
    """
    w = x[~np.isnan(x)]
    auto = 1.4826 * np.median(np.abs(w - np.median(w))) if len(w) else 0.5
    fl = max(auto, 1e-3) if floor is None else floor
    n = len(x)
    out = np.full(n, fl)
    for i in range(n):
        w = x[max(0, i - win):i + 1]
        w = w[~np.isnan(w)]
        if len(w) >= 30:
            out[i] = max(fl, 1.4826 * np.median(np.abs(w - np.median(w))))
    return out


def trailing_median(x: np.ndarray, win: int = 300) -> np.ndarray:
    """逐点过去 win 秒的滚动中位数 (含当前点), NaN 忽略。"""
    n = len(x)
    out = np.full(n, np.nan)
    for i in range(n):
        w = x[max(0, i - win + 1):i + 1]
        w = w[~np.isnan(w)]
        if len(w):
            out[i] = np.median(w)
    return out


def sprt_stream(r: np.ndarray, bound: float, sig: np.ndarray | None = None,
                self_ref: bool = False) -> np.ndarray:
    """单流 SPRT; 返回逐秒 bool: 接受 H1 (动作) 的秒。

    self_ref=False: H0 均值=1.0 (绝对公平份额, 可见跨流信息)。
    self_ref=True:  观测换为 r/自身过去300s中位 (仅本流信息, 内核可实现形态),
                    检测"相对自己水位的持续下坠", 不检测稳态低份额。
    """
    if self_ref:
        r = r / trailing_median(r)
        sig = None  # 变换后重算
    if sig is None:
        sig = rolling_sigma(r)
    n = len(r)
    llr = 0.0
    act = np.zeros(n, dtype=bool)
    for t in range(n):
        v = r[t]
        if np.isnan(v):
            continue
        s = sig[t]
        llr += (-(v - MU1) ** 2 + (v - 1.0) ** 2) / (2 * s * s)
        if llr >= bound:
            act[t] = True
            llr = 0.0
        elif llr <= -bound:
            llr = 0.0
    return act


def baseline_single(r: np.ndarray, thr: float = 0.5) -> np.ndarray:
    return np.where(np.isnan(r), False, r < thr)


def baseline_persist(r: np.ndarray, thr: float = 0.5, k: int = 3) -> np.ndarray:
    low = baseline_single(r)
    out = np.zeros(len(r), dtype=bool)
    run = 0
    for i, v in enumerate(low):
        run = run + 1 if v else 0
        # 在线忠实: 仅在第 k 个连续低采样秒动作, 不回填 (延迟列才真实)
        if run >= k:
            out[i] = True
    return out


def evaluate(round_r: dict[int, np.ndarray], labels: dict) -> dict:
    """round_r: port→r 序列; labels: {'dep30','dead'} port→bool 矩阵 (common.prepare_round)。

    事件类: dep30 (持续≥30s depression, 必须捕获) 与 dead (重度饿死)。
    触发段按 gap=30s 合并 (30s 粒度契约: 同一事件内反复动作只算一次检测)。
    """
    res: dict[str, dict] = {}
    det_funcs = {
        "sprt_log4": lambda r, s=None: sprt_stream(r, BOUNDS["log4"], s),
        "sprt_log8": lambda r, s=None: sprt_stream(r, BOUNDS["log8"], s),
        "sprt_log16": lambda r, s=None: sprt_stream(r, BOUNDS["log16"], s),
        "sprt8_self": lambda r, s=None: sprt_stream(r, BOUNDS["log8"], s, self_ref=True),
        "sprt16_self": lambda r, s=None: sprt_stream(r, BOUNDS["log16"], s, self_ref=True),
        "base_single": lambda r, s=None: baseline_single(r),
        "base_persist3": lambda r, s=None: baseline_persist(r, k=3),
        "base_persist5": lambda r, s=None: baseline_persist(r, k=5),
        "base_persist10": lambda r, s=None: baseline_persist(r, k=10),
    }
    ports = sorted(round_r)
    for name, fn in det_funcs.items():
        agg = {"delays": [], "stream_hours": 0.0}
        for cls in ("dep30", "dead"):
            agg[cls] = {"true": 0, "caught": 0}
        for j, port in enumerate(ports):
            r = round_r[port]
            act = fn(r, rolling_sigma(r))
            det = merge_eps(episodes(act), gap=30)
            agg["stream_hours"] += len(r) / 3600.0
            for cls in ("dep30", "dead"):
                true_eps = episodes(labels[cls][:, j])
                sc = score_detection(true_eps, det)
                agg[cls]["true"] += sc["true"]
                agg[cls]["caught"] += sc["caught"]
                if cls == "dep30":
                    agg["delays"] += sc["delays"]
                    agg["false_eps"] = agg.get("false_eps", 0) + sc["false_eps"]
                    agg["false_seconds"] = agg.get("false_seconds", 0) + sc["false_seconds"]
        agg["fp_per_sh"] = round(agg.get("false_eps", 0) / agg["stream_hours"], 3)
        agg["median_delay"] = float(np.median(agg["delays"])) if agg["delays"] else None
        res[name] = agg
    return res
