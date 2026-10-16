"""tcpboost-e18 原型: HMM + Viterbi 路径状态机的离线移植验证。

票面映射: 隐状态 OK/Slow/Dead; 票面观测是 RTT/loss, trace 只有吞吐 →
观测域映射 (报告 §2 记录):
  绝对形态 (遥测辅助上界): obs = r_t = rate/跨流中位数 — 隐含跨流信息,
                           单流内核拿不到, 作为"有遥测时能做多好"的上界。
  逐流形态 (内核可实现):   obs = r_t / trailing-max(r,300s) ≈ BBR bw/max_bw。
发射 (票面 state 定义映射到速率域): OK N(1.0,0.30²) Slow N(0.5,0.18²) Dead N(0.15,0.08²)。
基线: 票面所说"BBR 现行隐式启发式" = 单点阈值分段 (r≥0.5 OK, <0.25 Dead, 其余 Slow)。
"""
from __future__ import annotations

import numpy as np

STATES = ["OK", "Slow", "Dead"]
MU = np.array([1.0, 0.5, 0.15])
SD = np.array([0.30, 0.18, 0.08])
# 粘滞转移: 状态不易跳出, 退化可一步滑向更深
TRANS = np.array([
    [0.996, 0.003, 0.001],
    [0.006, 0.990, 0.004],
    [0.003, 0.007, 0.990],
])


def trailing_peak(x: np.ndarray, win: int = 300) -> np.ndarray:
    out = np.full(len(x), np.nan)
    for i in range(len(x)):
        w = x[max(0, i - win + 1):i + 1]
        w = w[~np.isnan(w)]
        if len(w):
            out[i] = w.max()
    return out


def _log_emis(x: np.ndarray) -> np.ndarray:
    """T×3 发射对数概率 (NaN 观测 → 三态均 0, 不更新)。"""
    out = np.zeros((len(x), 3))
    for k in range(3):
        z = (x - MU[k]) / SD[k]
        lp = -0.5 * z * z - np.log(SD[k]) - 0.5 * np.log(2 * np.pi)
        out[:, k] = np.where(np.isnan(x), 0.0, lp)
    return out


def viterbi(x: np.ndarray) -> np.ndarray:
    """全序列 Viterbi (离线上界); 返回逐秒状态索引 0/1/2。"""
    le = _log_emis(x)
    lt = np.log(TRANS)
    t = len(x)
    delta = le[0].copy()
    back = np.zeros((t, 3), dtype=int)
    for i in range(1, t):
        cand = delta[:, None] + lt  # prev×next
        back[i] = np.argmax(cand, axis=0)
        delta = cand[back[i], np.arange(3)] + le[i]
    path = np.zeros(t, dtype=int)
    path[-1] = int(np.argmax(delta))
    for i in range(t - 1, 0, -1):
        path[i - 1] = back[i, path[i]]
    return path


def online_state(x: np.ndarray) -> np.ndarray:
    """在线前向滤波 (逐步 argmax 预测后验; 固定 3 态, O(1) 每步, 内核可实现)。"""
    le = _log_emis(x)
    t = len(x)
    logp = np.full(3, -np.log(3))  # 均匀起始先验
    out = np.zeros(t, dtype=int)
    for i in range(t):
        j = logp + le[i]
        out[i] = int(np.argmax(j))
        j -= j.max()
        p = np.exp(j)
        logp = np.log((p / p.sum()) @ TRANS + 1e-300)
    return out


def heuristic_baseline(x: np.ndarray) -> np.ndarray:
    """单点阈值分段 (票面'现行隐式启发式')。"""
    st = np.zeros(len(x), dtype=int)
    st[(x >= 0.25) & (x < 0.5)] = 1
    st[x < 0.25] = 2
    return st


def evaluate(pr: dict, conf_out: dict | None = None) -> dict:
    """round prepare → 每检测器 {dep30/dead catch+delay, false-state 秒, fp_per_sh}。

    false-state 秒 = 真值 OK 而判 Slow/Dead 的秒; fp_per_sh = 该秒数/30 折算
    30s 动作桶 / 流时 (与 5pe 表 FP 口径近似可比)。
    """
    from common import episodes as ep

    det_funcs = {
        "hmm_viterbi_abs": viterbi,
        "hmm_online_abs": online_state,
        "hmm_viterbi_flow": lambda x: viterbi(x / np.maximum(trailing_peak(x), 1e-6)),
        "hmm_online_flow": lambda x: online_state(x / np.maximum(trailing_peak(x), 1e-6)),
        "heuristic_thr": heuristic_baseline,
    }
    r = pr["r"]
    n = r.shape[1]
    res: dict[str, dict] = {}
    for name, fn in det_funcs.items():
        agg = {"stream_hours": 0.0, "false_state_seconds": 0, "conf": np.zeros((3, 3), dtype=int)}
        for cls in ("dep30", "dead"):
            agg[cls] = {"true": 0, "caught": 0, "delays": []}
        for j in range(n):
            x = r[:, j]
            st = fn(x)
            true = np.zeros(len(x), dtype=int)
            true[pr["dep30"][:, j]] = 1
            true[pr["dead"][:, j]] = 2
            for a, b in zip(true, st):
                agg["conf"][a, b] += 1
            agg["stream_hours"] += len(x) / 3600.0
            agg["false_state_seconds"] += int(((true == 0) & (st != 0)).sum())
            for cls, want in (("dep30", 1), ("dead", 2)):
                eps_true = ep(pr[cls][:, j])
                agg[cls]["true"] += len(eps_true)
                for ta, tb in eps_true:
                    idx = np.where(st[ta:tb] >= want)[0]
                    if len(idx):
                        agg[cls]["caught"] += 1
                        agg[cls]["delays"].append(int(idx[0]))
        agg["fp_per_sh"] = round(agg["false_state_seconds"] / 30.0 / agg["stream_hours"], 3)
        if conf_out is not None:
            conf_out[name] = agg.pop("conf")
        else:
            agg.pop("conf")
        res[name] = agg
    return res
