"""
Analyse the CSV written by ScalpEngine or MomentumScalper
(MQL5/Files/ScalpEngine_<symbol>.csv or MomentumScalper_<symbol>.csv).

    python mt5/analyze_trades.py MomentumScalper_BTCUSDm.csv

Prints expectancy in R (risk units) overall, per setup, per exit reason and per
hour, plus MFE/MAE so you can tell whether the trail is too tight or the stop
too wide. Judge nothing with fewer than ~300 trades.
"""
import sys

import pandas as pd


def summarize(df: pd.DataFrame) -> pd.Series:
    wins = df[df.pnl > 0]
    losses = df[df.pnl <= 0]
    gross_loss = -losses.pnl.sum()
    return pd.Series({
        "trades": len(df),
        "win%": 100 * len(wins) / len(df) if len(df) else 0,
        "avg_R": df.r.mean(),
        "avg_win_R": wins.r.mean(),
        "avg_loss_R": losses.r.mean(),
        "profit_factor": wins.pnl.sum() / gross_loss if gross_loss > 0 else float("inf"),
        "net_pnl": df.pnl.sum(),
    })


def main(path: str) -> None:
    df = pd.read_csv(path, parse_dates=["open_time", "close_time"])
    if df.empty:
        print("No trades yet.")
        return
    sign = df.side.map({"long": 1, "short": -1})
    df["r"] = (df.exit - df.entry) * sign / df.risk
    df["mfe_r"] = df.mfe / df.risk
    df["mae_r"] = df.mae / df.risk
    df["spread_r"] = df.spread / df.risk
    df["hour"] = df.open_time.dt.hour

    pd.set_option("display.width", 140)
    pd.set_option("display.float_format", "{:.2f}".format)

    print(f"\n=== {path}: {len(df)} trades, {df.open_time.min()} to {df.close_time.max()} ===")
    print(summarize(df).to_string())
    if len(df) < 300:
        print(f"\n!! Only {len(df)} trades: too few to trust any of this.")

    print("\n--- by setup ---")
    print(df.groupby("setup").apply(summarize, include_groups=False))
    print("\n--- by exit reason ---")
    print(df.groupby("exit_reason").apply(summarize, include_groups=False))
    print("\n--- by side ---")
    print(df.groupby("side").apply(summarize, include_groups=False))
    print("\n--- by hour (server time) ---")
    print(df.groupby("hour").apply(summarize, include_groups=False)[["trades", "win%", "avg_R", "net_pnl"]])

    print("\n--- costs and excursions (in R) ---")
    print(f"spread at entry      : {df.spread_r.mean():.2f} R on average")
    print(f"winners peaked at    : {df[df.r > 0].mfe_r.mean():.2f} R, kept {df[df.r > 0].r.mean():.2f} R")
    went_green = df[(df.r <= 0) & (df.mfe_r >= 0.5)]
    print(f"losers that were +0.5R first: {len(went_green)} of {(df.r <= 0).sum()}"
          " (many = break-even/trail start too late)")
    print(f"stopped out          : {(df.exit_reason == 'stop').mean() * 100:.0f}% of trades")

    print("\n--- does the signal strength matter? (avg R by quartile) ---")
    for col in ("flow_imb", "speed_x", "book_imb", "room_r"):
        if col not in df:
            continue
        x = df[col].abs() if col in ("flow_imb", "book_imb") else df[col]
        if x.nunique() < 4:
            continue
        q = pd.qcut(x, 4, duplicates="drop")
        print(f"{col}:")
        print(df.groupby(q, observed=True).r.agg(["count", "mean"]).to_string())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
