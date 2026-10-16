"""
Strategy engine combining 8-EMA Ribbon, Supertrend, FVG, Liquidity Sweeps, and VWAP.
"""
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

from config import Config

WARMUP = 100


def _wilder(s: pd.Series, n: int) -> pd.Series:
    return s.ewm(alpha=1 / n, adjust=False).mean()


def _supertrend_dir(d: pd.DataFrame, tr: pd.Series, period: int, mult: float) -> np.ndarray:
    atr = _wilder(tr, period).values
    hl2 = ((d["high"] + d["low"]) / 2).values
    close = d["close"].values
    upper, lower = hl2 + mult * atr, hl2 - mult * atr
    fu, fl = upper.copy(), lower.copy()
    direction = np.ones(len(d))
    for i in range(1, len(d)):
        fu[i] = upper[i] if (upper[i] < fu[i - 1] or close[i - 1] > fu[i - 1]) else fu[i - 1]
        fl[i] = lower[i] if (lower[i] > fl[i - 1] or close[i - 1] < fl[i - 1]) else fl[i - 1]
        direction[i] = direction[i - 1]
        if direction[i - 1] == 1 and close[i] < fl[i]:
            direction[i] = -1
        elif direction[i - 1] == -1 and close[i] > fu[i]:
            direction[i] = 1
    return direction


def _htf_direction(df: pd.DataFrame, cfg: Config) -> pd.Series:
    if not cfg.htf_filter:
        return pd.Series(0, index=df.index)
    o = df.resample(f"{cfg.htf_min}min", label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    if len(o) < 55:
        return pd.Series(0, index=df.index)
    e21 = o["close"].ewm(span=21, adjust=False).mean()
    e50 = o["close"].ewm(span=50, adjust=False).mean()
    dirn = np.where((e21 > e50) & (o["close"] > e21), 1, np.where((e21 < e50) & (o["close"] < e21), -1, 0))
    htf = pd.DataFrame({"ready": o.index + pd.Timedelta(minutes=cfg.htf_min), "dir": dirn}).sort_values("ready")
    base = pd.DataFrame({"t": df.index + pd.Timedelta(minutes=cfg.tf_min)})
    merged = pd.merge_asof(base, htf, left_on="t", right_on="ready", direction="backward")
    return pd.Series(merged["dir"].fillna(0).values, index=df.index)


def prepare(df: pd.DataFrame, cfg: Config) -> pd.DataFrame:
    d = df.copy()
    c, h, l = d["close"], d["high"], d["low"]
    pc = c.shift()
    tr = pd.concat([h - l, (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)

    d["atr"] = _wilder(tr, cfg.atr_len)

    # 8-EMA Ribbon
    emas = [c.ewm(span=l, adjust=False).mean() for l in cfg.ema_lens]
    for idx, e in enumerate(emas, 1):
        d[f"ema_{idx}"] = e

    bull_count = pd.Series(0.0, index=d.index)
    for i in range(len(emas) - 1):
        bull_count += (emas[i] > emas[i+1]).astype(float)
    d["ribbon_strength"] = bull_count / (len(emas) - 1)

    # Fair Value Gaps
    d["bull_fvg"] = (d["low"] > d["high"].shift(2)) & ((d["low"] - d["high"].shift(2)) >= d["atr"] * cfg.fvg_min_atr)
    d["bear_fvg"] = (d["high"] < d["low"].shift(2)) & ((d["low"].shift(2) - d["high"]) >= d["atr"] * cfg.fvg_min_atr)

    # Swing structure & Sweeps
    d["swing_lo"] = l.rolling(cfg.swing_lookback).min()
    d["swing_hi"] = h.rolling(cfg.swing_lookback).max()
    d["bull_sweep"] = (l < d["swing_lo"].shift(1)) & (c > d["swing_lo"].shift(1))
    d["bear_sweep"] = (h > d["swing_hi"].shift(1)) & (c < d["swing_hi"].shift(1))

    # Momentum & Trend Strength
    delta = c.diff()
    up = _wilder(delta.clip(lower=0), cfg.rsi_len)
    dn = _wilder((-delta.clip(upper=0)), cfg.rsi_len)
    d["rsi"] = 100 - 100 / (1 + up / dn.replace(0, np.nan))

    up_move, dn_move = h.diff(), -l.diff()
    pdm = pd.Series(np.where((up_move > dn_move) & (up_move > 0), up_move, 0.0), index=d.index)
    mdm = pd.Series(np.where((dn_move > up_move) & (dn_move > 0), dn_move, 0.0), index=d.index)
    atr14 = _wilder(tr, 14)
    d["pdi"] = 100 * _wilder(pdm, 14) / atr14
    d["mdi"] = 100 * _wilder(mdm, 14) / atr14
    dx = 100 * (d["pdi"] - d["mdi"]).abs() / (d["pdi"] + d["mdi"]).replace(0, np.nan)
    d["adx"] = _wilder(dx.fillna(0), 14)

    d["st_dir"] = _supertrend_dir(d, tr, 10, max(1.0, 3.5 - 0.2 * cfg.sensitivity))

    typical = (h + l + c) / 3
    vol = d["volume"].where(d["volume"] > 0, 1.0)
    day = d.index.normalize()
    d["vwap"] = (typical * vol).groupby(day).cumsum() / vol.groupby(day).cumsum()

    d["htf_dir"] = _htf_direction(d, cfg)
    return d


@dataclass
class Signal:
    ts: pd.Timestamp
    side: str
    entry: float
    sl: float
    tp1: float
    tp2: float
    tp3: float
    score: int
    atr: float
    reasons: list = field(default_factory=list)


def signal_at(d: pd.DataFrame, i: int, cfg: Config) -> Optional[Signal]:
    if i < WARMUP:
        return None
    row, prev, ts = d.iloc[i], d.iloc[i - 1], d.index[i]
    if ts.weekday() >= 5:
        return None

    atr = float(row["atr"])
    if not np.isfinite(atr) or atr < cfg.min_atr:
        return None

    adx_min = max(10.0, 25.0 - 2.0 * cfg.sensitivity)
    best = None

    for side, s in (("BUY", 1), ("SELL", -1)):
        if (s == 1 and row["rsi"] >= cfg.rsi_ob) or (s == -1 and row["rsi"] <= cfg.rsi_os):
            continue

        score, why = 0, []

        # 1. 8-EMA Ribbon Alignment (up to 30 pts)
        strength = row["ribbon_strength"] if s == 1 else (1.0 - row["ribbon_strength"])
        if strength >= 0.5:
            score += 30
            why.append(f"8-EMA Ribbon aligned ({strength*100:.0f}%)")
        elif strength >= 0.3:
            score += 15
            why.append(f"8-EMA Ribbon partial alignment ({strength*100:.0f}%)")

        # 2. Supertrend (20 pts)
        if row["st_dir"] == s:
            score += 20
            why.append("Supertrend direction agrees")

        # 3. Higher-Timeframe Trend (20 pts)
        if cfg.htf_filter and row["htf_dir"] == s:
            score += 20
            why.append(f"{cfg.htf_min}m trend aligned")

        # 4. Smart Money FVG / Sweeps (Bonus up to 20 pts)
        if s == 1 and row["bull_fvg"]:
            score += 15
            why.append("Bullish FVG imbalance retest")
        elif s == -1 and row["bear_fvg"]:
            score += 15
            why.append("Bearish FVG imbalance retest")

        if s == 1 and row["bull_sweep"]:
            score += 15
            why.append("Liquidity sweep & reclaim")
        elif s == -1 and row["bear_sweep"]:
            score += 15
            why.append("Liquidity sweep & reclaim")

        # 5. VWAP & ADX (10 pts)
        if s * (row["close"] - row["vwap"]) > 0:
            score += 10
            why.append("Right side of VWAP")

        if score >= cfg.min_score and (best is None or score > best[0]):
            best = (score, side, s, why)

    if not best:
        return None
    score, side, s, why = best
    entry = float(row["close"])
    risk = cfg.sl_mult * atr
    if cfg.use_swing_sl:
        struct = (entry - row["swing_lo"]) if s == 1 else (row["swing_hi"] - entry)
        risk = min(cfg.sl_mult * atr, max(0.8 * atr, float(struct) + 0.2 * atr))
    r2 = lambda x: round(float(x), 2)
    return Signal(ts=ts, side=side, entry=r2(entry), sl=r2(entry - s * risk),
                  tp1=r2(entry + s * cfg.tp1_mult * atr), tp2=r2(entry + s * cfg.tp2_mult * atr),
                  tp3=r2(entry + s * cfg.tp3_mult * atr), score=int(score), atr=r2(atr), reasons=why)


def evaluate(df: pd.DataFrame, cfg: Config) -> Optional[Signal]:
    d = prepare(df, cfg)
    return signal_at(d, len(d) - 1, cfg)


def simulate(trade: dict, bars: pd.DataFrame, cfg: Config) -> dict:
    s = 1 if trade["side"] == "BUY" else -1
    entry, risk = trade["entry"], abs(trade["entry"] - trade["sl"])
    tps = [trade["tp1"], trade["tp2"], trade["tp3"]]
    sl_cur, legs, stage, banked = trade["sl"], 3, 0, 0.0
    status, events, used = "OPEN", [], 0

    for i, (t, b) in enumerate(bars.iterrows(), 1):
        used = i
        if (b["low"] <= sl_cur) if s == 1 else (b["high"] >= sl_cur):
            banked += (legs / 3) * s * (sl_cur - entry) / risk
            status = "BE" if sl_cur == entry else "SL"
            events.append(status)
            legs = 0
            break
        while stage < 3 and ((b["high"] >= tps[stage]) if s == 1 else (b["low"] <= tps[stage])):
            banked += (1 / 3) * s * (tps[stage] - entry) / risk
            legs -= 1
            stage += 1
            events.append(f"TP{stage}")
            if stage == 1 and cfg.be_after_tp1:
                sl_cur = entry
        if stage == 3:
            status, legs = "TP3", 0
            break
        if i >= cfg.expiry_bars:
            banked += (legs / 3) * s * (b["close"] - entry) / risk
            status, legs = "EXPIRED", 0
            events.append(status)
            break

    return {"status": status, "stage": stage, "events": events, "bars_used": used,
            "r": round(banked, 3) if status != "OPEN" else None}