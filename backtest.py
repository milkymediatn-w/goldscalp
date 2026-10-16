"""
Backtest the live strategy on historical candles from your configured data source.
Same code path as the bot: prepare() -> signal_at() -> simulate(). Results are net of spread.

    python backtest.py                 # uses PRESET / DATA_SOURCE from .env
    BARS=20000 python backtest.py      # more history (MT5 can serve tens of thousands of bars)
"""
import os

import numpy as np
import pandas as pd
from dotenv import load_dotenv

load_dotenv()
from config import load_config      # noqa: E402
from data import get_candles        # noqa: E402
from strategy import WARMUP, prepare, signal_at, simulate   # noqa: E402


def run(df: pd.DataFrame, cfg) -> pd.DataFrame:
    d = prepare(df, cfg)
    trades, i = [], WARMUP
    while i < len(d) - 1:
        sig = signal_at(d, i, cfg)
        if not sig:
            i += 1
            continue
        t = dict(side=sig.side, entry=sig.entry, sl=sig.sl, tp1=sig.tp1, tp2=sig.tp2, tp3=sig.tp3)
        res = simulate(t, d.iloc[i + 1:], cfg)
        if res["status"] == "OPEN":
            break  # ran out of data
        risk = abs(sig.entry - sig.sl)
        net = res["r"] - cfg.assumed_spread / risk
        trades.append(dict(time=sig.ts, side=sig.side, score=sig.score, status=res["status"],
                           stage=res["stage"], risk_usd=round(risk, 2), r=round(net, 3)))
        i += max(cfg.cooldown_bars, res["bars_used"])   # one trade at a time, like the live bot
    return pd.DataFrame(trades)


def report(t: pd.DataFrame, days: float):
    if t.empty:
        print("No trades generated.")
        return
    r = t["r"]
    eq = r.cumsum()
    dd = (eq.cummax() - eq).max()
    gl = -r[r < 0].sum()
    print(f"\nTrades: {len(t)}  ({len(t) / max(days, 1):.1f}/day)")
    print(f"Win rate: {(r > 0).mean() * 100:.1f}%   Profit factor: {r[r > 0].sum() / gl if gl else float('inf'):.2f}")
    print(f"Total: {r.sum():+.1f}R   Avg/trade: {r.mean():+.3f}R   Max drawdown: {dd:.1f}R")
    print(f"TP1 reached: {(t.stage >= 1).mean() * 100:.0f}%   TP2: {(t.stage >= 2).mean() * 100:.0f}%   TP3: {(t.stage >= 3).mean() * 100:.0f}%")
    print("\nBy score bucket:")
    t["bucket"] = pd.cut(t["score"], [0, 69, 74, 79, 84, 100], labels=["65-69", "70-74", "75-79", "80-84", "85+"])
    print(t.groupby("bucket", observed=True)["r"].agg(["count", "mean", "sum"]).round(3))
    print("\nBy side:")
    print(t.groupby("side")["r"].agg(["count", "mean", "sum"]).round(3))


if __name__ == "__main__":
    cfg = load_config()
    if os.getenv("BARS"):
        cfg.bars = int(os.environ["BARS"])
    print(cfg.summary())
    feed = get_candles(cfg)
    df = feed.df
    days = (df.index[-1] - df.index[0]).total_seconds() / 86400
    print(f"{len(df)} candles, {days:.0f} days, spread assumed ${feed.spread if feed.spread else cfg.assumed_spread:.2f}")
    if feed.spread:
        cfg.assumed_spread = feed.spread
    trades = run(df, cfg)
    report(trades, days)
    trades.to_csv("backtest_trades.csv", index=False)
    print("\nSaved backtest_trades.csv")
    print("Caution: one backtest on one period proves little. Check different months and regimes,")
    print("and don't tune parameters until the results look good (that's just overfitting).")
