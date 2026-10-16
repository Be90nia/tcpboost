"""tcpboost-b9z 原型: HMM(coarse) + SPRT(fine) 分层决策的离线移植验证。

架构 (票面): L1 HMM → 全局 context (OK/Slow/Dead); L2 SPRT within state → 实时早判。
离线实现:
  L1 = e18 steelman 在线滤波态 (EM 发射参数 + 慢自参照 1800s, e18 的最强形态)
  L2 = 自参照 SPRT (sprt8_self 逻辑), 仅当 L1 ∉ OK 时累积 LLR, 复位在 L1=OK
  动作 = L1 ∉ OK 且 LLR ≥ log8 (两层一致才动作)
对照组: L1-only (状态≠OK 即动作), L2-only (无门控 SPRT), 组合。
"""
from __future__ import annotations

import numpy as np

import e18_hmm
import t5pe_sprt as t5
from t5pe_sprt import BOUNDS, trailing_median

EMIT_MU = np.array([0.976, 0.44, 0.13])
EMIT_SD = np.array([0.205, 0.107, 0.06])


def l1_state(x: np.ndarray, win: int = 1800) -> np.ndarray:
    """在线前向滤波, EM 参数发射 + 慢自参照观测 (b9z 的 L1)。"""
    ref = t5.trailing_median(x, win=win)
    q = x / np.maximum(ref, 0.05)
    le = np.zeros((len(q), 3))
    for k in range(3):
        z = (q - EMIT_MU[k]) / EMIT_SD[k]
        lp = -0.5 * z * z - np.log(EMIT_SD[k]) - 0.5 * np.log(2 * np.pi)
        le[:, k] = np.where(np.isnan(q), 0.0, lp)
    lt = np.log(e18_hmm.TRANS)
    logp = np.full(3, -np.log(3))
    out = np.zeros(len(q), dtype=int)
    for i in range(len(q)):
        j = logp + le[i]
        out[i] = int(np.argmax(j))
        j -= j.max()
        p = np.exp(j)
        logp = np.log((p / p.sum()) @ e18_hmm.TRANS + 1e-300)
    return out


def l2_sprt_gated(x: np.ndarray, state: np.ndarray, bound: float = BOUNDS["log8"]) -> np.ndarray:
    """L2 SPRT: 仅在 L1 非态 OK 时累积; 动作 = 门开 且 LLR 过界。"""
    q = x / np.maximum(trailing_median(x), 0.05)
    sig = t5.rolling_sigma(q)
    n = len(q)
    act = np.zeros(n, dtype=bool)
    llr = 0.0
    for i in range(n):
        v = q[i]
        if np.isnan(v):
            continue
        if state[i] == 0:  # L1 说 OK → 关门并复位
            llr = 0.0
            continue
        s = sig[i]
        llr += (-(v - t5.MU1) ** 2 + (v - 1.0) ** 2) / (2 * s * s)
        if llr >= bound:
            act[i] = True
            llr = 0.0
        elif llr <= -bound:
            llr = 0.0
    return act


def evaluate(pr: dict) -> dict:
    from common import episodes, merge_eps, score_detection

    r, n = pr["r"], pr["r"].shape[1]
    res: dict[str, dict] = {}
    for name in ("l1_only", "l2_only", "hier"):
        res[name] = {"stream_hours": 0.0, "false_eps": 0, "false_seconds": 0, "delays": [],
                     "dep30": {"true": 0, "caught": 0}, "dead": {"true": 0, "caught": 0}}
    for j in range(n):
        x = r[:, j]
        st = l1_state(x)
        l1_act = (st != 0).astype(bool)
        l2_act = l2_sprt_gated(x, np.ones(len(x), dtype=int))  # 门全开 = L2-only
        hier_act = l2_sprt_gated(x, st)
        acts = {"l1_only": l1_act, "l2_only": l2_act, "hier": hier_act}
        sh = len(x) / 3600.0
        for nm, act in acts.items():
            a = res[nm]
            a["stream_hours"] += sh
            det = merge_eps(episodes(act), gap=30)
            for cls in ("dep30", "dead"):
                eps_true = episodes(pr[cls][:, j])
                a[cls]["true"] += len(eps_true)
                sc = score_detection(eps_true, det)
                a[cls]["caught"] += sc["caught"]
                if cls == "dep30":
                    a["delays"] += sc["delays"]
                    a["false_eps"] += sc["false_eps"]
                    a["false_seconds"] += sc["false_seconds"]
    for nm, a in res.items():
        a["fp_per_sh"] = round(a["false_eps"] / a["stream_hours"], 3)
        a["median_delay"] = float(np.median(a["delays"])) if a["delays"] else None
    return res
